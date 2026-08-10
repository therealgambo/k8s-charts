{{/*
Build the `ports` list (a []PortProtocol) for one toPorts entry, from either a single
port/endPort/protocol on the entry itself, or a `ports` sub-map grouping several port/protocol
pairs that share the same L7 rules/TLS/listener.
Params: <toPorts entry definition>
*/}}
{{- define "network-policies.portProtocols" -}}
{{- $def := . -}}
{{- if not (or $def.port $def.ports) -}}
  {{- fail "network-policies: a toPorts entry needs either `port` or a `ports` sub-map" -}}
{{- end -}}
{{- $list := list -}}
{{- if $def.ports -}}
  {{- range $name, $p := $def.ports -}}
    {{- $pp := dict "port" ($p.port | toString) "protocol" ($p.protocol | default "TCP") -}}
    {{- if $p.endPort -}}{{- $pp = set $pp "endPort" ($p.endPort | int) -}}{{- end -}}
    {{- $list = append $list $pp -}}
  {{- end -}}
{{- else -}}
  {{- $pp := dict "port" ($def.port | toString) "protocol" ($def.protocol | default "TCP") -}}
  {{- if $def.endPort -}}{{- $pp = set $pp "endPort" ($def.endPort | int) -}}{{- end -}}
  {{- $list = append $list $pp -}}
{{- end -}}
{{- toYaml $list -}}
{{- end -}}

{{/*
Build a PortRulesHTTP list from a map of named HTTP L7 rules.
Params: <map of name -> {method, path, host, headers, headerMatches}>
*/}}
{{- define "network-policies.httpRules" -}}
{{- $list := list -}}
{{- range $name, $h := . -}}
  {{- $h = $h | default dict -}}
  {{- $item := dict -}}
  {{- if $h.method -}}{{- $item = set $item "method" $h.method -}}{{- end -}}
  {{- if $h.path -}}{{- $item = set $item "path" $h.path -}}{{- end -}}
  {{- if $h.host -}}{{- $item = set $item "host" $h.host -}}{{- end -}}
  {{- if $h.headers -}}{{- $item = set $item "headers" $h.headers -}}{{- end -}}
  {{- if $h.headerMatches -}}
    {{- $hm := list -}}
    {{- range $h.headerMatches -}}
      {{- $m := dict "name" .name -}}
      {{- if .value -}}{{- $m = set $m "value" .value -}}{{- end -}}
      {{- if .mismatch -}}{{- $m = set $m "mismatch" .mismatch -}}{{- end -}}
      {{- if .secretName -}}
        {{- $s := dict "name" .secretName -}}
        {{- if .secretNamespace -}}{{- $s = set $s "namespace" .secretNamespace -}}{{- end -}}
        {{- $m = set $m "secret" $s -}}
      {{- end -}}
      {{- $hm = append $hm $m -}}
    {{- end -}}
    {{- $item = set $item "headerMatches" $hm -}}
  {{- end -}}
  {{- $list = append $list $item -}}
{{- end -}}
{{- toYaml $list -}}
{{- end -}}

{{/*
Build a PortRulesDNS list from a map of named DNS L7 rules.
Params: <map of name -> {matchName, matchPattern}>
*/}}
{{- define "network-policies.dnsRules" -}}
{{- $list := list -}}
{{- range $name, $d := . -}}
  {{- $d = $d | default dict -}}
  {{- $item := dict -}}
  {{- if $d.matchName -}}{{- $item = set $item "matchName" $d.matchName -}}{{- end -}}
  {{- if $d.matchPattern -}}{{- $item = set $item "matchPattern" $d.matchPattern -}}{{- end -}}
  {{- $list = append $list $item -}}
{{- end -}}
{{- toYaml $list -}}
{{- end -}}

{{/*
Build a TLSContext dict (terminatingTLS/originatingTLS) from a secret reference.
Params: <{secretName, secretNamespace, trustedCA, certificate, privateKey}>
*/}}
{{- define "network-policies.tlsContext" -}}
{{- $t := . | default dict -}}
{{- $out := dict -}}
{{- if $t.secretName -}}
  {{- $s := dict "name" $t.secretName -}}
  {{- if $t.secretNamespace -}}{{- $s = set $s "namespace" $t.secretNamespace -}}{{- end -}}
  {{- $out = set $out "secret" $s -}}
{{- end -}}
{{- if $t.trustedCA -}}{{- $out = set $out "trustedCA" $t.trustedCA -}}{{- end -}}
{{- if $t.certificate -}}{{- $out = set $out "certificate" $t.certificate -}}{{- end -}}
{{- if $t.privateKey -}}{{- $out = set $out "privateKey" $t.privateKey -}}{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{/*
Build a Listener dict, optionally referencing a CiliumEnvoyConfig/CiliumClusterwideEnvoyConfig.
Params: <{name, priority, envoyConfigKind, envoyConfigName}>
*/}}
{{- define "network-policies.listener" -}}
{{- $l := . | default dict -}}
{{- $out := dict "name" $l.name "priority" ($l.priority | int) -}}
{{- if or $l.envoyConfigKind $l.envoyConfigName -}}
  {{- $out = set $out "envoyConfig" (dict "kind" $l.envoyConfigKind "name" $l.envoyConfigName) -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{/*
Build a single ICMPRule (`icmps: [{fields: [...]}]`) wrapping every field in the given map.
Params: <map of name -> {family, type}>
*/}}
{{- define "network-policies.icmpRule" -}}
{{- $fields := list -}}
{{- range $name, $f := . -}}
  {{- $f = $f | default dict -}}
  {{- $item := dict "type" $f.type -}}
  {{- if $f.family -}}{{- $item = set $item "family" $f.family -}}{{- end -}}
  {{- $fields = append $fields $item -}}
{{- end -}}
{{- toYaml (list (dict "fields" $fields)) -}}
{{- end -}}

{{/*
Build a full toPorts list (PortRules, or PortDenyRules when mode=deny) from a map of named
toPorts entries. Deny rules only carry `ports` -- Cilium's PortDenyRule has no L7/TLS/listener.
Params: dict "ports" <map> "mode" "allow"|"deny"
*/}}
{{- define "network-policies.toPorts" -}}
{{- $mode := .mode -}}
{{- $list := list -}}
{{- range $name, $p := .ports -}}
  {{- $p = $p | default dict -}}
  {{- $rule := dict "ports" (include "network-policies.portProtocols" $p | fromYamlArray) -}}
  {{- if eq $mode "allow" -}}
    {{- $rules := $p.rules | default dict -}}
    {{- $l7 := dict -}}
    {{- if $rules.http -}}{{- $l7 = set $l7 "http" (include "network-policies.httpRules" $rules.http | fromYamlArray) -}}{{- end -}}
    {{- if $rules.dns -}}{{- $l7 = set $l7 "dns" (include "network-policies.dnsRules" $rules.dns | fromYamlArray) -}}{{- end -}}
    {{- if $l7 -}}{{- $rule = set $rule "rules" $l7 -}}{{- end -}}
    {{- if $p.terminatingTLS -}}{{- $rule = set $rule "terminatingTLS" (include "network-policies.tlsContext" $p.terminatingTLS | fromYaml) -}}{{- end -}}
    {{- if $p.originatingTLS -}}{{- $rule = set $rule "originatingTLS" (include "network-policies.tlsContext" $p.originatingTLS | fromYaml) -}}{{- end -}}
    {{- if $p.serverNames -}}{{- $rule = set $rule "serverNames" $p.serverNames -}}{{- end -}}
    {{- if $p.listener -}}{{- $rule = set $rule "listener" (include "network-policies.listener" $p.listener | fromYaml) -}}{{- end -}}
  {{- end -}}
  {{- $list = append $list $rule -}}
{{- end -}}
{{- toYaml $list -}}
{{- end -}}
