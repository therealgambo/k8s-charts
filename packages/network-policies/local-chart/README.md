# network-policies

A reusable Helm chart that renders namespaced [`CiliumNetworkPolicy`](https://docs.cilium.io/en/stable/security/policy/)
resources from a declarative, merge-friendly values schema. Add it as a Helm dependency of any
chart that needs network policies to get consistent policy structure, naming and Cluster Mesh
support across the estate, instead of every chart hand-rolling its own CNP YAML.

It targets Cilium **1.20**, is namespace-scoped only (no cluster-wide or host policies), and
covers L3/L4 selectors, L7 HTTP/DNS rules, CIDR groups, FQDN-based egress, Kubernetes Service
targeting, ICMP rules, mutual authentication (SPIRE), and explicit allow _and_ deny rules.

## Out of the box: closed by default

Installing this chart with no configuration at all renders two resources,
`ingress-default-deny`/`egress-default-deny`, that block all ingress/egress traffic for every pod
in the namespace. Every workload's `rules.<key>` entry is what opens up exactly what that workload
needs on top of that baseline -- see [Disabling the default-deny](#disabling-the-default-deny) if
a given namespace shouldn't be locked down this way.

## Testing & validation

The templating logic here is non-trivial (dynamic resource naming, allow/deny partitioning,
selector inference, the FQDN/SNI auto-derivation, the automatic DNS-egress trigger), so it's backed
by two layers of automated checking:

- **`values.schema.json`** -- every field this chart reads is typed and, for the maps with a fixed
  set of valid keys (`entities`, `defaultDeny`, a `rule`'s own top-level fields), constrained to
  exactly those keys. This turns typos (`kubernetse: true`, a misspelled entity name, `port` given
  as the wrong type) and structurally-incomplete entries (a `cidr` entry with none of
  `cidr`/`cidrGroupRef`/`cidrGroupSelector`) into an immediate `helm template`/`helm install`/
  `helm lint` error instead of a confusing render-time failure or, worse, a silently-wrong policy.
  It's validated automatically by Helm itself -- there's nothing extra to run.

- **[helm-unittest](https://github.com/helm-unittest/helm-unittest)** -- `tests/*_test.yaml`
  exercises the actual rendered output of every template against representative `rules` input:
  resource naming, selector inference vs. explicit override, the reserved namespace label, Cluster
  Mesh `cluster` string-vs-list, allow/deny partitioning, the FQDN SNI auto-derivation rules, and
  every trigger/opt-out/override path of the automatic `egress-dns` policy. Install the plugin once
  (`helm plugin install https://github.com/helm-unittest/helm-unittest`), then run:

  ```shell
  make unittest PACKAGE=network-policies
  # or, from this directory:
  helm unittest .
  ```

  CI runs this automatically on any PR that touches a package with a `tests/` dir (see
  `.github/workflows/validate-charts.yaml`).

`tests/` is excluded from the packaged chart artifact via `.helmignore` -- it's a development-time
check against the chart source, not something consuming charts need.

Neither layer replaces `kubeconform` against the real Cilium CRD schemas (see the repo root
README's validation section) -- schema validation and helm-unittest catch "did this chart do what
the values said", kubeconform catches "is the resulting CiliumNetworkPolicy actually valid".

## How rendering works: one workload, one place

Everything a workload needs -- its subject (which pods) and every ingress/egress peer type it
talks to -- lives under **one key in `rules`**, so you can read one place to see a workload's
whole network posture instead of cross-referencing a dozen top-level maps:

```yaml
rules:
  webapp:
    egress:
      cidr:
        office-vpn: { cidr: 10.0.0.0/8 }
      entities:
        world: { toPorts: { https: { port: "443" } } }

  processor:
    egress:
      kubernetes: true
      imds: true

  database:
    egress:
      cidr:
        backup-target: { cidr: 10.20.0.0/16 }
```

Each _type_ a workload populates (`endpoints`, `entities`, `cidr`, `nodes`, `groups`, and
egress-only `services`/`fqdns`/`kubernetes`/`imds`) still renders as its **own** small
CiliumNetworkPolicy, though -- named **`<direction>-<type>-<key>`** (e.g. `webapp`'s `egress.cidr`
above renders `egress-cidr-webapp`), in a file named to match it (`egress-cidr.yaml` renders every
workload that populates `egress.cidr`). The resource name is tied to that file name dynamically
(via `.Template.Name`), not hand-copied, so it can't drift out of sync with the file. You still get
small, focused, independently-diffable resources per concern -- just authored in one place per
workload rather than one place per concern.

This also gets you Helm's values-merging for free -- a `staging.values.yaml` that wants to add one
more allowed peer to an existing workload just adds another entry under its key rather than
repeating the whole thing:

```yaml
# base.values.yaml
rules:
  webapp:
    egress:
      entities:
        world: { toPorts: { https: { port: "443" } } }

# staging.values.yaml -- same key, adds a peer without repeating `world`
rules:
  webapp:
    egress:
      entities:
        cluster-mesh: {}
```

### The types

| Direction               | Type (file)  | Values path                     | Cilium field       | Peer shape                                                                                                                                                                                                                                                             |
| ----------------------- | ------------ | ------------------------------- | ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| both                    | `endpoints`  | `rules.<key>.<dir>.endpoints`   | `From/ToEndpoints` | map of name → selector (`matchLabels`, `matchExpressions`, `namespace`, `cluster`) + `toPorts`/`icmps`/`authentication`                                                                                                                                                |
| both                    | `entities`   | `rules.<key>.<dir>.entities`    | `From/ToEntities`  | map keyed **by the entity name itself** (`world`, `cluster`, `cluster-mesh`, `host`, `remote-node`, `kube-apiserver`, `ingress`, `init`, `health`, `unmanaged`, `none`, `all`, `world-ipv4`, `world-ipv6`) + `toPorts`/`icmps`/`authentication`                        |
| both                    | `cidr`       | `rules.<key>.<dir>.cidr`        | `From/ToCIDRSet`   | map of name → `{cidr, except[]}` or `{cidrGroupRef}`/`{cidrGroupSelector}` (a [`CiliumCIDRGroup`](https://docs.cilium.io/en/stable/network/kubernetes/ciliumcidrgroup/)) + `toPorts`/`icmps`/`authentication`. Omit `toPorts` to allow/deny every port from that CIDR. |
| both                    | `nodes`      | `rules.<key>.<dir>.nodes`       | `From/ToNodes`     | same shape as `endpoints`, minus `namespace` (nodes aren't namespaced)                                                                                                                                                                                                 |
| both                    | `groups`     | `rules.<key>.<dir>.groups`      | `From/ToGroups`    | map of name → `{aws: {labels, securityGroupIds, securityGroupNames}}` (Cilium's only supported external CIDR integration)                                                                                                                                              |
| egress only             | `services`   | `rules.<key>.egress.services`   | `ToServices`       | map of name → `{serviceName, namespace}` **or** `{matchLabels, selectorNamespace}` + `toPorts`/`icmps`/`authentication`                                                                                                                                                |
| egress only, allow-only | `fqdns`      | `rules.<key>.egress.fqdns`      | `ToFQDNs`          | map of name → `{matchName}`/`{matchPattern}` + `toPorts`/`icmps`/`authentication`. No deny variant -- Cilium's `EgressDenyRule` has no `ToFQDNs` field, so `deny: true` here fails the render.                                                                         |
| egress only             | `kubernetes` | `rules.<key>.egress.kubernetes` | --                 | shortcut, see [Convenience shortcuts](#convenience-shortcuts)                                                                                                                                                                                                          |
| egress only             | `imds`       | `rules.<key>.egress.imds`       | --                 | shortcut, see [Convenience shortcuts](#convenience-shortcuts)                                                                                                                                                                                                          |
| egress only             | `dns`        | `rules.<key>.egress.dns`        | --                 | automatic, see [Automatic DNS egress](#automatic-dns-egress)                                                                                                                                                                                                           |

A given type only renders a resource for a workload that actually populates it -- there's no
separate flag to disable a type you're not using. Every workload key also accepts: `enabled`
(default `true`), `description` (→ `spec.description` on every resource it renders), `labels`/
`annotations`, and the subject selector itself -- `labelSelector`/`labelSelectorExpressions`,
shared across every type that workload populates.

Deliberately **not** exposed:

- `fromRequires`/`toRequires` -- deprecated upstream (`+kubebuilder:validation:MaxItems=0`, i.e.
  unusable).
- Cluster-wide/host policies -- this chart is namespace-scoped by design (see
  [How rendering works](#how-rendering-works-one-workload-one-place)).
- A "just open a port" type with no peer at all. Every `toPorts` entry has to be attached to a
  peer -- `endpoints`/`entities`/`cidr`/`nodes`/`groups` (and, egress-only, `services`/`fqdns`) --
  so a port is never opened to literally anyone by accident. Attach it to the narrowest peer
  that's actually correct (`entities.world` if it genuinely does need to be internet-facing).
- A shared/reusable selector registry (`useSelector`). Every rule writes its own `labelSelector`
  explicitly, or relies on [inference from its key](#subject-selector-inference) -- there's no
  indirection to chase to see what a rule actually selects.

### Subject selector inference

The subject selector is **inferred** when neither `labelSelector` nor `labelSelectorExpressions`
is set on a workload: the key itself becomes `app.kubernetes.io/name`, so `rules.webapp` targets
`app.kubernetes.io/name: webapp` without repeating it. Set either to opt out and take full manual
control -- useful when the key doesn't match the app's name 1:1, or when more complex selecting
(`matchExpressions`) is needed:

```yaml
rules:
  webapp: # -> app.kubernetes.io/name: webapp, inferred
    egress:
      entities: { world: {} }
  webapp-metrics:
    labelSelector: # key isn't the app name -- selector given explicitly instead
      app.kubernetes.io/name: webapp
      component: metrics
    egress:
      entities: { world: {} }
```

### Allow and deny in the same resource

Any peer entry accepts `deny: true` to render into that resource's `spec.<direction>Deny` instead
of `spec.<direction>` -- evaluated ahead of allow rules regardless of ordering, and limited to
plain port/protocol matching (no L7 rules, TLS, listener or `authentication`, per Cilium's
`PortDenyRule`). Allow and deny peers of the same type under the same workload land in the
**same** resource, in the two different spec fields -- which is how Cilium's own examples usually
pair them:

```yaml
rules:
  webapp:
    ingress:
      cidr:
        vpn-allow:
          cidr: 10.0.0.0/8
        tor-exit-block:
          cidr: 1.2.3.0/24
          deny: true # -> spec.ingressDeny on the SAME ingress-cidr-webapp resource
```

### The reserved namespace label is always explicit

Every `endpoints` peer (`fromEndpoints`/`toEndpoints`) always gets the reserved
`k8s:io.kubernetes.pod.namespace` label stamped on it -- defaulting to this release's own
namespace when `namespace` isn't set, rather than relying on Cilium's implicit "bare `matchLabels`
are scoped to this policy's own namespace" behaviour. So a peer that's local to the namespace and
one that explicitly says `namespace: <this namespace>` render identically -- there's no implicit
case left to reason about when reading the rendered YAML.

`nodes`/`cidr`/`entities`/`groups`/`services` peers do **not** get this label: nodes aren't
namespaced, `world`/`host`/etc. entities aren't pod identities, CIDRs aren't identities at all, and
`toServices`' `namespace` is a distinct, explicit field on that type already.

### `toPorts` entries

Each named entry under a peer's `toPorts` becomes one `PortRule`:

```yaml
toPorts:
  https:
    port: "443" # required, unless `ports` (below) is used instead
    endPort: "" # optional, for a port range
    protocol: TCP # TCP | UDP | SCTP | ANY (default TCP)
    ports: {} # optional: group several port/protocol pairs under one shared
      # rules/TLS/listener config, e.g. {https: {port: "443"}, alt: {port: "8443"}}
    rules: # L7 (allow rules only -- ignored on a `deny: true` peer)
      http:
        get-root: { method: GET, path: "^/$" }
      dns:
        wildcard: { matchPattern: "*" }
    terminatingTLS: { secretName: "", secretNamespace: "" }
    originatingTLS: { secretName: "", secretNamespace: "" }
    serverNames: []
    listener:
      { name: "", priority: 0, envoyConfigKind: "", envoyConfigName: "" }
```

`port` accepts a Kubernetes named port (e.g. `"http"`) as well as a numeric string, per Cilium's
`PortProtocol.Port`.

### `icmps`

```yaml
icmps:
  echo-request:
    family: IPv4 # IPv4 (default) | IPv6
    type: 8 # numeric ICMP type, or a CamelCase name like EchoRequest
```

All entries in the map are grouped into a single `ICMPRule` (OR'd together).

### Convenience shortcuts

`kubernetes` and `imds` live directly under a workload's `egress`, not as a named map like the
other types (there's only ever one of each per workload):

```yaml
rules:
  processor:
    egress:
      kubernetes: true # boolean only
      imds: true # or {cidr, port} to override
```

- `kubernetes` allows egress to the `kube-apiserver` entity. That's all it does -- it's
  deliberately **not** where DNS access comes from, see
  [Automatic DNS egress](#automatic-dns-egress) below for that.
- `imds` allows the link-local cloud-provider metadata endpoint (`169.254.169.254`, AWS/GCP/Azure
  alike) on port 80/tcp.

Both are scoped to **that workload's own subject selector**, same as every other resource this
chart renders -- not every workload needs IMDS or direct API server access, so these were
deliberately not made namespace-wide. `egress-kubernetes-processor`/`egress-imds-processor` above
only apply to pods matching `processor`'s selector.

### Automatic DNS egress

Restricting a workload's egress without also allowing DNS just breaks it -- nothing can resolve
names any more, including for the very peers the other egress rules just allowed. So rather than
bundling DNS into the `kubernetes` shortcut (or requiring it to be hand-added everywhere), an
`egress-dns-<key>` resource renders **automatically** for any workload that has egress restricted
at all -- i.e. any of `entities`/`cidr`/`endpoints`/`nodes`/`groups`/`services`/`fqdns`/
`kubernetes`/`imds` populated. No flag needed:

```yaml
rules:
  webapp:
    egress:
      entities:
        world: {} # egress is now restricted for webapp -> egress-dns-webapp renders too
```

`egress.dns` itself only exists to **override** this automatic behaviour for one workload:

```yaml
rules:
  # explicit, without needing any other egress.* type to trigger it
  dns-only-job:
    egress:
      dns: true

  # opt out even though other egress exists (e.g. DNS is allowed some other way already)
  no-auto-dns:
    egress:
      dns: false
      entities:
        world: {}

  # override the target for just this one workload
  custom-resolver:
    egress:
      dns:
        cidr: 10.96.0.10/32
        port: "5353"
      entities:
        world: {}
```

The default target comes from the top-level `dns.cidr`/`dns.port` in [values.yaml](values.yaml),
which defaults to this estate's [node-local-dns](../../node-local-dns) virtual IP
(`169.254.20.25/32:53`) -- **not** the `kube-dns` Service. NodeLocal DNSCache intercepts DNS by
pointing the kubelet's `--cluster-dns` at a link-local address on each node and redirecting to it
via iptables, so that's the address pods actually talk to, not `kube-dns`'s ClusterIP. If a
different environment instead uses a
[`CiliumLocalRedirectPolicy`](https://docs.cilium.io/en/stable/network/kubernetes/local-redirect-policy/)
to get the same node-local routing -- redirecting traffic addressed to the `kube-dns` Service
transparently instead of changing where pods think they're sending DNS queries -- point `dns.cidr`
at that Service's ClusterIP instead (globally, or per workload via `egress.dns.cidr`).

### FQDN egress and SNI enforcement

DNS resolution alone doesn't prove traffic is still going to the named host once Cilium has
allowed the resolved IP -- the record can change, or the IP can be shared with something else. So
every `fqdns` entry enforces **SNI validation by default**: any TCP `toPorts` entry that doesn't
already set its own `serverNames` gets one derived from the FQDN and checked against the TLS
ClientHello, via Cilium's passive SNI check (no `terminatingTLS` or L7 `rules` required for this
alone -- see [`toPorts` entries](#toports-entries)):

```yaml
fqdns:
  github-api:
    matchName: "api.github.com"
    toPorts:
      https:
        port: "443" # -> serverNames: [api.github.com], derived automatically
```

Auto-derivation only handles a literal `matchName` or a leading-wildcard `matchPattern`
(`*.example.com`, matching Cilium's own FQDN wildcard convention and Envoy's SNI wildcard
matching); anything more exotic needs an explicit `sniServerNames` override. For hosts that don't
speak TLS at all -- plain SSH/SFTP and the like -- set `sni: false`, since there's no SNI to check
and leaving enforcement on would block the connection:

```yaml
fqdns:
  sftp-host:
    matchName: "sftp.example.com"
    sni: false
    toPorts:
      sftp:
        port: "22"
  custom-sni:
    matchName: "weird.example.com"
    sniServerNames: ["custom.sni.example.com"] # override instead of deriving from matchName
    toPorts:
      https:
        port: "8443"
```

### `commonLabels` / `commonAnnotations`

Merged into every rendered resource's `metadata.labels`/`.annotations` (a workload's own
`labels`/`annotations` still layer on top). Handy for stamping something like
`app.kubernetes.io/part-of` across every policy this chart renders.

### Disabling the default-deny

```yaml
defaultDeny:
  ingress:
    enabled: false
  egress:
    enabled: false
```

Set either to `false` if that direction's namespace-wide lockdown isn't wanted (e.g. it's managed
by a different mechanism). Each is independent.

## Quick start

Add as a dependency:

```yaml
# Chart.yaml
dependencies:
  - name: network-policies
    version: "0.1.0"
    repository: "oci://ghcr.io/therealgambo/k8s-charts/charts" # or your resolved chart repo
```

Configure it from that chart's own values:

```yaml
network-policies:
  rules:
    webapp:
      ingress:
        endpoints:
          ingress-controller:
            matchLabels:
              app.kubernetes.io/name: ingress-nginx
            toPorts:
              http:
                port: "8080"
      egress:
        kubernetes: true
        endpoints:
          postgres:
            matchLabels:
              app.kubernetes.io/name: postgres
            toPorts:
              pg:
                port: "5432"
```

This renders `ingress-endpoint-webapp`, `egress-kubernetes-webapp`, `egress-endpoint-webapp` and
`egress-dns-webapp` (added automatically, see [Automatic DNS egress](#automatic-dns-egress)), plus
the two default-deny resources, all in the release namespace. See [values.yaml](values.yaml) for
the fully annotated schema.

> [!NOTE]
> Cilium's CRD schema requires every policy to set at least one of `ingress`/`ingressDeny`/
> `egress`/`egressDeny` -- this chart only ever renders a resource for a type a workload actually
> populates, so this can't come up in practice, but the render still fails with a clear error if
> it somehow did rather than letting `kubectl apply` reject it later.

## Cluster Mesh

Two tools cover [Cluster Mesh](https://docs.cilium.io/en/stable/network/clustermesh/clustermesh/)
policy stanzas:

1. **The `cluster-mesh` entity** -- `entities` accepts `cluster-mesh`, meaning "traffic from/to
   anywhere in the connected mesh". Simplest option when you don't need to restrict to a specific
   remote cluster.
2. **The `cluster` field on any `endpoints`/`nodes` peer** -- injects Cilium's reserved
   `k8s:io.cilium.k8s.policy.cluster` label, scoping that one peer to a specific remote cluster's
   identities. Accepts either one cluster name or a list of names, OR'd together via a generated
   `matchExpressions` `In` clause:
   ```yaml
   endpoints:
     billing-service:
       matchLabels:
         app.kubernetes.io/name: billing
       cluster: cluster-b # only matches `billing` pods running in cluster-b
     billing-service-multi:
       matchLabels:
         app.kubernetes.io/name: billing
       cluster: [cluster-b, cluster-c] # matches `billing` pods in either cluster
   ```
   Omit `cluster` to match the given labels in _any_ connected cluster (including the local one).
   For anything beyond a simple OR list (excluding a cluster, matching by some other reserved
   label, ...), write a `matchExpressions` entry against `k8s:io.cilium.k8s.policy.cluster`
   directly -- it's a normal label, so nothing beyond the existing `matchExpressions` field is
   needed:
   ```yaml
   matchExpressions:
     - key: k8s:io.cilium.k8s.policy.cluster
       operator: NotIn
       values: [cluster-a]
   ```

## Mutual authentication (SPIRE)

Any peer entry on an **allow** rule (`entities`, `endpoints`, `cidr`, `nodes`, `groups`,
`services`, `fqdns`) accepts `authentication.mode`:

```yaml
endpoints:
  billing-service:
    matchLabels: { app.kubernetes.io/name: billing }
    authentication:
      mode: required # disabled | required | test-always-fail
```

`required` enforces mutual authentication (backed by [SPIFFE/SPIRE](../../spire) identities) for
that traffic before Cilium allows it. Not available on `deny: true` peers -- Cilium has no concept
of denying based on auth state.

## Worked examples

<details>
<summary>A workload with layered egress: CIDR, entity, endpoint and FQDN, plus a deny rule</summary>

```yaml
rules:
  webapp:
    egress:
      kubernetes: true # kube-apiserver entity
      cidr:
        office-vpn:
          cidr: 10.0.0.0/8
        known-bad-actors:
          cidrGroupRef: known-bad-actors # a CiliumCIDRGroup managed elsewhere
          deny: true
      entities:
        world: {}
      endpoints:
        postgres:
          matchLabels: { app.kubernetes.io/name: postgres }
          namespace: data
          toPorts:
            pg: { port: "5432" }
      fqdns:
        github-api:
          matchName: "api.github.com"
          toPorts:
            https:
              port: "443" # SNI enforcement is on by default -- see FQDN egress and SNI enforcement
```

</details>

<details>
<summary>Two workloads sharing a namespace, each with their own narrow egress</summary>

```yaml
rules:
  processor:
    egress:
      kubernetes: true
      imds: true # only `processor` gets IMDS access, not the whole namespace

  database:
    ingress:
      cidr:
        office-vpn:
          cidr: 10.0.0.0/8
          toPorts:
            pg: { port: "5432" }
    egress:
      cidr:
        backup-target:
          cidr: 10.20.0.0/16
          toPorts:
            https: { port: "443" }
```

</details>

<details>
<summary>Multiple peers sharing one subject, split across allow and deny</summary>

```yaml
rules:
  webapp:
    ingress:
      endpoints:
        frontend:
          matchLabels: { app.kubernetes.io/name: frontend }
          toPorts:
            http: { port: "8080" }
        legacy-caller:
          matchLabels: { app.kubernetes.io/name: legacy-caller }
          deny: true # -> spec.ingressDeny on the same ingress-endpoint-webapp resource
```

</details>

<details>
<summary>FQDN egress to a non-TLS host, with SNI validation disabled</summary>

SNI validation is on by default for `fqdns` entries (see
[FQDN egress and SNI enforcement](#fqdn-egress-and-sni-enforcement)), but it only makes sense for
TLS traffic. A host that doesn't speak TLS at all -- SSH/SFTP, a plain-TCP legacy service, ...
needs `sni: false`, or Cilium has nothing to check and blocks the connection outright:

```yaml
rules:
  batch-job:
    egress:
      # no need to enable anything for DNS itself -- fqdns being populated already means egress
      # is restricted for batch-job, so egress-dns-batch-job renders automatically
      fqdns:
        vendor-sftp:
          matchName: "sftp.vendor.example.com"
          sni: false # this host is plain SFTP, not TLS -- nothing to validate
          toPorts:
            sftp:
              port: "22"
        vendor-api:
          matchName: "api.vendor.example.com"
          toPorts:
            https:
              port: "443" # TLS as normal -- SNI enforcement stays on here
```

</details>
