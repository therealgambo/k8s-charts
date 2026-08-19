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
# via `kyverno apply --audit-warn`. No separate allow-list here -- the only way to suppress a
# violation is a real, reviewed kyverno.io/v2 PolicyException committed to
# kyverno-pod-policies/kyverno-cluster-policies' own `exceptions:` values (see each chart's
# base.values.yaml -- NOT values.yaml, whose shipped default deliberately stays `{}`, see the
# comment above `exceptions:` there), the same object that (once packages/kyverno's
# policyExceptions feature ships)
# governs real admission too -- there is no check-only escape hatch a target package can flip on
# its own. --exceptions-within-policies below makes `kyverno apply` actually honor those
# PolicyExceptions, since they render as part of the same pod-policies.yaml/cluster-policies.yaml
# files passed as this command's policy arguments (PolicyException is just another resource kind
# each chart emits) -- without that flag `kyverno apply` parses them out of those files but never
# applies them, silently failing every exempted resource exactly as if no exception existed at
# all (verified directly: same exception, same violations, until this flag was added).
# kyverno-cluster-policies' Category F (opt-in) policies render nothing by default, same as this
# check's target packages get by default -- they only apply here if a target package's own values
# happen to opt one in, same as any other policy.
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

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

# Each rendered into its own namespace, deliberately different from each other and from the
# target chart's own namespace (`make template` renders every package into --namespace <package
# name> -- see Makefile -- so the target here always lands in --namespace ${name}, never
# "default"). Every ClusterPolicy in both charts defensively excludes its OWN release
# namespace (see each chart's own excludeNamespaces helper in _helpers.tpl) -- if any two of the
# three renders shared a namespace, every target resource would be silently excluded from that
# ruleset instead of actually evaluated.
#
# All three renders go through `make template` -- the one authoritative entry point for rendering
# a chart in this repo -- rather than reimplementing its values layering here. That's safe to do
# unconditionally for the policy charts themselves too: `ci.values.yaml` never carries anything but
# whatever's needed for `helm template` to succeed in CI (see docs/values-layering.md), and each
# chart's own `kyverno-test`-only config/opt-in-policy overrides live in a separate
# `kyverno-test/values.yaml` that only `make kyverno-test` layers in (see the root Makefile) -- so
# nothing test-fixture-only ever leaks into this fleet-wide gate. `base.values.yaml` IS layered in,
# same as always -- that's deliberately where real, live `exceptions:` entries live (never in
# values.yaml's shipped default, see the comment above `exceptions:` in each chart's values.yaml),
# so skipping it here would make this check blind to every legitimate exception the moment one
# exists.
make --no-print-directory template PACKAGE=kyverno-pod-policies > "${tmpdir}/pod-policies.yaml"
make --no-print-directory template PACKAGE=kyverno-cluster-policies > "${tmpdir}/cluster-policies.yaml"
make --no-print-directory template PACKAGE="${name}" ENV="${env}" > "${tmpdir}/target.yaml"

# `kyverno apply` below only ever reports on resources it was actually GIVEN -- a policy whose
# ENTIRE match is a kind the target chart never renders has nothing to evaluate at all: no pass,
# no fail, no line anywhere in the output below, easy to mistake for "compliant" when it was
# simply never checked. require-labels (Namespace-only) is the known case (most charts never
# render their own Namespace) -- checked generically here (any policy matching `kinds:
# [Namespace]` exactly) so a future Namespace-only policy is still caught automatically.
# Deliberately NOT generalized to every policy/kind pair: most `kinds: [Pod]` policies are covered
# via Kyverno's autogen expansion (Pod -> Deployment/DaemonSet/... at evaluation time, invisible
# in this static template render), and plenty of policies (protect-kyverno-resources,
# disallow-webhook-tampering, ...) are legitimately scoped to kinds most charts will never render
# at all -- a blind "kind not present" check would flood with false positives for those.
# Informational only -- never fails this check, since "add a Namespace" is a real design decision
# for a package, not something to force. See the kyverno-policy-fix skill's SKILL.md step 4a-4.
if ! grep -q '^kind: Namespace$' "${tmpdir}/target.yaml"; then
    namespace_only_policies="$(awk '
        /^metadata:$/ { in_metadata=1; next }
        in_metadata && /^  name: / { policy=$2; in_metadata=0 }
        /kinds: \[Namespace\]/ { print policy }
    ' "${tmpdir}/pod-policies.yaml" "${tmpdir}/cluster-policies.yaml" | sort -u)"
    if [[ -n "${namespace_only_policies}" ]]; then
        echo "note: ${name} renders no Namespace -- the following Namespace-only polic(ies) were" >&2
        echo "  NOT evaluated (not passed -- just never checked): ${namespace_only_policies}" >&2
    fi
fi

set +e
bin/kyverno apply "${tmpdir}/pod-policies.yaml" "${tmpdir}/cluster-policies.yaml" \
    --resource "${tmpdir}/target.yaml" --audit-warn --detailed-results --exceptions-within-policies
status=$?
set -e

exit "${status}"
