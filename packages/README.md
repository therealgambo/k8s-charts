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
- `packageVersion` — bump this whenever the *patch* changes without an upstream version bump
- `workingDir` — defaults to `charts/`
- `additionalCharts` — sibling charts pulled from the same or another upstream (e.g. CRD charts)
- `auto` — enables `make chart-bump`-style automated version bumps

## Workflow

```
make prepare   # pulls upstream into packages/<name>/charts and applies existing patches
# ...edit packages/<name>/charts as needed...
make patch     # diffs your edits against pristine upstream and (re)writes generated-changes/
make charts    # archives the result into assets/ and charts/, updating index.yaml
make clean     # removes the working charts/ directory so the repo is PR-ready
```

Scope any target to one package with `PACKAGE=<name>`.
