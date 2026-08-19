---
name: kyverno-add-policy
description: Author a brand-new CEL Kyverno ClusterPolicy rule inside packages/kyverno-pod-policies or packages/kyverno-cluster-policies themselves (both local-chart, from-scratch charts) — template, tiering/enabled wiring, the exceptions rule-name registry, values.yaml/README documentation, and kyverno-test fixtures. This is the opposite direction from the kyverno-policy-fix skill, which fixes an existing violation in some OTHER package's chart; this one adds a new policy to the two policy charts themselves. Use when asked to add a new Kyverno policy/rule, harden kyverno-pod-policies or kyverno-cluster-policies with a new check, or extend the pod-security/cluster-governance ruleset.
---

# /kyverno-add-policy — author a new ClusterPolicy in kyverno-pod-policies or kyverno-cluster-policies

Adds a new rule to one of this repo's two from-scratch, cluster-wide Kyverno policy charts:
[packages/kyverno-pod-policies/local-chart](../../../packages/kyverno-pod-policies/local-chart)
(Pod Security Standards) or
[packages/kyverno-cluster-policies/local-chart](../../../packages/kyverno-cluster-policies/local-chart)
(broader org governance/cluster security outside PSS). Read whichever chart's own README fully
before starting — it's the authoritative reference for that chart's tiering vocabulary, the
blanket-kinds list, config-dependent policies, and Category F opt-in policies; this skill is the
condensed checklist, not a replacement. Every step below is copy-the-existing-pattern, not
improvisation — a new policy that doesn't follow the established shape will look inconsistent next
to the other 25.

## Step 0 — which chart, and what tier

- **kyverno-pod-policies** — the rule is a pod `securityContext`/PSS-style control (capabilities,
  privilege escalation, host namespaces/path/ports, seccomp, volume types, ...). Tier is
  **baseline** (default `Enforce`) or **restricted** (default `Audit`) — match the Kubernetes Pod
  Security Standards' own classification for this control, don't invent a third tier.
- **kyverno-cluster-policies** — everything else: labels/annotations, RBAC, image supply chain,
  DNS, resource limits, CRD/webhook self-protection, or a check scoped to one specific optional
  fleet component (rbac-manager, argo-cd, kargo, karpenter). Pick a tier:
  - **Enforce (default)** — the normal case for anything not gated on optional infra.
  - **Config-dependent** — the check only means something once a `config.*` list is populated
    (e.g. `config.allowedRegistries`); ships safely inert via `celPreconditions` until then, see
    `restrict-image-registries.yaml` as the template.
  - **Category F (opt-in/Disabled by default)** — targets a specific optional component's own CRD
    kind (not a generic Pod/Namespace check) and must stay a pure no-op if that component isn't
    even installed. Uses `kyverno-cluster-policies.policyEnabledOptIn` instead of `.policyEnabled`
    — see `restrict-kargo-promotion-scope.yaml` as the template. Only reaches for this when the
    check is genuinely meaningless outside that one component; don't default new general-purpose
    policies to opt-in just to be cautious.

Pick an `id` — kebab-case, `disallow-*`/`require-*`/`restrict-*` matching the existing naming
convention, unique across the chart. It becomes the `templates/<id>.yaml` filename AND the
`ClusterPolicy`'s `metadata.name` AND the `policies.<id>` values key — all three must match
exactly, everywhere.

## Step 1 — write `templates/<id>.yaml` from the closest existing example

Copy the nearest existing policy of the same shape rather than writing from scratch:
`disallow-host-ports.yaml` (simple baseline Pod check) or `require-run-as-nonroot.yaml`
(restricted) for kyverno-pod-policies; `restrict-image-registries.yaml` (config-dependent) or
`restrict-kargo-promotion-scope.yaml` (Category F opt-in) for kyverno-cluster-policies. The
skeleton, all charts share:

```yaml
{{/* one-paragraph comment: what this blocks, why, link to the kyverno/policies upstream example
     if adapted from one, and any CEL null-handling note (see below) */}}
{{- $id := "<id>" }}
{{- if ne .Values.enabled false }}
{{- if eq (include "<chart>.policyEnabled" (dict "id" $id "root" $)) "true" }}   {{/* or .policyEnabledOptIn for Category F */}}
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: {{ $id }}
  labels:
    {{- include "<chart>.labels" $ | nindent 4 }}
    {{- with .Values.commonLabels }}{{- toYaml . | nindent 4 }}{{- end }}
  annotations:
    policies.kyverno.io/title: <Human Title>
    policies.kyverno.io/category: <category text, matches the README table's grouping>
    policies.kyverno.io/subject: <Kind>
    policies.kyverno.io/description: >-
      <what this blocks/requires, and why>
    {{- with .Values.commonAnnotations }}{{- toYaml . | nindent 4 }}{{- end }}
spec:
  background: {{ .Values.background | default true }}
  rules:
    - name: <rule-name>
      match:
        any:
          - resources: { kinds: [Pod], operations: [CREATE, UPDATE] }   # or the real target kind
      exclude:
        {{- include "<chart>.exclude" (dict "id" $id "root" $) | nindent 8 }}
      validate:
        failureAction: {{ include "<chart>.failureAction" (dict "id" $id "tierDefault" "Enforce" "root" $) }}
        cel:
          expressions:
            - expression: <CEL>
              message: "<what failed>"
{{- end }}
{{- end }}
```

Hard rules, all confirmed against the existing 25 policies:

- **`match`/`exclude` must only ever use `kinds`/`namespaces`** (via the `<chart>.exclude` helper
  for the latter). Adding `names`, `selector`, or `annotations` there **silently disables Kyverno's
  autogen** (Deployment/StatefulSet/DaemonSet/ReplicaSet/Job/CronJob coverage) — the policy would
  then only ever catch bare Pods. Per-workload carve-outs belong in `exceptions:` (which uses
  `selector` safely, since `PolicyException` isn't autogen'd), never in the policy's own `exclude`.
- **CEL null-safety**: any field that can be legitimately *absent* on the object (not just
  zero-valued) — `initContainers`, `ephemeralContainers`, a container's `capabilities`/`ports`,
  etc. — must use the optional-chaining pattern already used everywhere in this chart:
  `object.spec.?initContainers.orValue([])`, then guard downstream `.all()`/`.map()` calls with a
  null-check ternary where a nested value could itself resolve to CEL `null` rather than an empty
  list: `(variables.initContainers == null ? [] : variables.initContainers)`. This is a real,
  previously-fixed crash class in this repo (a present-but-null field breaking `.all()`
  repo-wide) — copy the pattern from `disallow-host-ports.yaml`/`restrict-image-registries.yaml`
  exactly rather than writing a fresh `object.spec.initContainers` direct access.
- Use `celPreconditions` (see `restrict-image-registries.yaml`) for any config-dependent policy so
  an empty `config.*` list means "not opted in yet", not "block everything".
- `failureAction` and `exclude` always go through the chart's own helpers — never hardcode
  `Enforce`/`Audit` or a bare `exclude:` block by hand.

## Step 2 — register the rule name(s) in `_helpers.tpl`'s registry

Add one line to `<chart>.policyRuleNames` in `templates/_helpers.tpl`:

```
<id>: [<rule-name-1>, <rule-name-2>]
```

listing every `rules[].name` your new template actually defines (most policies have exactly one).
**This is easy to forget and fails silently until someone writes an exception against this id** —
`<chart>.exceptionEntry` (used by `exceptions:` rendering) calls `fail` on an unknown id, so a
missing registry entry only surfaces the first time someone tries to exempt this policy, not when
the policy itself is added. Do it now.

For kyverno-cluster-policies specifically, also check whether your new policy's target kind belongs
in `<chart>.blanketResourceKinds` (only relevant if you're adding to the
`require-resource-labels`/`require-resource-annotations` family, not a general-purpose policy).

## Step 3 — wire `values.yaml` documentation (no schema change needed)

`policies.<id>` doesn't need a new `values.schema.json` entry — the schema already covers every
policy id generically via `additionalProperties: {$ref: "#/definitions/policyToggle"}`. What *does*
need updating is the descriptive comment block above `policies: {}` in `values.yaml`: add `<id>` to
the appropriate bulleted list (baseline/restricted for kyverno-pod-policies; the lettered category
table for kyverno-cluster-policies) so the values file stays a readable index, matching the
existing entries' style.

## Step 4 — update the chart's README table

Add one row to the relevant table in `README.md` (`| id | rule name(s) | Blocks | Tier |`, adapting
columns to whichever chart's table shape) — this is the other authoritative index of what the
chart ships, and `kyverno-policy-fix`/other skills lean on it being accurate.

## Step 5 — kyverno-test fixtures (proves the CEL, not just the template)

Add a known-good/known-bad `Pod` (or real target kind) pair to `kyverno-test/resources.yaml`,
**namespaced `workloads`** — never `default`/`kube-node-lease`/`kube-public`, all of which every
policy's `exclude` block excludes by default, which would make a "should fail" fixture silently
skip instead of actually being evaluated:

```yaml
###### <id> / <rule-name>
---
apiVersion: v1
kind: Pod
metadata:
  name: <rule-name>-pass
  namespace: workloads
spec:
  containers:
    - name: app
      image: dummyimagename
      # ...compliant shape...
---
apiVersion: v1
kind: Pod
metadata:
  name: <rule-name>-fail
  namespace: workloads
spec:
  containers:
    - name: app
      image: dummyimagename
      # ...violating shape...
```

Then add the matching `results:` entries to `kyverno-test/kyverno-test.yaml`:

```yaml
  - policy: <id>
    rule: <rule-name>
    kind: Pod
    resources: [<rule-name>-pass]
    result: pass
  - policy: <id>
    rule: <rule-name>
    kind: Pod
    resources: [<rule-name>-fail]
    result: fail
```

Run it:

```
make kyverno-test PACKAGE=<kyverno-pod-policies|kyverno-cluster-policies>
```

(requires the `kyverno` CLI, `./scripts/pull-kyverno.sh`; renders the chart fresh into
`kyverno-test/policies.rendered.yaml` first, gitignored, never commit that file).

## Step 6 — helm-unittest coverage for the templating layer

`kyverno-test` (Step 5) proves the CEL logic; it says nothing about whether `policies.<id>.enabled:
false` actually skips the resource, or a `validationFailureAction` override actually wins — that's
`tests/policy-toggles_test.yaml`'s job. Add your new template to that suite's `templates:` list and
at minimum one `it:` case confirming it renders as a `ClusterPolicy` with the right default
`failureAction` for its tier — copy the shape of an existing `it:` block for the same tier rather
than inventing new assertions. Run:

```
make unittest PACKAGE=<kyverno-pod-policies|kyverno-cluster-policies>
```

## Step 7 — full verification

```
make template PACKAGE=<chart> | kubeconform -strict -summary -ignore-missing-schemas
make unittest PACKAGE=<chart>
make kyverno-test PACKAGE=<chart>
```

Then confirm the new policy doesn't unexpectedly break every *other* package in the repo — a new
Enforce-tier policy can turn up real, pre-existing fleet-wide violations the moment it ships (this
happened for real with `disallow-wildcard-rbac`/`require-explicit-automount` in
kyverno-cluster-policies — see that chart's README). Spot-check a representative handful of
packages, not all ~30:

```
make prepare PACKAGE=<some-package> && make kyverno-policy-check PACKAGE=<some-package>
```

If it does turn up widespread violations, that's an expected/documented tradeoff to flag in the PR
description, not a bug in the new policy — don't water down the CEL just to avoid it. Genuine
per-package carve-outs belong in that package's own `kyverno-policy-fix` pass afterward, or (if the
policy's own default posture is wrong) reconsider Enforce-vs-Audit for this specific id.
