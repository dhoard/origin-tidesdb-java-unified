#!/usr/bin/env bash
#
# build.sh — full build entry point.
#
# 1. build-dependencies.sh: cleans ./libs and ./workspace, clones and builds
#    the native dependencies, and copies the .so files into ./libs.
# 2. ./mvnw clean install: builds the unified JAR with the embedded natives.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"

cd "$PROJECT_DIR"

./build-dependencies.sh
./mvnw clean install
