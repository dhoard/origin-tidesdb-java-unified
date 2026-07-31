#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
WORK_DIR="${WORK_DIR:-$PROJECT_DIR/build/work}"
mkdir -p "$WORK_DIR"

# Parse upstream.properties
while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
    key=$(echo "$key" | xargs | tr '.-' '__')
    value=$(echo "$value" | xargs)
    declare "$key=$value"
done < "$PROJECT_DIR/upstream.properties"

# clone_and_checkout <name> <branch> <tag> <repo_url> <dest_dir>
clone_and_checkout() {
    local name="$1" branch="$2" tag="$3" repo="$4" dest="$5"
    if [ ! -d "$dest" ]; then
        git clone --branch "$branch" "$repo" "$dest"
    else
        git -C "$dest" fetch origin "$branch"
        git -C "$dest" checkout "$branch"
        git -C "$dest" pull --ff-only origin "$branch"
    fi
    if [ -n "$tag" ]; then
        git -C "$dest" checkout "$tag"
    fi
}

clone_and_checkout tidesdb "$tidesdb_branch" "$tidesdb_tag" "$tidesdb_repo" "$WORK_DIR/tidesdb"
clone_and_checkout tidesdb-java "$tidesdb_java_branch" "$tidesdb_java_tag" "$tidesdb_java_repo" "$WORK_DIR/tidesdb-java"

echo "Sources checked out."
