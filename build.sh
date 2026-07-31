#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
LIBS_DIR="$PROJECT_DIR/libs"
GENERATED_RESOURCES_DIR="$PROJECT_DIR/build/generated-resources"
NATIVE_RESOURCE_DIR="$GENERATED_RESOURCES_DIR/native/linux-x86_64"
MAVEN_REPO_DIR="$PROJECT_DIR/build/m2"

# --- Temporary build directory in /tmp ---
TMP_BUILD_DIR=$(mktemp -d -t tidesdb-build-XXXXXX)
echo "[BUILD] Work directory: $TMP_BUILD_DIR"

trap 'echo "[ERROR] Command failed (line $LINENO): $BASH_COMMAND" >&2' ERR
trap 'rm -rf "$TMP_BUILD_DIR"; rm -f "$PROJECT_DIR/dependency-reduced-pom.xml"' EXIT

# --- Source and build directories under /tmp/<tmpdir>/ ---
TIDESDB_SRC="$TMP_BUILD_DIR/tidesdb"
TIDESDB_JAVA_SRC="$TMP_BUILD_DIR/tidesdb-java"
ZSTD_SRC="$TMP_BUILD_DIR/zstd"
LZ4_SRC="$TMP_BUILD_DIR/lz4"
SNAPPY_SRC="$TMP_BUILD_DIR/snappy"

TIDESDB_BUILD="$TMP_BUILD_DIR/tidesdb-build"
JNI_BUILD="$TMP_BUILD_DIR/jni-build"
ZSTD_BUILD="$TMP_BUILD_DIR/zstd-build"
LZ4_BUILD="$TMP_BUILD_DIR/lz4-build"
SNAPPY_BUILD="$TMP_BUILD_DIR/snappy-build"

DEPS_INSTALL="$TMP_BUILD_DIR/deps-install"
TIDESDB_INSTALL="$TMP_BUILD_DIR/tidesdb-install"

phase() { echo ""; echo "===[ $(date -u +%T) ] $* ==="; }

# ===================================================================
# Preflight checks
# ===================================================================
preflight() {
    local errors=0 missing=()

    check_cmd() {
        local cmd="$1" min_ver="${2:-}" label="${3:-$1}"
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "[PREFLIGHT] MISSING: $label ($cmd)"
            missing+=("$label ($cmd)")
            ((errors++)) || true
            return 1
        fi
        if [ -n "$min_ver" ]; then
            local ver
            ver=$("$cmd" --version 2>&1 | head -1 | grep -oE '[0-9]+(\.[0-9]+)+' | head -1 || true)
            [ -z "$ver" ] && echo "[PREFLIGHT] WARNING: could not determine version of $cmd"
        fi
        return 0
    }

    echo "[PREFLIGHT] Host: $(uname -a)"

    local os arch
    os=$(uname -s); arch=$(uname -m)
    [[ "$os" != "Linux" ]] && { echo "[PREFLIGHT] FAIL: expected Linux, detected $os"; ((errors++)); }
    [[ "$arch" != "x86_64" && "$arch" != "amd64" ]] && { echo "[PREFLIGHT] FAIL: expected x86_64, detected $arch"; ((errors++)); }

    check_cmd bash   ""       "Bash"
    check_cmd git    ""       "Git"
    check_cmd cmake  "3.25"   "CMake (>= 3.25 required by TidesDB)"
    check_cmd ninja  ""       "Ninja"
    check_cmd gcc    ""       "GCC"
    check_cmd g++    ""       "G++"
    check_cmd ld     ""       "GNU ld"
    check_cmd ar     ""       "GNU ar"
    check_cmd ranlib ""       "ranlib"
    check_cmd readelf ""      "readelf"
    check_cmd ldd    ""       "ldd"
    check_cmd file   ""       "file"
    check_cmd sha256sum ""    "sha256sum"
    check_cmd tar    ""       "tar"
    check_cmd curl   ""       "curl"

    check_cmd java "" "Java"
    check_cmd javac "" "javac"
    check_cmd jar "" "jar"

    local java_ver
    java_ver=$(java -version 2>&1 | head -1 | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || echo "0")
    if [ "$(echo "$java_ver >= 11" | bc -l 2>/dev/null || echo 0)" != "1" ]; then
        echo "[PREFLIGHT] FAIL: Java >= 11 required, detected $java_ver"
        ((errors++))
    fi
    if ! javac -version >/dev/null 2>&1; then
        echo "[PREFLIGHT] FAIL: javac not found"
        ((errors++))
    fi

    [ ! -x "$PROJECT_DIR/mvnw" ] && { echo "[PREFLIGHT] FAIL: mvnw not found or not executable"; ((errors++)); }
    [ ! -f "$PROJECT_DIR/upstream.properties" ] && { echo "[PREFLIGHT] FAIL: upstream.properties not found"; ((errors++)); }

    for var in LD_LIBRARY_PATH LD_PRELOAD CFLAGS CXXFLAGS LDFLAGS; do
        [ -n "${!var:-}" ] && echo "[PREFLIGHT] WARNING: $var is set (${!var}). This may contaminate native linkage."
    done

    local free_kb
    free_kb=$(df -k "$PROJECT_DIR" | tail -1 | awk '{print $4}')
    [ "$free_kb" -lt 2097152 ] && { echo "[PREFLIGHT] FAIL: insufficient disk space (< 2 GB free)"; ((errors++)); }

    if [ "$errors" -gt 0 ]; then
        echo ""
        echo "===== PREFLIGHT FAILED ($errors issue(s)) ====="
        for m in "${missing[@]}"; do echo "  - $m"; done
        exit 1
    fi
    echo "[PREFLIGHT] All checks passed."
}

# ===================================================================
# Parse upstream.properties
# ===================================================================
parse_upstream_properties() {
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        key=$(echo "$key" | xargs | tr '.-' '__')
        value=$(echo "$value" | xargs)
        declare -g "$key=$value"
    done < "$PROJECT_DIR/upstream.properties"
}

# ===================================================================
# Clone sources
# ===================================================================
clone_sources() {
    clone_checkout() {
        local name="$1" branch="$2" tag="$3" repo="$4" dest="$5"
        echo "[CLONE] $name (branch: $branch${tag:+, tag: $tag})"
        git clone --branch "$branch" "$repo" "$dest"
        if [ -n "$tag" ]; then
            git -C "$dest" checkout "$tag"
        fi
        echo "[CLONE] $name checked out at $(git -C "$dest" rev-parse HEAD)"
    }

    clone_checkout zstd        "$zstd_branch"        "$zstd_tag"        "$zstd_repo"        "$ZSTD_SRC"
    clone_checkout lz4         "$lz4_branch"         "$lz4_tag"         "$lz4_repo"         "$LZ4_SRC"
    clone_checkout snappy      "$snappy_branch"      "$snappy_tag"      "$snappy_repo"      "$SNAPPY_SRC"
    clone_checkout tidesdb     "$tidesdb_branch"     "$tidesdb_tag"     "$tidesdb_repo"     "$TIDESDB_SRC"
    clone_checkout tidesdb-java "$tidesdb_java_branch" "$tidesdb_java_tag" "$tidesdb_java_repo" "$TIDESDB_JAVA_SRC"
}

# ===================================================================
# Build compression dependencies (static libraries)
# ===================================================================
build_compression_deps() {
    echo "[DEPS] Building zstd (static)..."
    cmake -S "$ZSTD_SRC/build/cmake" -B "$ZSTD_BUILD" \
        -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DZSTD_BUILD_STATIC=ON -DZSTD_BUILD_SHARED=OFF \
        -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_CONTRIB=OFF -DZSTD_BUILD_TESTS=OFF \
        -DCMAKE_INSTALL_PREFIX="$DEPS_INSTALL" \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    cmake --build "$ZSTD_BUILD"
    cmake --install "$ZSTD_BUILD" --prefix "$DEPS_INSTALL"

    echo "[DEPS] Building lz4 (static)..."
    cmake -S "$LZ4_SRC/build/cmake" -B "$LZ4_BUILD" \
        -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_STATIC_LIBS=ON -DBUILD_SHARED_LIBS=OFF \
        -DLZ4_BUILD_CLI=OFF \
        -DCMAKE_INSTALL_PREFIX="$DEPS_INSTALL" \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    cmake --build "$LZ4_BUILD"
    cmake --install "$LZ4_BUILD" --prefix "$DEPS_INSTALL"

    echo "[DEPS] Building snappy (static)..."
    cmake -S "$SNAPPY_SRC" -B "$SNAPPY_BUILD" \
        -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DSNAPPY_BUILD_TESTS=OFF -DSNAPPY_BUILD_BENCHMARKS=OFF \
        -DCMAKE_INSTALL_PREFIX="$DEPS_INSTALL" \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    cmake --build "$SNAPPY_BUILD"
    cmake --install "$SNAPPY_BUILD" --prefix "$DEPS_INSTALL"

    echo "[DEPS] Static compression libraries installed to $DEPS_INSTALL"
    ls -la "$DEPS_INSTALL/lib"/*.a
}

# ===================================================================
# Build TidesDB as a shared library with statically-linked compression
# ===================================================================
build_tidesdb() {
    echo "[TIDESDB] Building TidesDB as shared library..."

    # Set environment so the C compiler can find compression headers and libraries.
    # CPATH is used by GCC for header search; LIBRARY_PATH is used for -l flags.
    export CPATH="$DEPS_INSTALL/include"
    export LIBRARY_PATH="$DEPS_INSTALL/lib"

    # Use CMAKE_INSTALL_LIBDIR=lib so the .so path is predictable.
    cmake -S "$TIDESDB_SRC" -B "$TIDESDB_BUILD" \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=ON \
        -DTIDESDB_BUILD_TESTS=OFF \
        -DTIDESDB_WITH_SANITIZER=OFF \
        -DTIDESDB_WITH_S3=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DCMAKE_INSTALL_PREFIX="$TIDESDB_INSTALL" \
        -DCMAKE_INSTALL_LIBDIR=lib

    cmake --build "$TIDESDB_BUILD"

    # Install TidesDB so the JNI build can find it via CMAKE_PREFIX_PATH.
    cmake --install "$TIDESDB_BUILD" --prefix "$TIDESDB_INSTALL"

    unset CPATH LIBRARY_PATH

    echo "[TIDESDB] Built: $TIDESDB_INSTALL/lib/libtidesdb.so"
    ls -la "$TIDESDB_INSTALL/lib/libtidesdb.so"
}

# ===================================================================
# Build JNI library using upstream CMakeLists.txt (no patching)
# ===================================================================
build_jni() {
    echo "[JNI] Building libtidesdb_jni.so using upstream CMakeLists.txt..."

    # The upstream JNI CMakeLists.txt searches /usr/local/lib FIRST in its HINTS,
    # which can pick up a system-installed TidesDB.  Explicitly pass the library
    # and include paths as cache variables so find_library resolves to our build.
    local tidesdb_lib="$TIDESDB_INSTALL/lib/libtidesdb.so"
    local tidesdb_inc="$TIDESDB_INSTALL/include"

    # Resolve the symlink so the JNI .so has a direct NEEDED on the versioned soname.
    # (libtidesdb.so -> libtidesdb.so.9, and ld records the resolved soname.)
    if [ -L "$tidesdb_lib" ]; then
        local real_lib
        real_lib="$(cd "$(dirname "$tidesdb_lib")" && readlink "$tidesdb_lib")"
        tidesdb_lib="$(dirname "$tidesdb_lib")/$real_lib"
    fi

    # Skip RPATH so the .so does not embed a /tmp build path.
    cmake -S "$TIDESDB_JAVA_SRC/src/main/c" -B "$JNI_BUILD" \
        -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="-D_GNU_SOURCE" \
        -DTIDESDB_LIBRARY:FILEPATH="$tidesdb_lib" \
        -DTIDESDB_INCLUDE_DIR:PATH="$tidesdb_inc" \
        -DCMAKE_SKIP_RPATH=ON \
        -DCMAKE_SKIP_INSTALL_RPATH=ON

    cmake --build "$JNI_BUILD"

    echo "[JNI] Built: $JNI_BUILD/libtidesdb_jni.so"
    ls -la "$JNI_BUILD/libtidesdb_jni.so"
}

# ===================================================================
# Verify native libraries
# ===================================================================
verify_native() {
    local lib_tidesdb="$TIDESDB_INSTALL/lib/libtidesdb.so"
    local lib_jni="$JNI_BUILD/libtidesdb_jni.so"

    # --- Verify libtidesdb.so ---
    echo "[VERIFY] === libtidesdb.so ==="
    if [ ! -f "$lib_tidesdb" ]; then echo "[VERIFY] FAIL: $lib_tidesdb not found"; exit 3; fi
    echo "[VERIFY] $(file "$lib_tidesdb")"

    local forbidden=("libs3" "libcurl" "libssl" "libcrypto")
    local ldd_out
    ldd_out=$(ldd "$lib_tidesdb" 2>&1)
    local fail=0

    for dep in "${forbidden[@]}"; do
        if echo "$ldd_out" | grep -qi "$dep"; then
            echo "[VERIFY] FAIL: forbidden dynamic dependency in libtidesdb.so: $dep"
            fail=1
        fi
    done

    # libtidesdb.so should NOT dynamically depend on compression libs (they are static)
    local compress_deps=("libtidesdb" "libzstd" "liblz4" "libsnappy")
    for dep in "${compress_deps[@]}"; do
        if echo "$ldd_out" | grep -qi "$dep"; then
            echo "[VERIFY] FAIL: compression dependency leaked in libtidesdb.so: $dep"
            fail=1
        fi
    done

    echo "[VERIFY] libtidesdb.so ldd:"
    echo "$ldd_out"
    echo "[VERIFY] libtidesdb.so readelf NEEDED:"
    readelf -d "$lib_tidesdb" | grep 'NEEDED' || echo "(none)"

    if readelf -d "$lib_tidesdb" | grep -qiE '(RPATH|RUNPATH).*(/tmp|/home|/build|/vcpkg)'; then
        echo "[VERIFY] FAIL: suspicious RPATH/RUNPATH in libtidesdb.so"
        fail=1
    fi

    if [ "$fail" -ne 0 ]; then exit 3; fi
    echo "[VERIFY] libtidesdb.so PASS"

    # --- Verify libtidesdb_jni.so ---
    echo ""
    echo "[VERIFY] === libtidesdb_jni.so ==="
    if [ ! -f "$lib_jni" ]; then echo "[VERIFY] FAIL: $lib_jni not found"; exit 3; fi
    echo "[VERIFY] $(file "$lib_jni")"

    ldd_out=$(ldd "$lib_jni" 2>&1)
    fail=0

    # libtidesdb_jni.so MUST dynamically depend on libtidesdb.so (allowed)
    # but must NOT depend on compression libs directly
    for dep in "${forbidden[@]}"; do
        if echo "$ldd_out" | grep -qi "$dep"; then
            echo "[VERIFY] FAIL: forbidden dynamic dependency in libtidesdb_jni.so: $dep"
            fail=1
        fi
    done

    local jni_forbidden=("libzstd" "liblz4" "libsnappy")
    for dep in "${jni_forbidden[@]}"; do
        if echo "$ldd_out" | grep -qi "$dep"; then
            echo "[VERIFY] FAIL: compression dependency leaked in libtidesdb_jni.so: $dep"
            fail=1
        fi
    done

    echo "[VERIFY] libtidesdb_jni.so ldd:"
    echo "$ldd_out"
    echo "[VERIFY] libtidesdb_jni.so readelf NEEDED:"
    readelf -d "$lib_jni" | grep 'NEEDED' || echo "(none)"

    if readelf -d "$lib_jni" | grep -qiE '(RPATH|RUNPATH).*(/tmp|/home|/build|/vcpkg)'; then
        echo "[VERIFY] FAIL: suspicious RPATH/RUNPATH in libtidesdb_jni.so"
        fail=1
    fi

    if [ "$fail" -ne 0 ]; then exit 3; fi
    echo "[VERIFY] libtidesdb_jni.so PASS"
    echo "[VERIFY] Native libraries: PASS"
}

# ===================================================================
# Build the upstream tidesdb-java Java artifact
# ===================================================================
build_upstream_java() {
    echo "[JAVA-UPSTREAM] Building pinned tidesdb-java source..."
    "$TIDESDB_JAVA_SRC/mvnw" \
        -f "$TIDESDB_JAVA_SRC/pom.xml" \
        -DskipTests \
        -Dmaven.javadoc.skip=true \
        -Djacoco.skip=true \
        clean install

    # Verify the cloned source tree is unmodified
    git -C "$TIDESDB_JAVA_SRC" diff --exit-code
    echo "[JAVA-UPSTREAM] tidesdb-java artifact built, source unchanged."
}

# ===================================================================
# Copy native libraries to ./libs/ and to generated-resources
# ===================================================================
copy_libs() {
    echo "[LIBS] Copying native libraries..."

    # Clean generated-resources so stale artifacts from a previous build
    # (different version, different hash) do not linger in the JAR.
    rm -rf "$GENERATED_RESOURCES_DIR"

    # ./libs/ for local reference / debugging
    mkdir -p "$LIBS_DIR"
    cp "$TIDESDB_INSTALL/lib/libtidesdb.so" "$LIBS_DIR/"
    cp "$JNI_BUILD/libtidesdb_jni.so" "$LIBS_DIR/"

    # generated-resources for inclusion in the unified JAR
    mkdir -p "$NATIVE_RESOURCE_DIR"
    cp "$TIDESDB_INSTALL/lib/libtidesdb.so" "$NATIVE_RESOURCE_DIR/"
    cp "$JNI_BUILD/libtidesdb_jni.so" "$NATIVE_RESOURCE_DIR/"

    echo "[LIBS] Libraries in $LIBS_DIR:"
    ls -la "$LIBS_DIR/"
    echo "[LIBS] Libraries in $NATIVE_RESOURCE_DIR:"
    ls -la "$NATIVE_RESOURCE_DIR/"
}

# ===================================================================
# Build the unified Java project
# ===================================================================
build_java() {
    echo "[JAVA] Building unified JAR..."
    cd "$PROJECT_DIR"
    ./mvnw clean install
    rm -f "$PROJECT_DIR/dependency-reduced-pom.xml"
    echo "[JAVA] Unified JAR built."
}



# ===================================================================
# Main build phases
# ===================================================================
parse_upstream_properties

phase "Preflight checks"
preflight

phase "Clone upstream sources"
clone_sources

phase "Build compression dependencies (zstd, lz4, snappy)"
build_compression_deps

phase "Build TidesDB (shared library, static compression)"
build_tidesdb

phase "Build JNI library (libtidesdb_jni.so)"
build_jni

phase "Verify native library dependencies"
verify_native

phase "Build upstream tidesdb-java Java artifact"
build_upstream_java

phase "Copy native libraries to ./libs/ and generated-resources"
copy_libs

phase "Build unified Java project"
build_java

# --- Success ---
trap - EXIT
echo ""
echo "===== BUILD SUCCESS =====
"
