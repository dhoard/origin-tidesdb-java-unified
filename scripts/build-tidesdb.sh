#!/usr/bin/env bash
#
# build.sh — Robust build script for TidesDB (Unix: Linux, macOS, BSD, SunOS)
#
# This script individually checks for every required tool, then builds TidesDB
# using the standard cmake workflow documented at:
#   https://tidesdb.com/reference/building/#unix-linuxmacos
#
# Usage:
#   ./build.sh                          # Development build (Debug + sanitizers + profiling)
#   ./build.sh --release                # Production/Release build
#   ./build.sh debug                    # Explicit development build (same as default)
#   ./build.sh minimal                  # Minimal: Release, no tests, static lib, no install
#   ./build.sh clean                    # Clean build dir then development build
#   ./build.sh --with-s3                # Enable S3 connector (needs libcurl)
#   ./build.sh --no-compression         # Zero-dependency build (no compression libs)
#   ./build.sh --no-tests               # Skip building tests
#   ./build.sh --static                 # Static library instead of shared
#   ./build.sh --sanitizer              # Enable address/UB sanitizers
#   ./build.sh --profiling              # Enable read profiling
#   ./build.sh --mimalloc               # Use mimalloc allocator
#   ./build.sh --tcmalloc               # Use tcmalloc allocator
#   ./build.sh --jemalloc               # Use jemalloc allocator
#   ./build.sh --install                # Install after build
#   ./build.sh --prefix /usr/local      # Install prefix (default: /usr/local)
#   ./build.sh --build-dir mybuild      # Custom build directory (default: build)
#   ./build.sh --skip-checks            # Skip tool checks (not recommended)

set -euo pipefail

# ─── Colour helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

pass_msg() { printf "${GREEN}✓${NC} %s\n" "$*"; }
fail_msg() { printf "${RED}✗${NC} %s\n" "$*"; }
warn_msg() { printf "${YELLOW}⚠${NC} %s\n" "$*"; }
info_msg() { printf "${CYAN}→${NC} %s\n" "$*"; }
header_msg() { printf "\n${BOLD}%s${NC}\n" "$*"; }

# ─── Defaults (development build) ───────────────────────────────────────────
BUILD_TYPE="Debug"
BUILD_DIR="build"
CLEAN_FIRST=false
SKIP_CHECKS=false
WITH_S3="OFF"
WITH_SNAPPY="ON"
WITH_LZ4="ON"
WITH_ZSTD="ON"
BUILD_TESTS="ON"
BUILD_SHARED="ON"
WITH_SANITIZER="ON"
WITH_PROFILING="ON"
WITH_MIMALLOC="OFF"
WITH_TCMALLOC="OFF"
WITH_JEMALLOC="OFF"
DO_INSTALL=false
INSTALL_PREFIX=""
EXTRA_CMAKE_ARGS=()

# ─── Parse arguments ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        debug)
            BUILD_TYPE="Debug"
            WITH_SANITIZER="ON"
            WITH_PROFILING="ON"
            ;;
        --release)
            BUILD_TYPE="Release"
            WITH_SANITIZER="OFF"
            WITH_PROFILING="OFF"
            ;;
        minimal)
            BUILD_TYPE="Release"
            BUILD_TESTS="OFF"
            BUILD_SHARED="OFF"
            ;;
        clean)     CLEAN_FIRST=true ;;
        --with-s3) WITH_S3="ON" ;;
        --no-compression)
            WITH_SNAPPY="OFF"
            WITH_LZ4="OFF"
            WITH_ZSTD="OFF"
            ;;
        --no-tests)  BUILD_TESTS="OFF" ;;
        --static)    BUILD_SHARED="OFF" ;;
        --sanitizer) WITH_SANITIZER="ON" ;;
        --profiling) WITH_PROFILING="ON" ;;
        --mimalloc)  WITH_MIMALLOC="ON" ;;
        --tcmalloc)  WITH_TCMALLOC="ON" ;;
        --jemalloc)  WITH_JEMALLOC="ON" ;;
        --install)   DO_INSTALL=true ;;
        --prefix)
            shift
            INSTALL_PREFIX="$1"
            ;;
        --build-dir)
            shift
            BUILD_DIR="$1"
            ;;
        --skip-checks) SKIP_CHECKS=true ;;
        -D*)
            # Pass arbitrary cmake defines through
            EXTRA_CMAKE_ARGS+=("$1")
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Usage: $0 [--release] [debug|minimal|clean] [--with-s3] [--no-compression] [--no-tests] [--static] [--sanitizer] [--profiling] [--mimalloc|--tcmalloc|--jemalloc] [--install] [--prefix PATH] [--build-dir DIR] [--skip-checks] [-D...]"
            exit 1
            ;;
    esac
    shift
done

# ─── Mutual-exclusion check for allocators ───────────────────────────────────
ALLOC_COUNT=0
[[ "$WITH_MIMALLOC" == "ON" ]] && ((ALLOC_COUNT++))
[[ "$WITH_TCMALLOC" == "ON" ]] && ((ALLOC_COUNT++))
[[ "$WITH_JEMALLOC" == "ON" ]] && ((ALLOC_COUNT++))
if [[ $ALLOC_COUNT -gt 1 ]]; then
    fail_msg "Cannot enable more than one allocator (mimalloc, tcmalloc, jemalloc). Choose one."
    exit 1
fi

# ─── OS detection ────────────────────────────────────────────────────────────
OS_NAME="$(uname -s)"
OS_ARCH="$(uname -m)"

case "$OS_NAME" in
    Linux)   OS_FAMILY="linux" ;;
    Darwin)  OS_FAMILY="macos" ;;
    FreeBSD) OS_FAMILY="freebsd" ;;
    OpenBSD) OS_FAMILY="openbsd" ;;
    NetBSD)  OS_FAMILY="netbsd" ;;
    DragonFly) OS_FAMILY="dragonfly" ;;
    SunOS)   OS_FAMILY="sunos" ;;
    *)
        fail_msg "Unsupported OS: $OS_NAME"
        exit 1
        ;;
esac

# Snappy is not packaged for SunOS — auto-disable
if [[ "$OS_FAMILY" == "sunos" ]] && [[ "$WITH_SNAPPY" == "ON" ]]; then
    warn_msg "SunOS detected — disabling Snappy (not packaged for OmniOS/Illumos)"
    WITH_SNAPPY="OFF"
fi

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  TidesDB Build Script                                           ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
printf "║  OS:       %-52s ║\n" "${OS_NAME} (${OS_ARCH})"
printf "║  Type:     %-52s ║\n" "${BUILD_TYPE}"
printf "║  Build dir:%-52s ║\n" "${BUILD_DIR}"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# ─── Step 1: Tool checks ────────────────────────────────────────────────────
if [[ "$SKIP_CHECKS" == "false" ]]; then
    header_msg "Checking build tools…"
    echo ""
    ALL_OK=true

    check_tool() {
        local name="$1"
        local cmd="$2"
        local install_hint="$3"
        local version_flag="${4:---version}"

        printf "  %-20s " "$name"
        if command -v "$cmd" &>/dev/null; then
            local ver
            ver="$($cmd $version_flag 2>&1 | head -1 | cut -c1-60)"
            printf "${GREEN}✓${NC} found  %s\n" "$ver"
            return 0
        else
            printf "${RED}✗${NC} MISSING\n"
            printf "    ${YELLOW}→${NC} Install: %s\n" "$install_hint"
            ALL_OK=false
            return 1
        fi
    }

    check_header() {
        local name="$1"
        local header="$2"
        local install_hint="$3"

        printf "  %-20s " "$name"
        # Try common include paths
        local found=false
        for dir in /usr/include /usr/local/include /opt/homebrew/include /opt/local/include /usr/pkg/include /opt/ooce/include; do
            if [[ -f "$dir/$header" ]]; then
                printf "${GREEN}✓${NC} found  %s\n" "$dir/$header"
                found=true
                break
            fi
        done
        if [[ "$found" == "false" ]]; then
            # Try compiler check
            if echo "#include <$header>" | ${CC:-cc} -fsyntax-only -x c - 2>/dev/null; then
                printf "${GREEN}✓${NC} found  (compiler can resolve)\n"
            else
                printf "${RED}✗${NC} MISSING\n"
                printf "    ${YELLOW}→${NC} Install: %s\n" "$install_hint"
                ALL_OK=false
                return 1
            fi
        fi
    }

    check_lib() {
        local name="$1"
        local lib_flag="$2"
        local install_hint="$3"

        printf "  %-20s " "$name"
        local test_file
        test_file="$(mktemp /tmp/tidesdb_check.XXXXXX.c)"
        echo "int main(void){return 0;}" > "$test_file"
        if ${CC:-cc} -o /dev/null "$test_file" $lib_flag 2>/dev/null; then
            printf "${GREEN}✓${NC} found  (links with %s)\n" "$lib_flag"
            rm -f "$test_file"
            return 0
        else
            printf "${RED}✗${NC} MISSING\n"
            printf "    ${YELLOW}→${NC} Install: %s\n" "$install_hint"
            rm -f "$test_file"
            ALL_OK=false
            return 1
        fi
    }

    # ── Always-required tools ────────────────────────────────────────────
    check_tool "cmake"       "cmake"    "cmake (≥3.25)"             "--version" || true
    check_tool "make"        "make"     "make (or ninja-build)"     "--version" || true
    check_tool "C compiler"  "${CC:-cc}" "gcc or clang (C11)"       "--version" || true

    # Check cmake version ≥ 3.25
    if command -v cmake &>/dev/null; then
        CMAKE_VER="$(cmake --version 2>/dev/null | head -1 | grep -oP '[\d]+\.[\d]+\.[\d]+' || echo "0.0.0")"
        CMAKE_MAJOR="${CMAKE_VER%%.*}"
        CMAKE_MINOR="$(echo "$CMAKE_VER" | cut -d. -f2)"
        if [[ "$CMAKE_MAJOR" -lt 3 ]] || { [[ "$CMAKE_MAJOR" -eq 3 ]] && [[ "$CMAKE_MINOR" -lt 25 ]]; }; then
            fail_msg "cmake version $CMAKE_VER is too old (need ≥ 3.25)"
            ALL_OK=false
        fi
    fi

    # Check for a C11-capable compiler
    if command -v "${CC:-cc}" &>/dev/null; then
        C11_TEST="$(mktemp /tmp/tidesdb_c11.XXXXXX.c)"
        echo '#if __STDC_VERSION__ < 201112L
#error "C11 required"
#endif
int main(void){return 0;}' > "$C11_TEST"
        if ! ${CC:-cc} -std=c11 -o /dev/null "$C11_TEST" 2>/dev/null; then
            fail_msg "C compiler does not support C11"
            ALL_OK=false
        fi
        rm -f "$C11_TEST"
    fi

    # ── pthreads (hard requirement) ──────────────────────────────────────
    check_lib "pthreads"     "-lpthread" \
        "Linux: build-essential | macOS: built-in | BSD: built-in | SunOS: built-in" || true

    # ── libatomic (needed on 32-bit and PowerPC) ─────────────────────────
    case "$OS_ARCH" in
        i386|i486|i586|i686|armv7*|ppc|ppc64le|riscv64)
            check_lib "libatomic" "-latomic" \
                "Debian: libatomic1 | Fedora: libatomic | Arch: (in gcc-libs)" || true
            ;;
    esac

    # ── Compression libraries (optional but checked when enabled) ────────
    if [[ "$WITH_SNAPPY" == "ON" ]]; then
        check_header "libsnappy" "snappy-c.h" \
            "Debian: libsnappy-dev | Fedora: snappy-devel | Arch: snappy | macOS: brew install snappy" || true
        check_lib "libsnappy (link)" "-lsnappy" \
            "Debian: libsnappy-dev | Fedora: snappy-devel | macOS: brew install snappy" || true
    fi

    if [[ "$WITH_LZ4" == "ON" ]]; then
        check_header "liblz4" "lz4.h" \
            "Debian: liblz4-dev | Fedora: lz4-devel | Arch: lz4 | macOS: brew install lz4" || true
        check_lib "liblz4 (link)" "-llz4" \
            "Debian: liblz4-dev | Fedora: lz4-devel | macOS: brew install lz4" || true
    fi

    if [[ "$WITH_ZSTD" == "ON" ]]; then
        check_header "libzstd" "zstd.h" \
            "Debian: libzstd-dev | Fedora: libzstd-devel | Arch: zstd | macOS: brew install zstd" || true
        check_lib "libzstd (link)" "-lzstd" \
            "Debian: libzstd-dev | Fedora: libzstd-devel | macOS: brew install zstd" || true
    fi

    # ── Optional: S3 (libcurl) ───────────────────────────────────────────
    if [[ "$WITH_S3" == "ON" ]]; then
        check_header "libcurl" "curl/curl.h" \
            "Debian: libcurl4-openssl-dev | Fedora: libcurl-devel | macOS: brew install curl" || true
        check_lib "libcurl (link)" "-lcurl" \
            "Debian: libcurl4-openssl-dev | Fedora: libcurl-devel | macOS: brew install curl" || true
    fi

    # ── Optional: mimalloc ───────────────────────────────────────────────
    if [[ "$WITH_MIMALLOC" == "ON" ]]; then
        check_header "mimalloc" "mimalloc.h" \
            "Debian: (via vcpkg) | macOS: brew install mimalloc | From source: github.com/microsoft/mimalloc" || true
        check_lib "mimalloc (link)" "-lmimalloc" \
            "Install via vcpkg, Homebrew, or from source" || true
    fi

    # ── Optional: tcmalloc ───────────────────────────────────────────────
    if [[ "$WITH_TCMALLOC" == "ON" ]]; then
        check_header "tcmalloc" "gperftools/tcmalloc.h" \
            "Debian: libgoogle-perftools-dev | macOS: brew install gperftools" || true
        check_lib "tcmalloc (link)" "-ltcmalloc" \
            "Debian: libgoogle-perftools-dev | macOS: brew install gperftools" || true
    fi

    # ── Optional: jemalloc ───────────────────────────────────────────────
    if [[ "$WITH_JEMALLOC" == "ON" ]]; then
        check_header "jemalloc" "jemalloc/jemalloc.h" \
            "Debian: libjemalloc-dev | macOS: brew install jemalloc" || true
        check_lib "jemalloc (link)" "-ljemalloc" \
            "Debian: libjemalloc-dev | macOS: brew install jemalloc" || true
    fi

    echo ""
    if [[ "$ALL_OK" == "false" ]]; then
        fail_msg "Some required tools are missing. Install them and re-run, or use --skip-checks."
        echo ""
        echo "  Quick install commands:"
        echo ""
        case "$OS_FAMILY" in
            linux)
                echo "    sudo apt install -y cmake build-essential libzstd-dev liblz4-dev libsnappy-dev"
                echo "    # or: sudo dnf install cmake gcc libzstd-devel lz4-devel snappy-devel"
                ;;
            macos)
                echo "    brew install cmake zstd lz4 snappy"
                ;;
            freebsd)
                echo "    sudo pkg install cmake pkgconf liblz4 zstd snappy"
                ;;
            openbsd)
                echo "    sudo pkg_add cmake gmake lz4 zstd snappy pkgconf"
                ;;
            netbsd)
                echo "    sudo pkgin install cmake lz4 zstd snappy"
                ;;
            dragonfly)
                echo "    sudo pkg install cmake lz4 zstd snappy"
                ;;
            sunos)
                echo "    sudo pkg install cmake lz4 zstd"
                ;;
        esac
        exit 1
    fi
    pass_msg "All required tools found."
else
    warn_msg "Skipping tool checks (--skip-checks)."
fi

# ─── Step 2: Clean previous build (if requested) ────────────────────────────
if [[ "$CLEAN_FIRST" == "true" ]]; then
    info_msg "Cleaning previous build directory: ${BUILD_DIR}"
    rm -rf "$BUILD_DIR"
fi

# ─── Step 3: CMake configure ────────────────────────────────────────────────
header_msg "Configuring with CMake…"
echo ""

CMAKE_ARGS=(
    -S .
    -B "$BUILD_DIR"
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE"
    -DTIDESDB_WITH_SNAPPY="$WITH_SNAPPY"
    -DTIDESDB_WITH_LZ4="$WITH_LZ4"
    -DTIDESDB_WITH_ZSTD="$WITH_ZSTD"
    -DTIDESDB_BUILD_TESTS="$BUILD_TESTS"
    -DBUILD_SHARED_LIBS="$BUILD_SHARED"
    -DTIDESDB_WITH_SANITIZER="$WITH_SANITIZER"
    -DENABLE_READ_PROFILING="$WITH_PROFILING"
    -DTIDESDB_WITH_S3="$WITH_S3"
    -DTIDESDB_WITH_MIMALLOC="$WITH_MIMALLOC"
    -DTIDESDB_WITH_TCMALLOC="$WITH_TCMALLOC"
    -DTIDESDB_WITH_JEMALLOC="$WITH_JEMALLOC"
)

# Append any extra user-provided cmake defines
CMAKE_ARGS+=("${EXTRA_CMAKE_ARGS[@]}")

info_msg "cmake ${CMAKE_ARGS[*]}"
echo ""

if ! cmake "${CMAKE_ARGS[@]}"; then
    fail_msg "CMake configuration failed."
    echo ""
    echo "  Hints:"
    echo "    - Check that compression library *development* packages are installed"
    echo "    - On macOS, ensure Xcode Command Line Tools are installed: xcode-select --install"
    echo "    - On macOS with non-Homebrew package managers, use -DMACOS_DEPENDENCY_PREFIX=/path -DUSE_HOMEBREW=OFF"
    echo "    - On macOS, Homebrew is auto-detected at /opt/homebrew (ARM) or /usr/local (Intel)"
    echo "    - On FreeBSD/OpenBSD/DragonFlyBSD, packages are in /usr/local"
    echo "    - On NetBSD, packages are in /usr/pkg"
    echo "    - On OmniOS/Illumos, packages are in /opt/ooce"
    exit 1
fi

pass_msg "CMake configuration successful."
echo ""

# ─── Step 4: Build ──────────────────────────────────────────────────────────
header_msg "Building TidesDB…"
echo ""

# Determine number of parallel jobs
if command -v nproc &>/dev/null; then
    NPROC="$(nproc)"
elif command -v sysctl &>/dev/null; then
    NPROC="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
else
    NPROC=4
fi

if ! cmake --build "$BUILD_DIR" --clean-first --verbose -j"$NPROC"; then
    fail_msg "Build failed."
    exit 1
fi

pass_msg "Build successful."
echo ""

# ─── Step 5: Install (optional) ─────────────────────────────────────────────
if [[ "$DO_INSTALL" == "true" ]]; then
    header_msg "Installing TidesDB…"
    echo ""

    INSTALL_ARGS=(--install "$BUILD_DIR")
    if [[ -n "$INSTALL_PREFIX" ]]; then
        INSTALL_ARGS+=(--prefix "$INSTALL_PREFIX")
    fi

    info_msg "cmake ${INSTALL_ARGS[*]}"
    echo ""

    if ! cmake "${INSTALL_ARGS[@]}"; then
        fail_msg "Install failed. You may need sudo."
        exit 1
    fi

    # On Linux, run ldconfig
    if [[ "$OS_FAMILY" == "linux" ]]; then
        if command -v ldconfig &>/dev/null; then
            info_msg "Running ldconfig to update shared library cache…"
            sudo ldconfig 2>/dev/null || warn_msg "Could not run ldconfig (may need sudo). Run: sudo ldconfig"
        fi
    fi

    pass_msg "Install successful."
    echo ""
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
header_msg "Build Summary"
echo ""
echo "  Library:  ${BUILD_DIR}/libtidesdb.$(if [[ "$OS_FAMILY" == "macos" ]]; then echo "dylib"; elif [[ "$BUILD_SHARED" == "ON" ]]; then echo "so"; else echo "a"; fi)"
echo "  Includes: ${BUILD_DIR}/include/tidesdb/"
echo "  Version:  $(grep -oP 'TIDESDB_VERSION "\K[^"]*' "${BUILD_DIR}/tidesdb_version.h" 2>/dev/null || echo "unknown")"
echo ""

if [[ "$BUILD_TESTS" == "ON" ]]; then
    echo "  Run tests:"
    echo "    cd ${BUILD_DIR} && ctest --output-on-failure"
    echo "    # or run individual tests:"
    echo "    ./${BUILD_DIR}/tidesdb_tests"
    echo "    ./${BUILD_DIR}/block_manager_tests"
    echo "    ./${BUILD_DIR}/skip_list_tests"
    echo "    ./${BUILD_DIR}/compress_tests"
    echo "    ./${BUILD_DIR}/bloom_filter_tests"
    echo "    ./${BUILD_DIR}/clock_cache_tests"
    echo "    ./${BUILD_DIR}/manifest_tests"
    echo "    ./${BUILD_DIR}/queue_tests"
    echo "    ./${BUILD_DIR}/btree_tests"
    echo "    ./${BUILD_DIR}/local_cache_tests"
    echo "    ./${BUILD_DIR}/objstore_tests"
fi

echo ""
pass_msg "Done."
