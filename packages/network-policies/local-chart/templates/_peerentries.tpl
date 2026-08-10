{{/*
Every builder below turns ONE named map (entities, cidr, endpoints, ...) into a list of
independent Cilium ingress/egress rule *entries* -- one entry per map key, each carrying only its
own selector plus its own toPorts/icmps/authentication. Cilium ORs entries within a list together,
so this is equivalent to (and more flexible than) folding every peer into one big entry: each
named peer can allow a different set of ports.

Callers partition each map by its entries' own `deny: true` flag first and call the relevant
builder once per mode ("allow"/"deny"), since Cilium's deny rules only support plain port/protocol
matching (no L7/TLS/listener/authentication).
*/}}

{{/*
fromEndpoints / toEndpoints / fromNodes / toNodes -- all four share the same
{matchLabels/matchExpressions/cluster, toPorts, icmps, authentication} shape. Pass "namespaced"
true for fromEndpoints/toEndpoints (pods -- always stamps the reserved namespace label, see
network-policies.endpointSelector) and false for fromNodes/toNodes (nodes aren't namespaced).
Params: dict "entries" <map> "field" "fromEndpoints"|"toEndpoints"|"fromNodes"|"toNodes"
             "mode" "allow"|"deny" "namespaced" bool "root" $
*/}}
{{- define "network-policies.selectorEntries" -}}
{{- $field := .field -}}
{{- $mode := .mode -}}
{{- $root := .root -}}
{{- $selTemplate := "network-policies.selector" -}}
{{- if .namespaced -}}{{- $selTemplate = "network-policies.endpointSelector" -}}{{- end -}}
{{- $list := list -}}
{{- range $name, $e := .entries -}}
  {{- $e = $e | default dict -}}
  {{- $sel := include $selTemplate (dict "sel" $e "root" $root) | fromYaml -}}
  {{- $item := dict $field (list $sel) -}}
  {{- if $e.toPorts -}}{{- $item = set $item "toPorts" (include "network-policies.toPorts" (dict "ports" $e.toPorts "mode" $mode) | fromYamlArray) -}}{{- end -}}
  {{- if $e.icmps -}}{{- $item = set $item "icmps" (include "network-policies.icmpRule" $e.icmps | fromYamlArray) -}}{{- end -}}
  {{- if eq $mode "allow" -}}
    {{- $auth := $e.authentication | default dict -}}
    {{- if $auth.mode -}}{{- $item = set $item "authentication" (dict "mode" $auth.mode) -}}{{- end -}}
  {{- end -}}
  {{- $list = append $list $item -}}
{{- end -}}
{{- toYaml $list -}}
{{- end -}}

{{/*
fromEntities / toEntities. The map key IS the Cilium entity name (world, cluster, cluster-mesh,
host, remote-node, kube-apiserver, ingress, init, health, unmanaged, none, all, world-ipv4,
world-ipv6).
Params: dict "entries" <map> "field" "fromEntities"|"toEntities" "mode" "allow"|"deny"
*/}}
{{- define "network-policies.entityEntries" -}}
{{- $field := .field -}}
{{- $mode := .mode -}}
{{- $list := list -}}
{{- range $entity, $e := .entries -}}
  {{- $e = $e | default dict -}}
  {{- $item := dict $field (list $entity) -}}
  {{- if $e.toPorts -}}{{- $item = set $item "toPorts" (include "network-policies.toPorts" (dict "ports" $e.toPorts "mode" $mode) | fromYamlArray) -}}{{- end -}}
  {{- if $e.icmps -}}{{- $item = set $item "icmps" (include "network-policies.icmpRule" $e.icmps | fromYamlArray) -}}{{- end -}}
  {{- if eq $mode "allow" -}}
    {{- $auth := $e.authentication | default dict -}}
    {{- if $auth.mode -}}{{- $item = set $item "authentication" (dict "mode" $auth.mode) -}}{{- end -}}
  {{- end -}}
  {{- $list = append $list $item -}}
{{- end -}}
{{- toYaml $list -}}
{{- end -}}

{{/*
fromCIDR / toCIDR (unified with the old *CIDRSet) -- named CIDR blocks, each optionally with
`except` sub-ranges and its own toPorts/icmps/authentication. Omitting `toPorts` allows/denies
every port from that CIDR; give it to restrict to specific ports, folding what used to be the
separate ports-less "fromCIDR" shortcut into the same map.
Params: dict "entries" <map> "field" "fromCIDR"|"toCIDR" "mode" "allow"|"deny" "root" $
*/}}
{{- define "network-policies.cidrEntries" -}}
{{- $field := .field -}}
{{- $mode := .mode -}}
{{- $root := .root -}}
{{- $list := list -}}
{{- range $name, $c := .entries -}}
  {{- $c = $c | default dict -}}
  {{- if not (or $c.cidr $c.cidrGroupRef $c.cidrGroupSelector) -}}
    {{- fail (printf "network-policies: %s.%s needs one of `cidr`, `cidrGroupRef` or `cidrGroupSelector`" $field $name) -}}
  {{- end -}}
  {{- $rule := dict -}}
  {{- if $c.cidr -}}{{- $rule = set $rule "cidr" $c.cidr -}}{{- end -}}
  {{- if $c.cidrGroupRef -}}{{- $rule = set $rule "cidrGroupRef" $c.cidrGroupRef -}}{{- end -}}
  {{- if $c.cidrGroupSelector -}}
    {{- $rule = set $rule "cidrGroupSelector" (include "network-policies.selector" (dict "sel" $c.cidrGroupSelector "root" $root) | fromYaml) -}}
  {{- end -}}
  {{- if $c.except -}}{{- $rule = set $rule "except" $c.except -}}{{- end -}}
  {{- $item := dict $field (list $rule) -}}
  {{- if $c.toPorts -}}{{- $item = set $item "toPorts" (include "network-policies.toPorts" (dict "ports" $c.toPorts "mode" $mode) | fromYamlArray) -}}{{- end -}}
  {{- if $c.icmps -}}{{- $item = set $item "icmps" (include "network-policies.icmpRule" $c.icmps | fromYamlArray) -}}{{- end -}}
  {{- if eq $mode "allow" -}}
    {{- $auth := $c.authentication | default dict -}}
    {{- if $auth.mode -}}{{- $item = set $item "authentication" (dict "mode" $auth.mode) -}}{{- end -}}
  {{- end -}}
  {{- $list = append $list $item -}}
{{- end -}}
{{- toYaml $list -}}
{{- end -}}

{{/*
toFQDNs -- egress-only, allow-only (Cilium's EgressDenyRule has no ToFQDNs field at all, so
`deny: true` is rejected by the caller before this is ever reached). A toFQDNs entry may not share
a rule with any other To* selector, which is automatically satisfied here since every named entry
renders as its own isolated rule.

SNI enforcement defaults ON: DNS resolution alone doesn't prove the traffic is actually going to
the named host (the resolved IP could later change, or be shared), so every TCP toPorts entry that
doesn't already set its own `serverNames` gets one derived from the FQDN, using Cilium's passive
SNI check (no TLS termination or L7 rules required for this alone -- see
`network-policies.toPorts`'s handling of `serverNames`). Set `sni: false` on an entry for hosts
that don't terminate TLS at all (e.g. plain SSH/SFTP), where there's no SNI to check. Only a
literal `matchName` or a leading-wildcard `matchPattern` (`*.example.com`, matching Cilium's own
FQDN wildcard convention) can be turned into a serverNames value automatically; anything else
needs an explicit `sniServerNames` override. Ports already carrying their own L7 `rules` are left
alone unless `terminatingTLS` is also set, since Cilium rejects serverNames + L7 rules without TLS
termination.
Params: dict "entries" <map> "mode" "allow"
*/}}
{{- define "network-policies.fqdnEntries" -}}
{{- $mode := .mode -}}
{{- $list := list -}}
{{- range $name, $f := .entries -}}
  {{- $f = $f | default dict -}}
  {{- if not (or $f.matchName $f.matchPattern) -}}
    {{- fail (printf "network-policies: toFQDNs.%s needs `matchName` or `matchPattern`" $name) -}}
  {{- end -}}
  {{- $sel := dict -}}
  {{- if $f.matchName -}}{{- $sel = set $sel "matchName" $f.matchName -}}{{- end -}}
  {{- if $f.matchPattern -}}{{- $sel = set $sel "matchPattern" $f.matchPattern -}}{{- end -}}
  {{- $item := dict "toFQDNs" (list $sel) -}}

  {{- $sniEnabled := true -}}
  {{- if hasKey $f "sni" -}}{{- $sniEnabled = $f.sni -}}{{- end -}}
  {{- $sniValues := $f.sniServerNames -}}
  {{- if not $sniValues -}}
    {{- if $f.matchName -}}
      {{- $sniValues = list $f.matchName -}}
    {{- else if hasPrefix "*." $f.matchPattern -}}
      {{- $sniValues = list $f.matchPattern -}}
    {{- end -}}
  {{- end -}}
  {{- $ports := $f.toPorts | default dict -}}
  {{- if and $sniEnabled $sniValues -}}
    {{- $withSNI := dict -}}
    {{- range $pname, $p := $ports -}}
      {{- $p = $p | default dict -}}
      {{- $proto := $p.protocol | default "TCP" -}}
      {{- $rules := $p.rules | default dict -}}
      {{- if and (eq $proto "TCP") (not $p.serverNames) (or (not $rules) $p.terminatingTLS) -}}
        {{- $p = merge (dict) $p -}}
        {{- $p = set $p "serverNames" $sniValues -}}
      {{- end -}}
      {{- $withSNI = set $withSNI $pname $p -}}
    {{- end -}}
    {{- $ports = $withSNI -}}
  {{- end -}}

  {{- if $ports -}}{{- $item = set $item "toPorts" (include "network-policies.toPorts" (dict "ports" $ports "mode" $mode) | fromYamlArray) -}}{{- end -}}
  {{- if $f.icmps -}}{{- $item = set $item "icmps" (include "network-policies.icmpRule" $f.icmps | fromYamlArray) -}}{{- end -}}
  {{- $auth := $f.authentication | default dict -}}
  {{- if $auth.mode -}}{{- $item = set $item "authentication" (dict "mode" $auth.mode) -}}{{- end -}}
  {{- $list = append $list $item -}}
{{- end -}}
{{- toYaml $list -}}
{{- end -}}

{{/*
toServices -- select a Kubernetes Service either by name+namespace or by label selector, and allow
egress to whatever backends it currently resolves to.
Params: dict "entries" <map> "mode" "allow"|"deny" "root" $
*/}}
{{- define "network-policies.serviceEntries" -}}
{{- $mode := .mode -}}
{{- $root := .root -}}
{{- $list := list -}}
{{- range $name, $s := .entries -}}
  {{- $s = $s | default dict -}}
  {{- $svc := dict -}}
  {{- if $s.serviceName -}}
    {{- $k8sSvc := dict "serviceName" $s.serviceName -}}
    {{- if $s.namespace -}}{{- $k8sSvc = set $k8sSvc "namespace" $s.namespace -}}{{- end -}}
    {{- $svc = set $svc "k8sService" $k8sSvc -}}
  {{- else if $s.matchLabels -}}
    {{- $selDef := dict "matchLabels" $s.matchLabels "matchExpressions" $s.matchExpressions -}}
    {{- $sel := include "network-policies.selector" (dict "sel" $selDef "root" $root) | fromYaml -}}
    {{- $selNs := dict "selector" $sel -}}
    {{- if $s.selectorNamespace -}}{{- $selNs = set $selNs "namespace" $s.selectorNamespace -}}{{- end -}}
    {{- $svc = set $svc "k8sServiceSelector" $selNs -}}
  {{- else -}}
    {{- fail (printf "network-policies: toServices.%s needs `serviceName` or `matchLabels`" $name) -}}
  {{- end -}}
  {{- $item := dict "toServices" (list $svc) -}}
  {{- if $s.toPorts -}}{{- $item = set $item "toPorts" (include "network-policies.toPorts" (dict "ports" $s.toPorts "mode" $mode) | fromYamlArray) -}}{{- end -}}
  {{- if $s.icmps -}}{{- $item = set $item "icmps" (include "network-policies.icmpRule" $s.icmps | fromYamlArray) -}}{{- end -}}
  {{- if eq $mode "allow" -}}
    {{- $auth := $s.authentication | default dict -}}
    {{- if $auth.mode -}}{{- $item = set $item "authentication" (dict "mode" $auth.mode) -}}{{- end -}}
  {{- end -}}
  {{- $list = append $list $item -}}
{{- end -}}
{{- toYaml $list -}}
{{- end -}}

{{/*
fromGroups / toGroups -- CIDRs sourced from an external integration (currently AWS security
groups only, per upstream Cilium).
Params: dict "entries" <map> "field" "fromGroups"|"toGroups" "mode" "allow"|"deny"
*/}}
{{- define "network-policies.groupEntries" -}}
{{- $field := .field -}}
{{- $mode := .mode -}}
{{- $list := list -}}
{{- range $name, $g := .entries -}}
  {{- $g = $g | default dict -}}
  {{- $aws := $g.aws | default dict -}}
  {{- $awsOut := dict -}}
  {{- if $aws.labels -}}{{- $awsOut = set $awsOut "labels" $aws.labels -}}{{- end -}}
  {{- if $aws.securityGroupIds -}}{{- $awsOut = set $awsOut "securityGroupsIds" $aws.securityGroupIds -}}{{- end -}}
  {{- if $aws.securityGroupNames -}}{{- $awsOut = set $awsOut "securityGroupsNames" $aws.securityGroupNames -}}{{- end -}}
  {{- $item := dict $field (list (dict "aws" $awsOut)) -}}
  {{- if $g.toPorts -}}{{- $item = set $item "toPorts" (include "network-policies.toPorts" (dict "ports" $g.toPorts "mode" $mode) | fromYamlArray) -}}{{- end -}}
  {{- if $g.icmps -}}{{- $item = set $item "icmps" (include "network-policies.icmpRule" $g.icmps | fromYamlArray) -}}{{- end -}}
  {{- if eq $mode "allow" -}}
    {{- $auth := $g.authentication | default dict -}}
    {{- if $auth.mode -}}{{- $item = set $item "authentication" (dict "mode" $auth.mode) -}}{{- end -}}
  {{- end -}}
  {{- $list = append $list $item -}}
{{- end -}}
{{- toYaml $list -}}
{{- end -}}

{{/*
Egress "allow the kube-apiserver entity" shortcut, used by egress-kubernetes.yaml. Deliberately
does nothing DNS-related -- see egress-dns.yaml for that, which renders on its own trigger (egress
being restricted at all for a workload), independent of this one.
*/}}
{{- define "network-policies.kubernetesEntries" -}}
{{- toYaml (list (dict "toEntities" (list "kube-apiserver"))) -}}
{{- end -}}

{{/*
Egress "allow the link-local cloud-provider metadata endpoint" shortcut
(169.254.169.254, used by AWS/GCP/Azure alike), used by egress-imds.yaml. Pass a dict instead of
`true` to override.
Params: <true | {cidr, port}>
*/}}
{{- define "network-policies.imdsEntries" -}}
{{- $cfg := . -}}
{{- if kindIs "bool" $cfg -}}{{- $cfg = dict -}}{{- end -}}
{{- $cfg = $cfg | default dict -}}
{{- $cidr := $cfg.cidr | default "169.254.169.254/32" -}}
{{- $port := $cfg.port | default "80" | toString -}}
{{- $entry := dict "toCIDR" (list $cidr) -}}
{{- $entry = set $entry "toPorts" (list (dict "ports" (list (dict "port" $port "protocol" "TCP")))) -}}
{{- toYaml (list $entry) -}}
{{- end -}}
