---
name: resolve-upstream-bump-conflict
description: Fix a packages/<name> whose generated-changes/ patch set no longer applies cleanly against a new upstream chart version — `make prepare` fails with "unable to apply patch" / "Hunk #N FAILED" / a *.rej file, whether hit locally while bumping a package by hand or via a failed updatecli auto-bump PR. Use when make prepare or an updatecli pipeline apply errors out on a package, when a patch/overlay no longer applies after an upstream version bump, or when asked to resolve a chart patch conflict.
---

# /resolve-upstream-bump-conflict — fix a `make prepare` patch conflict after an upstream bump

This is the human-in-the-loop step `updatecli/README.md`'s "Known limitations" calls out
explicitly: when a new upstream chart release changes something this repo's own
`generated-changes/patch/**/*.patch` also touches, the patch no longer applies cleanly and
`make prepare`/the updatecli pipeline fails — no PR opens, nothing gets fixed automatically.
Someone has to reconcile the patch against the new upstream by hand. This skill is that recipe,
confirmed step-by-step against this repo's actual `charts-build-scripts prepare`/`patch` behavior
(not assumed from docs) — follow it exactly, especially Step 4's warning.

## Step 0 — figure out the package and get the failure for real

Get `<name>` from `$ARGUMENTS` or the failing CI job/PR. If `packages/<name>/package.yaml` hasn't
already been bumped to the new upstream `url`/`version` (e.g. you're resolving this ahead of
updatecli, or its PR only got as far as the failing `make` step), bump it now the same way
updatecli would — see [updatecli/README.md](../../../updatecli/README.md)'s "What a manifest does"
target stage — then reproduce locally:

```
make prepare PACKAGE=<name>
```

This **always cleans and re-pulls fresh upstream first** (`make prepare` runs charts-build-scripts'
own cleanup before pulling — you never need a separate `make clean` before it), then applies every
`generated-changes/patch/**/*.patch` file in order. Read the failure carefully:

```
patching file templates/controller.yaml
Hunk #1 FAILED at 7.
1 out of 2 hunks FAILED -- saving rejects to file templates/controller.yaml.rej
```

- **This is real GNU `patch` under the hood** (confirmed directly — not a Go reimplementation), so
  ordinary patch/fuzz semantics apply: a hunk whose *context* lines drifted slightly but whose
  target lines still exist often still applies with fuzz, silently, no error at all. An actual
  failure means a hunk's `-`/context lines genuinely can't be found anywhere near the expected line
  number in the new upstream file — upstream rewrote or removed the exact lines this repo's patch
  depends on.
  - **Only the hunks that fail are rejected — other hunks in the same file, and every other
    file's patches, still apply independently.** A patch with multiple hunks can partially apply.
  - **A failure aborts the whole `make prepare` run immediately** — any patch files later in the
    list (alphabetical by path) never get applied at all, and the overlay-copying step
    (`generated-changes/overlay/**`, e.g. `base.values.yaml`, `namespace.yaml`) never runs either,
    since it comes after all patches in the pipeline. `packages/<name>/charts/` is left in a
    **partially-prepared** state — this matters a lot for Step 4 below.
- The rejected hunk is saved to `<file>.rej` right next to the (unpatched, pristine-upstream)
  `<file>` inside `packages/<name>/charts/...` — open it to see exactly which lines charts-build-
  scripts expected vs. what it's diffing against:
  ```
  cat packages/<name>/charts/templates/<file>.rej
  ```
  It's in the same unified-diff format as the `.patch` file it came from — the `-` lines are what
  the old patch expected to remove, the `+` lines are what it meant to add.

## Step 1 — see what upstream actually changed there

Compare the `.rej` hunk's expected context against what's actually in the freshly-pulled file now:

```
sed -n '<approx-line>,+20p' packages/<name>/charts/templates/<file>
```

Common causes, in likely order: upstream reformatted/reordered the surrounding template (renamed a
value key, changed indentation, split one block into several), upstream added the same guard this
repo's patch was adding (the change may simply not be needed anymore — see Step 5), or upstream
removed/renamed the field this patch was targeting entirely (the change may need to move
elsewhere, or the whole patch may no longer make sense — check with whoever owns the reason it was
added, or the PR that introduced it).

## Step 2 — reapply the *intent* of the failed hunk by hand

Don't try to hand-edit the `.patch` file's diff syntax — edit the actual working file instead, the
same way you'd make any other local chart edit:

```
$EDITOR packages/<name>/charts/templates/<file>
```

Apply the same conceptual change the rejected hunk was making (visible in the `.rej` file's `+`
lines), adapted to whatever upstream's new surrounding structure actually looks like. Delete the
`.rej` file once done — it's not a real chart file and must not survive into the regenerated patch:

```
rm packages/<name>/charts/templates/<file>.rej
```

**Also delete any stray `*.orig` files** next to files that got patched — GNU `patch` leaves one of
these as a backup of the pre-patch content for *every* successfully-patched file, conflict or not
(confirmed directly: even a fully clean `make prepare` leaves `<file>.orig` next to every file its
patches touch). It's harmless sitting in `packages/<name>/charts/` (gitignored, and Step 4's
`make prepare` rebuild will not recreate it since prepare re-pulls a clean copy each time) — but
Step 4 below explains why it's dangerous to leave around when you run `make patch` **without**
first getting a clean `make prepare` in between:

```
find packages/<name>/charts -name '*.orig' -delete
```

## Step 3 — repeat for every other failure

A single upstream bump can break more than one patch file. Re-run `make prepare PACKAGE=<name>`
after each fix — remember Step 0's warning that a failure aborts the whole run, so **fixing one
file's conflict does not mean the run will get further next time**: it may immediately hit the
*next* patch file in line that was never reached before. Keep iterating step 1→2→3 (fix the file
`make prepare` now fails on, delete its `.rej`/`.orig`, re-run) until `make prepare PACKAGE=<name>`
exits **0** with no errors at all, applying every patch and every overlay file successfully.

## Step 4 — DO NOT run `make patch` until Step 3 exited clean — this is the one that bites

**Confirmed by direct testing, and it silently destroys unrelated work:** `charts-build-scripts
patch` does not incrementally update `generated-changes/`, it **regenerates it wholesale** from
whatever is currently sitting in `packages/<name>/charts/` versus a fresh upstream pull. If you run
`make patch PACKAGE=<name>` against a tree that only got **partially** prepared (Step 0's "a
failure aborts the run" — some patches never applied, overlay files never copied in), `make patch`
correctly concludes those never-applied changes "aren't there anymore" and **deletes their
`.patch`/overlay files from `generated-changes/` outright** — no warning, no error, it looks like a
perfectly normal successful `make patch` run. This is real, reproducible data loss if it lands in a
commit: legitimate patches and overlays (e.g. a `namespace.yaml` overlay, unrelated
`serviceaccount.yaml.patch` files later in the alphabetical list than the one that failed) vanish
from the repo along with whatever they were fixing.

The guard is simple: **only ever run `make patch PACKAGE=<name>` immediately after a `make prepare
PACKAGE=<name>` that exited 0 with no errors**, never after a failed or partial one, and never
reuse a `charts/` tree left over from a failed run. If in doubt, re-run `make prepare` once more
right before `make patch` to be sure.

```
make prepare PACKAGE=<name>   # must exit 0, zero errors, before proceeding
make patch PACKAGE=<name>
```

## Step 5 — verify the regenerated patch is sane, not just present

`git diff --stat -- packages/<name>/generated-changes` and `git status --porcelain --
packages/<name>/generated-changes`. Expect to see: the file(s) you actually fixed, changed. **Any
unrelated `.patch`/overlay file showing as deleted is the Step 4 failure mode** — stop, don't
commit, and redo Step 4's `make prepare` → `make patch` sequence from scratch (Step 0's automatic
clean means simply re-running `make prepare` fixes the tree state; `git checkout --
packages/<name>/generated-changes` first if `make patch` already ran and clobbered files, before
retrying).

Then confirm the result actually works, not just that the diff looks plausible:

```
make template PACKAGE=<name> | kubeconform -strict -summary -ignore-missing-schemas
make unittest PACKAGE=<name>
make kyverno-policy-check PACKAGE=<name>
make clean PACKAGE=<name>
```

(`kyverno-policy-check` failures on an *unrelated* policy id aren't this skill's job to fix — see
the `kyverno-policy-fix` skill instead; only worry here if the conflict resolution itself
introduced a new violation.)

## Step 6 — if updatecli was the one that hit this

Push the fix as a normal edit to the same `updatecli_main_<name>` branch the failed PR opened (or
its own failed dry-run left behind) rather than starting over — updatecli's next scheduled run will
still try to re-open/update it once `package.yaml` matches what's actually merged. If you resolved
this ahead of time (before updatecli ever got to it), no further action needed; the next run will
find `make prepare`/`make patch` already clean and proceed normally.
