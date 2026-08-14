# updatecli/

Automated upstream tracking for every package in [`packages/`](../packages/),
powered by [updatecli](https://www.updatecli.io/). On a schedule (and on
demand), it checks each package's upstream for a newer release and, if one
exists, bumps `packages/<name>/package.yaml`, regenerates the chart with
`charts-build-scripts` and opens a PR with the result.

## Layout

- `updatecli.d/<name>.yaml` — one manifest per package, named to match its
  `packages/<name>/` directory. Each one is short: a `$pkg` dict of facts
  about that package, followed by `{{ template "..." $pkg }}` calls into
  the shared partials below. See "Adding a package" for the recipe. Each one
  also sets `pipelineid: "{{ $pkg.name }}"` right after its `name:` line —
  without it, updatecli auto-generates an opaque hash from the `name:` title
  instead (that's where old `updatecli_main_<hash>` branches came from). A
  stable, predictable pipelineid gives readable `updatecli_main_<name>`
  branches and lets the workflow target one package at a time via
  `--pipeline-ids <name>` (see the workflow bullet below).
- `updatecli.d/_common.yaml` — Go template `define` blocks shared by every
  package regardless of shape: the `scms` block, the `packageBuildVersion`
  and `buildChart` targets, and the `github/pullrequest` action.
- `updatecli.d/_dockerimage-chart.yaml`, `_githubrelease-chart.yaml`,
  `_helmchart.yaml` — one partial per upstream shape (see "Adding a
  package"), each defining that shape's `source`/`condition` pair plus its
  own `upstreamVersionChanged`/`packageURL` targets (these can't live in
  `_common.yaml` because they need the shape's own URL-construction logic,
  and Go's `{{ template "name" }}` action requires "name" to be a static
  string literal — it can't dynamically dispatch to "whichever shape this
  package is").
- Files prefixed with `_` are **partials**: updatecli concatenates every
  `_*.yaml` in this directory into each of the *other* manifests before
  rendering (a native feature since updatecli v0.103.0), so their `define`
  blocks are callable from any `<name>.yaml` in the same directory. They're
  never loaded as standalone pipelines themselves.
- `values.yaml` — repo identity shared by every manifest (`.github.*`); commit
  author/email are derived at runtime from `GITHUB_ACTOR` instead, so they
  automatically match whichever credential is authenticating (see below)
- [`.github/workflows/updatecli.yaml`](../.github/workflows/updatecli.yaml) —
  runs `updatecli pipeline diff` on PRs that touch this directory (catches
  broken manifests before merge) and, on a daily schedule / manual dispatch,
  a `discover` job that lists the package manifests followed by an `apply`
  job matrixed one-per-package (`--pipeline-ids <name>`, `fail-fast: false`)
  so the run's wall-clock time doesn't grow linearly as packages are added,
  and one package's build failure can't cancel the rest

## How the partials fit together

A `{{ template "name" $pkg }}` call does **not** inherit the caller's
variables — inside a `define`, both `.` and `$` are rebound to whatever was
passed at the call site, not the root `values.yaml` data. That's why every
`$pkg` dict includes a `"github" .github` entry (copied from the real root,
at the top of each package file, before any `template` call rebinds `.`) —
`common.scm` reaches it back out as plain `.github.owner`.

Each `define`'s body is hand-indented 4 spaces to match where it's always
invoked (right after a `<id>:` line nested one level under a top-level key),
since a `template` action's output can't be piped through `nindent` the way
Helm's `include` can — `template` always writes directly to the output at
its call site, so the indentation has to already be correct in the source.

## What a manifest does

Each `updatecli.d/<name>.yaml` follows the same four stages:

1. **source** — resolve the latest upstream version (e.g. via the
   `githubrelease` resource)
2. **conditions** — sanity-check the resolved version actually exists (e.g.
   the release asset is reachable), and gate the whole run on it actually
   being new: a `failwhen: true` condition compares it against what's
   already in `package.yaml` and stops the pipeline cleanly (no error, no
   PR) when there's nothing to do, before any target — including the
   `make`-running one — runs at all
3. **targets** — write the new version into `packages/<name>/package.yaml`,
   then run `make prepare PACKAGE=<name> && make patch PACKAGE=<name> && make
   charts PACKAGE=<name> && make clean PACKAGE=<name>` (via a `shell` target)
   to regenerate `charts/`, `assets/` and `index.yaml` exactly as a human
   contributor would locally
4. **action** — open a PR with whatever changed, via the shared `scms.default`
   block

If the existing patch set in `generated-changes/` no longer applies against
the new upstream version, `make prepare`/`make patch` fails, the target
errors out, and no PR is opened — the bump needs a human to resolve the
conflict manually first (see the main [README](../README.md) workflow).

Nothing is auto-merged: PRs land for review like any other change.

## Adding a package

When you add a new `packages/<name>/package.yaml` (see
[packages/README.md](../packages/README.md)), add a matching
`updatecli.d/<name>.yaml`. In the common case this is the entire file (see
`updatecli.d/cert-manager.yaml` for a real one this short):

```gotemplate
{{ $pkg := dict "name" "<name>" "image" "<registry>/<path>" "tagfilter" "^v?\\d+\\.\\d+\\.\\d+$" "github" .github }}
name: "Bump <name> chart to the latest upstream release"
pipelineid: "{{ $pkg.name }}"

scms:
  default:{{ template "common.scm" $pkg }}

sources:
  lastRelease:{{ template "dockerimage.source" $pkg }}

conditions:
  chartTagPublished:{{ template "dockerimage.condition" $pkg }}
  upstreamVersionChanged:{{ template "dockerimage.upstreamVersionChanged" $pkg }}

targets:
  packageURL:{{ template "dockerimage.packageURL" $pkg }}
  packageBuildVersion:{{ template "common.packageBuildVersion" $pkg }}
  buildChart:{{ template "common.buildChart" $pkg }}

actions:
  default:{{ template "common.action" $pkg }}
```

Always include `"github" .github` in `$pkg` (see "How the partials fit
together" above for why), and always pass `$pkg` — not `.` — to every
`template` call. The four stages/block *names* (`common.scm`, `<shape>.source`,
etc.) never change; only which shape's partial you call, and what fields you
put in `$pkg`, do. Pick the shape based on how the package pulls upstream:

- **OCI registry chart** (a `url` like `oci://ghcr.io/<org>/<chart>:<version>`,
  like `kargo`, `cert-manager`, `grafana`, `karpenter`, `kyverno`,
  `node-local-dns`, `node-problem-detector`): use the `dockerimage.*`
  templates from `_dockerimage-chart.yaml` (as in the example above). `$pkg`
  needs `image` (registry host included, e.g. `ghcr.io/akuity/kargo-charts/kargo`
  — any standard OCI registry works, not just `ghcr.io`; `quay.io` and
  `public.ecr.aws` are also in use here) and, almost always, `tagfilter`.
  **Always set `tagfilter: "^v?\\d+\\.\\d+\\.\\d+$"`** (note the doubled
  backslashes — this is a Go template string literal, not raw YAML).
  Real-world OCI chart registries are noisy — cosign `sha256-....sig`
  signatures, `artifacthub.io` verification tags, nightly builds, bare
  date-stamped tags — and `dockerimage` returns raw tag strings, so a bare
  integer tag (e.g. a date like `20221219`) parses as a technically-valid
  but enormous semver major and wins over any real release under
  `>=0.0.0` if it isn't filtered out first (this bit `karpenter` for real
  during testing; `kargo` is the one existing package that omits `tagfilter`
  entirely, and only because `ghcr.io/akuity/kargo-charts/kargo` happens not
  to carry any noise tags). Some registries (`cert-manager` on `quay.io`)
  also double-tag every release as both `X.Y.Z` and `vX.Y.Z`; check what's
  already pinned in `package.yaml` and narrow the `tagfilter` to just that
  convention (`^v\\d+...` vs `^v?\\d+...`) so the source can't flip-flop
  between the two.
- **Classic Helm repository chart** (a `url` like
  `https://<host>/<path>/<chart>-<version>.tgz` served from a plain
  `index.yaml`-based Helm repo — typically a GitHub Pages site — rather
  than a GitHub release or an OCI registry, like `aws-lb-controller` and
  `rbac-manager`): use the `helmchart.*` templates from `_helmchart.yaml`.
  `$pkg` needs `repoURL` (the repo root, not the `.tgz`) and `chartName`;
  add `displayName` too if the chart's own name differs from the package
  folder name (see `aws-lb-controller.yaml`, where the folder is shortened
  but the PR description should say the real chart name). Don't assume the
  upstream project's GitHub releases track the chart version at all — e.g.
  `aws/eks-charts` cuts one sequential `v0.0.N` release per repo change
  covering every chart, and `FairwindsOps/rbac-manager` tags releases by
  *app* version, not the (independently versioned) chart.
- **GitHub release** (either a direct chart release asset under
  `releases/download/...`, like `external-dns`; or — for a chart mirror
  with no independent versioning of its own, like `cilium`, `tetragon`,
  `consul` and `vault` — the separate *application* repo's release, with
  the chart's own host, e.g. `helm.cilium.io` or
  `helm.releases.hashicorp.com`, providing the actual asset): use the
  `githubrelease.*` templates from `_githubrelease-chart.yaml`. `$pkg`
  needs `owner`, `repo`, `versionPattern` (the `versionfilter` regex
  scoped to this project's release tag convention) and `capturePattern`
  (the same tag with the bare version captured in group 1), plus
  `urlParts` — a list of literal string segments that get joined by the
  resolved version, so a 2-element list produces one substitution
  (`["https://helm.cilium.io/cilium-", ".tgz"]`) and a 3-element list
  produces two (`argo-cd`/`external-dns`/`coredns`/etc. embed the version
  twice: once in the release-tag path segment, once in the asset
  filename). If the tracked repo isn't named after the package (`consul`
  tracks `hashicorp/consul-k8s`, `vault` tracks `hashicorp/vault-helm`), add
  `sourceLabel` so the `sources.lastRelease.name` wording says the repo
  being tracked, not the package folder name. For the chart-mirror shape
  specifically, also set `releaseNoun` to `"release"` (it defaults to
  `"helm chart release"`, which is wrong when what's actually being
  tracked is the app's own release, not a release of the chart). Verify
  the chart-mirror host and the app repo's tags actually move in lockstep
  before relying on this (check a few historical tags against the chart
  host) since nothing enforces it structurally. `owner`/`repo`/
  `capturePattern` also drive `common.releaseLink` (in `_common.yaml`),
  which turns the version mentioned in the PR description into a link to
  that release's actual GitHub release page — no extra `$pkg` fields
  needed. It falls back to plain unlinked text for the `dockerimage.*`/
  `helmchart.*` shapes below, which don't track an upstream GitHub repo at
  all.
- **Hybrid shapes**: nothing requires using one shape's *entire* set of
  templates — mix and match per block if a package's version tracking and
  asset hosting genuinely differ. The building blocks (`githubrelease.source`
  paired with `dockerimage.condition`/`dockerimage.upstreamVersionChanged`/
  `dockerimage.packageURL`, or any other combination) are all still there in
  `_githubrelease-chart.yaml`/`_dockerimage-chart.yaml`/`_helmchart.yaml` if a
  package's version tracking and asset hosting genuinely come from different
  places. `yugabyte.yaml` is a real example: yugabyte-db's own GitHub
  releases (`githubrelease.source`) are what's tracked for freshness, but the
  chart itself ships from a classic Helm repo (`helmchart.condition`/
  `helmchart.packageURL`) under a *truncated* version — the release tag's
  trailing PATCH component is dropped by `capturePattern`, since the Helm
  chart's own `version:` field doesn't carry it. That truncation also breaks
  `common.releaseLink`'s usual tagPrefix + `source "lastRelease"`
  reconstruction (it assumes the capture group is the entire tag suffix), so
  that manifest hand-rolls its `actions.default` with a second source
  (`lastReleaseTag`) instead of reusing `common.action`. See the comment at
  the top of `yugabyte.yaml` for the full reasoning.

If a package's shape doesn't fit any of the three `_*.yaml` partials at all,
write the `sources`/`conditions`/`targets` blocks out by hand in that one
manifest instead of forcing a new shared partial into existence for a single
package — see `gateway-api-crd.yaml`, `metrics-server.yaml`, `spire.yaml` and
`onlineboutique.yaml` for real examples (each pulls its chart straight out of
a subdirectory of the upstream app repo at a pinned commit, tracked via the
latest release tag, rather than fetching a packaged chart asset). Still reuse
`common.scm`/`common.packageBuildVersion`/`common.buildChart`/`common.action`
for the boilerplate that's genuinely universal.

Targets act on whatever is pushed to `main` on GitHub, not your local working
tree — a new package only becomes bumpable once its `package.yaml` (and, once
generated, `generated-changes/`) is merged.

Before merging, render the pipeline locally to confirm it parses and looks
right — this doesn't touch GitHub, it just resolves the templates:

```
GITHUB_TOKEN=<any placeholder> GITHUB_ACTOR=<any placeholder> \
  updatecli manifest show --config ./updatecli/updatecli.d --values ./updatecli/values.yaml
```

(The `SCM repository retrieved` clone attempt will fail with a placeholder
token — that's fine and expected; the rendered pipeline spec printed below it
is what you're checking.)

## Authentication: the `updatecli` GitHub App

The workflow authenticates as a dedicated GitHub App rather than the default
`GITHUB_TOKEN`, because commits/PRs made with the default token don't trigger
other `on: push`/`on: pull_request` workflows (GitHub's anti-recursion
protection) — so any CI you have wouldn't run on these auto-bump PRs. App
installation tokens don't have that restriction.

**One-time setup:**

1. Create the App: your GitHub account → **Settings → Developer settings →
   GitHub Apps → New GitHub App**. Webhook: uncheck "Active" (not needed).
2. Grant these **Repository permissions** only:
   | Permission | Level | Why |
   |---|---|---|
   | Contents | Read and write | clone/branch/commit/push |
   | Pull requests | Read and write | open the PR |
   | Issues | Read and write | the PR labels are set via the shared issues/PR label endpoints |
   | Metadata | Read-only | mandatory baseline |
3. "Where can this GitHub App be installed" → **Only on this account**.
4. Generate a private key (App settings → **Generate a private key**,
   downloads a `.pem`).
5. Install the App on this repo (App settings → **Install App**).
6. In the repo's **Settings → Secrets and variables → Actions**, add:
   - a repo **variable** `UPDATECLI_APP_ID` — the App ID (App settings page)
   - a repo **secret** `UPDATECLI_APP_PRIVATE_KEY` — the full contents of the
     downloaded `.pem`

The workflow exchanges these for a short-lived installation token via
[`actions/create-github-app-token`](https://github.com/actions/create-github-app-token)
at the start of each run and passes it through as `GITHUB_TOKEN`/`GITHUB_ACTOR`
— the same env vars every manifest already reads, so no manifest changes are
needed when rotating or recreating the App.

With this in place, **Settings → Actions → General → Workflow permissions**
does not need "Read and write" — the default token is only used for
`actions/checkout` (read-only).

## Known limitations

- A version bump gets its own PR/branch; if a newer version shows up before
  the previous PR is merged, the old PR is left open rather than superseded.
- The `buildChart` shell target's own "changed" signal is just "did the
  command produce output" (which `make`'s logging always does), so it can't
  be trusted to decide whether a rebuild is even necessary — that's why
  `upstreamVersionChanged` exists as a separate, earlier gate (see above)
  rather than relying on the target itself to skip cleanly.
- When adding a manifest for a new package, note that `disablesourceinput:
  true` and `sourceid` can't be set together on the same condition/target
  (updatecli errors on load) — use one or the other, not both, on every
  block that sets an explicit `value:`.
- The `yaml` target's default engine (`goccy`) unconditionally quotes any
  scalar value it writes, including bare integers — so the
  `packageBuildVersion` target (which resets `packageVersion`, an `int`
  field in charts-build-scripts) needs `engine: "yamlpath"` explicitly,
  otherwise it writes `packageVersion: "1"` and `charts-build-scripts`
  fails strict unmarshalling with `cannot unmarshal !!str "1" into int`
  (this broke a real updatecli PR — #8 — before the fix). Every manifest's
  `packageBuildVersion` target already pins this; keep doing so in any new
  one, and copy an existing target rather than writing it from scratch.
- That same target resets the value to `"01"`, not `"1"`, to match this
  repo's zero-padded convention for a fresh build of a new upstream
  version (every hand-written `package.yaml` starts at `01`). This is
  cosmetic, not functional: `gopkg.in/yaml.v2` (what charts-build-scripts
  actually unmarshals with) parses a bare `01`...`09` as a plain decimal
  int same as `1`...`9`, not octal — verified directly against that
  library, not assumed.

## Running locally

```
brew install updatecli/updatecli/updatecli  # or see https://www.updatecli.io/docs/prologue/installation/
GITHUB_TOKEN=<a token with repo read/write access> GITHUB_ACTOR=<your github username> \
  updatecli pipeline diff --config ./updatecli/updatecli.d --values ./updatecli/values.yaml
```

Note that targets act on the pushed state of `main` on GitHub (it clones the
repo fresh), not your local working tree, so a package only becomes bumpable
once its `package.yaml` has been merged. Also note `pipeline diff` still
pushes its `updatecli_main_<id>` working branch for real (it only skips
opening the actual PR) — delete that branch afterwards if you don't intend to
let it become a real PR, otherwise the next run rebases onto it instead of a
clean `main`.
