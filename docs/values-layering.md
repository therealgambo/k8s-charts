# Values file layering

Every packaged chart is rendered with the same precedence so environment
overrides never shadow each other:

1. `values.yaml` — the chart's own defaults (implicit)
2. `base.values.yaml` — shared overrides for the package, if present
3. `ci.values.yaml` — CI/testing-only config (exercises opt-in policy
   behavior for kyverno-test), if present
4. `<env>.values.yaml` — environment-specific overrides (`test`, `staging`,
   `production`), if present

All of these live alongside `values.yaml` inside the prepared chart dir (see
[package structure](package-structure.md)), so they're captured into
`generated-changes/` by `make patch` like any other local edit and persist
across future `make prepare` runs.
