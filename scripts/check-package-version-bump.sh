#!/usr/bin/env bash
set -euo pipefail

# Verifies a package's packageVersion field moved correctly relative to BASE_REF, per the
# convention documented in packages/README.md:
#   - packageVersion resets to "01" when the upstream `url`/`commit` changes (a real new upstream
#     release) -- this keeps a *published* chart's version tied 1:1 to what upstream actually
#     shipped, per the packageVersion field's whole reason for existing: unique, immutable
#     versions for what `make charts` publishes.
#   - packageVersion strictly increases when anything else about the package changes (a hand-
#     edited patch under generated-changes/, a values-file tweak, etc.) with the upstream
#     url/commit unchanged -- otherwise two different patch sets would publish under the same
#     chart version.
# Packages pinned `url: local` (the from-scratch charts -- currently network-policies,
# kyverno-pod-policies, kyverno-cluster-policies) have no upstream to bump against and are
# skipped entirely.
#
# Usage:
#   ./scripts/check-package-version-bump.sh <base-ref> <package-name> [head-ref]
#
# With no head-ref, compares BASE_REF against the working tree (including uncommitted changes),
# so this can be run locally before anything is even committed. CI always passes an explicit
# head-ref (a committed SHA) for an exact, reproducible check -- see validate-charts.yaml.
#
# Known gap: only compares the package's own top-level `url`/`commit` fields. No package in this
# repo currently uses `additionalCharts` (a second upstream pulled alongside the main one) -- if
# one starts to, this script needs to compare those sub-entries' url/commit too, since a bump
# there wouldn't otherwise be detected.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "usage: $(basename "$0") <base-ref> <package-name> [head-ref]" >&2
    exit 1
fi

base_ref="$1"
package="$2"
head_ref="${3:-}"
pkg_path="packages/${package}/package.yaml"

show_base() {
    git -C "${REPO_ROOT}" show "${base_ref}:$1" 2>/dev/null || true
}

show_head() {
    if [[ -n "${head_ref}" ]]; then
        git -C "${REPO_ROOT}" show "${head_ref}:$1" 2>/dev/null || true
    else
        [[ -f "${REPO_ROOT}/$1" ]] && cat "${REPO_ROOT}/$1" || true
    fi
}

diff_quiet() {
    # $1 = path, relative to repo root. Diffs base_ref -> head_ref/worktree.
    if [[ -n "${head_ref}" ]]; then
        git -C "${REPO_ROOT}" diff --quiet "${base_ref}" "${head_ref}" -- "$1" 2>/dev/null
    else
        git -C "${REPO_ROOT}" diff --quiet "${base_ref}" -- "$1" 2>/dev/null
    fi
}

get_field() {
    # $1 = package.yaml content, $2 = top-level key. Every field this script cares about
    # (url, commit, packageVersion) is a flat, unindented scalar -- same assumption
    # scripts/chart-dir.sh already makes about workingDir.
    awk -F': *' -v k="^${2}:[[:space:]]*" '$0 ~ k {sub(/^[^:]+: */,""); gsub(/^"|"$/,""); print; exit}' <<< "$1"
}

head_pkg="$(show_head "${pkg_path}")"
if [[ -z "${head_pkg}" ]]; then
    echo "error: ${pkg_path} not found at $( [[ -n "${head_ref}" ]] && echo "${head_ref}" || echo "the working tree" )" >&2
    exit 1
fi

base_pkg="$(show_base "${pkg_path}")"
if [[ -z "${base_pkg}" ]]; then
    echo "${package}: new package (no ${pkg_path} at ${base_ref}), skipping packageVersion check"
    exit 0
fi

head_url="$(get_field "${head_pkg}" url)"
if [[ "${head_url}" == "local" ]]; then
    echo "${package}: url: local (from-scratch package), skipping packageVersion check"
    exit 0
fi

base_url="$(get_field "${base_pkg}" url)"
head_commit="$(get_field "${head_pkg}" commit)"
base_commit="$(get_field "${base_pkg}" commit)"
head_pv="$(get_field "${head_pkg}" packageVersion)"
base_pv="$(get_field "${base_pkg}" packageVersion)"

upstream_changed=0
[[ "${head_url}" != "${base_url}" || "${head_commit}" != "${base_commit}" ]] && upstream_changed=1

if [[ "${upstream_changed}" -eq 1 ]]; then
    if [[ "${head_pv}" != "01" ]]; then
        echo "error: ${package}: upstream url/commit changed (${base_url:-${base_commit}} -> ${head_url:-${head_commit}}) but packageVersion is '${head_pv}' -- reset it to '01' for the new upstream release" >&2
        exit 1
    fi
    echo "${package}: upstream url/commit changed, packageVersion correctly reset to 01"
    exit 0
fi

# Upstream unchanged: anything else that changed about the package (package.yaml itself, minus
# the packageVersion line -- or its generated-changes/ patch set) requires a strict bump.
strip_pv() { grep -v '^packageVersion:' <<< "$1" || true; }

pkg_content_changed=0
[[ "$(strip_pv "${base_pkg}")" != "$(strip_pv "${head_pkg}")" ]] && pkg_content_changed=1

patch_changed=0
diff_quiet "packages/${package}/generated-changes/" || patch_changed=1

if [[ "${pkg_content_changed}" -eq 0 && "${patch_changed}" -eq 0 ]]; then
    echo "${package}: no upstream or patch change, packageVersion check skipped"
    exit 0
fi

if [[ "${head_pv}" == "${base_pv}" ]]; then
    echo "error: ${package}: package.yaml/generated-changes changed with no upstream url/commit bump, but packageVersion wasn't bumped (still '${head_pv}') -- published charts need a unique, immutable version per patch set" >&2
    exit 1
fi

if ! [[ "${base_pv}" =~ ^[0-9]+$ && "${head_pv}" =~ ^[0-9]+$ ]]; then
    echo "error: ${package}: packageVersion must be a plain unsigned integer (got base='${base_pv}' head='${head_pv}')" >&2
    exit 1
fi

# 10# forces base-10 interpretation -- without it, bash treats a leading-zero value like "08"/"09"
# as (invalid) octal and errors out.
if (( 10#${head_pv} <= 10#${base_pv} )); then
    echo "error: ${package}: packageVersion must strictly increase for a patch-only change (base='${base_pv}' head='${head_pv}')" >&2
    exit 1
fi

echo "${package}: packageVersion bumped ${base_pv} -> ${head_pv} for a patch-only change"
