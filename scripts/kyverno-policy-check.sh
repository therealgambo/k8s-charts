#!/usr/bin/env bash
set -euo pipefail

# Renders <package>'s chart and asserts the result against this repo's OWN
# packages/kyverno-pod-policies/local-chart ruleset -- always rendered fresh from source, never a
# separately pulled/pinned copy, so this check can never drift from the policies actually shipped
# here. Complements `make kyverno-test PACKAGE=kyverno-pod-policies`, which proves that chart's own
# CEL rule *logic* is correct against curated fixtures -- this instead points the (already-proven)
# ruleset at every OTHER chart in the repo, to catch real Pod Security Standards violations before
# they merge.
#
# Enforcement mirrors exactly what the policies chart itself ships with (see its README):
# baseline-tier violations (validationFailureAction: Enforce) fail this check; restricted-tier
# violations (Audit) are reported but never fail it, via `kyverno apply --audit-warn`. No
# allow-list or exceptions here -- every package is held to the same bar, unconditionally.
#
# Usage: ./scripts/kyverno-policy-check.sh <package> [env]
#
# Requires: helm, the kyverno CLI (./scripts/pull-kyverno.sh), and <package>'s chart already
# prepared (`make prepare PACKAGE=<package>`).

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

name="${1:?usage: $(basename "$0") <package> [env]}"
env="${2:-staging}"

# Neither renders any Pod-shaped resource (ClusterPolicy/PolicyException, NetworkPolicy) for this
# ruleset to ever match -- skip outright rather than run a pointless (if harmless) scan.
if [[ "${name}" == "kyverno-pod-policies" || "${name}" == "network-policies" ]]; then
    echo "skip: ${name} renders no workload resources for the pod-policies ruleset to evaluate"
    exit 0
fi

target_chart="$(./scripts/chart-dir.sh "${name}")"
test -d "${target_chart}" || { echo "error: ${target_chart} not found -- run 'make prepare PACKAGE=${name}' first" >&2; exit 1; }

policies_chart="$(./scripts/chart-dir.sh kyverno-pod-policies)"

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

# Rendered into its own namespace, deliberately different from whatever namespace the target
# chart's resources land in (helm template defaults to "default" with no --namespace given).
# Every ClusterPolicy here defensively excludes its OWN release namespace (see
# kyverno-pod-policies.excludeNamespaces in _helpers.tpl) -- if both renders shared a namespace,
# every target resource would be silently excluded instead of actually evaluated.
helm template kyverno-pod-policies "${policies_chart}" --namespace kyverno-pod-policies \
    > "${tmpdir}/policies.yaml"

# Same values layering `make template` uses -- reuse it directly rather than re-implement it here.
make --no-print-directory template PACKAGE="${name}" ENV="${env}" > "${tmpdir}/target.yaml"

set +e
bin/kyverno apply "${tmpdir}/policies.yaml" --resource "${tmpdir}/target.yaml" --audit-warn --detailed-results
status=$?
set -e

exit "${status}"
