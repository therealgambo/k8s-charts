#!/usr/bin/env bash
set -euo pipefail

# Renders <package> against this repo's OWN kyverno-pod-policies + kyverno-cluster-policies
# rulesets, same as `make kyverno-policy-check`/scripts/kyverno-policy-check.sh, plus two things
# that script doesn't give you:
#
#   1. Failures grouped and counted by policy id, so a long flat `kyverno apply` transcript turns
#      into "which ids do I actually need to fix, and how many resources does each touch".
#   2. --with <values-file>: test a CANDIDATE values change (e.g. a would-be base.values.yaml
#      addition) without writing it into the repo. Renders the target chart TWICE via
#      `make template` -- once with its normal stack, once with the candidate file layered on top
#      via EXTRA_VALUES (see docs/values-layering.md) -- and diffs the two violation lists into
#      CLEARED / STILL FAILING / NEWLY FAILING sections, so you can confirm a fix actually fixes
#      what you think it does (and doesn't regress anything else) before touching
#      packages/<name>/charts/base.values.yaml for real.
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

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

# All renders go through `make template` -- the one authoritative entry point for rendering a
# chart in this repo -- matching scripts/kyverno-policy-check.sh exactly, including base.values.
# yaml (where real, live `exceptions:` entries live for these two charts -- never values.yaml's
# shipped default, see the comment above `exceptions:` in each chart's values.yaml).
make --no-print-directory template PACKAGE=kyverno-pod-policies > "${tmpdir}/pod-policies.yaml"
make --no-print-directory template PACKAGE=kyverno-cluster-policies > "${tmpdir}/cluster-policies.yaml"

render() {
    local out="$1"; shift
    local extra="${1:-}"
    make --no-print-directory template PACKAGE="${name}" ENV="${env}" EXTRA_VALUES="${extra}" > "${out}"
}

summarize() {
    local log="$1" label="$2"
    echo "--- ${label}: failures by policy id ---"
    grep -E '^policy [a-z0-9-]+ -> resource .* failed' "${log}" \
        | sed -E 's/^policy ([a-z0-9-]+) ->.*/\1/' | sort | uniq -c | sort -rn
}

# kyverno apply only ever reports on resources it was actually GIVEN -- a policy whose ENTIRE
# match is a kind the target chart never renders has nothing to evaluate at all: no pass, no fail,
# no line anywhere in the output, easy to mistake for "compliant" when it was simply never
# checked. require-labels (Namespace-only) is the known case (most charts never render their own
# Namespace) -- checked generically here (any policy matching `kinds: [Namespace]` exactly) so a
# future Namespace-only policy is still caught automatically. Deliberately NOT generalized to
# every policy/kind pair: most `kinds: [Pod]` policies are covered via Kyverno's autogen expansion
# (Pod -> Deployment/DaemonSet/... at evaluation time, invisible in this static template render),
# and plenty of policies (protect-kyverno-resources, disallow-webhook-tampering, ...) are
# legitimately scoped to kinds most charts will never render at all -- a blind "kind not present"
# check floods with false positives for those. See kyverno-policy-fix SKILL.md step 4a-4.
check_missing_namespace() {
    local resource_file="$1"
    grep -q '^kind: Namespace$' "${resource_file}" && return 0
    # Track the most recently seen `metadata: / name:` (every doc in these two files is a
    # ClusterPolicy or PolicyException, always name-before-rules, so this reliably attributes
    # each `kinds: [...]` line to its owning policy) and print it whenever that policy's match is
    # exactly [Namespace].
    local namespace_only_policies
    namespace_only_policies="$(awk '
        /^metadata:$/ { in_metadata=1; next }
        in_metadata && /^  name: / { policy=$2; in_metadata=0 }
        /kinds: \[Namespace\]/ { print policy }
    ' "${tmpdir}/pod-policies.yaml" "${tmpdir}/cluster-policies.yaml" | sort -u)"
    if [[ -n "${namespace_only_policies}" ]]; then
        echo
        echo "⚠ this chart renders no Namespace -- the following Namespace-only polic(ies) were NOT"
        echo "  evaluated at all (not passed -- just never checked):"
        echo "${namespace_only_policies}" | sed 's/^/    - /'
        echo "  Confirm by hand whether that's actually fine or whether this chart needs its own"
        echo "  Namespace, per SKILL.md step 4a-4."
    fi
}

render "${tmpdir}/target.yaml"
check_missing_namespace "${tmpdir}/target.yaml"
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
