{{/*
Chart name, trimmed the standard `helm create` way.
*/}}
{{- define "network-policies.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels stamped on every resource this chart renders.
*/}}
{{- define "network-policies.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" | quote }}
app.kubernetes.io/name: {{ include "network-policies.name" . | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
{{- end -}}

{{/*
Resolve a selector definition into a Cilium EndpointSelector (the `matchLabels`/`matchExpressions`
shape shared by every selector in this chart: the subject `labelSelector`, peer selectors in
ingress/egress rules, `cidrGroupSelector`, and `toServices`' `k8sServiceSelector`).

Handles:
  - `cluster: <name>` or `cluster: [<name>, ...]` -- Cluster Mesh convenience. Scopes the
    selector to identities from that remote cluster (or any one of several, OR'd together via a
    generated matchExpression when given as a list) using the reserved
    `k8s:io.cilium.k8s.policy.cluster` label. Leave unset to match the given labels in *any*
    connected cluster. For anything fancier (exclude a cluster, etc.), write a matchExpression
    against that same reserved key directly -- it's a normal label, nothing special is needed.
  - `namespace: <ns>` -- injects the reserved `k8s:io.kubernetes.pod.namespace` label when set.
    Peer pod selectors should go through `network-policies.endpointSelector` below instead, which
    always sets this (defaulting to the release namespace) rather than only when given explicitly.

Every selector is written out explicitly wherever it's used -- there's no shared/reusable selector
registry to look up, deliberately: it's clearer to read a rule's matchLabels right where they're
used than to chase an indirection.

Params: dict "sel" <selector definition, may be nil/empty> "root" $
Always renders a (possibly empty) EndpointSelector -- an empty selector is valid Cilium and
matches everything, which is sometimes exactly what's wanted (e.g. the default-deny policies).
*/}}
{{- define "network-policies.selector" -}}
{{- $sel := .sel | default dict -}}
{{- $matchLabels := dict -}}
{{- range $k, $v := ($sel.matchLabels | default dict) -}}
  {{- $matchLabels = set $matchLabels $k $v -}}
{{- end -}}
{{- if $sel.namespace -}}
  {{- $matchLabels = set $matchLabels "k8s:io.kubernetes.pod.namespace" $sel.namespace -}}
{{- end -}}
{{- $matchExpressions := $sel.matchExpressions | default list -}}
{{- if $sel.cluster -}}
  {{- if kindIs "slice" $sel.cluster -}}
    {{/* multiple clusters -> OR'd via a matchExpression; a bare matchLabels entry can only ever
         express a single exact value. */}}
    {{- $matchExpressions = append $matchExpressions (dict "key" "k8s:io.cilium.k8s.policy.cluster" "operator" "In" "values" $sel.cluster) -}}
  {{- else -}}
    {{- $matchLabels = set $matchLabels "k8s:io.cilium.k8s.policy.cluster" $sel.cluster -}}
  {{- end -}}
{{- end -}}
{{- $out := dict -}}
{{- if $matchLabels -}}{{- $out = set $out "matchLabels" $matchLabels -}}{{- end -}}
{{- if $matchExpressions -}}{{- $out = set $out "matchExpressions" $matchExpressions -}}{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{/*
Same as network-policies.selector, but for POD peer selectors specifically (fromEndpoints/
toEndpoints): always sets `namespace` (defaulting to the release namespace) before delegating, so
the reserved `k8s:io.kubernetes.pod.namespace` label is always present on the rendered selector --
even when the peer is implicitly local -- rather than relying on Cilium's implicit "bare
matchLabels are scoped to this policy's own namespace" behaviour. Do NOT use this for
fromNodes/toNodes (nodes aren't namespaced) or toServices' selector (it selects Services, whose
namespace is controlled by a separate explicit field, not this reserved pod label).
Params: dict "sel" <selector definition, may be nil/empty> "root" $
*/}}
{{- define "network-policies.endpointSelector" -}}
{{- $root := .root -}}
{{- $sel := .sel | default dict -}}
{{- $ns := $sel.namespace | default $root.Release.Namespace -}}
{{- $out := merge (dict) $sel -}}
{{- $out = set $out "namespace" $ns -}}
{{- include "network-policies.selector" (dict "sel" $out "root" $root) -}}
{{- end -}}

{{/*
Split a map of named entries into two maps by each entry's own `deny: true` flag, so a per-type
template can build its allow entries and deny entries separately (Cilium keeps allow/deny in
different spec fields, with different capabilities). Returns {allow: {...}, deny: {...}}.
Params: <map, may be nil>
*/}}
{{- define "network-policies.partitionByDeny" -}}
{{- $allow := dict -}}
{{- $deny := dict -}}
{{- range $name, $e := . -}}
  {{- $e = $e | default dict -}}
  {{- if $e.deny -}}{{- $deny = set $deny $name $e -}}{{- else -}}{{- $allow = set $allow $name $e -}}{{- end -}}
{{- end -}}
{{- toYaml (dict "allow" $allow "deny" $deny) -}}
{{- end -}}
