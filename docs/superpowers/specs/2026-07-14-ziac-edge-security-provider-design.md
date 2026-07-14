# Ziac M70 Edge Security Provider Design

Date: 2026-07-14
Status: accepted for implementation

## Objective

Complete the secure global edge path for static and HTTP delivery. M70 adds a
Cloud CDN backend bucket, Cloud Armor policy, TLS policy and Certificate Manager
chain that can terminate HTTPS through a certificate-map-aware Compute proxy.

## Resource Surface

M70 manages eight resource types:

1. `gcp.compute.BackendBucket`
2. `gcp.compute.SecurityPolicy`
3. `gcp.compute.SslPolicy`
4. `gcp.certificatemanager.DnsAuthorization`
5. `gcp.certificatemanager.Certificate`
6. `gcp.certificatemanager.CertificateMap`
7. `gcp.certificatemanager.CertificateMapEntry`
8. `gcp.compute.CertificateMapTargetHttpsProxy`

Compute resources use the pinned Compute v1 Discovery contract. Certificate
Manager resources use its v1 Google API contract and long-running operations.

## Policy And Lifecycle

`BackendBucket` owns one Cloud Storage origin, Cloud CDN mode, TTL policy,
negative caching, stale serving, request coalescing, compression, cache-key
shape and an optional edge Cloud Armor policy. Bucket identity is immutable;
cache and edge policy update with the current fingerprint.

`SecurityPolicy` owns an ordered rule set and requires exactly one default rule
at priority 2147483647. Rules use tagged match and action unions so source-IP
matches cannot be confused with CEL expressions and allow, deny and throttle
parameters cannot coexist. Policy kind is either backend or edge. Type changes
replace; rule changes use the current fingerprint and bounded 412 retry.

`SslPolicy` owns minimum TLS version, profile and optional custom features.
Custom features are legal only with the custom profile. Changes update with the
current fingerprint.

Certificate Manager support is managed-certificate only in M70. A certificate
declares immutable domains, DNS authorization outputs and scope. Private keys
never enter this tranche. DNS authorization, certificate, map and map-entry
identity use canonical AIP resource names. Domain/matcher identity changes
replace conservatively; map entries can rotate by replacement while a proxy
continues to reference the stable map.

`CertificateMapTargetHttpsProxy` references a typed URL-map output and a typed
Certificate Manager map output. QUIC and SSL policy are explicit. The proxy is
conservatively replaceable; certificate renewal and hostname rotation happen
behind the stable certificate map.

## Opinionated Components

`ProtectedCdnBucket` composes an edge Cloud Armor policy and CDN backend bucket.
It does not make the source bucket public and does not synthesize storage IAM.

`ManagedCertificateMap` composes one DNS authorization and managed certificate
per declared domain, one stable map and hostname entries. It returns the DNS
record outputs needed for explicit Cloud DNS or external-DNS wiring and never
claims readiness before Certificate Manager reports `ACTIVE`.

## Product Integration

Permission synthesis derives exact Compute backend-bucket, security-policy,
SSL-policy and target-proxy methods plus Certificate Manager CRUD. Cloud Asset
mapping adopts official identities and classifies the new proxy only when its
`certificateMap` property is present.

Canvas metadata exposes cache policy, Armor rules, TLS policy, certificate
scope/state, map membership and DNS authorization. Edges distinguish cache
origin traffic, security enforcement, DNS authorization and certificate
selection. Cost estimates keep cache egress, fill, lookup, Armor request and
certificate quantities explicit and configuration-based.

## Qualification

The local receipt applies a protected CDN origin and managed certificate map,
imports into empty state, refreshes to no-op and performs retention-aware
cleanup. The authenticated runner requires ADC, a disposable project, a test
bucket and delegated test domain. It must observe DNS authorization, an active
certificate, a proxy attached to the map, a cache hit and an Armor deny probe.

## Definition Of Done

M70 is locally complete when declarations, lifecycle adapters, components,
intelligence, estate, visual, cost, documentation, examples and qualification
boundaries pass the release gate. DNS propagation, active issuance, cache-hit
and Armor enforcement remain separate authenticated evidence.

## Primary Google Contracts

- Compute v1 BackendBuckets, SecurityPolicies, SslPolicies and
  TargetHttpsProxies resources.
- Certificate Manager v1 DnsAuthorizations, Certificates, CertificateMaps and
  CertificateMapEntries resources.
- Cloud CDN cache and Cloud Armor edge-security behavior.
