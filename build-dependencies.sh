#!/usr/bin/env bash
# TIDESDB_CROSS_PLATFORM_PATCH=1
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
GENERATED_RESOURCES_DIR="$PROJECT_DIR/build/generated-resources"
WORKSPACE_DIR="$PROJECT_DIR/workspace"

TIDESDB_SRC="$WORKSPACE_DIR/tidesdb"
TIDESDB_JAVA_SRC="$WORKSPACE_DIR/tidesdb-java"
ZSTD_SRC="$WORKSPACE_DIR/zstd"
LZ4_SRC="$WORKSPACE_DIR/lz4"
SNAPPY_SRC="$WORKSPACE_DIR/snappy"

TIDESDB_BUILD="$WORKSPACE_DIR/tidesdb-build"
JNI_BUILD="$WORKSPACE_DIR/jni-build"
ZSTD_BUILD="$WORKSPACE_DIR/zstd-build"
LZ4_BUILD="$WORKSPACE_DIR/lz4-build"
SNAPPY_BUILD="$WORKSPACE_DIR/snappy-build"
DEPS_INSTALL="$WORKSPACE_DIR/deps-install"
TIDESDB_INSTALL="$WORKSPACE_DIR/tidesdb-install"

OS="$(uname -s)"
MACHINE_ARCH="$(uname -m)"

case "$MACHINE_ARCH" in
  x86_64|amd64) RESOURCE_ARCH="x86_64" ;;
  arm64|aarch64) RESOURCE_ARCH="aarch64" ;;
  *) echo "[PREFLIGHT] FAIL: unsupported architecture: $MACHINE_ARCH"; exit 1 ;;
esac

case "$OS" in
  Linux)
    PLATFORM="linux-$RESOURCE_ARCH"
    CORE_LIB="libtidesdb.so"
    JNI_LIB="libtidesdb_jni.so"
    ;;
  Darwin)
    PLATFORM="macos-$RESOURCE_ARCH"
    CORE_LIB="libtidesdb.dylib"
    JNI_LIB="libtidesdb_jni.dylib"
    ;;
  *)
    echo "[PREFLIGHT] FAIL: unsupported operating system: $OS"
    exit 1
    ;;
esac

NATIVE_RESOURCE_DIR="$GENERATED_RESOURCES_DIR/native/$PLATFORM"

log() { printf '[%s] %s\n' "$(date -u +%T)" "$*"; }
phase() { echo ""; echo "===[ $(date -u +%T) ] $* ==="; }
trap 'log "Command failed (line $LINENO): $BASH_COMMAND"' ERR

empty_workspace() {
  log "Creating/emptying $WORKSPACE_DIR"
  mkdir -p "$WORKSPACE_DIR"
  find "$WORKSPACE_DIR" -mindepth 1 -delete
}
trap empty_workspace EXIT

empty_build() {
  log "Creating/emptying $PROJECT_DIR/build"
  rm -rf "$PROJECT_DIR/build"
  mkdir -p "$PROJECT_DIR/build"
}

empty_build
empty_workspace

preflight() {
  local errors=0
  local missing=()

  check_cmd() {
    local cmd="$1"
    local label="${2:-$1}"
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "[PREFLIGHT] MISSING: $label ($cmd)"
      missing+=("$label ($cmd)")
      errors=$((errors + 1))
    fi
  }

  echo "[PREFLIGHT] Host: $(uname -a)"
  echo "[PREFLIGHT] Target classifier: $PLATFORM"

  check_cmd bash Bash
  check_cmd git Git
  check_cmd cmake CMake
  check_cmd ninja Ninja
  check_cmd file file
  check_cmd tar tar
  check_cmd curl curl
  check_cmd java Java
  check_cmd javac javac
  check_cmd jar jar

  if [[ "$OS" == "Darwin" ]]; then
    check_cmd clang Clang
    check_cmd clang++ Clang++
    check_cmd ar ar
    check_cmd ranlib ranlib
    check_cmd otool otool
    check_cmd install_name_tool install_name_tool
    check_cmd shasum shasum
    export CC="${CC:-clang}"
    export CXX="${CXX:-clang++}"
  else
    check_cmd gcc GCC
    check_cmd g++ G++
    check_cmd ld "GNU ld"
    check_cmd ar "GNU ar"
    check_cmd ranlib ranlib
    check_cmd readelf readelf
    check_cmd ldd ldd
    check_cmd patchelf patchelf
    check_cmd sha256sum sha256sum
    export CC="${CC:-gcc}"
    export CXX="${CXX:-g++}"
  fi

  local cmake_major cmake_minor
  cmake_major="$(cmake --version 2>/dev/null | sed -nE 's/^cmake version ([0-9]+)\.([0-9]+).*/\1/p' | head -1)"
  cmake_minor="$(cmake --version 2>/dev/null | sed -nE 's/^cmake version ([0-9]+)\.([0-9]+).*/\2/p' | head -1)"
  if [[ -z "$cmake_major" || -z "$cmake_minor" ]] ||
     (( cmake_major < 3 || (cmake_major == 3 && cmake_minor < 25) )); then
    echo "[PREFLIGHT] FAIL: CMake >= 3.25 required"
    errors=$((errors + 1))
  fi

  local java_ver
  java_ver="$(java -version 2>&1 | head -1 | sed -E 's/.*version "([0-9]+).*/\1/' || echo 0)"
  if [[ ! "$java_ver" =~ ^[0-9]+$ ]] || (( java_ver < 11 )); then
    echo "[PREFLIGHT] FAIL: Java >= 11 required"
    errors=$((errors + 1))
  fi

  [[ -f "$PROJECT_DIR/dependencies.properties" ]] || {
    echo "[PREFLIGHT] FAIL: dependencies.properties not found"
    errors=$((errors + 1))
  }

  local free_kb
  free_kb="$(df -k "$PROJECT_DIR" | tail -1 | awk '{print $4}')"
  if (( free_kb < 2097152 )); then
    echo "[PREFLIGHT] FAIL: insufficient disk space (< 2 GB free)"
    errors=$((errors + 1))
  fi

  if (( errors > 0 )); then
    echo ""
    echo "===== PREFLIGHT FAILED ($errors issue(s)) ====="
    printf '  - %s\n' "${missing[@]:-}"
    exit 1
  fi

  echo "[PREFLIGHT] All checks passed."
}

parse_upstream_properties() {
  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
    key="$(echo "$key" | xargs | tr '.-' '__')"
    value="$(echo "$value" | xargs)"
    # bash 3.2 (macOS default /bin/bash) lacks 'declare -g'; printf -v writes the
    # global (non-local) variable from inside the function on both 3.2 and 5.x.
    printf -v "$key" '%s' "$value"
  done < "$PROJECT_DIR/dependencies.properties"
}

clone_sources() {
  clone_checkout() {
    local name="$1" branch="$2" tag="$3" repo="$4" dest="$5"
    echo "[CLONE] $name (branch: $branch${tag:+, tag: $tag})"
    git clone --branch "$branch" "$repo" "$dest"
    [[ -z "$tag" ]] || git -C "$dest" checkout "$tag"
    echo "[CLONE] $name checked out at $(git -C "$dest" rev-parse HEAD)"
  }

  clone_checkout zstd "$zstd_branch" "$zstd_tag" "$zstd_repo" "$ZSTD_SRC"
  clone_checkout lz4 "$lz4_branch" "$lz4_tag" "$lz4_repo" "$LZ4_SRC"
  clone_checkout snappy "$snappy_branch" "$snappy_tag" "$snappy_repo" "$SNAPPY_SRC"
  clone_checkout tidesdb "$tidesdb_branch" "$tidesdb_tag" "$tidesdb_repo" "$TIDESDB_SRC"
  clone_checkout tidesdb-java "$tidesdb_java_branch" "$tidesdb_java_tag" "$tidesdb_java_repo" "$TIDESDB_JAVA_SRC"
}

cmake_platform_args=()
if [[ "$OS" == "Darwin" ]]; then
  cmake_platform_args+=("-DCMAKE_OSX_ARCHITECTURES=$MACHINE_ARCH")
fi

build_compression_deps() {
  echo "[DEPS] Building zstd (static)..."
  cmake -S "$ZSTD_SRC/build/cmake" -B "$ZSTD_BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DZSTD_BUILD_STATIC=ON -DZSTD_BUILD_SHARED=OFF \
    -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_CONTRIB=OFF -DZSTD_BUILD_TESTS=OFF \
    -DCMAKE_INSTALL_PREFIX="$DEPS_INSTALL" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    "${cmake_platform_args[@]}"
  cmake --build "$ZSTD_BUILD" --parallel
  cmake --install "$ZSTD_BUILD" --prefix "$DEPS_INSTALL"

  echo "[DEPS] Building lz4 (static)..."
  cmake -S "$LZ4_SRC/build/cmake" -B "$LZ4_BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_STATIC_LIBS=ON -DBUILD_SHARED_LIBS=OFF \
    -DLZ4_BUILD_CLI=OFF \
    -DCMAKE_INSTALL_PREFIX="$DEPS_INSTALL" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    "${cmake_platform_args[@]}"
  cmake --build "$LZ4_BUILD" --parallel
  cmake --install "$LZ4_BUILD" --prefix "$DEPS_INSTALL"

  echo "[DEPS] Building snappy (static)..."
  cmake -S "$SNAPPY_SRC" -B "$SNAPPY_BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DSNAPPY_BUILD_TESTS=OFF -DSNAPPY_BUILD_BENCHMARKS=OFF \
    -DCMAKE_INSTALL_PREFIX="$DEPS_INSTALL" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    "${cmake_platform_args[@]}"
  cmake --build "$SNAPPY_BUILD" --parallel
  cmake --install "$SNAPPY_BUILD" --prefix "$DEPS_INSTALL"
}

find_core_library() {
  find "$TIDESDB_INSTALL/lib" -maxdepth 1 -type f \
    \( -name 'libtidesdb.so*' -o -name 'libtidesdb*.dylib' \) \
    | sort | head -1
}

find_jni_library() {
  find "$JNI_BUILD" -type f \
    \( -name 'libtidesdb_jni.so' -o -name 'libtidesdb_jni.dylib' \) \
    | head -1
}

build_tidesdb() {
    echo "[TIDESDB] Building shared library with statically linked compression..."

    local zstd_static="$DEPS_INSTALL/lib/libzstd.a"
    local lz4_static="$DEPS_INSTALL/lib/liblz4.a"
    local snappy_static="$DEPS_INSTALL/lib/libsnappy.a"

    [[ -f "$zstd_static" ]] || { echo "Missing $zstd_static"; exit 2; }
    [[ -f "$lz4_static" ]] || { echo "Missing $lz4_static"; exit 2; }
    [[ -f "$snappy_static" ]] || { echo "Missing $snappy_static"; exit 2; }

    export CPATH="$DEPS_INSTALL/include${CPATH:+:$CPATH}"

    local platform_args=()
    local linker_flags=""

    case "$(uname -s)" in
        Darwin)
            platform_args+=(
                "-DUSE_HOMEBREW=OFF"
                "-DMACOS_DEPENDENCY_PREFIX=$DEPS_INSTALL"
                "-DCMAKE_OSX_ARCHITECTURES=$(uname -m)"
            )
            linker_flags="-lc++"
            ;;
        Linux)
            linker_flags="-lstdc++"
            ;;
        *)
            echo "Unsupported host: $(uname -s)"
            exit 1
            ;;
    esac

    cmake -S "$TIDESDB_SRC" -B "$TIDESDB_BUILD" \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON \
        -DTIDESDB_BUILD_TESTS=OFF \
        -DTIDESDB_WITH_SANITIZER=OFF \
        -DTIDESDB_WITH_S3=OFF \
        -DTIDESDB_WITH_SNAPPY=ON \
        -DTIDESDB_WITH_LZ4=ON \
        -DTIDESDB_WITH_ZSTD=ON \
        "-DTIDESDB_SNAPPY_TARGET:STRING=$snappy_static" \
        "-DTIDESDB_LZ4_TARGET:STRING=$lz4_static" \
        "-DTIDESDB_ZSTD_TARGET:STRING=$zstd_static" \
        "-DCMAKE_SHARED_LINKER_FLAGS:STRING=$linker_flags" \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DCMAKE_INSTALL_PREFIX="$TIDESDB_INSTALL" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        "${platform_args[@]}"

    local cache="$TIDESDB_BUILD/CMakeCache.txt"
    grep -Fq "TIDESDB_SNAPPY_TARGET:STRING=$snappy_static" "$cache" || {
        echo "[TIDESDB] FAIL: Snappy static override was not accepted"
        grep 'TIDESDB_.*_TARGET' "$cache" || true
        exit 2
    }
    grep -Fq "TIDESDB_LZ4_TARGET:STRING=$lz4_static" "$cache" || {
        echo "[TIDESDB] FAIL: LZ4 static override was not accepted"
        exit 2
    }
    grep -Fq "TIDESDB_ZSTD_TARGET:STRING=$zstd_static" "$cache" || {
        echo "[TIDESDB] FAIL: Zstd static override was not accepted"
        exit 2
    }

    cmake --build "$TIDESDB_BUILD" --parallel
    cmake --install "$TIDESDB_BUILD" --prefix "$TIDESDB_INSTALL"

    unset CPATH

    echo "[TIDESDB] Link command:"
    find "$TIDESDB_BUILD" -name link.txt -print -exec cat {} \; 2>/dev/null || true
}

remove_macos_build_rpaths() {
  local binary="$1"
  local rpath

  while IFS= read -r rpath; do
    [[ -n "$rpath" ]] || continue

    case "$rpath" in
      @loader_path|@loader_path/*|@rpath|@rpath/*|@executable_path|@executable_path/*)
        ;;
      /*)
        echo "[MACHO] Removing absolute LC_RPATH from $binary: $rpath"
        install_name_tool -delete_rpath "$rpath" "$binary"
        ;;
    esac
  done < <(
    otool -l "$binary" |
      awk '
        $1 == "cmd" && $2 == "LC_RPATH" {
          want_path = 1
          next
        }
        want_path && $1 == "path" {
          print $2
          want_path = 0
        }
      '
  )
}

verify_no_absolute_macos_rpaths() {
  local binary="$1"
  local bad=0
  local rpath

  while IFS= read -r rpath; do
    [[ -n "$rpath" ]] || continue
    case "$rpath" in
      /*)
        echo "[VERIFY] FAIL: absolute LC_RPATH remains in $binary: $rpath"
        bad=1
        ;;
    esac
  done < <(
    otool -l "$binary" |
      awk '
        $1 == "cmd" && $2 == "LC_RPATH" {
          want_path = 1
          next
        }
        want_path && $1 == "path" {
          print $2
          want_path = 0
        }
      '
  )

  return "$bad"
}


normalize_macos_install_names() {
  local core="$1"
  local jni="$2"
  local core_name="${CORE_LIB:-${CORE_NAME:-libtidesdb.dylib}}"
  local jni_name="${JNI_LIB:-${JNI_NAME:-libtidesdb_jni.dylib}}"
  local dependency

  echo "[MACHO] Setting core install name: @loader_path/$core_name"
  install_name_tool -id "@loader_path/$core_name" "$core"

  echo "[MACHO] Setting JNI install name: @loader_path/$jni_name"
  install_name_tool -id "@loader_path/$jni_name" "$jni"

  while IFS= read -r dependency; do
    [[ -n "$dependency" ]] || continue

    case "$dependency" in
      *libtidesdb_jni*.dylib)
        # This is the JNI library's own install name, not the core dependency.
        ;;
      *libtidesdb*.dylib)
        echo "[MACHO] Rewriting JNI dependency:"
        echo "        $dependency"
        echo "     -> @loader_path/$core_name"
        install_name_tool \
          -change "$dependency" "@loader_path/$core_name" "$jni"
        ;;
    esac
  done < <(
    otool -L "$jni" |
      tail -n +2 |
      awk '{print $1}'
  )

  if ! otool -D "$core" | tail -n +2 | grep -Fxq "@loader_path/$core_name"; then
    echo "[MACHO] FAIL: core install name was not normalized"
    otool -D "$core"
    return 1
  fi

  if ! otool -L "$jni" | grep -Fq "@loader_path/$core_name"; then
    echo "[MACHO] FAIL: JNI does not reference @loader_path/$core_name"
    otool -L "$jni"
    return 1
  fi
}

build_jni() {
  local core tidesdb_inc
  core="$(find_core_library)"
  tidesdb_inc="$TIDESDB_INSTALL/include"

  local jni_c_flags=""
  local rpath_args=()
  if [[ "$OS" == "Linux" ]]; then
    jni_c_flags="-D_GNU_SOURCE"
    rpath_args+=("-DCMAKE_BUILD_RPATH=\$ORIGIN" "-DCMAKE_INSTALL_RPATH=\$ORIGIN")
  else
    rpath_args+=("-DCMAKE_BUILD_RPATH=@loader_path" "-DCMAKE_INSTALL_RPATH=@loader_path")
  fi

  local java_home
  if [[ -n "${JAVA_HOME:-}" && -f "$JAVA_HOME/include/jni.h" ]]; then
    java_home="$JAVA_HOME"
  elif [[ "$OS" == "Darwin" ]] && [[ -x /usr/libexec/java_home ]]; then
    java_home="$(/usr/libexec/java_home)"
  else
    local javac_path
    javac_path="$(command -v javac)"
    if command -v readlink >/dev/null 2>&1; then
      javac_path="$(readlink -f "$javac_path" 2>/dev/null || echo "$javac_path")"
    fi
    java_home="$(cd "$(dirname "$javac_path")/.." && pwd)"
  fi

  [[ -f "$java_home/include/jni.h" ]] || {
    echo "[JNI] FAIL: jni.h not found under JAVA_HOME=$java_home"
    echo "[JNI] Set JAVA_HOME to a full JDK installation and rerun."
    exit 2
  }

  local java_platform_include
  case "$OS" in
    Darwin) java_platform_include="$java_home/include/darwin" ;;
    Linux)  java_platform_include="$java_home/include/linux" ;;
    *)      echo "[JNI] FAIL: unsupported JNI platform: $OS"; exit 2 ;;
  esac

  [[ -f "$java_platform_include/jni_md.h" ]] || {
    echo "[JNI] FAIL: jni_md.h not found under $java_platform_include"
    exit 2
  }

  export JAVA_HOME="$java_home"

  echo "[JNI] JAVA_HOME=$JAVA_HOME"
  echo "[JNI] Building JNI bridge for $PLATFORM..."
  cmake -S "$TIDESDB_JAVA_SRC/src/main/c" -B "$JNI_BUILD" -G Ninja \
    -DJAVA_HOME:PATH="$JAVA_HOME" \
    -DJAVA_INCLUDE_PATH:PATH="$JAVA_HOME/include" \
    -DJAVA_INCLUDE_PATH2:PATH="$java_platform_include" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="$jni_c_flags" \
    -DTIDESDB_LIBRARY:FILEPATH="$core" \
    -DTIDESDB_INCLUDE_DIR:PATH="$tidesdb_inc" \
    "${rpath_args[@]}" \
    "${cmake_platform_args[@]}"

  cmake --build "$JNI_BUILD" --parallel

  local jni
  jni="$(find_jni_library)"
  [[ -n "$jni" ]] || { echo "[JNI] FAIL: JNI library not found"; exit 2; }

  if [[ "${OS:-${HOST_OS:-}}" == "Darwin" ]]; then
    install_name_tool -id "@loader_path/$JNI_LIB" "$jni"
    remove_macos_build_rpaths "$core"
    remove_macos_build_rpaths "$jni"
  fi

  if [[ "${OS:-${HOST_OS:-}}" == "Darwin" ]]; then
    normalize_macos_install_names "$core" "$jni"
  fi

  if [[ "$OS" == "Linux" ]]; then
    # CMake embeds the full-path TidesDB directory in the JNI lib's RUNPATH even with
    # CMAKE_BUILD_RPATH=$ORIGIN set (that option does not replace the computed rpath).
    # Replace any absolute build-machine path with the relocatable $ORIGIN token so
    # verify_native's absolute-path check passes and runtime resolution works from the
    # extraction cache (libtidesdb.so.9 as a sibling of libtidesdb_jni.so).
    patchelf --set-rpath '$ORIGIN' "$jni"
    # The core lib is normally free of RPATH (static compression + system libs); normalize
    # it as well so an absolute path can never leak into the shipped artifact.
    patchelf --set-rpath '$ORIGIN' "$core"
    echo "[JNI] RUNPATH normalized to \$ORIGIN:"
    readelf -d "$core" "$jni" | grep -E 'RPATH|RUNPATH' || true
  fi

  echo "[JNI] Built: $jni"
  file "$jni"
}

verify_native() {
  local core jni
  core="$(find_core_library)"
  jni="$(find_jni_library)"
  local fail=0

  echo "[VERIFY] === $CORE_LIB ==="
  file "$core"

  echo "[VERIFY] === $JNI_LIB ==="
  file "$jni"

  local deps
  if [[ "$OS" == "Darwin" ]]; then
    deps="$(otool -L "$core"; otool -L "$jni")"
    echo "$deps"

    for forbidden in libzstd liblz4 libsnappy libcurl libssl libcrypto libs3; do
      if grep -qi "$forbidden" <<<"$deps"; then
        echo "[VERIFY] FAIL: forbidden dynamic dependency: $forbidden"
        fail=1
      fi
    done

    if ! verify_no_absolute_macos_rpaths "$core"; then
      fail=1
    fi
    if ! verify_no_absolute_macos_rpaths "$jni"; then
      fail=1
    fi

    if ! otool -L "$jni" | grep -q "@loader_path/$CORE_LIB"; then
      echo "[VERIFY] FAIL: JNI library does not reference @loader_path/$CORE_LIB"
      fail=1
    fi
  else
    deps="$(ldd "$core"; ldd "$jni")"
    echo "$deps"

    for forbidden in libzstd liblz4 libsnappy libcurl libssl libcrypto libs3; do
      if grep -qi "$forbidden" <<<"$deps"; then
        echo "[VERIFY] FAIL: forbidden dynamic dependency: $forbidden"
        fail=1
      fi
    done

    if readelf -d "$core" "$jni" | grep -qiE '(RPATH|RUNPATH).*(/tmp|/home|/build|/vcpkg)'; then
      echo "[VERIFY] FAIL: suspicious RPATH/RUNPATH"
      fail=1
    fi
  fi

  (( fail == 0 )) || exit 3
  echo "[VERIFY] Native libraries: PASS"
}

build_upstream_java() {
  echo "[JAVA-UPSTREAM] Building pinned tidesdb-java source..."
  "$TIDESDB_JAVA_SRC/mvnw" \
    -f "$TIDESDB_JAVA_SRC/pom.xml" \
    -DskipTests \
    -Dmaven.javadoc.skip=true \
    -Djacoco.skip=true \
    clean install
  git -C "$TIDESDB_JAVA_SRC" diff --exit-code
}

copy_libs() {
  local core jni
  core="$(find_core_library)"
  jni="$(find_jni_library)"

  rm -rf "$GENERATED_RESOURCES_DIR"
  mkdir -p "$NATIVE_RESOURCE_DIR"

  cp -L "$core" "$NATIVE_RESOURCE_DIR/$CORE_LIB"
  cp -L "$jni" "$NATIVE_RESOURCE_DIR/$JNI_LIB"

  if [[ "$OS" == "Darwin" ]]; then
    install_name_tool -id "@loader_path/$CORE_LIB" "$NATIVE_RESOURCE_DIR/$CORE_LIB"
  fi

  echo "[LIBS] Libraries in $NATIVE_RESOURCE_DIR:"
  ls -la "$NATIVE_RESOURCE_DIR"
}

parse_upstream_properties

phase "Preflight checks"
preflight

phase "Clone upstream sources"
clone_sources

phase "Build compression dependencies"
build_compression_deps

phase "Build TidesDB"
build_tidesdb

phase "Build JNI library"
build_jni

phase "Verify native library dependencies"
verify_native

phase "Build upstream tidesdb-java artifact"
build_upstream_java

phase "Copy native libraries"
copy_libs

echo ""
echo "===== DEPENDENCIES BUILD SUCCESS ($PLATFORM) ====="
