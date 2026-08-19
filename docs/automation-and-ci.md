# Automation & CI workflows

## updatecli

`updatecli/` — one manifest per package (`updatecli.d/<name>.yaml`) that
checks upstream for a new release and, if found, runs the same
prepare/patch/charts/clean pipeline and opens a PR. Manifests are built
from shared Go-template partials (`_common.yaml`,
`_dockerimage-chart.yaml`, `_githubrelease-chart.yaml`,
`_helmchart.yaml`) keyed by how the package's upstream is shaped (OCI
registry / classic Helm repo / GitHub release). See
[updatecli/README.md](../updatecli/README.md) before adding or editing a
manifest — it documents each shape in detail, known pitfalls (tag
filtering noise, the `packageBuildVersion` int-vs-string yaml quirk), and
the GitHub App auth setup. Use the `updatecli-add-package` skill (or
`/updatecli-add-package <name>`) to add a new package's `package.yaml` +
matching `updatecli.d/<name>.yaml` manifest. When a version bump (local or
via a failed updatecli PR) fails because `generated-changes/` no longer
applies against the new upstream, use the `resolve-upstream-bump-conflict`
skill rather than hand-patching — `make patch` run against a partially
prepared tree silently deletes unrelated patches/overlays, a real footgun
that skill's Step 4 guards against.

## GitHub Actions (`.github/workflows/`)

- `validate-charts.yaml` — `helm lint` + `kubeconform` against every
  package a PR touches, plus the `package-version-bump` check (see
  [package structure](package-structure.md)).
- `chart-diff.yaml` — renders each touched package from both `main` and
  the PR branch and posts a `dyff` diff comment.
- `release-charts.yaml` — on merge to `main`, builds and pushes every
  changed package to GHCR as an OCI artifact
  (`oci://ghcr.io/therealgambo/k8s-charts/<chart-name>:<version>`).
- `updatecli.yaml` — validates manifests on PRs; daily/dispatch `discover`
  + per-package matrixed `apply` jobs that open the version-bump PRs.
- `pr-chart*.yaml` — PR chart preview lifecycle (build/sweep/cleanup).
