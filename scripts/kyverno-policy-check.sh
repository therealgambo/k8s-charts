#!/usr/bin/env bash
set -euo pipefail

# Renders <package>'s chart and asserts the result against this repo's OWN
# packages/kyverno-pod-policies/local-chart AND packages/kyverno-cluster-policies/local-chart
# rulesets, layered together -- always rendered fresh from source, never a separately pulled/
# pinned copy, so this check can never drift from the policies actually shipped here. Complements
# `make kyverno-test PACKAGE=<policies-chart>`, which proves each policies chart's OWN CEL rule
# *logic* is correct against curated fixtures -- this instead points both (already-proven)
# rulesets at every OTHER chart in the repo, to catch real violations before they merge.
#
# Enforcement mirrors exactly what the policies charts themselves ship with (see their READMEs):
# Enforce-tier violations fail this check; Audit-tier violations are reported but never fail it,
# via `kyverno apply --audit-warn`. No allow-list or exceptions here -- every package is held to
# the same bar, unconditionally. kyverno-cluster-policies' Category F (opt-in) policies render
# nothing by default, same as this check's target packages get by default -- they only apply here
# if a target package's own values happen to opt one in, same as any other policy.
#
# Usage: ./scripts/kyverno-policy-check.sh <package> [env]
#
# Requires: helm, the kyverno CLI (./scripts/pull-kyverno.sh), and <package>'s chart already
# prepared (`make prepare PACKAGE=<package>`).

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

name="${1:?usage: $(basename "$0") <package> [env]}"
env="${2:-staging}"

# None of the three render any workload-shaped resource (ClusterPolicy/PolicyException,
# NetworkPolicy) for either ruleset to ever match -- skip outright rather than run a pointless (if
# harmless) scan.
if [[ "${name}" == "kyverno-pod-policies" || "${name}" == "kyverno-cluster-policies" || "${name}" == "network-policies" ]]; then
    echo "skip: ${name} renders no workload resources for the policy rulesets to evaluate"
    exit 0
fi

target_chart="$(./scripts/chart-dir.sh "${name}")"
test -d "${target_chart}" || { echo "error: ${target_chart} not found -- run 'make prepare PACKAGE=${name}' first" >&2; exit 1; }

pod_policies_chart="$(./scripts/chart-dir.sh kyverno-pod-policies)"
cluster_policies_chart="$(./scripts/chart-dir.sh kyverno-cluster-policies)"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

# Each rendered into its own namespace, deliberately different from each other and from whatever
# namespace the target chart's resources land in (helm template defaults to "default" with no
# --namespace given). Every ClusterPolicy in both charts defensively excludes its OWN release
# namespace (see each chart's own excludeNamespaces helper in _helpers.tpl) -- if any two of the
# three renders shared a namespace, every target resource would be silently excluded from that
# ruleset instead of actually evaluated. Rendered directly via `helm template`, NOT `make
# template` -- deliberately bypasses kyverno-cluster-policies' own `ci.values.yaml` (which exists
# only to exercise config-dependent/opt-in policies for that chart's own kyverno-test), so this
# check always evaluates the two rulesets' real shipped defaults, not a testing-only configuration.
helm template kyverno-pod-policies "${pod_policies_chart}" --namespace kyverno-pod-policies \
    > "${tmpdir}/pod-policies.yaml"
helm template kyverno-cluster-policies "${cluster_policies_chart}" --namespace kyverno-cluster-policies \
    > "${tmpdir}/cluster-policies.yaml"

# Same values layering `make template` uses -- reuse it directly rather than re-implement it here.
make --no-print-directory template PACKAGE="${name}" ENV="${env}" > "${tmpdir}/target.yaml"

set +e
bin/kyverno apply "${tmpdir}/pod-policies.yaml" "${tmpdir}/cluster-policies.yaml" \
    --resource "${tmpdir}/target.yaml" --audit-warn --detailed-results
status=$?
set -e

exit "${status}"
