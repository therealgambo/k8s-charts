# packages/

Each subdirectory here is a package tracked by [rancher/charts-build-scripts](https://github.com/rancher/charts-build-scripts).
A package is a `package.yaml` (plus, once `make patch` has run at least once, a
`generated-changes/` directory of patches/overlays/excludes) describing an
upstream Helm chart and how to pull it.

## Adding a package

Create `packages/<name>/package.yaml`, e.g. pulling a chart straight out of a
subdirectory of the upstream project's git repo:

```yaml
url: https://github.com/<org>/<repo>.git
subdirectory: charts/<chart-name>
chartRepoBranch: main
version: 1.2.3
```

Or pulling a pre-packaged `.tgz` release asset directly:

```yaml
url: https://github.com/<org>/<repo>/releases/download/v1.2.3/<chart-name>-1.2.3.tgz
version: 1.2.3
```

Key fields (see `PackageOptions`/`UpstreamOptions` in charts-build-scripts for
the full set):

- `url` — upstream git repo or a direct chart archive URL
- `subdirectory` — path within the upstream repo to treat as chart root (git sources only)
- `chartRepoBranch` / `commit` — what to check out (git sources only)
- `version` — the version to stamp on the package this cycle
- `packageVersion` — for any package whose `url` isn't `local`, this must
  move every time the package does: reset to `01` when `url`/`commit`
  itself changed (a real new upstream release), otherwise bumped whenever
  the *patch* changes without an upstream version bump. Two different patch
  sets must never publish under the same `packageVersion` — that's what
  keeps every published chart version unique and immutable. Enforced by
  `make check-package-version PACKAGE=<name>` and CI's
  `package-version-bump` job (see `scripts/check-package-version-bump.sh`);
  `updatecli`'s own automated bumps already comply.
- `workingDir` — defaults to `charts/`
- `additionalCharts` — sibling charts pulled from the same or another upstream (e.g. CRD charts)
- `auto` — enables `make chart-bump`-style automated version bumps

## Workflow

```
make prepare   # pulls upstream into packages/<name>/charts and applies existing patches
# ...edit packages/<name>/charts as needed...
make template  # renders the prepared chart with values.yaml -> base.values.yaml -> [ENV].values.yaml layered
make patch     # diffs your edits against pristine upstream and (re)writes generated-changes/
make charts    # archives the result into assets/ and charts/, updating index.yaml
make clean     # removes the working charts/ directory so the repo is PR-ready
```

Scope any target to one package with `PACKAGE=<name>`.

To give a package environment-specific values, add `base.values.yaml` and/or
`test.values.yaml`/`staging.values.yaml`/`production.values.yaml` alongside
`values.yaml` in `packages/<name>/charts` (after `make prepare`), then run
`make patch` to capture them into `generated-changes/` like any other local
edit. Always render with `make template PACKAGE=<name> [ENV=staging]` rather
than calling `helm template` directly, so the values files stay layered in
the right order — see [Values file ordering](../README.md#values-file-ordering).

## Staying up to date with upstream

Once a package exists here, add a matching manifest under
[`updatecli/updatecli.d/<name>.yaml`](../updatecli/README.md) so
[updatecli](https://www.updatecli.io/) checks it for new upstream releases
and opens a PR — running this same workflow — whenever one appears.
