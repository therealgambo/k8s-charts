# updatecli/

Automated upstream tracking for every package in [`packages/`](../packages/),
powered by [updatecli](https://www.updatecli.io/). On a schedule (and on
demand), it checks each package's upstream for a newer release and, if one
exists, bumps `packages/<name>/package.yaml`, regenerates the chart with
`charts-build-scripts` and opens a PR with the result.

## Layout

- `updatecli.d/<name>.yaml` — one manifest per package, named to match its
  `packages/<name>/` directory
- `values.yaml` — repo identity shared by every manifest (`.github.*`); commit
  author/email are derived at runtime from `GITHUB_ACTOR` instead, so they
  automatically match whichever credential is authenticating (see below)
- [`.github/workflows/updatecli.yaml`](../.github/workflows/updatecli.yaml) —
  runs `updatecli pipeline diff` on PRs that touch this directory (catches
  broken manifests before merge) and `updatecli pipeline apply` on a daily
  schedule / manual dispatch (does the actual bump + PR)

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
`updatecli.d/<name>.yaml`. The `source`/`condition` shape depends on how the
package pulls upstream:

- **GitHub release asset** (a direct `.tgz` URL under
  `releases/download/...`, like `external-dns`): use a `githubrelease` source
  with a `versionfilter` regex scoped to that project's chart-release tags,
  and a `yaml` target that rewrites the `url` field with the new version
  templated in. Copy `updatecli.d/external-dns.yaml` as a starting point.
- **Git-tracked chart** (a `url`/`subdirectory`/`chartRepoBranch` pointing at
  a chart living inside a git repo, with a separate `version` field): use a
  `githubtag` or `githubrelease` source instead, and target the `version` key
  directly rather than `url`.
- **OCI registry chart** (a `url` like `oci://ghcr.io/<org>/<chart>:<version>`,
  like `kargo`, `cert-manager`, `grafana`, `karpenter`, `kyverno`,
  `node-local-dns`, `node-problem-detector`): use a `dockerimage` source
  pointed at the OCI image (registry host included, e.g.
  `ghcr.io/akuity/kargo-charts/kargo` — any standard OCI registry works,
  not just `ghcr.io`; `quay.io` and `public.ecr.aws` are also in use here)
  with a `semver` `versionfilter` — pattern `>=0.0.0` picks the newest
  stable tag, since semver constraint matching only considers pre-release
  tags (`-rc.1` etc.) when the constraint itself has a pre-release
  component. **Always pair this with a `tagfilter: '^v?\d+\.\d+\.\d+$'`.**
  Real-world OCI chart registries are noisy — cosign `sha256-....sig`
  signatures, `artifacthub.io` verification tags, nightly builds, bare
  date-stamped tags — and `dockerimage` returns raw tag strings, so a bare
  integer tag (e.g. a date like `20221219`) parses as a technically-valid
  but enormous semver major and wins over any real release under
  `>=0.0.0` if it isn't filtered out first (this bit `karpenter` for real
  during testing). Some registries (`cert-manager` on `quay.io`) also
  double-tag every release as both `X.Y.Z` and `vX.Y.Z`; check what's
  already pinned in `package.yaml` and narrow the `tagfilter` to just that
  convention (`^v\d+...` vs `^v?\d+...`) so the source can't flip-flop
  between the two. Use a matching `dockerimage` condition
  (`tag: '{{ source "..." }}'`) in place of the `curl`-based asset check,
  and target the `url` field with the tag interpolated back in. Copy
  `updatecli.d/kargo.yaml` as a starting point.
- **Classic Helm repository chart** (a `url` like
  `https://<host>/<path>/<chart>-<version>.tgz` served from a plain
  `index.yaml`-based Helm repo — typically a GitHub Pages site — rather
  than a GitHub release or an OCI registry, like `aws-lb-controller` and
  `rbac-manager`): use a `helmchart` source with `url` set to the repo root
  (not the `.tgz`) and `name` set to the chart name; it reads `index.yaml`
  and picks the newest stable version automatically. Don't assume the
  upstream project's GitHub releases track the chart version at all — e.g.
  `aws/eks-charts` cuts one sequential `v0.0.N` release per repo change
  covering every chart, and `FairwindsOps/rbac-manager` tags releases by
  *app* version, not the (independently versioned) chart. Use a matching
  `helmchart` condition (`version: '{{ source "..." }}'`) and target the
  `url` field with the chart name and version templated back into the
  flat `<repo>/<chart>-<version>.tgz` layout. Copy
  `updatecli.d/aws-lb-controller.yaml` as a starting point.

Keep the `scms` and `actions` blocks identical to the existing manifests
(they just reference `values.yaml`) so every package behaves consistently.

Targets act on whatever is pushed to `main` on GitHub, not your local working
tree — a new package only becomes bumpable once its `package.yaml` (and, once
generated, `generated-changes/`) is merged.

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

## Running locally

```
brew install updatecli/tap/updatecli  # or see https://www.updatecli.io/docs/prologue/installation/
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
