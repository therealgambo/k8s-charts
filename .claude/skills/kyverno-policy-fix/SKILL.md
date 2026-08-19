---
name: kyverno-policy-fix
description: Fix (or just investigate) Kyverno policy violations reported by `make kyverno-policy-check PACKAGE=<name>` for a packages/<name> chart in this k8s-charts repo — missing required resource labels/annotations, pod-security hardening (dropped capabilities, privilege escalation, runAsNonRoot, seccompProfile, restricted volume types, hostPath), missing emptyDir sizeLimit, automountServiceAccountToken, disallowed priorityClassName, and similar kyverno-pod-policies/kyverno-cluster-policies findings. Use when the user asks to fix Kyverno violations, make a chart pass `kyverno-policy-check`, bring a package into policy compliance, references kyverno-cluster-policies/kyverno-pod-policies failures on a specific package, or runs `/kyverno-policy-fix <package>`.
---

# /kyverno-policy-fix — bring a packages/<name> chart into Kyverno compliance

Fixes `make kyverno-policy-check` violations for one package. There's no fixed, repo-wide list of
value keys to set: every upstream chart wires labels, annotations, pod/container
`securityContext`, `automountServiceAccountToken`, `priorityClassName`, and volume shapes through
its own `values.yaml` differently, or sometimes not at all. Treat each package as a discovery
exercise and work through the steps below in order — don't skip straight to editing templates.

**Golden rule: `packages/<name>/charts/values.yaml` is never edited to fix a violation.** It's
re-derived from upstream by every `make prepare` and diffed against pristine upstream by `make
patch` — an edit there becomes part of that diff and has to be re-reconciled on every future
upstream bump. `packages/<name>/charts/base.values.yaml` is the layer this repo carved out
specifically for local overrides on top of upstream defaults (see
[README.md](../../../README.md#values-file-ordering)) — that's the only values file this skill
ever writes to.

## Step 0 — figure out the package

Parse `$ARGUMENTS` for a package name (e.g. `aws-ebs-csi-driver`). If none was given, ask, or
infer it from whatever the user was just running `make kyverno-policy-check` against.

Confirm it's a forked package (`packages/<name>/charts` + `generated-changes/`, produced by `make
patch`) — steps 4/4a below assume that layout. `local-chart` packages (no upstream to diff
against — e.g. `packages/network-policies`, `packages/kyverno-pod-policies`,
`packages/kyverno-cluster-policies` itself) have no `generated-changes/` indirection: apply the
same discovery/decision logic, but edit `local-chart/templates/` directly instead.

## Step 1 — get the baseline violation list

```
make prepare PACKAGE=<name>
.claude/skills/kyverno-policy-fix/verify.sh <name>
```

`verify.sh` runs the exact same render + `kyverno apply` as `make kyverno-policy-check
PACKAGE=<name>`, plus a summary of failures grouped and counted by policy id (`--env <env>` to
match a non-default `ENV`). Group by id first — one policy id usually affects every resource of a
kind the same way, so one fix tends to clear several failures at once. Enforce-tier ids fail the
run; Audit-tier ids print as warnings and don't — this mirrors the required CI gate exactly, which
runs this same check unconditionally on every changed package, no allow-list.

## Step 2 — per violated id, find out whether the flagged field is already values-driven

Read `packages/<name>/charts/values.yaml` (and `values.schema.json`, if present) for a plausible
knob — common shapes to look for:
- `commonLabels`/`customLabels`/`podLabels`/`extraLabels` and
  `commonAnnotations`/`podAnnotations`/`extraAnnotations` for the label/annotation policies.
- `securityContext`/`podSecurityContext`/`containerSecurityContext` for the pod-hardening ones.
- `serviceAccount.automountServiceAccountToken` — note this sets it on the ServiceAccount object,
  NOT necessarily the pod spec `require-explicit-automount` actually checks. Different fields,
  easy to conflate.
- `priorityClassName`.
- An `emptyDir:`-shaped value passed straight through for a specific volume (e.g.
  `xxxVolume.emptyDir`, `xxxVolume.emptyDir.sizeLimit`).

Don't stop at reading `values.yaml` — confirm with the templates that the value actually reaches
the field the policy checks:

```
grep -rn "Values\.<candidateKey>" packages/<name>/charts/templates/
```

- A helper a value gets wired into (e.g. a chart's common `<chart>.labels`) isn't always
  `include`d by every template in the chart — grep for the helper's own name across
  `templates/**/*.yaml` to see which resource kinds it actually covers. Helm test hooks
  (`templates/tests/`) in particular often build their own bare `metadata:` block instead of
  calling it — expect gaps there even after the main workload/RBAC resources are clean, and handle
  them as a separate, smaller step-4-or-4a fix rather than assuming the shared helper covers
  everything.
- Watch for a template-side fallback `values.yaml` doesn't show, e.g. `priorityClassName: {{
  .Values.node.priorityClassName | default "system-node-critical" }}` — the values file may show
  the key as unset/blank while the rendered resource still carries a real value.

## Step 3 — values-driven fix → verify a candidate, then write it to `base.values.yaml`

Test the candidate change WITHOUT writing it into the repo yet:

```
cat > /tmp/candidate.values.yaml <<'EOF'
customLabels:
  metadata.example.com/team: <team>
EOF
.claude/skills/kyverno-policy-fix/verify.sh <name> --with /tmp/candidate.values.yaml
```

This re-renders with the candidate layered on top of the real `values.yaml -> base.values.yaml ->
ci.values.yaml -> <ENV>.values.yaml` stack (same order `make template` uses) and prints CLEARED /
STILL FAILING / NEWLY FAILING sections — confirm the change fixes what you expect and doesn't
regress anything else. Only once confirmed, move exactly that content into
`packages/<name>/charts/base.values.yaml` (create the file if `make prepare` didn't leave one),
then `make patch PACKAGE=<name>` to capture it into `generated-changes/`.

Worked example, from `packages/aws-ebs-csi-driver` (confirmed with the workflow above): its
`aws-ebs-csi-driver.labels` helper already renders `.Values.customLabels` via `toYaml`, and every
RBAC/workload template the label policies flag includes that helper, so `customLabels:
{metadata.example.com/team: <team>}` alone clears `require-resource-labels` everywhere except the
`templates/tests/` hook resources (the gap the step-2 bullet above calls out).
`controller.socketDirVolume`/`node.probeDirVolume` are likewise `emptyDir:`-shaped values passed
straight through, so setting `sizeLimit` under each clears `require-emptydir-sizelimit` for both
DaemonSets and the Deployment — no template edit at all. That chart has no equivalent
`customAnnotations`-shaped value, though, so `require-resource-annotations` there needs step 4.

## Step 4 — no values knob reaches the field → patch the template

When step 2's discovery turns up nothing — the field is hardcoded, or no template even references
a value for it — there's no values-only fix. Edit `packages/<name>/charts/templates/<file>.yaml`
(or `_helpers.tpl`) directly after `make prepare`, then capture it the normal way with `make patch
PACKAGE=<name>`.

For `require-resource-labels`/`require-resource-annotations` specifically, don't improvise one —
follow step 4a below, which is exactly this situation worked through in detail (most charts have
no common-annotations helper at all, same as `aws-ebs-csi-driver` above).

## Step 4a — label/annotation-specific template-patch pattern

`packages/kyverno-cluster-policies` renders cluster-wide Kyverno `ClusterPolicy` resources
(`require-labels`, `require-resource-labels`, `require-resource-annotations`) that block admission
of resources missing required metadata — see
[packages/kyverno-cluster-policies/local-chart/values.yaml](../../../packages/kyverno-cluster-policies/local-chart/values.yaml)
`config.requiredResourceLabels` / `config.requiredResourceAnnotations` /
`config.requiredNamespaceLabels` for the current key lists, and that chart's
`kyverno-cluster-policies.blanketResourceKinds` helper (`local-chart/templates/_helpers.tpl`) for
exactly which kinds `require-resource-labels`/`require-resource-annotations` match (Deployment,
StatefulSet, DaemonSet, ReplicaSet, Job, CronJob, Pod, Service, ConfigMap, Secret, Ingress,
ServiceAccount, PersistentVolumeClaim, Role, RoleBinding, ClusterRole, ClusterRoleBinding,
NetworkPolicy — `require-labels` is Namespace-only, separately).

Do NOT hand-add literal label/annotation keys to individual resources. Use this pattern instead —
worked example already applied in `packages/kube-state-metrics`
(`generated-changes/patch/templates/_helpers.tpl.patch`, and every other `*.yaml.patch` in that
same directory):

1. **Add two reusable helper definitions** to `packages/<name>/charts/templates/_helpers.tpl`
   (after `make prepare PACKAGE=<name>`):
   - `<chart>.patchedLabels` — one line per key in `config.requiredResourceLabels` not already
     covered by the chart's standard labels. Most charts already emit
     `app.kubernetes.io/name`/`app.kubernetes.io/managed-by` in their own common-labels helper, so
     this is usually just `metadata.example.com/team: <team>`.
   - `<chart>.patchedAnnotations` — one line per key in `config.requiredResourceAnnotations`,
     currently just `metadata.example.com/repository: https://github.com/therealgambo/k8s-charts`.

   Keep both scoped to exactly what the policies require — don't fold in unrelated
   labels/annotations.

2. **Wire `<chart>.patchedLabels` into the chart's existing common-labels helper** (usually
   `<chart>.labels`) with one `{{- include "<chart>.patchedLabels" . }}` line, so every resource
   that already renders that helper picks it up for free. Most charts have no equivalent
   common-*annotations* helper (annotations tend to be per-resource and often conditional on
   `.Values.xxx.annotations`), so `<chart>.patchedAnnotations` normally needs including explicitly
   per resource instead — step 3 below.

3. **For every resource template of a kind `blanketResourceKinds` covers**, confirm
   `.metadata.labels` already renders `<chart>.patchedLabels` transitively (step 2), and add
   `{{- include "<chart>.patchedAnnotations" . | indent 4 }}` (match the file's existing
   `indent`/`nindent` style) under `.metadata.annotations`. If `annotations:` is currently only
   emitted conditionally (`{{- with .Values.annotations }}\nannotations:\n...`), make the key
   unconditional and include the helper first, keeping the existing user-supplied-annotations
   block below it — see
   `packages/kube-state-metrics/generated-changes/patch/templates/deployment.yaml.patch` and
   `rbac-configmap.yaml.patch` for that exact shape; see `service.yaml.patch`,
   `serviceaccount.yaml.patch`, `pdb.yaml.patch`, `stsdiscovery-role.yaml.patch`, and
   `verticalpodautoscaler.yaml.patch` for resources that had no annotations block at all yet.

4. **If the chart doesn't already render a `Namespace`** (check
   `packages/<name>/charts/templates/namespace.yaml` after `make prepare`), create one explicitly
   — `require-labels` is Namespace-scoped and can't be satisfied by a namespace Helm never
   creates. This is a wholly new file, not a diff against upstream, so it goes under
   `packages/<name>/generated-changes/overlay/templates/namespace.yaml` (`make patch` classifies
   new files as overlays automatically), never under `generated-changes/patch/`. See
   [packages/kube-state-metrics/generated-changes/overlay/templates/namespace.yaml](../../../packages/kube-state-metrics/generated-changes/overlay/templates/namespace.yaml)
   as the worked example: it sets `config.requiredNamespaceLabels`' key (`pager.example.com/key`)
   as a literal directly in `.metadata.labels` — NOT via `patchedLabels`, since the
   Namespace-label list and the blanket resource-label list are separate `config` keys —
   alongside the chart's normal `<chart>.labels` include, and still includes
   `<chart>.patchedAnnotations`.

## Step 5 — the violation reflects the workload's real requirement → PolicyException, not a workaround

Some violations are the chart correctly doing something it has to do — neither a values override
nor a template patch is the right fix, and forcing one would break the workload rather than harden
it. `packages/aws-ebs-csi-driver`'s node DaemonSets are one example: `restrict-priorityclass`
fires because a CSI node plugin has to out-survive node-pressure eviction (`system-node-critical`),
and `disallow-host-path`/`require-run-as-nonroot` fire because it has to run as root with hostPath
mounts to bind the kubelet's registration/driver sockets. Before reaching for step 3 or 4, ask:
would the "fix" actually change what the workload needs to do, or only silence the check? If the
former, this is a selector-scoped `exceptions` entry in
`packages/kyverno-pod-policies/local-chart/values.yaml` /
`packages/kyverno-cluster-policies/local-chart/values.yaml` instead — see each chart's own README
for how exceptions are declared. This is the exception, not the default — steps 3, 4, and 4a above
are.

## Step 6 — verify for real

```
make patch PACKAGE=<name>
make kyverno-policy-check PACKAGE=<name>
make template PACKAGE=<name> | kubeconform -strict -summary -ignore-missing-schemas
```
