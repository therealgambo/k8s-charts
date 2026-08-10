{{/*
Assemble and print one CiliumNetworkPolicy from an already-built subject selector plus allow/deny
entry lists. Every ingress-*.yaml/egress-*.yaml template funnels through this so naming, labels,
annotations and the "at least one direction populated" check live in exactly one place.

Params: dict
  "root"         $
  "fileBase"     the rendering template's own file name, e.g. "ingress-entity" (see
                 network-policies.fileBase below) -- becomes the resource name prefix, and
                 combined with "key" the whole resource name.
  "key"          the workload's rule key from values (e.g. "webapp" from `rules.webapp`).
  "cfg"          the rules.<key> value as a whole: {labelSelector, labelSelectorExpressions,
                 labels, annotations, description, ingress: {...}, egress: {...}}. Every resource
                 generated for a given workload (one per populated type) shares this same subject
                 selector/labels/annotations/description.
  "direction"    "ingress" | "egress"
  "allowEntries" list of already-built entries for spec.<direction> (may be empty)
  "denyEntries"  list of already-built entries for spec.<direction>Deny (may be empty)

Subject selector inference: if neither labelSelector nor labelSelectorExpressions is set, the key
itself is used as `app.kubernetes.io/name` -- so a key that already matches the app's name doesn't
need to repeat it. Setting either field opts out of inference entirely and takes full manual
control (no merging of the inferred label into what's given).
*/}}
{{- define "network-policies.emitResource" -}}
{{- $root := .root -}}
{{- $cfg := .cfg | default dict -}}
{{- $direction := .direction -}}
{{- $spec := dict -}}
{{- $hasExplicitSelector := or $cfg.labelSelector $cfg.labelSelectorExpressions -}}
{{- $matchLabels := $cfg.labelSelector -}}
{{- if and (not $hasExplicitSelector) .key -}}
  {{- $matchLabels = dict "app.kubernetes.io/name" .key -}}
{{- end -}}
{{- $selDef := dict "matchLabels" $matchLabels "matchExpressions" $cfg.labelSelectorExpressions -}}
{{- $spec = set $spec "endpointSelector" (include "network-policies.selector" (dict "sel" $selDef "root" $root) | fromYaml) -}}
{{- if .allowEntries -}}{{- $spec = set $spec $direction .allowEntries -}}{{- end -}}
{{- if .denyEntries -}}{{- $spec = set $spec (printf "%sDeny" $direction) .denyEntries -}}{{- end -}}
{{- if not (or (hasKey $spec $direction) (hasKey $spec (printf "%sDeny" $direction))) -}}
  {{- $label := .fileBase -}}
  {{- if .key -}}{{- $label = printf "%s.%s" .fileBase .key -}}{{- end -}}
  {{- fail (printf "network-policies: %s has no entries defined -- add at least one, or remove the key" $label) -}}
{{- end -}}
{{- if $cfg.description -}}{{- $spec = set $spec "description" $cfg.description -}}{{- end -}}
{{- $labels := mergeOverwrite (dict) (include "network-policies.labels" $root | fromYaml) ($root.Values.commonLabels | default dict) ($cfg.labels | default dict) -}}
{{- $annotations := mergeOverwrite (dict) ($root.Values.commonAnnotations | default dict) ($cfg.annotations | default dict) -}}
{{- $name := .fileBase -}}
{{- if .key -}}{{- $name = printf "%s-%s" .fileBase .key -}}{{- end -}}
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: {{ $name | lower | trunc 253 | trimSuffix "-" }}
  namespace: {{ $root.Release.Namespace }}
  labels: {{- toYaml $labels | nindent 4 }}
{{- with $annotations }}
  annotations: {{- toYaml . | nindent 4 }}
{{- end }}
spec: {{- toYaml $spec | nindent 2 }}
{{ end -}}

{{/*
The current template's own file name, minus the .yaml extension -- e.g. a template invoked as
".../templates/ingress-entity.yaml" returns "ingress-entity". Every resource name is dynamically
tied to the file that rendered it this way, rather than a hand-copied string that could drift if
the file is ever renamed.
Params: $ (the template's own root context, for .Template.Name)
*/}}
{{- define "network-policies.fileBase" -}}
{{- base .Template.Name | trimSuffix ".yaml" -}}
{{- end -}}

{{/*
The two blanket, namespace-wide "block everything" policies (see ingress-default-deny.yaml /
egress-default-deny.yaml): an empty endpointSelector (every pod in the namespace) with an
explicitly empty spec.ingress/egress. In Cilium, the field merely being *present* -- even as an
empty list -- is what triggers default-deny for that direction once no other rule allows
something back in.
Params: dict "root" $ "fileBase" "ingress-default-deny" "direction" "ingress"|"egress"
*/}}
{{- define "network-policies.emitDefaultDeny" -}}
{{- $root := .root -}}
{{- $spec := dict "endpointSelector" dict -}}
{{- $spec = set $spec .direction (list) -}}
{{- $labels := mergeOverwrite (dict) (include "network-policies.labels" $root | fromYaml) ($root.Values.commonLabels | default dict) -}}
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: {{ .fileBase }}
  namespace: {{ $root.Release.Namespace }}
  labels: {{- toYaml $labels | nindent 4 }}
spec: {{- toYaml $spec | nindent 2 }}
{{ end -}}
