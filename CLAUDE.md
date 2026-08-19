# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Helm chart repository built and maintained with
[rancher/charts-build-scripts](https://github.com/rancher/charts-build-scripts):
upstream charts under `packages/<name>/` are tracked as **forks with a patch
set on top**, not copied in wholesale — an upgrade to a new upstream version
is a diff/rebase, not a manual re-vendor. A few packages have no upstream at
all and are written directly in this repo (see
[docs/package-structure.md](docs/package-structure.md)).

## Commands

```
make prepare PACKAGE=<name>              # pull upstream into packages/<name>/charts and apply existing patches
make template PACKAGE=<name> [ENV=staging] [EXTRA_VALUES=path]  # render the prepared chart (values.yaml -> base.values.yaml -> ci.values.yaml -> $(ENV).values.yaml -> EXTRA_VALUES layered) -- the one authoritative entry point for rendering a chart in this repo, every check/skill goes through it
make patch PACKAGE=<name>                # diff local edits against upstream and (re)generate generated-changes/
make charts PACKAGE=<name>               # archive the finalized chart into assets/ and charts/, updating index.yaml
make clean PACKAGE=<name>                # remove local working state so the repo is PR-ready
make unittest PACKAGE=<name>             # helm-unittest against packages/<name>/{charts,local-chart}/tests (no-op if no tests/ dir)
make kyverno-test PACKAGE=<name>         # `kyverno test` a policies chart's own CEL rules against packages/<name>/{...}/kyverno-test fixtures (no-op if no kyverno-test/ dir)
make kyverno-policy-check PACKAGE=<name> [ENV=staging]  # assert PACKAGE's rendered chart against the kyverno-pod-policies + kyverno-cluster-policies rulesets
make check-images PACKAGE=<name> [ENV=staging]          # confirm every image PACKAGE's rendered chart references is actually pullable
make check-package-version PACKAGE=<name> [BASE_REF=origin/main]  # verify PACKAGE's packageVersion was bumped/reset correctly relative to BASE_REF
```

`PACKAGE` is required by every Build Pipeline target. The first run of any
target downloads the pinned `charts-build-scripts` binary into `bin/`
automatically (pinned versions live in `scripts/version`). **Always use
`make template` instead of calling `helm template` directly** — it applies
the repo's values-file layering and renders into `--namespace <package
name>` (not helm's `default` fallback), which `kyverno-policy-check` relies
on.

Reproduce CI's per-PR checks locally (after `make prepare PACKAGE=<name>`):

```
helm lint packages/<name>/charts
make template PACKAGE=<name> | kubeconform -strict -summary -ignore-missing-schemas
```

There is no single "run everything" command — work one `PACKAGE=` at a time.

## Architecture

Details are split out by topic — load whichever is relevant to the task:

- [Package structure](docs/package-structure.md) — `package.yaml`,
  `generated-changes/`, the `charts/`-vs-`local-chart/` working tree split,
  and build output (`charts/`, `assets/`).
- [Values file layering](docs/values-layering.md) — the
  `values.yaml` → `base.values.yaml` → `ci.values.yaml` → `<env>.values.yaml`
  precedence.
- [Kyverno policy enforcement](docs/kyverno-policies.md) — the two
  cross-cutting policy charts every other package is checked against, and
  when to use the `kyverno-policy-fix` / `kyverno-add-policy` skills.
- [Automation & CI workflows](docs/automation-and-ci.md) — `updatecli/`
  upstream-tracking and `.github/workflows/`.
- [Repo layout: config/ and scripts/](docs/repo-layout.md) — build-script
  configuration and helper scripts.
