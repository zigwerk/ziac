# GCP Edge Security

M70 completes a secure global static-delivery and TLS path using Cloud CDN,
Cloud Armor, Certificate Manager and Compute HTTPS proxies. It follows Ziac's
three provider layers: typed resources, hardened lifecycle adapters and
opinionated components.

## Managed Resources

`BackendBucket` binds a private Cloud Storage origin to explicit CDN cache
mode, TTLs, cache-key shape, negative caching, stale serving, request
coalescing, compression and an optional edge security policy. `SecurityPolicy`
uses tagged match and action unions and requires exactly one match-all default
rule at priority 2147483647. `SslPolicy` makes minimum TLS and profile choices
visible in the graph.

Certificate Manager support includes managed `DnsAuthorization`,
`Certificate`, `CertificateMap` and `CertificateMapEntry` resources. Private
keys never enter Ziac. `CertificateMapTargetHttpsProxy` attaches a stable map
to a Compute HTTPS proxy so certificates and hostnames can rotate behind the
frontend.

Compute mutations checkpoint global operations and update mutable resources
with the current fingerprint plus bounded conflict retries. Certificate
Manager mutations checkpoint generic Google long-running operations. State
uses canonical `projects/...` resource names; noncanonical imports are
rejected.

## Components

- `ProtectedCdnBucket` composes one edge Cloud Armor policy and one CDN backend
  bucket. It does not make the origin public or invent Storage IAM.
- `ManagedCertificateMap` creates one DNS authorization and managed
  certificate per domain, then a stable map and hostname entries. It returns
  typed DNS record outputs for explicit Cloud DNS or external DNS wiring.

`examples/secure_edge.zig` combines both components with a modern TLS policy
and certificate-map HTTPS proxy.

## Intelligence And Visualization

Permission synthesis derives exact Compute CRUD and use permissions plus the
Certificate Manager `certs`, `certmaps`, `certmapentries` and
`dnsauthorizations` permissions required by each graph edge. It includes
`dnsauthorizations.use`, `certs.use` and `certmaps.use` only where resources are
wired together.

Cloud Asset mapping supports all eight official resource identities. A
`TargetHttpsProxy` is classified as Ziac's certificate-map proxy only when the
asset payload proves a `certificateMap`; legacy proxies retain their existing
type.

Canvas artifacts expose cache, Armor rule count, TLS profile, certificate
scope, DNS authorization and map membership. Edges distinguish cache origin,
security enforcement, DNS authorization, certificate selection and TLS
policy. Cost estimates accept explicit SKU IDs and quantities for cache
egress, cache fill, lookups, Armor requests and certificate months. They remain
configuration estimates, never billed cost.

## Qualification

The deterministic local gate applies the full graph, imports every resource
into empty state, refreshes to no-op, performs retention-aware cleanup and
emits `ziac.gcp.edge-security-qualification.v1` evidence.

`scripts/qualify-edge-security.sh` is the fail-closed authenticated boundary.
It requires ADC, a project ending in `-ziac-disposable`, delegated test DNS,
named CDN and certificate resources, a cacheable probe URL and an Armor deny
URL. A passing receipt proves DNS authorization, an active managed
certificate, map-to-proxy attachment, an observed CDN `Age` header, an HTTP 403
Armor probe, second-state no-op import and destructive cleanup. Missing
credentials or configuration produce a structured exit-77 skip.

## Google Contracts

- [Backend buckets](https://cloud.google.com/compute/docs/reference/rest/v1/backendBuckets)
- [Cloud CDN](https://cloud.google.com/cdn/docs)
- [Cloud Armor security policies](https://cloud.google.com/armor/docs/security-policy-overview)
- [Certificate Manager REST v1](https://cloud.google.com/certificate-manager/docs/reference/certificate-manager/rest)
- [Certificate Manager permissions](https://cloud.google.com/certificate-manager/docs/permissions)
- [Certificate maps](https://cloud.google.com/certificate-manager/docs/maps)
