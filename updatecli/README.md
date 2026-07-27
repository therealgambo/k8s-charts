# updatecli/

Automated upstream tracking for every package in [`packages/`](../packages/),
powered by [updatecli](https://www.updatecli.io/). On a schedule (and on
demand), it checks each package's upstream for a newer release and, if one
exists, bumps `packages/<name>/package.yaml`, regenerates the chart with
`charts-build-scripts` and opens a PR with the result.

## Layout

- `updatecli.d/<name>.yaml` — one manifest per package, named to match its
  `packages/<name>/` directory
- `values.yaml` — repo/bot identity shared by every manifest (`.github.*`,
  `.bot.*`)
- [`.github/workflows/updatecli.yaml`](../.github/workflows/updatecli.yaml) —
  runs `updatecli pipeline diff` on PRs that touch this directory (catches
  broken manifests before merge) and `updatecli pipeline apply` on a daily
  schedule / manual dispatch (does the actual bump + PR)

## What a manifest does

Each `updatecli.d/<name>.yaml` follows the same four stages:

1. **source** — resolve the latest upstream version (e.g. via the
   `githubrelease` resource)
2. **condition** — sanity-check the resolved version actually exists before
   touching anything (e.g. the release asset is reachable)
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

Keep the `scms` and `actions` blocks identical to the existing manifests
(they just reference `values.yaml`) so every package behaves consistently.

Targets act on whatever is pushed to `main` on GitHub, not your local working
tree — a new package only becomes bumpable once its `package.yaml` (and, once
generated, `generated-changes/`) is merged.

## Requirements

- Repo setting **Settings → Actions → General → Workflow permissions** must
  allow "Read and write permissions" (needed for the workflow's default
  `GITHUB_TOKEN` to push a branch and open a PR).
- No extra secrets are needed — manifests authenticate with the workflow's
  built-in `GITHUB_TOKEN`.

## Known limitations

- A version bump gets its own PR/branch; if a newer version shows up before
  the previous PR is merged, the old PR is left open rather than superseded.
- The default `GITHUB_TOKEN` does not trigger other workflows on the PRs it
  opens. If you later want CI to run automatically on these PRs, swap the
  token for a GitHub App or PAT in `values.yaml`/the workflow's secrets.

## Running locally

```
brew install updatecli/tap/updatecli  # or see https://www.updatecli.io/docs/prologue/installation/
GITHUB_TOKEN=<a token with repo read/write access> GITHUB_ACTOR=<your github username> \
  updatecli pipeline diff --config ./updatecli/updatecli.d --values ./updatecli/values.yaml
```

`pipeline diff` never pushes or opens a PR — swap in `pipeline apply` to
actually run the bump locally. Note that targets act on the pushed state of
`main` on GitHub (it clones the repo fresh), not your local working tree, so
a package only becomes bumpable once its `package.yaml` has been merged.
