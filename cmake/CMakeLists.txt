cmake_minimum_required(VERSION 3.25)
project(tidesdb-native C CXX)

set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# ── Compression libraries (static, PIC) ──────────────────────────────────────
# These must be built BEFORE TidesDB so its CMake can find the targets defined
# by their config packages.  We install them to a local prefix so TidesDB's
# CMake (via CMAKE_PREFIX_PATH / TIDESDB_*_TARGET) can resolve them.

# zstd
set(ZSTD_BUILD_PROGRAMS OFF CACHE BOOL "")
set(ZSTD_BUILD_CONTRIB OFF CACHE BOOL "")
set(ZSTD_BUILD_TESTS OFF CACHE BOOL "")
set(ZSTD_BUILD_STATIC ON CACHE BOOL "")
set(ZSTD_BUILD_SHARED OFF CACHE BOOL "")
add_subdirectory(${ZSTD_SOURCE_DIR}/build/cmake zstd_build)

# lz4
set(LZ4_BUILD_CLI OFF CACHE BOOL "")
set(LZ4_BUILD_LEGACY_LZ4C OFF CACHE BOOL "")
set(BUILD_STATIC_LIBS ON CACHE BOOL "")
set(BUILD_SHARED_LIBS OFF CACHE BOOL "")
add_subdirectory(${LZ4_SOURCE_DIR}/build/cmake lz4_build)

# snappy
set(SNAPPY_BUILD_TESTS OFF CACHE BOOL "")
set(SNAPPY_BUILD_BENCHMARKS OFF CACHE BOOL "")
set(SNAPPY_INSTALL OFF CACHE BOOL "")
set(BUILD_SHARED_LIBS OFF CACHE BOOL "")
add_subdirectory(${SNAPPY_SOURCE_DIR} snappy_build)


# ── TidesDB (built as SHARED, links static compression libs) ─────────────────
set(TIDESDB_WITH_ZSTD ON CACHE BOOL "")
set(TIDESDB_WITH_LZ4 ON CACHE BOOL "")
set(TIDESDB_WITH_SNAPPY ON CACHE BOOL "")
set(TIDESDB_BUILD_TESTS OFF CACHE BOOL "")
set(TIDESDB_WITH_SANITIZER OFF CACHE BOOL "")
set(ENABLE_READ_PROFILING OFF CACHE BOOL "")
set(TIDESDB_WITH_S3 OFF CACHE BOOL "")

# Point TidesDB at the static compression targets built above.
# The _tidesdb_link_compression function checks TIDESDB_<X>_TARGET first,
# then known CMake target names, then falls back to -l<name>.
# We use the known target names created by the add_subdirectory calls.
set(TIDESDB_ZSTD_TARGET libzstd_static CACHE STRING "")
set(TIDESDB_LZ4_TARGET lz4_static CACHE STRING "")
set(TIDESDB_SNAPPY_TARGET snappy CACHE STRING "")

# Build TidesDB as a shared library so libtidesdb.so is produced.
set(BUILD_SHARED_LIBS ON CACHE BOOL "")

add_subdirectory(${TIDESDB_SOURCE_DIR} tidesdb_build)

# Ensure the build-tree include directory exists for downstream consumers.
# TidesDB's CMake already creates ${CMAKE_CURRENT_BINARY_DIR}/tidesdb_build/include
# as a POST_BUILD step; we just need it present before anything tries to use it.

# ── Install target ───────────────────────────────────────────────────────────
# The compression libs are already installed by the individual builds above
# (if CMAKE_INSTALL_PREFIX is set).  TidesDB installs via its own install()
# rules.  This project's build.sh orchestrates the install steps.
