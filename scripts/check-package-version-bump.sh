#!/usr/bin/env bash
set -euo pipefail

# Verifies a package's packageVersion field moved correctly relative to BASE_REF, per the
# convention documented in packages/README.md:
#   - packageVersion resets to "01" when the upstream `url`/`commit` changes (a real new upstream
#     release) -- this keeps a *published* chart's version tied 1:1 to what upstream actually
#     shipped, per the packageVersion field's whole reason for existing: unique, immutable
#     versions for what `make charts` publishes.
#   - packageVersion strictly increases whenever anything else under packages/<name>/ changes,
#     with the upstream url/commit unchanged -- a hand-edited patch under generated-changes/, a
#     values-file tweak, or (for a from-scratch `url: local` package, which has no upstream to
#     bump against at all) any edit under local-chart/ -- otherwise two different patch sets would
#     publish under the same chart version. This applies equally to every package, forked or
#     from-scratch: what triggers the bump differs (an upstream release vs. a hand-authored
#     change), but the requirement that a change needs its own packageVersion does not.
#
# Usage:
#   ./scripts/check-package-version-bump.sh <base-ref> <package-name> [head-ref]
#
# With no head-ref, compares BASE_REF against the working tree (including uncommitted changes),
# so this can be run locally before anything is even committed. CI always passes an explicit
# head-ref (a committed SHA) for an exact, reproducible check -- see validate-charts.yaml.
#
# Known gap: upstream-changed detection only compares the package's own top-level `url`/`commit`
# fields. No package in this repo currently uses `additionalCharts` (a second upstream pulled
# alongside the main one) -- if one starts to, this script needs to compare those sub-entries'
# url/commit too, since a bump there wouldn't otherwise be distinguished from a plain patch change
# (it would still correctly demand a packageVersion bump, just via the strict-increase path
# instead of the reset-to-01 one).

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
    # $@ = pathspecs, relative to repo root. Diffs base_ref -> head_ref/worktree.
    if [[ -n "${head_ref}" ]]; then
        git -C "${REPO_ROOT}" diff --quiet "${base_ref}" "${head_ref}" -- "$@" 2>/dev/null
    else
        git -C "${REPO_ROOT}" diff --quiet "${base_ref}" -- "$@" 2>/dev/null
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

base_url="$(get_field "${base_pkg}" url)"
head_url="$(get_field "${head_pkg}" url)"
base_commit="$(get_field "${base_pkg}" commit)"
head_commit="$(get_field "${head_pkg}" commit)"
base_pv="$(get_field "${base_pkg}" packageVersion)"
head_pv="$(get_field "${head_pkg}" packageVersion)"

# `url: local` packages (network-policies, kyverno-pod-policies, kyverno-cluster-policies) never
# have a real upstream release to reset against -- url/commit just never differ for them -- but
# they still get held to the same bar below: any other change under packages/<name>/ still needs
# a strict packageVersion bump.
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

# Upstream unchanged: anything else that changed under packages/<name>/ -- package.yaml itself
# (minus the packageVersion line), generated-changes/, local-chart/, values files, kyverno-test
# fixtures, whatever -- requires a strict bump. Excluding package.yaml from the directory pathspec
# and diffing it separately (with packageVersion stripped) is what lets a packageVersion-only edit
# not count as "something changed" on its own.
strip_pv() { grep -v '^packageVersion:' <<< "$1" || true; }

pkg_content_changed=0
[[ "$(strip_pv "${base_pkg}")" != "$(strip_pv "${head_pkg}")" ]] && pkg_content_changed=1

other_files_changed=0
diff_quiet "packages/${package}/" ":(exclude)${pkg_path}" || other_files_changed=1

if [[ "${pkg_content_changed}" -eq 0 && "${other_files_changed}" -eq 0 ]]; then
    echo "${package}: no upstream or patch change, packageVersion check skipped"
    exit 0
fi

if [[ "${head_pv}" == "${base_pv}" ]]; then
    echo "error: ${package}: packages/${package}/ changed with no upstream url/commit bump, but packageVersion wasn't bumped (still '${head_pv}') -- published charts need a unique, immutable version per change" >&2
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
