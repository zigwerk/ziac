# Ziac Spanner, Memorystore, And Private Connectivity Design

Date: 2026-07-13
Milestone: M66
Status: Approved for implementation

## Objective

Make globally distributed relational storage, low-latency caches, and their
private network dependencies usable through Ziac's three provider layers:

1. typed low-level resources;
2. hardened Google lifecycle adapters;
3. opinionated components with compile-time graph validation.

The implementation uses pinned GA Discovery contracts and keeps every network
mutation visible in the desired graph.

## Contract Provenance

The implementation pins these GA Discovery documents:

- `spanner:v1`, revision `20260622`, SHA-256
  `6e97664d011e3f3e91b19f654a926e4977270cbea2351e94c2cb45896502d5d1`;
- `redis:v1`, revision `20260707`, SHA-256
  `600495e7c28025e4af8a2d83067a0ded935c55a96acaa67ed9128e584b6646a2`;
- `servicenetworking:v1`, revision `20260622`, SHA-256
  `d845894da9ed689b1b76e80a570c105834b3dcd89670f389ba5d0d147ea3575f`.

All three documents are fetched from their service-owned `$discovery` URLs.

## Managed Surface

### Spanner

- `gcp.spanner.Instance`
- `gcp.spanner.Database`
- `gcp.spanner.Backup`
- `gcp.spanner.BackupSchedule`
- `gcp.spanner.InstanceIamMember`
- `gcp.spanner.DatabaseIamMember`

Instance capacity is a tagged union: fixed nodes, fixed processing units, or
managed autoscaling. Fixed processing units are validated against Google's
100-unit and 1000-unit increments. Autoscaling requires Enterprise or
Enterprise Plus and carries explicit min/max and CPU/storage targets.

Database creation owns dialect, initial DDL, optional CMEK, version retention,
default leader, and drop protection. Subsequent DDL is submitted through
`databases.updateDdl`; the provider records normalized server DDL so a refreshed
no-op plan is deterministic. Destructive schema intent remains visible as DDL,
not inferred by Ziac.

Backups own an RFC 3339 expiry and optional CMEK. Backup schedules own cron,
retention, full versus incremental mode, and optional CMEK. Data-bearing
resources default to protect and retain.

Spanner IAM resources use additive etag-safe policy mutation at instance and
database scope. They never own unrelated bindings or members.

### Memorystore

- `gcp.redis.Instance`
- `gcp.redis.Cluster`
- `gcp.redis.AclPolicy`

Classic Redis owns tier, memory, version, network mode, AUTH, TLS, replicas,
persistence, CMEK, maintenance, and sorted Redis configuration. It can use
direct peering or private services access, but PSA must be represented by an
explicit graph dependency.

When AUTH is enabled, the declaration must provide a Secret Manager secret.
The provider immediately writes Google's generated auth value as a new version,
zeroes transient plaintext buffers, and stores only a secret reference in Ziac
state. A failed persistence step records a redacted recovery identity.

Redis Cluster owns shards, replicas, node type, PSC consumer network, AUTH,
TLS, persistence, CMEK, deletion protection, ACL policy, maintenance, and
sorted Redis configuration. Cluster networking uses the API's native PSC
automation and does not depend on a Service Networking peering connection.

ACL policy rules are canonicalized before hashing. Cluster references to an ACL
policy create a graph edge and wait for policy readiness.

### Private Services Access

- `gcp.compute.PrivateServiceRange`
- `gcp.servicenetworking.Connection`

The private service range is a Compute global internal address with
`purpose=VPC_PEERING`, a prefix length, and an explicit VPC network. The
Service Networking connection owns the producer service and the complete set of
reserved range names. Updates use the API's patch operation; deletion is
protected and retained by default because removing shared peering can strand
unrelated managed services.

## High-Level Components

`PrivateServiceAccess` composes the range and connection and exposes the
connection name and network as typed public outputs.

`SpannerDatabase` composes one instance, one database, optional backup schedule,
optional on-demand backups, and exact additive instance/database IAM. It exposes
the canonical database name and never creates application credentials.

`MemorystoreCache` is a tagged component:

- classic Redis requires an explicit network and, when using private services
  access, an explicit connectivity output;
- Redis Cluster requires exactly one PSC network and optionally composes an ACL
  policy;
- both expose typed host/port or discovery endpoint outputs and reject mixed
  classic/cluster settings.

## Lifecycle And Drift

All create, update, and delete operations checkpoint Google LRO names and can
resume through `OperationContext.operation_handle`. Reads normalize Google
defaults, unordered maps, and output-only fields before hashing.

Replacement boundaries are explicit:

- Spanner instance and database identity, instance config, database dialect,
  and database encryption are replacement inputs;
- backup source, schedule parent, Redis location/network/connect mode, Redis
  tier, Redis Cluster PSC network, and CMEK are replacement inputs;
- capacity, labels, DDL, expiry, retention, Redis size/configuration,
  persistence, maintenance, and deletion protection are mutable where the GA
  API supports them.

Data deletion requires both Ziac destructive authority and disabled Google-side
drop/deletion protection. Retain/protect defaults are never silently relaxed.

## Product Integration

The milestone also synchronizes:

- provider catalog and pinned Discovery provenance;
- API and deployer/runtime IAM synthesis;
- Cloud Asset identity mapping and observed/managed reconciliation;
- canvas topology, private network, database, backup, cache and IAM edges;
- configuration-estimate cost inputs for Spanner compute/storage/backup and
  Memorystore capacity;
- installed examples, agent documentation, and an authenticated disposable
  project qualification runner.

## Qualification

Local deterministic tests cover declaration validation, request/response
normalization, LRO resume, import, refresh/no-op, update, protection, retain and
destroy behavior. A remote qualification runner must create a disposable
private network, prove Spanner SQL and Redis PING data paths, import into a
second state, require a refreshed no-op, and clean up under explicit destructive
authority. Without ADC, required CLIs, or a project ending in
`-ziac-disposable`, it exits 77 with a structured skip.
