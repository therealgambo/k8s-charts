#!/usr/bin/env bash
set -euo pipefail

# Prints the names of packages under packages/ touched between two git refs,
# one per line. With --all, prints every tracked package instead (used for
# manual/non-PR runs, where there's no base ref to diff against).
#
# Usage:
#   ./scripts/changed-packages.sh <base-ref> <head-ref>
#   ./scripts/changed-packages.sh --all

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

is_package() {
    [[ -f "${REPO_ROOT}/packages/$1/package.yaml" ]]
}

if [[ "${1:-}" == "--all" ]]; then
    for dir in "${REPO_ROOT}"/packages/*/; do
        name="$(basename "${dir}")"
        is_package "${name}" && echo "${name}"
    done
    exit 0
fi

if [[ $# -ne 2 ]]; then
    echo "usage: $(basename "$0") <base-ref> <head-ref> | --all" >&2
    exit 1
fi

git -C "${REPO_ROOT}" diff --name-only "$1" "$2" -- packages/ \
    | awk -F/ '{print $2}' \
    | sort -u \
    | while read -r name; do
        is_package "${name}" && echo "${name}"
      done
