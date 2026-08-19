---
name: updatecli-add-package
description: Add automated upstream-tracking to a Helm chart package in this k8s-charts repo — create packages/<name>/package.yaml (if it doesn't exist yet) and a matching updatecli/updatecli.d/<name>.yaml manifest so updatecli opens a version-bump PR whenever a new upstream release appears. Use when the user asks to add a new package/chart, wire up updatecli for a package, track a new upstream chart for auto-updates, or runs `/updatecli-add-package <name>`.
---

# /updatecli-add-package — wire a package into updatecli's auto-bump pipeline

Adds (or completes) `packages/<name>/package.yaml` and writes
`updatecli/updatecli.d/<name>.yaml` so [updatecli](https://www.updatecli.io/)
checks that package's upstream daily and opens a version-bump PR when it
moves. [updatecli/README.md](../../../updatecli/README.md) is the full
reference this skill leans on — read it if anything below feels
underspecified, especially the "Adding a package" section and the shape
recipes it links to. This skill is the condensed, do-it-now version of that
doc.

Every manifest reduces to one shared shape driven by `$pkg`, a small dict of
facts about the package, fed into shared partials
(`_common.yaml`/`_dockerimage-chart.yaml`/`_githubrelease-chart.yaml`/
`_helmchart.yaml`). The only real work is (a) figuring out which shape this
package's upstream actually is, and (b) getting `$pkg`'s fields right for
that shape. Steps 1–3 below do that; don't freelance a new manifest
structure — copy the closest existing `updatecli.d/<name>.yaml` for the
chosen shape and edit the `$pkg` line, same as every one of the 37 that
already exist.

## Step 0 — package name and existing `package.yaml`

Get `<name>` from `$ARGUMENTS`, or ask. Check whether
`packages/<name>/package.yaml` already exists:

- **Exists** (adding auto-tracking to a package someone already hand-wrote)
  → read it now, it tells you the shape directly: a `url:` that's
  `oci://...` is the dockerimage shape, a `.../index.yaml`-backed `url:`
  ending in `.tgz` served from a plain Helm repo is the helmchart shape, a
  GitHub `releases/download/...` asset (or a chart-mirror host like
  `helm.cilium.io`) is the githubrelease shape. Skip straight to Step 2 with
  that confirmed.
- **Doesn't exist** (a genuinely new package) → do Step 1 first to work out
  the shape, then write `package.yaml` as part of Step 2. See
  [packages/README.md](../../../packages/README.md) for the full
  `package.yaml` field reference (`url`, `subdirectory`, `chartRepoBranch`/
  `commit`, `version`, `packageVersion`, `workingDir`, `additionalCharts`).
  A brand-new hand-written `package.yaml` conventionally starts at
  `packageVersion: 01`.

Also check `packages/<name>/package.yaml`'s `url` isn't `local` — from-scratch
packages (`network-policies`, `kyverno-pod-policies`,
`kyverno-cluster-policies`) have no upstream and get no updatecli manifest at
all. If asked to add one for a `url: local` package, stop and say so.

## Step 1 — classify the upstream shape

Figure out how the chart is actually published upstream (check the project's
own docs/README for its Helm install instructions — that's normally the
fastest way to see the real URL/registry a user would `helm install` or
`helm repo add` from):

- **OCI registry chart** — installed via `helm install oci://<registry>/<path>
  --version x.y.z` (e.g. `ghcr.io/...`, `quay.io/...`,
  `public.ecr.aws/...`). → dockerimage shape.
- **Classic Helm repository** — `helm repo add <name> https://<host>/<path>`
  backed by a plain `index.yaml` (typically a GitHub Pages site), then
  `helm install <name>/<chart>`. → helmchart shape.
- **GitHub release asset** — the chart `.tgz` is attached directly to a
  GitHub release under `releases/download/<tag>/<chart>-<version>.tgz`, OR
  there's no independently-versioned chart release at all and the chart is
  mirrored from a *different* host (e.g. `helm.cilium.io`,
  `helm.releases.hashicorp.com`) that tracks some separate application
  repo's own releases. → githubrelease shape (the second case is the
  "chart-mirror" variant — see `updatecli/README.md`'s bullet on it, and
  `cilium.yaml`/`tetragon.yaml`/`consul.yaml`/`vault.yaml` for real
  examples).
- **None of the above fits** — pulled straight from a subdirectory of the
  upstream app repo at a pinned commit with no independent chart versioning,
  or something else entirely → hand-rolled `sources`/`conditions`/`targets`
  written out in the package's own manifest instead of forcing a new shared
  partial into existence. See `gateway-api-crd.yaml` (tracks a release *tag*
  via two `gittag` sources, writes `$.commit` not `$.version`),
  `metrics-server.yaml`, `spire.yaml`, `onlineboutique.yaml` for real
  examples, and `yugabyte.yaml` for a *hybrid* (githubrelease source +
  helmchart condition/target, because the two disagree on what "the
  version" even is) — reuse `common.scm`/`common.packageBuildVersion`/
  `common.buildChart`/`common.action` even here; only the
  `sources`/`conditions`/`packageURL` are genuinely bespoke.

If genuinely unsure, open two or three existing manifests for packages with
a similar upstream (same registry host, or same "app repo mirrors chart
elsewhere" pattern) and match whichever one's `$pkg` shape fits, rather than
inventing a new pattern.

## Step 2 — write/confirm `packages/<name>/package.yaml`

For a brand-new package, write `package.yaml` matching the classified shape
(see [packages/README.md](../../../packages/README.md) for field meaning):

```yaml
# OCI shape
url: oci://<registry>/<path>:<version>
packageVersion: 01
```
```yaml
# helmchart / githubrelease shape (a fetchable .tgz URL either way)
url: https://<host>/<path>/<chart>-<version>.tgz
packageVersion: 01
```
```yaml
# hand-rolled "pull a subdirectory at a commit" shape (no version:)
url: https://github.com/<org>/<repo>.git
subdirectory: <path>/<chart>
commit: <full-sha>
packageVersion: 01
```

Use whatever the *current* latest upstream release actually is for the
initial `url`/`version`/`commit` — this file is what `make prepare
PACKAGE=<name>` reads, and Step 4 needs it to already resolve to something
real.

## Step 3 — write `updatecli/updatecli.d/<name>.yaml`

Copy the closest existing manifest for the chosen shape rather than writing
from scratch — `cert-manager.yaml` (dockerimage), `aws-load-balancer-controller.yaml`
(helmchart), `cilium.yaml` (githubrelease chart-mirror), `argo-cd.yaml` or
`external-dns.yaml` (githubrelease with a doubled version in the asset path)
are all short, clean examples. The skeleton is always:

```gotemplate
{{ $pkg := dict "name" "<name>" ...shape fields... "github" .github }}
name: "Bump <name> chart to the latest upstream release"
pipelineid: "{{ $pkg.name }}"

scms:
  default:{{ template "common.scm" $pkg }}

sources:
  lastRelease:{{ template "<shape>.source" $pkg }}

conditions:
  <descriptiveId>:{{ template "<shape>.condition" $pkg }}
  upstreamVersionChanged:{{ template "<shape>.upstreamVersionChanged" $pkg }}

targets:
  packageURL:{{ template "<shape>.packageURL" $pkg }}
  packageBuildVersion:{{ template "common.packageBuildVersion" $pkg }}
  buildChart:{{ template "common.buildChart" $pkg }}

actions:
  default:{{ template "common.action" $pkg }}
```

Always include `"github" .github` in `$pkg` and always pass `$pkg` (never
`.`) to every `template` call — see `updatecli/README.md`'s "How the
partials fit together" for why. `pipelineid` must be set right after `name:`
(gives a stable, readable `updatecli_main_<name>` branch instead of an
opaque hash, and lets CI target one package via `--pipeline-ids`).

`$pkg` fields needed per shape (from each partial's own header comment —
re-read it in `updatecli/updatecli.d/_<shape>-chart.yaml` if unsure):

- **dockerimage**: `name`, `image` (registry host included), `tagfilter`
  (near-always set — **omit only if you've confirmed, like `kargo`, that the
  registry carries no noise tags**). Always write `tagfilter` as
  `"^v?\\d+\\.\\d+\\.\\d+$"` — doubled backslashes, it's a Go template string
  literal, not raw YAML — and narrow the `^v?` to whichever of `^v` / `^`
  the upstream actually uses if it double-tags releases both ways (check a
  few real tags on the registry first).
- **helmchart**: `name`, `repoURL` (the repo root, not the `.tgz`),
  `chartName`, plus `displayName` if the chart's own name differs from the
  package folder name.
- **githubrelease**: `name`, `owner`, `repo`, `versionPattern` (the tag
  regex), `capturePattern` (same tag with the version captured in group 1),
  `urlParts` (list of literal string segments joined by the resolved
  version — 2 elements = one substitution, 3 elements = two, for
  chart/asset paths that embed the version twice). Add `sourceLabel` if the
  tracked repo isn't named after the package (mirror shape), and
  `releaseNoun: "release"` for the chart-mirror variant specifically
  (defaults to `"helm chart release"`, wrong when tracking the app's own
  release). Verify the chart-mirror host and the app repo's tags actually
  move in lockstep against a few historical tags before relying on this.

Don't set both `disablesourceinput: true` and an explicit `sourceid` on the
same block — updatecli rejects the manifest.

## Step 4 — validate

Render without touching GitHub (placeholders are fine — the clone attempt
fails harmlessly, the printed pipeline spec is what you're checking; scope
to just the new manifest so you're not re-rendering all 37):

```
GITHUB_TOKEN=x GITHUB_ACTOR=x updatecli manifest show \
  --config ./updatecli/updatecli.d --values ./updatecli/values.yaml \
  --pipeline-ids <name>
```

Confirm the rendered `sources`/`conditions`/`targets` look right — real
`image`/`repoURL`/`owner`+`repo` values substituted in, no leftover
`<placeholder>` text, `packageURL`'s `value:` pointing at a URL shape that
matches `package.yaml`'s `url:` field exactly (a mismatch there means
`upstreamVersionChanged` will never fire clean, or `packageURL` will write
something `make prepare` can't fetch).

If you have a real `GITHUB_TOKEN` (needs repo read/write) and want to
confirm it actually resolves the live upstream version and runs the full
`make prepare && make patch && make charts && make clean` pipeline for
real:

```
GITHUB_TOKEN=<real token> GITHUB_ACTOR=<your github username> updatecli pipeline diff \
  --config ./updatecli/updatecli.d --values ./updatecli/values.yaml \
  --pipeline-ids <name>
```

This is optional but the only way to catch a wrong `tagfilter`/
`versionPattern`/`urlParts` before it ships. Note it still pushes a real
`updatecli_main_<name>` working branch even though `diff` skips opening the
PR — delete that branch afterward unless you actually want it to become a
PR, otherwise the next real run rebases onto it instead of a clean `main`.
Also note it acts on `main` as pushed to GitHub, not your local working
tree — a brand-new package's `package.yaml` has to be committed/pushed
first for this to have anything to diff against.

## Step 5 — sanity-check the build pipeline itself

Whether or not Step 4's live dry-run was possible, confirm the `make`
pipeline `common.buildChart` will actually invoke works standalone:

```
make prepare PACKAGE=<name>
make patch PACKAGE=<name>
make charts PACKAGE=<name>
make clean PACKAGE=<name>
```

If this fails, the manifest is correct but the *package* itself isn't ready
— fix that first (see the main [README](../../../README.md) and
[packages/README.md](../../../packages/README.md)), Step 4 can't help here
since it only validates the updatecli side.
