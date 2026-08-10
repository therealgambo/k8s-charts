{{/*
Chart name, trimmed the standard `helm create` way.
*/}}
{{- define "kyverno-pod-policies.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels stamped on every resource this chart renders.
*/}}
{{- define "kyverno-pod-policies.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" | quote }}
app.kubernetes.io/name: {{ include "kyverno-pod-policies.name" . | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
{{- end -}}

{{/*
Whether a given policy id should render at all: chart master switch AND that id's own `enabled`.
Params: dict "id" <policy id> "root" $
Returns the literal string "true" or "false" -- compare with `eq (include ...) "true"`.
*/}}
{{- define "kyverno-pod-policies.policyEnabled" -}}
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
Resolve the effective `validate.failureAction` for a policy id, in priority order:
  1. .Values.validationFailureAction (global override) if non-empty -- wins over everything.
  2. .Values.policies.<id>.validationFailureAction if non-empty.
  3. tierDefault, passed in by the calling template ("Enforce" for baseline, "Audit" for restricted).
Params: dict "id" <policy id> "tierDefault" "Enforce"|"Audit" "root" $
*/}}
{{- define "kyverno-pod-policies.failureAction" -}}
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
additions. Deduped and sorted so re-renders are diff-stable. Deliberately short by default -- see
README "Scoping exclusions" for why kube-system/kyverno aren't blanket-excluded here, and use
PolicyException + a label selector for those instead.
Params: dict "id" <policy id> "root" $
*/}}
{{- define "kyverno-pod-policies.excludeNamespaces" -}}
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
coverage) for this rule. Fine-grained, per-workload carve-outs belong in `exceptions:` /
PolicyException instead, which supports `selector` safely since it isn't autogen'd.
Params: dict "id" <policy id> "root" $
*/}}
{{- define "kyverno-pod-policies.exclude" -}}
{{- $root := .root -}}
{{- $cfg := index ($root.Values.policies | default dict) .id | default dict -}}
{{- $ns := include "kyverno-pod-policies.excludeNamespaces" (dict "id" .id "root" $root) | fromYamlArray -}}
{{- $resource := dict "namespaces" $ns -}}
{{- $kinds := dig "exclude" "kinds" list $cfg -}}
{{- if $kinds -}}
{{- $resource = set $resource "kinds" $kinds -}}
{{- end -}}
{{- toYaml (dict "any" (list (dict "resources" $resource))) -}}
{{- end -}}

{{/*
Static registry: policy id -> its ClusterPolicy's base rule name(s), NOT including the
"autogen-"/"autogen-cronjob-" copies Kyverno's autogen feature generates for Pod-controller kinds.
Kept here as one explicit source of truth since Helm can't introspect another template's rendered
`rules[].name` list. MUST be kept in sync with the `name:` used in each policy's own template file.
*/}}
{{- define "kyverno-pod-policies.policyRuleNames" -}}
disallow-privileged-containers: [privileged-containers]
disallow-host-namespaces: [host-namespaces]
disallow-host-path: [host-path]
disallow-host-ports: [host-ports-none]
disallow-capabilities: [adding-capabilities]
disallow-host-process: [host-process-containers]
disallow-proc-mount: [check-proc-mount]
disallow-selinux: [selinux-type, selinux-user-role]
restrict-seccomp: [check-seccomp]
restrict-sysctls: [check-sysctls]
disallow-capabilities-strict: [require-drop-all, adding-capabilities-strict]
disallow-privilege-escalation: [privilege-escalation]
require-run-as-nonroot: [run-as-non-root]
require-run-as-non-root-user: [run-as-non-root-user]
restrict-seccomp-strict: [check-seccomp-strict]
restrict-volume-types: [restricted-volumes]
{{- end -}}

{{/*
Expand one policy id into the `exceptions[]` entry PolicyException needs: policyName (== the id,
since every ClusterPolicy's metadata.name here equals its id) + every base rule name PLUS its
autogen siblings (autogen-<rule> for Deployment/StatefulSet/DaemonSet/ReplicaSet, plus
autogen-cronjob-<rule> for CronJob) -- Kyverno does NOT implicitly apply an exception written
against the base Pod rule name to the autogen-copied rules, see
https://kyverno.io/docs/guides/exceptions/.
Params: <policy id string>. Fails loudly if the id isn't in the registry (typo guard).
*/}}
{{- define "kyverno-pod-policies.exceptionEntry" -}}
{{- $id := . -}}
{{- $registry := include "kyverno-pod-policies.policyRuleNames" "" | fromYaml -}}
{{- $rules := index $registry $id -}}
{{- if not $rules -}}
{{- fail (printf "exceptions: unknown policy id %q (see policies: in values.yaml)" $id) -}}
{{- end -}}
{{- $allRuleNames := list -}}
{{- range $r := $rules -}}
{{- $allRuleNames = append $allRuleNames $r -}}
{{- $allRuleNames = append $allRuleNames (printf "autogen-%s" $r) -}}
{{- $allRuleNames = append $allRuleNames (printf "autogen-cronjob-%s" $r) -}}
{{- end -}}
{{- dict "policyName" $id "ruleNames" $allRuleNames | toYaml -}}
{{- end -}}
