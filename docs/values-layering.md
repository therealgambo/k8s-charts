# Values file layering

`make template` is the one authoritative entry point for rendering a
package's chart — every mechanism in this repo that needs a chart's rendered
manifests (CI's kubeconform/image-availability/kyverno-policy-check jobs,
`make kyverno-test`, the kyverno-policy-fix skill's verify.sh, ...) goes
through it rather than reimplementing this layering by hand. It renders with
the same precedence every time, so environment overrides never shadow each
other:

1. `values.yaml` — the chart's own defaults (implicit)
2. `base.values.yaml` — shared overrides for the package, if present
3. `ci.values.yaml` — whatever's needed for `helm template` to succeed in CI
   (a dummy secret, a stand-in for a `required` value with no sane default,
   ...), if present — never real config, and never a place to exercise
   optional/opt-in behavior for a specific consumer of the render (that's
   what `EXTRA_VALUES` is for, below)
4. `<env>.values.yaml` — environment-specific overrides (`test`, `staging`,
   `production`), if present

A caller that needs one more values file layered on top of that stack — a
candidate change under test, or overrides scoped to one specific consumer of
the render (e.g. `make kyverno-test`'s own fixture-only config, see
[Kyverno policy enforcement](kyverno-policies.md)) — passes
`EXTRA_VALUES=<path>` rather than reimplementing the stack above to splice
one more `-f` in. It's layered last, so it can override anything.

Both the release name and `--namespace` are set to the package name, so a
package's rendered output is always the same, predictable identity
regardless of who's calling `make template` or what flags they passed.

`values.yaml`, `base.values.yaml`, `ci.values.yaml`, and `<env>.values.yaml`
all live alongside `values.yaml` inside the prepared chart dir (see
[package structure](package-structure.md)), so they're captured into
`generated-changes/` by `make patch` like any other local edit and persist
across future `make prepare` runs. A file passed via `EXTRA_VALUES` is not
part of the chart itself — it's supplied by whichever caller needs it, from
wherever that caller keeps it (e.g. `<chart-dir>/kyverno-test/values.yaml`).
