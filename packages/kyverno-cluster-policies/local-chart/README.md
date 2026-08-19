# kyverno-cluster-policies

A cluster-wide Helm chart of CEL-based [Kyverno](https://kyverno.io) `ClusterPolicy` resources
enforcing organizational governance and cluster-security controls that sit **outside** the
Kubernetes Pod Security Standards -- image supply chain, DNS hygiene, resource/DoS protection,
RBAC privilege-escalation prevention, CRD "confused-deputy" lateral movement, and policy-engine
self-protection -- plus centrally-managed `PolicyException` carve-outs. Companion to
[`packages/kyverno-pod-policies`](../../kyverno-pod-policies), which owns every PSS/pod
`securityContext` control; this chart deliberately does not duplicate any of those. Like that
chart, this one is a **singleton**: install it once, cluster-wide -- it's not a dependency of other
charts.

It assumes the companion [`packages/kyverno`](../../kyverno) chart (the policy engine itself) is
already installed. Rules targeting `kind: Pod` rely on Kyverno's
[autogen](https://kyverno.io/docs/policy-types/cluster-policy/autogen/) feature to also cover
Deployment/StatefulSet/DaemonSet/ReplicaSet/Job/CronJob pod templates automatically. Several rules
here target entirely different kinds (Namespace, Role/ClusterRole/RoleBinding/ClusterRoleBinding,
ValidatingWebhookConfiguration/MutatingWebhookConfiguration, CustomResourceDefinition, and a
handful of this fleet's own operator CRDs) -- autogen does not apply to those; they're matched
directly.

## Enforced by default, tiered -- but not the PSS way

kyverno-pod-policies ties its tiers to the Kubernetes Pod Security Standards' own baseline/
restricted split. That vocabulary doesn't map onto this chart's much broader scope, so every policy
here instead carries one of:

- **Enforce (default)** -- every policy in this chart, except the Category F (opt-in) ids below,
  blocks on admission by default. Config-dependent policies (an empty `config.*` allow-list below)
  stay a safe no-op via `celPreconditions` until their list is populated -- see "Config-dependent
  policies" below. A few non-config-dependent ids (`disallow-wildcard-rbac`,
  `require-explicit-automount`) **will** surface real existing violations across this fleet
  immediately -- see each policy's own template comment. Soften any individual id back to
  visibility-only with `policies.<id>.validationFailureAction: Audit`, or every id at once with the
  global `validationFailureAction` override.
- **Disabled (default)** -- opt-in only (Category F). Targets an optional cluster component
  (rbac-manager, argo-cd, kargo, karpenter) that may not even be installed. Unlike every other
  policy here, "not set" means **off** for these -- set `policies.<id>.enabled: true` explicitly to
  turn one on. See "Opt-in (Disabled) policies" below.

`Audit` remains a valid `validationFailureAction` value everywhere -- it's just no longer any
policy's *default* -- so per-cluster or per-policy downgrades stay a one-line override, same
precedence order as kyverno-pod-policies: global `validationFailureAction` >
`policies.<id>.validationFailureAction` > tier default.

## The policies

Every id below is both its `templates/<id>.yaml` file name and its `ClusterPolicy`'s
`metadata.name`. Full CEL is in each file; this is what each one blocks, and which `config.*`
value (if any) it needs populated to mean anything.

### A. Organizational governance

| id | kind | rule name(s) | Blocks/requires | Tier |
|---|---|---|---|---|
| `require-labels` | Namespace | `check-required-labels` | Missing keys from `config.requiredNamespaceLabels` | Enforce |
| `require-resource-labels` | [blanket kind list](#blanket-label-and-annotation-enforcement) | `check-required-resource-labels` | Missing keys from `config.requiredResourceLabels` | Enforce |
| `require-resource-annotations` | [blanket kind list](#blanket-label-and-annotation-enforcement) | `check-required-resource-annotations` | Missing keys from `config.requiredResourceAnnotations` | Enforce |
| `disallow-reserved-annotation-prefixes` | Pod (autogen) | `reserved-annotation-prefix` | End users setting `kyverno.io/`-prefixed annotations | Enforce |

#### Blanket label and annotation enforcement

`require-labels` only ever looked at `Namespace` objects. `require-resource-labels` and
`require-resource-annotations` extend the same required-key check to every other manifest kind a
Helm chart in this fleet actually renders:

```
Deployment, StatefulSet, DaemonSet, ReplicaSet, Job, CronJob, Pod, Service, ConfigMap, Secret,
Ingress, ServiceAccount, PersistentVolumeClaim, Role, RoleBinding, ClusterRole, ClusterRoleBinding,
NetworkPolicy
```

(the exact list lives in one place, `kyverno-cluster-policies.blanketResourceKinds` in
`_helpers.tpl`, so the two policies can never drift apart on scope). Deliberately **not**
`kind: "*"` -- a true wildcard would also catch Kubernetes-internal/system-managed objects (`Lease`,
`Endpoints`, `EndpointSlice`, `Event`, `ControllerRevision`, `CSIStorageCapacity`, ...) that carry no
custom labels by convention and were never meant to be governed by org label/annotation policy;
enforcing there risks blocking things like leader-election `Lease`s, not just chart manifests. If
your fleet renders a kind that isn't in that list, it's simply not covered by these two policies --
`_helpers.tpl`'s own comment is the place to extend the list, not a per-cluster override (there
isn't one; unlike `exclude.kinds`, this is scope, not a carve-out).

`Namespace` is deliberately excluded from the blanket list too -- that's what `require-labels`
already owns, with its own `config.requiredNamespaceLabels` key. The two blanket policies use their
own separate keys (`config.requiredResourceLabels` / `config.requiredResourceAnnotations`) rather
than reusing `requiredNamespaceLabels`, since a Namespace and a Secret may legitimately need
different required keys -- populate both the same way if you want identical enforcement everywhere.

Both are Enforce by default and, like `require-labels`, need no `celPreconditions` skip-when-empty
guard -- `.all()` over an empty required-keys list is vacuously true, so an unpopulated
`config.requiredResourceLabels`/`config.requiredResourceAnnotations` is a safe no-op from day one,
same as `require-labels` itself.

### B. Supply chain

| id | kind | rule name(s) | Blocks/requires | Tier |
|---|---|---|---|---|
| `disallow-latest-tag` | Pod (autogen) | `require-and-validate-image-tag` | `:latest` tag, or no tag at all | Enforce |
| `restrict-image-registries` | Pod (autogen) | `validate-registries` | Image outside `config.allowedRegistries` (empty ⇒ inert, see below) | Enforce |

### C. DNS hygiene

Admission-time pod-spec fields -- a distinct layer from [network-policies](../../network-policies)'
L3/L4 Cilium enforcement, not a duplicate of it.

| id | kind | rule name(s) | Blocks/requires | Tier |
|---|---|---|---|---|
| `restrict-dns-policy` | Pod (autogen) | `restrict-dns-policy` | `dnsPolicy: Default`/`None` | Enforce |
| `disallow-custom-dns-config` | Pod (autogen) | `disallow-custom-nameservers` | `dnsConfig.nameservers` outside `config.allowedNameservers` (empty ⇒ inert, see below) | Enforce |
| `disallow-host-aliases` | Pod (autogen) | `disallow-host-aliases` | Any `hostAliases` entry | Enforce |

### D. Resource and DoS protection

| id | kind | rule name(s) | Blocks/requires | Tier |
|---|---|---|---|---|
| `require-emptydir-sizelimit` | Pod (autogen) | `require-emptydir-sizelimit` | `emptyDir` volume with no `sizeLimit` | Enforce |
| `restrict-priorityclass` | Pod (autogen) | `restrict-priorityclass` | `system-cluster-critical`/`system-node-critical` priorityClassName | Enforce |
| `require-resource-requests-limits` | Pod (autogen) | `validate-resources` | Missing cpu/memory requests+limits | Enforce |

### E. RBAC privilege-escalation prevention

| id | kind | rule name(s) | Blocks/requires | Tier |
|---|---|---|---|---|
| `disallow-rbac-escalation-verbs` | Role, ClusterRole | `escalate` | `bind`/`escalate`/`impersonate` verbs on roles/clusterroles resources | Enforce |
| `disallow-wildcard-rbac` | Role, ClusterRole | `wildcard-verbs`, `wildcard-resources`, `wildcard-apigroups` | `*` in verbs/resources/apiGroups | Enforce |
| `disallow-clusteradmin-binding` | RoleBinding, ClusterRoleBinding | `clusteradmin-default-sa-binding` | Binding `cluster-admin` to a namespace's `default` ServiceAccount | Enforce |
| `require-explicit-automount` | Pod (autogen) | `require-explicit-automount` | `automountServiceAccountToken` left unset | Enforce |

### F. CRD confused-deputy / lateral movement (opt-in, disabled by default)

The core mechanism: a principal only needs create/patch on a *namespaced* (or even cluster-scoped)
custom resource; the *operator's own* ServiceAccount -- often broad -- does the privileged action on
their behalf. Autogen never reaches these, and admission control for them is otherwise easy to
overlook entirely. Every id below targets a CRD from an *optional* component of this fleet and
**defaults off** -- opt in per-cluster once that component is actually installed and the relevant
`config.*` allow-list is populated. See "Opt-in (Disabled) policies" for the mechanics.

| id | kind | rule name(s) | Blocks/requires | Needs |
|---|---|---|---|---|
| `restrict-rbacdefinition-clusterrole` | `rbacmanager.reactiveops.io/v1beta1 RBACDefinition` | `restrict-clusterrole` | `clusterRole` values outside `config.rbacDefinitionAllowedClusterRoles` | [rbac-manager](../../rbac-manager) |
| `restrict-argocd-application-project` | `argoproj.io/v1alpha1 Application` | `require-scoped-project` | `spec.project` unset or `default` | [argo-cd](../../argo-cd) |
| `restrict-kargo-promotion-scope` | `kargo.akuity.io/v1alpha1 Promotion` | `restrict-promotion-target` | `spec.stage` outside `config.kargoAllowedTargets` | [kargo](../../kargo) |
| `restrict-karpenter-nodeclass-profile` | `karpenter.k8s.aws/v1 EC2NodeClass` | `restrict-instance-profile` | `spec.role`/`spec.instanceProfile` outside `config.karpenterAllowedInstanceProfiles` | [karpenter](../../karpenter) |
| `restrict-crd-creation` | CustomResourceDefinition | `restrict-creation` | Creator identity outside `config.gitopsIdentities` | -- |

**CRD field paths were confirmed against each project's real Go API types** (rbac-manager's
`pkg/apis/rbacmanager/v1beta1/rbacdefinition_types.go`, kargo's `api/v1alpha1/promotion_types.go`,
karpenter's `pkg/apis/v1/ec2nodeclass.go`), not assumed from memory -- but CRDs evolve. Re-verify
the field path against whatever version of each component you actually run before enabling one of
these in `Enforce`.

### G. Policy-engine self-protection

Stops a compromised identity from simply turning off every other control in this chart (or
kyverno-pod-policies) rather than fighting them directly. `background: false` on both -- a
background re-scan of pre-existing resources isn't a real admission request, so `request.userInfo`
wouldn't be meaningful there.

| id | kind | rule name(s) | Blocks/requires | Tier |
|---|---|---|---|---|
| `protect-kyverno-resources` | ClusterPolicy, PolicyException | `restrict-changes` | Modification by an identity outside `config.gitopsIdentities` (empty ⇒ inert, see below) | Enforce |
| `disallow-webhook-tampering` | ValidatingWebhookConfiguration, MutatingWebhookConfiguration | `restrict-changes` | Same, non-GitOps modification | Enforce |

**`request.userInfo` availability**: classic `kyverno.io/v1 ClusterPolicy` CEL isn't as
well-documented for this as the newer `ValidatingPolicy` CRD -- confirmed by reading Kyverno's own
Go source (`pkg/cel/engine/request.go`), which builds the `request` CEL variable directly from the
standard `admission/v1.AdmissionRequest` type (carries `UserInfo`) for both engines alike; the
kyverno.io docs site 404'd when fetched directly for this, consistent with kyverno-pod-policies'
own README note that GitHub, not the docs site, is the actual source of truth here.

**Deliberately not shipped** (documented gaps, not silent omissions):

- `verify-image-signatures` -- needs Kyverno's `verifyImages` (cosign), an entirely different rule
  type from `validate.cel`. Worth its own follow-up, not bolted on here.
- `restrict-namespace-naming` -- naming conventions are too org-specific to default to anything
  sane; `config.requiredNamespaceLabels` (via `require-labels`) covers the governance need without
  guessing at a regex.
- A general RBAC-level control mirroring `kyverno/policies`'
  `restrict-clusterrole-mutating-validating-admission-webhooks` (restrict which ClusterRoles may
  grant write access to webhook configs at all, rather than gating the webhook objects themselves
  by identity) -- complementary to `disallow-webhook-tampering`, no CEL variant exists upstream yet
  to adapt from; worth adding alongside it in a future iteration.

## Config-dependent policies: empty list means inert, not "block everything"

Several policies above validate against a `config.*` allow-list (see values.yaml's `config:`
block) that defaults to empty. For allow-list-shaped checks (`restrict-image-registries`,
`disallow-custom-dns-config`, `protect-kyverno-resources`, `disallow-webhook-tampering`,
`restrict-crd-creation`), an empty list would otherwise mean "nothing is allowed" -- flagging every
single resource. Each of those instead uses a `celPreconditions` guard that skips the rule entirely
when its list is empty, so "not configured yet" reads as "not opted in yet" (no PolicyReport noise)
rather than "block everything". `require-labels`, `require-resource-labels`, and
`require-resource-annotations` don't need this guard -- they're *required*-keys checks, not
allow-lists, and `.all()` over an empty required-keys list is vacuously true on its own.

## The CEL null-vs-absent gotcha, and how every policy here avoids it

Documented against kyverno-pod-policies (see that chart's `kyverno-policy-check` CI gate notes,
reproduced against a real chart's `volumes: null`): Kyverno's CEL `.?field.orValue(default)` idiom
only substitutes `default` when `field` is **absent**. A field that's **present but explicitly
`null`** (a real thing Helm/other charts render, not a hypothetical) still resolves to CEL's null,
and calling `.all()`/`.exists()` on that null errors with `no such overload` -- counted as a policy
violation, not skipped, by Kyverno's engine. Every policy here that touches an optional list- or
map-typed field guards against this with an explicit null-coalesce at the point of use, e.g.:

```
variables:
  - name: volumes
    expression: "object.spec.?volumes.orValue([])"
expressions:
  - expression: "(variables.volumes == null ? [] : variables.volumes).all(volume, ...)"
```

This applies to `celPreconditions` expressions too, not just `validate.cel.expressions` -- a
precondition that itself errors on an explicit null is just as real a false positive as the rule
body erroring. `require-emptydir-sizelimit` and `restrict-image-registries`'s `kyverno-test`
fixtures include a dedicated present-but-null regression case each (`volumes: null`,
`initContainers: null`) proving this in practice, not just in theory; `require-labels`'s does the
same for a map-typed field (`labels: null`).

## Opt-in (Disabled) policies

Category F ids use a different gate than every other policy here.  Everywhere else,
`policies.<id>.enabled` is *opt-out* -- unset means on. For Category F, it's *opt-in* -- unset means
off, and only an explicit `policies.<id>.enabled: true` renders the `ClusterPolicy` at all:

```yaml
policies:
  restrict-rbacdefinition-clusterrole:
    enabled: true   # this cluster runs rbac-manager
  restrict-argocd-application-project:
    enabled: true   # this cluster runs argo-cd
```

The master switch (`enabled: false` at chart root) still suppresses these too, same as everything
else. There is no tier for these -- once opted in, they run at `Enforce` (or whatever
`policies.<id>.validationFailureAction`/the global override says), not a passive audit default;
opting in is itself the deliberate choice.

## How autogen works here

Identical mechanics to kyverno-pod-policies for every `kind: Pod` rule: `match` is
`{resources: {kinds: [Pod], operations: [...]}}` only, and Kyverno's autogen feature projects
equivalent rules onto Deployment/StatefulSet/DaemonSet/ReplicaSet/Job/CronJob automatically.
**Never** add `names`/`selector`/`annotations` to a Pod-kind policy's `match`/`exclude` -- doing so
silently disables autogen for that rule. Rules matching other kinds (Role, ClusterRoleBinding,
CustomResourceDefinition, this fleet's operator CRDs, ...) have no such mechanism -- Kyverno never
autogens non-Pod-controller kinds, so those match the kind directly and only ever apply to that
exact kind.

## Testing & validation

Same three-layer strategy as kyverno-pod-policies -- see that chart's README for the full
rationale of why each layer exists and what it can't catch. Summary:

- **`tests/*_test.yaml`** (helm-unittest, `make unittest PACKAGE=kyverno-cluster-policies`) --
  templating layer: toggles, tier defaults, exclude merging, the Category F opt-in gate, exceptions'
  autogen-vs-non-autogen rule-name expansion, and that a `config.*` list actually lands in the
  right CEL variable as a JSON-encoded string.
- **`kyverno-test/`** (Kyverno CLI test, `make kyverno-test PACKAGE=kyverno-cluster-policies`) --
  rule *logic*: a known-good/known-bad fixture pair per rule name (48 assertions total), plus
  dedicated present-but-null regression fixtures for the gotcha above. Renders with this chart's own
  `kyverno-test/values.yaml` layered on top of the normal `make template` stack (see that file's own
  comment, and the root Makefile's `kyverno-test` target) so every `config.*`-dependent and
  Category F policy is actually exercised, not silently skipped -- `kyverno-test/values.yaml` only
  affects `make kyverno-test` for this package, never the fleet-wide check below, which renders
  this chart via the same `make template` every other package uses, picking up this chart's real
  shipped defaults.
  - The 3 identity-gated rules (`protect-kyverno-resources`, `disallow-webhook-tampering`,
    `restrict-crd-creation`) only get a "fail" fixture: the Kyverno CLI's `userinfo:` setting is one
    value for the *entire* Test run, not per-resource, so there's no way to inject both an
    authorized and an unauthorized identity in a single `kyverno-test.yaml`. The security-relevant
    direction (wrong identity blocked) is proven; "right identity is allowed" isn't separately
    fixture-tested here -- see `kyverno-test/kyverno-test.yaml`'s header comment.
  - Cluster-scoped fixtures (ClusterRole, ClusterRoleBinding, RBACDefinition, EC2NodeClass,
    ClusterPolicy, ValidatingWebhookConfiguration, CustomResourceDefinition) carry a
    `metadata.namespace` they'd never really have -- a kyverno-test-CLI-only workaround for the same
    "default namespace gets excluded" issue kyverno-pod-policies' fixtures dodge by using the
    `workloads` namespace, which the CLI appears to apply even to cluster-scoped kinds internally.
    See the comment on the first such fixture in `kyverno-test/resources.yaml`.
- **[`scripts/kyverno-policy-check.sh`](../../../scripts/kyverno-policy-check.sh)** (`make
  kyverno-policy-check PACKAGE=<name>`) -- points this chart's ruleset (layered together with
  kyverno-pod-policies') at every *other* real chart in the repo. See that chart's README for the
  enforcement/no-allowlist philosophy, which this shares exactly.

## Exceptions

Same shape and mechanics as kyverno-pod-policies' `exceptions:` -- see that chart's README for the
full field reference, worked examples, and why selector-scoped exceptions are preferred over
widening `excludeNamespaces`. One difference: `match.kinds` defaults to the Pod-controller kind list
(`[Pod, Deployment, StatefulSet, DaemonSet, Job, CronJob, ReplicaSet]`), which is only correct for
this chart's Pod-kind policies -- override it explicitly for anything else, e.g.:

```yaml
exceptions:
  platform-team-cluster-admin-ish-role:
    policies: [disallow-wildcard-rbac]
    match:
      kinds: [ClusterRole]
      names: ["platform-team-admin"]
```

Rule names (including `autogen-`/`autogen-cronjob-` siblings) are still resolved automatically --
but only for ids whose registry entry has `autogen: true` (every Pod-kind id). Non-Pod-kind ids
(Category E/F/G, `require-labels`) never get autogen siblings appended, since Kyverno never
generates them in the first place.

### Prerequisite, and a namespace caveat

Same prerequisite as kyverno-pod-policies: `exceptions:` here renders nothing effective until
`features.policyExceptions.enabled: true` on the companion `packages/kyverno` chart, with
`.namespace` pointed at wherever a chart's `PolicyException`s should be honored from. As of
writing, that companion feature **isn't enabled at all yet** (blocked on an unrelated
charts-build-scripts/grafana-subchart tooling issue against `packages/kyverno` -- see
kyverno-pod-policies' README/git history) -- not something this chart's own work unblocks.

`policyExceptions.namespace` accepts exactly **one** namespace, not a list. If this chart and
kyverno-pod-policies are released into *different* namespaces, only one of their `PolicyException`
sets can ever be honored at a time once that feature does land. The smallest fix: release both
charts into the **same** namespace (e.g. both into `kyverno-pod-policies`) so a single
`policyExceptions.namespace` value covers both. Extending the companion chart to accept a list of
namespaces instead is a real alternative but a larger change -- not attempted here.

## Why CEL, why not `ValidatingPolicy`

Identical reasoning to kyverno-pod-policies -- see that chart's README section of the same name.
The companion `packages/kyverno` chart's `--generateValidatingAdmissionPolicy` flag means every
classic CEL `ClusterPolicy` rule here, including the non-Pod-kind ones, still auto-projects into a
native `ValidatingAdmissionPolicy` + report, without needing the newer CRDs.

## Quick start

```
helm install kyverno-cluster-policies oci://ghcr.io/therealgambo/k8s-charts/kyverno-cluster-policies \
  --namespace kyverno-cluster-policies --create-namespace
```

Every policy here is `Enforce` by default (see "Enforced by default, tiered" above) -- review the
config-independent ids most likely to surface real fleet violations immediately
(`disallow-wildcard-rbac`, `require-explicit-automount`; see each template's own comment) before or
right after install, and downgrade any of them to `Audit` per-cluster while triaging if needed. Then
populate `config.*` for the config-dependent policies (allow-lists like `allowedRegistries`,
required-key lists like `requiredResourceLabels`) and opt in whichever Category F policies apply to
your cluster, and set `features.policyExceptions` on the `kyverno` release (see above) if
`exceptions:` is used.

## Worked examples

<details>
<summary>Opt in to the CRD confused-deputy policies for a cluster running rbac-manager and argo-cd</summary>

```yaml
config:
  rbacDefinitionAllowedClusterRoles: [view, edit]
policies:
  restrict-rbacdefinition-clusterrole:
    enabled: true
  restrict-argocd-application-project:
    enabled: true
```

`restrict-kargo-promotion-scope`/`restrict-karpenter-nodeclass-profile` stay off -- this cluster
doesn't run kargo or karpenter.

</details>

<details>
<summary>Populate restrict-image-registries' allow-list (it's already Enforce by default)</summary>

`restrict-image-registries` is Enforce by default like every other policy here, but its
`celPreconditions` guard keeps it a no-op until `config.allowedRegistries` is populated -- no
`policies.<id>.validationFailureAction` override needed, just set the list:

```yaml
config:
  allowedRegistries:
    - ghcr.io/therealgambo/
```

Want to review matches before it starts blocking? Downgrade just this one policy:

```yaml
config:
  allowedRegistries:
    - ghcr.io/therealgambo/
policies:
  restrict-image-registries:
    validationFailureAction: Audit
```

</details>

<details>
<summary>A non-Pod-kind exception, full YAML in/out</summary>

```yaml
exceptions:
  platform-operator-wildcard-role:
    policies: [disallow-wildcard-rbac]
    match:
      kinds: [ClusterRole]
      names: ["platform-operator"]
```

Renders:

```yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: platform-operator-wildcard-role
  namespace: kyverno-cluster-policies
spec:
  exceptions:
    - policyName: disallow-wildcard-rbac
      ruleNames: [wildcard-verbs, wildcard-resources, wildcard-apigroups]
  match:
    any:
      - resources:
          kinds: [ClusterRole]
          names: ["platform-operator"]
```

Note the absence of any `autogen-*` rule names -- `disallow-wildcard-rbac` targets Role/ClusterRole,
which Kyverno never autogens.

</details>
