# kyverno-pod-policies

A cluster-wide Helm chart of CEL-based [Kyverno](https://kyverno.io) `ClusterPolicy` resources
enforcing the [Kubernetes Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/),
plus centrally-managed `PolicyException` carve-outs. This chart is a **singleton**: install it
once, cluster-wide -- it's not a dependency of other charts, unlike [network-policies](../../network-policies),
which every workload chart depends on individually.

It assumes the companion [`packages/kyverno`](../../kyverno) chart (the policy engine itself) is
already installed. Every rule here is written in CEL, matching only `kind: Pod` and relying on
Kyverno's [autogen](https://kyverno.io/docs/policy-types/cluster-policy/autogen/) feature to also
cover Deployment/StatefulSet/DaemonSet/ReplicaSet/Job/CronJob pod templates automatically.

## Enforced by default, tiered

Installing this chart with no configuration enforces every **baseline**-tier control immediately
(`validationFailureAction: Enforce` -- non-compliant pods are rejected on admission) and reports
on every **restricted**-tier control without blocking (`Audit` -- visible in `PolicyReport`, but
nothing is rejected). This mirrors the Kubernetes Pod Security Standards' own baseline/restricted
split: baseline controls are things a workload almost never legitimately needs (privileged mode,
host namespaces, hostPath, ...), so blocking them by default is safe; restricted controls
(`runAsNonRoot`, dropping all capabilities, ...) are real hardening that plenty of existing
workloads haven't adopted yet, so they start as visibility-only.

Three ways to change the enforcement posture, in precedence order (highest wins):

1. **Global override** -- `validationFailureAction: Audit` (or `Enforce`) forces *every* policy to
   that action, ignoring tier defaults and any per-policy setting. Useful for "audit everything
   fleet-wide during rollout, flip to enforce once `PolicyReport`s are clean."
2. **Per-policy override** -- `policies.<id>.validationFailureAction: Enforce` promotes one
   restricted-tier control (or demotes one baseline-tier control) without touching the rest.
3. **Tier default** -- `Enforce` for baseline, `Audit` for restricted, if nothing above overrides it.

## The policies

Every id below is both its `templates/<id>.yaml` file name and its `ClusterPolicy`'s
`metadata.name`. Full CEL is in each file; this is what each one blocks.

**Baseline (default `Enforce`)**

| id | rule name(s) | Blocks |
|---|---|---|
| `disallow-privileged-containers` | `privileged-containers` | Any container running with `privileged: true` |
| `disallow-host-namespaces` | `host-namespaces` | `hostNetwork`/`hostIPC`/`hostPID: true` |
| `disallow-host-path` | `host-path` | Any `hostPath` volume |
| `disallow-host-ports` | `host-ports-none` | Any non-zero `containerPort.hostPort` |
| `disallow-capabilities` | `adding-capabilities` | Adding capabilities beyond the default baseline allow-list |
| `disallow-host-process` | `host-process-containers` | Windows `securityContext.windowsOptions.hostProcess: true` (no-op on Linux nodes) |
| `disallow-proc-mount` | `check-proc-mount` | Any `procMount` other than `Default` |
| `disallow-selinux` | `selinux-type`, `selinux-user-role` | SELinux `type` outside an allow-list; setting SELinux `user`/`role` at all |
| `restrict-seccomp` | `check-seccomp` | `seccompProfile.type: Unconfined` |
| `restrict-sysctls` | `check-sysctls` | Any sysctl outside a known-safe subset |

**Restricted (default `Audit`)**

| id | rule name(s) | Blocks |
|---|---|---|
| `disallow-capabilities-strict` | `require-drop-all`, `adding-capabilities-strict` | Not dropping `ALL` capabilities; adding anything but `NET_BIND_SERVICE` |
| `disallow-privilege-escalation` | `privilege-escalation` | `allowPrivilegeEscalation` not explicitly `false` |
| `require-run-as-nonroot` | `run-as-non-root` | Root not excluded via `runAsNonRoot` at pod level or on every container |
| `require-run-as-non-root-user` | `run-as-non-root-user` | Explicit `runAsUser: 0` at pod or container level |
| `restrict-seccomp-strict` | `check-seccomp-strict` | Effective `seccompProfile.type` unset, or not `RuntimeDefault`/`Localhost` |
| `restrict-volume-types` | `restricted-volumes` | Any volume type outside the PSS-restricted allow-list |

**Deliberately not shipped** (documented gaps, not silent omissions):

- `disallow-host-ports-range` -- upstream Kyverno frames this as an *alternate* to
  `disallow-host-ports`, not an addition (allow a fixed port range instead of blocking hostPorts
  outright). Shipping both would double-enforce/conflict; copy `disallow-host-ports.yaml` and
  adjust the CEL if a fixed range is needed instead of zero.
- An AppArmor control -- Kubernetes' PSS baseline includes one, but Kyverno's own `pod-security-cel`
  library has no CEL version of it yet (only the older, pattern-based `restrict-apparmor-profiles`).
  Not hand-rolling one against an API Kyverno hasn't stabilized in CEL.

## How autogen works here

Every policy's `match` is `{resources: {kinds: [Pod], operations: [CREATE, UPDATE]}}` -- nothing
else. Kyverno's autogen feature (on by default, no flag needed) then generates equivalent rules
for Deployment/StatefulSet/DaemonSet/ReplicaSet/Job/CronJob automatically, rewriting the CEL's
`object.spec...` path to reach through each controller's pod template. **Never** add `names`,
`selector`, or `annotations` to a policy's `match`/`exclude` block -- any of those silently
disables autogen for that rule, so the policy would only ever apply to bare Pods, not the
controllers that actually create them in practice.

## Testing & validation

Two different, complementary layers of test coverage, for two different questions:

- **`tests/*_test.yaml`** ([helm-unittest](https://github.com/helm-unittest/helm-unittest), via
  `make unittest PACKAGE=kyverno-pod-policies`) -- "does the *templating* behave as intended?" e.g.
  does `policies.<id>.enabled: false` actually skip that resource, does the global
  `validationFailureAction` override actually win over a per-policy one, does `excludeNamespaces`
  actually land in the rendered `exclude` block. It has no idea what the CEL inside a rule
  evaluates to -- a `validate.cel.expressions` typo that's still syntactically valid YAML would
  pass every one of these tests.
- **`kyverno-test/`** ([Kyverno CLI test](https://kyverno.io/docs/guides/testing-policies/), via
  `make kyverno-test PACKAGE=kyverno-pod-policies`) -- "does the *rule logic* itself behave as
  intended?" Renders the chart, then feeds the result to `kyverno test` against
  `kyverno-test/resources.yaml` (a known-good/known-bad Pod fixture pair per rule) with the
  expected pass/fail outcome for each declared in `kyverno-test/kyverno-test.yaml`. This is what
  actually proves e.g. `disallow-privileged-containers`' CEL rejects `privileged: true` and
  accepts a Pod without it -- helm-unittest structurally can't tell those two cases apart.

`make kyverno-test` requires the `kyverno` CLI (`./scripts/pull-kyverno.sh`, version pinned in
[scripts/version](../../../scripts/version) to match `packages/kyverno`'s `appVersion`) and renders
the chart fresh into `kyverno-test/policies.rendered.yaml` each run (gitignored -- never committed,
so it can't drift from the live templates). Every fixture in `kyverno-test/resources.yaml`
deliberately lives in a `workloads` namespace, not `default` -- see the comment at the top of
`kyverno-test/kyverno-test.yaml` for why (short version: it would otherwise get silently caught by
every policy's own `exclude` block, which always excludes the release namespace `helm template`
defaults to). Both suites run in CI via `.github/workflows/validate-charts.yaml`'s
`helm-unittest`/`kyverno-test` jobs.

## Exceptions

```yaml
exceptions:
  <name>:
    enabled: true
    policies: []            # required -- policy ids this exempts (see table above). Rule names,
                             # including the autogen-/autogen-cronjob- variants, are resolved
                             # automatically -- don't hand-write Kyverno rule names.
    match:
      kinds: []              # default [Pod, Deployment, StatefulSet, DaemonSet, Job, CronJob, ReplicaSet]
      namespaces: []
      names: []              # wildcards ('*', '?') allowed, per Kyverno
      selector:               # matchLabels/matchExpressions
        matchLabels: {}
        matchExpressions: []
    conditions: {}           # optional passthrough -> spec.conditions (JMESPath any/all)
    labels: {}
    annotations: {}
```

Each entry renders one `kyverno.io/v2 PolicyException` in this release's own namespace.

### Scoping exclusions: selector, not whole-namespace

A namespace rarely has exactly one workload in it forever -- `kube-system` in particular mixes
node-level DaemonSets (CNI, kube-proxy, CSI node plugins) that legitimately need
baseline-violating settings with anything else that happens to land there later. That's why
`excludeNamespaces` (the chart-wide namespace-exclude list) deliberately only contains
`kube-node-lease`/`kube-public` -- namespaces that never run arbitrary workloads. Putting
`kube-system` there instead would exempt *everything* in it, not just the DaemonSets that need it.

The scalable fix is to exempt by **label selector** via `exceptions:`, not by widening
`excludeNamespaces`. `PolicyException.spec.match.any[].resources.selector` is evaluated directly
by Kyverno at admission time -- unlike a `ClusterPolicy`'s own `match`/`exclude`, it is **not**
autogen'd, so using `selector` here doesn't hit the "selector disables autogen" restriction
described above. Most node-level system DaemonSets already carry a stable identifying label
(`k8s-app: kube-proxy`, `app.kubernetes.io/name: cilium`, ...), so one entry scoped to that
namespace *and* that label covers exactly those workloads, and scales by adding a label value to
an existing entry rather than hand-listing Pod names or excluding the whole namespace:

```yaml
exceptions:
  kube-system-node-agents:
    policies: [disallow-host-namespaces, disallow-host-path, disallow-privileged-containers, disallow-host-ports]
    match:
      namespaces: [kube-system]
      selector:
        matchExpressions:
          - key: k8s-app
            operator: In
            values: [kube-proxy]   # add more node-agent labels here as needed, one list, one PR

  kyverno-controller:
    policies: [disallow-host-path, restrict-seccomp]   # whatever the kyverno chart's pods actually need
    match:
      namespaces: [kyverno]
      selector:
        matchLabels:
          app.kubernetes.io/instance: kyverno
```

Neither entry ships by default -- the exact node-agent labels (CNI choice, whether kube-proxy even
runs vs. a CNI's kube-proxy-replacement mode, ...) are cluster-specific, so guessing them into a
default would either be wrong or silently too broad. Populate `exceptions:` for what your own
`kube-system`/`kyverno` namespaces actually run, reviewed like any other values change.

### Prerequisite: enable exceptions on the `kyverno` chart

`exceptions:` here renders nothing effective until the companion `packages/kyverno` chart allows
it -- Kyverno only honors `PolicyException` objects from an allow-listed namespace, and that
feature is **off** by default:

```yaml
# packages/kyverno/charts/base.values.yaml
features:
  policyExceptions:
    enabled: true
    namespace: kyverno-pod-policies   # wherever THIS chart is released -- a single namespace, not a list
```

Point `namespace` at exactly this chart's release namespace, not `"*"` -- `"*"` would let a
`PolicyException` from *any* namespace apply, undermining "closed by default" the same way a
blanket `excludeNamespaces` entry would.

## Why CEL, why not `ValidatingPolicy`

Kyverno also ships newer, still-alpha `policies.kyverno.io` CRDs (`ValidatingPolicy`, etc.) that
are pure CEL and map 1:1 onto a native `ValidatingAdmissionPolicy`. This chart uses the classic
`kyverno.io/v1 ClusterPolicy` CEL rules instead: the companion `packages/kyverno` chart already
runs its admission controller with `--generateValidatingAdmissionPolicy` and
`--validatingAdmissionPolicyReports` enabled, so a classic CEL `ClusterPolicy` rule gets
auto-projected into a native `ValidatingAdmissionPolicy` (apiserver-side enforcement) *and* a
`ValidatingAdmissionPolicyReport` on top of Kyverno's own webhook path and `PolicyReport` --
without needing the newer, less battle-tested CRDs at all.

## `background: true` and PolicyReport

Every policy sets `spec.background: true` (no per-policy override). Kyverno's background
controller continuously re-scans **existing** resources against every policy, independent of
admission events, and records the result as `PolicyReport`/`ClusterPolicyReport` entries --
including for `Audit`-mode restricted-tier controls, which never block anything. This is what
surfaces already-misconfigured workloads (the "highlight workloads that may be misconfigured"
requirement) rather than only catching new ones at admission time.

## Quick start

```
helm install kyverno-pod-policies oci://ghcr.io/therealgambo/k8s-charts/kyverno-pod-policies \
  --namespace kyverno-pod-policies --create-namespace
```

Then set `features.policyExceptions` on the `kyverno` release (see above) if `exceptions:` is used.

## Worked examples

<details>
<summary>Roll out audit-only fleet-wide first, then flip to tiered enforcement</summary>

```yaml
# base.values.yaml -- initial rollout: nothing blocks yet, only reports
validationFailureAction: Audit
```

```yaml
# base.values.yaml -- once PolicyReports are clean, remove the override and let each policy use
# its own tier default (Enforce for baseline, Audit for restricted)
validationFailureAction: ""
```

</details>

<details>
<summary>Promote one restricted-tier control to Enforce ahead of the rest</summary>

```yaml
policies:
  disallow-privilege-escalation:
    validationFailureAction: Enforce
```

</details>

<details>
<summary>A policy plus a matching exception, full YAML in/out</summary>

```yaml
exceptions:
  metrics-agent-hostnetwork:
    policies: [disallow-host-namespaces]
    match:
      namespaces: [monitoring]
      selector:
        matchLabels:
          app.kubernetes.io/name: node-exporter
```

Renders:

```yaml
apiVersion: kyverno.io/v2
kind: PolicyException
metadata:
  name: metrics-agent-hostnetwork
  namespace: kyverno-pod-policies
spec:
  exceptions:
    - policyName: disallow-host-namespaces
      ruleNames: [host-namespaces, autogen-host-namespaces, autogen-cronjob-host-namespaces]
  match:
    any:
      - resources:
          kinds: [Pod, Deployment, StatefulSet, DaemonSet, Job, CronJob, ReplicaSet]
          namespaces: [monitoring]
          selector:
            matchLabels:
              app.kubernetes.io/name: node-exporter
```

</details>
