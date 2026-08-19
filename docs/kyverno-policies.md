# Kyverno policy enforcement (cross-cutting)

Two from-scratch policy charts apply to (almost) every other package's
rendered output:

- `packages/kyverno-pod-policies/local-chart` — pod-security hardening
  (dropped capabilities, privilege escalation, runAsNonRoot, seccompProfile,
  restricted volume types, hostPath, emptyDir sizeLimit,
  automountServiceAccountToken, etc.), tiered Enforce/Audit, CEL-based
  Kyverno `ClusterPolicy` resources.
- `packages/kyverno-cluster-policies/local-chart` — broader org
  governance/cluster security outside pod security (required
  labels/annotations, disallowed `priorityClassName`, etc.), with an
  opt-in category and an autogen-aware exception registry.

`make kyverno-policy-check PACKAGE=<name>` renders `<name>`'s chart plus both
policy charts (namespaced separately so their own self-exclusion rules don't
blind them to the target) and asserts the target against both rulesets via
`kyverno apply`. Enforce-tier violations fail the check; Audit-tier
violations are reported but don't fail it. There is **no allow-list** —
every package is held to the same bar; the only sanctioned way to suppress a
violation is a real `kyverno.io/v2` `PolicyException` added to one policy
chart's own `base.values.yaml` `exceptions:` (never `values.yaml`, whose
shipped default is deliberately `{}`).

Use the `kyverno-policy-fix` skill (or `/kyverno-policy-fix <package>`) to
investigate or fix a `kyverno-policy-check` failure on a package. Use the
`kyverno-add-policy` skill to author a brand-new rule inside
`kyverno-pod-policies`/`kyverno-cluster-policies` themselves (the opposite
direction — extending the ruleset, not complying with it).

`make kyverno-test` is the opposite direction: it proves a *policy chart's
own* CEL rule logic against curated fixtures in its `kyverno-test/` dir —
`make kyverno-policy-check` instead points the (already-proven) rulesets at
every *other* chart to catch real violations before merge. A policy chart's
fixtures often need config-dependent or Category F (opt-in) policies turned
on to actually exercise their CEL — that's what a `<chart-dir>/kyverno-test/
values.yaml`, if present, is for (layered on top of the normal
`make template` stack via `EXTRA_VALUES`, scoped to `make kyverno-test`
only — see [values layering](values-layering.md)). It's never picked up by
`make kyverno-policy-check` or any other renderer of the chart, so a
fixture-only policy toggle can never leak into the fleet-wide gate.

Both `kyverno-*` make targets require the `kyverno` CLI
(`scripts/pull-kyverno.sh`).
