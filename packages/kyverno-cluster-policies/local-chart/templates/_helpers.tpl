{{/*
Chart name, trimmed the standard `helm create` way.
*/}}
{{- define "kyverno-cluster-policies.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels stamped on every resource this chart renders.
*/}}
{{- define "kyverno-cluster-policies.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" | quote }}
app.kubernetes.io/name: {{ include "kyverno-cluster-policies.name" . | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
{{- end -}}

{{/*
Whether a given policy id should render at all: chart master switch AND that id's own `enabled`.
For every policy EXCEPT the Category F (opt-in) ids, "not set" means "on" -- mirrors
kyverno-pod-policies. Category F ids use kyverno-cluster-policies.policyEnabledOptIn instead (see
below), NOT this helper -- opt-in policies must never default to on.
Params: dict "id" <policy id> "root" $
Returns the literal string "true" or "false" -- compare with `eq (include ...) "true"`.
*/}}
{{- define "kyverno-cluster-policies.policyEnabled" -}}
{{- $root := .root -}}
{{- $cfg := index ($root.Values.policies | default dict) .id | default dict -}}
{{- if eq $root.Values.enabled false -}}
false
{{- else if eq $cfg.enabled false -}}
false
{{- else -}}
true
{{- end -}}
{{- end -}}

{{/*
Whether a Category F (opt-in) policy id should render: chart master switch AND that id's own
`enabled` explicitly set to true. Deliberately the inverse default of
kyverno-cluster-policies.policyEnabled above -- "not set" means OFF here, since these policies
target CRDs from optional cluster components (rbac-manager, argo-cd, kargo, karpenter) that may not
even be installed, and need org-specific config/ lists populated before they mean anything.
Params: dict "id" <policy id> "root" $
Returns the literal string "true" or "false" -- compare with `eq (include ...) "true"`.
*/}}
{{- define "kyverno-cluster-policies.policyEnabledOptIn" -}}
{{- $root := .root -}}
{{- $cfg := index ($root.Values.policies | default dict) .id | default dict -}}
{{- if eq $root.Values.enabled false -}}
false
{{- else if eq $cfg.enabled true -}}
true
{{- else -}}
false
{{- end -}}
{{- end -}}

{{/*
Resolve the effective `validate.failureAction` for a policy id, in priority order:
  1. .Values.validationFailureAction (global override) if non-empty -- wins over everything.
  2. .Values.policies.<id>.validationFailureAction if non-empty.
  3. tierDefault, passed in by the calling template ("Enforce" for Enforce-tier, "Audit" for
     Audit-tier). Category F (opt-in) policies pass "Enforce" here too -- once explicitly opted
     in, they're not a passive audit-only control.
Params: dict "id" <policy id> "tierDefault" "Enforce"|"Audit" "root" $
*/}}
{{- define "kyverno-cluster-policies.failureAction" -}}
{{- $root := .root -}}
{{- $cfg := index ($root.Values.policies | default dict) .id | default dict -}}
{{- if $root.Values.validationFailureAction -}}
{{- $root.Values.validationFailureAction -}}
{{- else if $cfg.validationFailureAction -}}
{{- $cfg.validationFailureAction -}}
{{- else -}}
{{- .tierDefault -}}
{{- end -}}
{{- end -}}

{{/*
Namespace list for a policy's exclude.any[].resources.namespaces: chart-wide excludeNamespaces +
this release's own namespace (always, defensively) + that policy's own exclude.namespaces
additions. Deduped and sorted so re-renders are diff-stable. Meaningless (but harmless) for
cluster-scoped kinds -- there's no namespace field for the filter to match against.
Params: dict "id" <policy id> "root" $
*/}}
{{- define "kyverno-cluster-policies.excludeNamespaces" -}}
{{- $root := .root -}}
{{- $cfg := index ($root.Values.policies | default dict) .id | default dict -}}
{{- $extra := dig "exclude" "namespaces" list $cfg -}}
{{- $ns := concat ($root.Values.excludeNamespaces | default list) (list $root.Release.Namespace) $extra -}}
{{- toYaml ($ns | uniq | sortAlpha) -}}
{{- end -}}

{{/*
Full `exclude` block for a policy's rule, ready to `{{ include ... | nindent N }}`. Only
`namespaces`/`kinds` are ever used here -- never `names`/`selector`/`annotations`, which would
silently disable Kyverno's autogen (Deployment/StatefulSet/DaemonSet/Job/CronJob/ReplicaSet
coverage) for a Pod-kind rule. Fine-grained, per-workload carve-outs belong in `exceptions:` /
PolicyException instead, which supports `selector` safely since it isn't autogen'd.
Params: dict "id" <policy id> "root" $
*/}}
{{- define "kyverno-cluster-policies.exclude" -}}
{{- $root := .root -}}
{{- $cfg := index ($root.Values.policies | default dict) .id | default dict -}}
{{- $ns := include "kyverno-cluster-policies.excludeNamespaces" (dict "id" .id "root" $root) | fromYamlArray -}}
{{- $resource := dict "namespaces" $ns -}}
{{- $kinds := dig "exclude" "kinds" list $cfg -}}
{{- if $kinds -}}
{{- $resource = set $resource "kinds" $kinds -}}
{{- end -}}
{{- toYaml (dict "any" (list (dict "resources" $resource))) -}}
{{- end -}}

{{/*
Curated kind list for the "blanket" resource-level label/annotation policies
(require-resource-labels, require-resource-annotations): every kind a Helm chart in this fleet
typically renders, deliberately NOT `kind: "*"` -- a true wildcard would also catch Kubernetes-
internal/system-managed objects (Lease, Endpoints, EndpointSlice, Event, ControllerRevision,
CSIStorageCapacity, ...) that carry no custom labels by convention and were never meant to be
governed by org label/annotation policy; enforcing there risks blocking things like leader-election
Leases, not just chart manifests. Namespace is deliberately excluded too -- already covered by
require-labels' own config.requiredNamespaceLabels, which is intentionally a separate config key
(namespaces and workload manifests may need different required keys). Kept as one shared helper so
the two policies can never drift apart on scope.
*/}}
{{- define "kyverno-cluster-policies.blanketResourceKinds" -}}
[Deployment, StatefulSet, DaemonSet, ReplicaSet, Job, CronJob, Pod, Service, ConfigMap, Secret, Ingress, ServiceAccount, PersistentVolumeClaim, Role, RoleBinding, ClusterRole, ClusterRoleBinding, NetworkPolicy]
{{- end -}}

{{/*
Static registry: policy id -> { autogen: bool, rules: [base rule name(s)] }, NOT including the
"autogen-"/"autogen-cronjob-" copies Kyverno's autogen feature generates for Pod-controller kinds --
those are only relevant when autogen: true (i.e. the policy's `match` is `kind: Pod`). Kept here as
one explicit source of truth since Helm can't introspect another template's rendered `rules[].name`
list, nor its `match.any[].resources.kinds`. MUST be kept in sync with the `name:`/`kinds:` used in
each policy's own template file -- unlike kyverno-pod-policies' equivalent registry, `autogen` is
NOT always true here, since several ids target Role/ClusterRole/RoleBinding/ClusterRoleBinding/
CustomResourceDefinition/webhook-config/operator-CRD kinds that Kyverno never autogens.
*/}}
{{- define "kyverno-cluster-policies.policyRuleNames" -}}
require-labels: {autogen: false, rules: [check-required-labels]}
require-resource-labels: {autogen: false, rules: [check-required-resource-labels]}
require-resource-annotations: {autogen: false, rules: [check-required-resource-annotations]}
disallow-reserved-annotation-prefixes: {autogen: true, rules: [reserved-annotation-prefix]}
disallow-latest-tag: {autogen: true, rules: [require-and-validate-image-tag]}
restrict-image-registries: {autogen: true, rules: [validate-registries]}
restrict-dns-policy: {autogen: true, rules: [restrict-dns-policy]}
disallow-custom-dns-config: {autogen: true, rules: [disallow-custom-nameservers]}
disallow-host-aliases: {autogen: true, rules: [disallow-host-aliases]}
require-emptydir-sizelimit: {autogen: true, rules: [require-emptydir-sizelimit]}
restrict-priorityclass: {autogen: true, rules: [restrict-priorityclass]}
require-resource-requests-limits: {autogen: true, rules: [validate-resources]}
disallow-rbac-escalation-verbs: {autogen: false, rules: [escalate]}
disallow-wildcard-rbac: {autogen: false, rules: [wildcard-verbs, wildcard-resources, wildcard-apigroups]}
disallow-clusteradmin-binding: {autogen: false, rules: [clusteradmin-default-sa-binding]}
require-explicit-automount: {autogen: true, rules: [require-explicit-automount]}
protect-kyverno-resources: {autogen: false, rules: [restrict-changes]}
disallow-webhook-tampering: {autogen: false, rules: [restrict-changes]}
restrict-rbacdefinition-clusterrole: {autogen: false, rules: [restrict-clusterrole]}
restrict-argocd-application-project: {autogen: false, rules: [require-scoped-project]}
restrict-kargo-promotion-scope: {autogen: false, rules: [restrict-promotion-target]}
restrict-karpenter-nodeclass-profile: {autogen: false, rules: [restrict-instance-profile]}
restrict-crd-creation: {autogen: false, rules: [restrict-creation]}
{{- end -}}

{{/*
Expand one policy id into the `exceptions[]` entry PolicyException needs: policyName (== the id,
since every ClusterPolicy's metadata.name here equals its id) + every base rule name, PLUS its
autogen siblings (autogen-<rule> for Deployment/StatefulSet/DaemonSet/ReplicaSet, plus
autogen-cronjob-<rule> for CronJob) only when that id's registry entry has autogen: true. Kyverno
does NOT implicitly apply an exception written against the base Pod rule name to the autogen-copied
rules, see https://kyverno.io/docs/guides/exceptions/.
Params: <policy id string>. Fails loudly if the id isn't in the registry (typo guard).
*/}}
{{- define "kyverno-cluster-policies.exceptionEntry" -}}
{{- $id := . -}}
{{- $registry := include "kyverno-cluster-policies.policyRuleNames" "" | fromYaml -}}
{{- $entry := index $registry $id -}}
{{- if not $entry -}}
{{- fail (printf "exceptions: unknown policy id %q (see policies: in values.yaml)" $id) -}}
{{- end -}}
{{- $allRuleNames := list -}}
{{- range $r := $entry.rules -}}
{{- $allRuleNames = append $allRuleNames $r -}}
{{- if $entry.autogen -}}
{{- $allRuleNames = append $allRuleNames (printf "autogen-%s" $r) -}}
{{- $allRuleNames = append $allRuleNames (printf "autogen-cronjob-%s" $r) -}}
{{- end -}}
{{- end -}}
{{- dict "policyName" $id "ruleNames" $allRuleNames | toYaml -}}
{{- end -}}
