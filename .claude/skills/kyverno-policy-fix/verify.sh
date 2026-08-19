#!/usr/bin/env bash
set -euo pipefail

# Renders <package> against this repo's OWN kyverno-pod-policies + kyverno-cluster-policies
# rulesets, same as `make kyverno-policy-check`/scripts/kyverno-policy-check.sh, plus two things
# that script doesn't give you:
#
#   1. Failures grouped and counted by policy id, so a long flat `kyverno apply` transcript turns
#      into "which ids do I actually need to fix, and how many resources does each touch".
#   2. --with <values-file>: test a CANDIDATE values change (e.g. a would-be base.values.yaml
#      addition) without writing it into the repo. Renders the target chart TWICE -- once with the
#      normal values.yaml -> base.values.yaml -> ci.values.yaml -> ENV.values.yaml stack (same
#      order `make template` uses, see Makefile), once with the candidate file layered on top of
#      that -- and diffs the two violation lists into CLEARED / STILL FAILING / NEWLY FAILING
#      sections, so you can confirm a fix actually fixes what you think it does (and doesn't
#      regress anything else) before touching packages/<name>/charts/base.values.yaml for real.
#
# See the kyverno-policy-fix skill's SKILL.md for how this fits into the overall workflow.
#
# Usage:
#   verify.sh <package> [--env <env>] [--with <values-file>]
#
# Requires: helm, the kyverno CLI (bin/kyverno, via scripts/pull-kyverno.sh), and <package>'s
# chart already prepared (`make prepare PACKAGE=<package>`).

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "${REPO_ROOT}"

name="${1:?usage: $(basename "$0") <package> [--env <env>] [--with <values-file>]}"
shift

env="staging"
with_file=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env) env="$2"; shift 2 ;;
        --with) with_file="$2"; shift 2 ;;
        *) echo "error: unknown arg '$1'" >&2; exit 1 ;;
    esac
done

target_chart="$(./scripts/chart-dir.sh "${name}")"
test -d "${target_chart}" || { echo "error: ${target_chart} not found -- run 'make prepare PACKAGE=${name}' first" >&2; exit 1; }

pod_policies_chart="$(./scripts/chart-dir.sh kyverno-pod-policies)"
cluster_policies_chart="$(./scripts/chart-dir.sh kyverno-cluster-policies)"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

helm template kyverno-pod-policies "${pod_policies_chart}" --namespace kyverno-pod-policies \
    > "${tmpdir}/pod-policies.yaml"
helm template kyverno-cluster-policies "${cluster_policies_chart}" --namespace kyverno-cluster-policies \
    > "${tmpdir}/cluster-policies.yaml"

# Reimplements the value-file stack `make template` uses rather than shelling out to it, since
# that target has no way to layer one more -f on top for --with.
render() {
    local out="$1"; shift
    local values=()
    [[ -f "${target_chart}/values.yaml" ]] && values+=(-f "${target_chart}/values.yaml")
    [[ -f "${target_chart}/base.values.yaml" ]] && values+=(-f "${target_chart}/base.values.yaml")
    [[ -f "${target_chart}/ci.values.yaml" ]] && values+=(-f "${target_chart}/ci.values.yaml")
    [[ -f "${target_chart}/${env}.values.yaml" ]] && values+=(-f "${target_chart}/${env}.values.yaml")
    for f in "$@"; do values+=(-f "$f"); done
    helm template "${target_chart}" "${values[@]}" > "${out}"
}

summarize() {
    local log="$1" label="$2"
    echo "--- ${label}: failures by policy id ---"
    grep -E '^policy [a-z0-9-]+ -> resource .* failed' "${log}" \
        | sed -E 's/^policy ([a-z0-9-]+) ->.*/\1/' | sort | uniq -c | sort -rn
}

render "${tmpdir}/target.yaml"
bin/kyverno apply "${tmpdir}/pod-policies.yaml" "${tmpdir}/cluster-policies.yaml" \
    --resource "${tmpdir}/target.yaml" --audit-warn --detailed-results --exceptions-within-policies \
    > "${tmpdir}/baseline.log" 2>&1 || true
cat "${tmpdir}/baseline.log"
echo
summarize "${tmpdir}/baseline.log" "baseline"

if [[ -n "${with_file}" ]]; then
    echo
    echo "=== re-rendering with ${with_file} layered on top ==="
    render "${tmpdir}/target-with.yaml" "${with_file}"
    bin/kyverno apply "${tmpdir}/pod-policies.yaml" "${tmpdir}/cluster-policies.yaml" \
        --resource "${tmpdir}/target-with.yaml" --audit-warn --detailed-results --exceptions-within-policies \
        > "${tmpdir}/with.log" 2>&1 || true
    cat "${tmpdir}/with.log"
    echo
    summarize "${tmpdir}/with.log" "with ${with_file}"

    grep -E '^policy [a-z0-9-]+ -> resource .* failed' "${tmpdir}/baseline.log" | sort -u > "${tmpdir}/baseline.violations"
    grep -E '^policy [a-z0-9-]+ -> resource .* failed' "${tmpdir}/with.log" | sort -u > "${tmpdir}/with.violations"

    echo
    echo "--- CLEARED by ${with_file} ---"
    comm -23 "${tmpdir}/baseline.violations" "${tmpdir}/with.violations" || true
    echo
    echo "--- STILL FAILING ---"
    comm -12 "${tmpdir}/baseline.violations" "${tmpdir}/with.violations" || true
    echo
    echo "--- NEWLY FAILING (regression -- investigate before committing) ---"
    comm -13 "${tmpdir}/baseline.violations" "${tmpdir}/with.violations" || true
fi
