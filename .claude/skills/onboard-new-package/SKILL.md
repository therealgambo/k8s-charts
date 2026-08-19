---
name: onboard-new-package
description: End-to-end checklist for adding a brand-new Helm chart package to this k8s-charts repo, from a bare packages/<name>/package.yaml through Kyverno compliance, automated upstream tracking, and CI-equivalent validation. Sequences the more detailed updatecli-add-package and kyverno-policy-fix skills rather than duplicating their steps. Use when asked to onboard/add/vendor a brand-new package or chart into this repo from scratch (not for bumping an existing package's version, and not for a from-scratch url:-local package — see the notes below).
---

# /onboard-new-package — add a brand-new packages/<name> to this repo

This is the front door for a genuinely new forked-upstream package — it doesn't replace the two
skills that do the real work, it just sequences them correctly and fills the gaps between them
(values-file setup, testing scaffolding, final CI-equivalent validation). If the package is a
from-scratch chart with no upstream at all (`url: local`, like `network-policies` or the two
`kyverno-*-policies` charts), this skill doesn't apply — that's a much larger, bespoke design
exercise, not an onboarding checklist; ask for guidance rather than following this.

## Step 1 — `package.yaml`

Write `packages/<name>/package.yaml` pointing at the chart's current upstream release. See
[packages/README.md](../../../packages/README.md) for the field reference (`url`,
`subdirectory`, `chartRepoBranch`/`commit`, `version`, `packageVersion`, `workingDir`,
`additionalCharts`) — a fresh package conventionally starts at `packageVersion: 01` and omits
`workingDir` (defaults to `charts/`, the forked-package convention; see
[[local-chart-package-convention]] if this is somehow a from-scratch package instead — shouldn't be
per the note above).

## Step 2 — pull it in and confirm it renders

```
make prepare PACKAGE=<name>
make template PACKAGE=<name> | kubeconform -strict -summary -ignore-missing-schemas
helm lint packages/<name>/charts
```

If this package needs environment-specific values (most do eventually), add `base.values.yaml`
and/or `test.values.yaml`/`staging.values.yaml`/`production.values.yaml` alongside `values.yaml`
inside `packages/<name>/charts/` now — see the main
[README's "Values file ordering"](../../../README.md#values-file-ordering). Any local edit at this
point (values files or template changes) needs capturing:

```
make patch PACKAGE=<name>
```

## Step 3 — bring it into Kyverno compliance

Every package in this repo is held to the same `kyverno-pod-policies` + `kyverno-cluster-policies`
bar, no allow-list:

```
make kyverno-policy-check PACKAGE=<name>
```

If this fails, use the **`kyverno-policy-fix`** skill (`/kyverno-policy-fix <name>`) to work through
the violations — don't hand-roll fixes here, that skill has the full discovery workflow (values
knob vs. template patch vs. a genuine `PolicyException`) already worked out.

## Step 4 — testing scaffolding, if warranted

- `tests/` (helm-unittest, `make unittest PACKAGE=<name>`) — add if this package has non-trivial
  conditional templating worth locking down. Not every package needs this; skip for a
  straightforward vendor with no local template patches.
- `check-images` — confirm every referenced image is actually pullable, catching an upstream chart
  tag whose images never got published:
  ```
  make check-images PACKAGE=<name>
  ```

## Step 5 — wire up automated upstream tracking

Use the **`updatecli-add-package`** skill (`/updatecli-add-package <name>`) to classify this
package's upstream shape (OCI / classic Helm repo / GitHub release / hand-rolled) and write the
matching `updatecli/updatecli.d/<name>.yaml` manifest, then validate it per that skill's Step 4.

## Step 6 — final check and cleanup

```
make check-package-version PACKAGE=<name>
make clean PACKAGE=<name>
```

(`check-package-version` no-ops for a genuinely new package — see
[packages/README.md](../../../packages/README.md) — it only matters from here on, whenever this
package's patch set changes again without an upstream bump.)

Confirm `git status` shows only `packages/<name>/package.yaml`,
`packages/<name>/generated-changes/`, and `updatecli/updatecli.d/<name>.yaml` — never
`packages/<name>/charts/` (gitignored build output) or anything under repo-root `assets/`/`charts/`.
The PR that adds this package is exactly those files; CI (`validate-charts.yaml`, the Kyverno
policy checks) re-runs everything above on the PR itself.
