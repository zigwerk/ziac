# GCP Provider Coverage

Ziac is a broad Google Cloud infrastructure provider with additional
Google-native architecture components. Cloud Run and global routing are a
specialization, not a limit on the resources Ziac intends to manage.

## Coverage Stages

- `planned`: owned by a named roadmap milestone but not yet declarable.
- `contract`: typed Google API contract exists, but lifecycle support is not
  complete.
- `managed`: declaration and deterministic provider lifecycle tests pass.
- `qualified`: an authenticated disposable-project lifecycle receipt also
  passes.

Use `ziac provider resources --json` as the machine-readable contract for the
installed version. Add `--service storage`, `--service cloud-run`, or another
service family to return one slice. Without `--json`, the command emits the same
deterministic catalog as a Markdown table. Observed Cloud Asset Inventory kinds
do not count as managed resources.

The report includes the pinned `googleapis/googleapis` revision, Cloud Run v2
descriptor and normalized snapshot digests, plus dated Compute v1, Cloud DNS v1
and Cloud Storage v1 Discovery revisions and document digests. Proto field
behavior and Discovery source upgrades produce versioned semantic-diff JSON
before a contract lock changes.

## Managed Surface

The current deterministic provider gate contains 181 managed GCP resource types.
Authenticated qualification remains separate and is tracked in the roadmap.
The live dispatcher exports the same sorted type registry, and tests compare it
to the catalog in both directions so provider code and documentation cannot
silently diverge.

### Foundation and identity

- `gcp.project.Service`
- `gcp.iam.ServiceAccount`
- `gcp.iam.ProjectMember`
- `gcp.artifact.Repository`
- `gcp.secret.Secret`
- `gcp.secret.SecretVersion`
- `gcp.secret.SecretIamMember`

### KMS and Secret Manager security lifecycle

M77 hardens eight managed resources across Cloud KMS and Secret Manager. KMS
keys model purpose-compatible algorithms, software/HSM/external protection,
rotation, version state and additive conditional IAM. Secrets model automatic
or regional replication, CMEK, notifications, rotation, aliases, annotations,
safe version state and additive conditional IAM.

Key rings, keys, key versions and secrets are retained by default. Ordinary
reconciliation only performs reversible enable/disable transitions. Scheduling
KMS destruction, restoring a scheduled version and destroying a secret version
are target-bound governed actions with exact capability digests and receipts.
Cloud Asset identities, regional canvas topology, security edges, exact
permission synthesis and explicit configuration estimates are synchronized.
See `gcp-kms-secret-manager.md`.

### Cloud Run and builds

- `gcp.run.Service`
- `gcp.run.ServiceIamMember`
- `gcp.run.Job`
- `gcp.run.JobIamMember`
- `gcp.run.WorkerPool`
- `gcp.cloudbuild.ZigImage`
- `gcp.storage.BuildBucket`
- `gcp.storage.SourceObject`

Jobs and Worker Pools share typed multi-container, identity, Secret Manager,
Direct VPC, CMEK and GPU controls while preserving their distinct lifecycle.
Executions are governed actions with exact capability digests and receipts;
they are not managed resources. `ScheduledZigJob` uses OAuth to call the Google
RunJob API with exact resource IAM. Workload permission synthesis, Cloud Asset
identity, separate 3D canvas groups and explicit compute-duration cost estimates
are synchronized. See `gcp-cloud-run-workloads.md`.

### General Cloud Storage

- `gcp.storage.Bucket`
- `gcp.storage.BucketIamMember`
- `gcp.storage.Object`

`Bucket` covers location, storage class, uniform bucket-level access,
public-access prevention, versioning, soft-delete retention, bucket retention,
typed multi-rule lifecycle transitions, CORS, labels, default CMEK and
metageneration-safe updates. Import accepts `buckets/<name>` or `gs://<name>`.
Buckets are retained by default. Deleting a non-empty bucket reports
`ResourceNotEmpty`; recursive cleanup requires both `force_destroy = true` and
the operation's explicit destructive confirmation.

`BucketIamMember` owns one exact role/member/condition identity. Its etag-safe
read-modify-write preserves unrelated conditional and unconditional bindings,
requests policy version 3 and raises the policy version when a condition is
added. `Object` verifies source size, CRC32C and SHA-256 before immutable media
upload, adopts only generation-pinned identities and uses generation
preconditions for explicit deletion. The specialized `BuildBucket` and
`SourceObject` remain retained and content-addressed.

Estate scans emit the same `buckets/<name>` physical identity used by managed
state. Visual artifacts include bucket location, class, retention, soft-delete,
lifecycle, CORS and IAM inspector facts. Configuration estimates keep storage
capacity, operation count and egress assumptions separate and label the result
as a catalog-price estimate rather than billed cost.

Three higher-level components compile common safe graphs:

```zig
var uploads = try ziac.gcp.UploadBucket.build(allocator, provider, .{
    .name = "acme-uploads",
    .location = "EU",
    .writers = &.{"serviceAccount:api@acme.iam.gserviceaccount.com"},
    .cors_origins = &.{"https://app.acme.example"},
});
defer uploads.deinit();
```

- `AssetBucket` creates a versioned private bucket plus exact readers.
- `UploadBucket` adds object-creator bindings, upload CORS and typed transition
  and deletion lifecycle rules.
- `StaticAssetBucket` creates a versioned static bucket; public access is an
  explicit opt-in that adds only `allUsers` object-viewer access.

Official contracts: [Buckets](https://cloud.google.com/storage/docs/json_api/v1/buckets),
[Objects: insert](https://cloud.google.com/storage/docs/json_api/v1/objects/insert),
[request preconditions](https://cloud.google.com/storage/docs/request-preconditions),
and [conditional bucket IAM](https://cloud.google.com/storage/docs/json_api/v1/buckets/setIamPolicy).
Authenticated disposable-project qualification remains the final open M57
evidence item.

### Pub/Sub

- `gcp.pubsub.Schema`
- `gcp.pubsub.Topic`
- `gcp.pubsub.TopicIamMember`
- `gcp.pubsub.Subscription`
- `gcp.pubsub.SubscriptionIamMember`
- `gcp.pubsub.Snapshot`

The typed surface covers schema revisions, topic schema policy, CMEK, retention,
persistence regions, pull and authenticated push delivery, expiration,
ordering, filtering, exactly-once delivery, retry, dead-letter policy and
snapshots. Exact optional conditional IAM uses policy version 3 and preserves
unrelated bindings.

`ZigSubscriber` composes these primitives around an existing Cloud Run service.
It creates a dedicated OIDC identity and grants only resource-scoped Run
invoker, dead-letter forwarding and explicitly requested publisher access. The
graph preflight synthesizes Pub/Sub, Cloud Run and IAM API permissions. Estate
scans map topic/subscription identity, the canvas renders event edges with the
official Pub/Sub mark, and costs remain explicit configuration estimates.

See `gcp-pubsub.md` for examples, lifecycle semantics and the authenticated
qualification boundary.

### Cloud Tasks and Eventarc

- `gcp.tasks.Queue`
- `gcp.tasks.QueueIamMember`
- `gcp.eventarc.Trigger`

Cloud Tasks queues include normalized rate, retry, routing, logging and
queue-level OIDC/OAuth controls. Exact queue IAM preserves unrelated policy and
uses version 3, etags and bounded conflict retries. Eventarc triggers include
filters, channels, service identity, transport ownership and Cloud Run, GKE,
Workflow or private HTTP destinations with resumable long-running operations.

`ZigTaskWorker` and `EventPipeline` compile the runtime identities, exact Run
invoker and publisher/enqueuer access, queue or trigger and optional transport
resources. Permission synthesis includes both product permissions and service
account act-as. Cloud Asset Inventory identity, regional canvas metadata,
delivery edges and explicit operation/event cost assumptions are synchronized.

See `gcp-tasks-eventarc.md` for lifecycle, deletion tombstone, delivery and
qualification semantics.

### Networking and global delivery

- `gcp.compute.Network`
- `gcp.compute.Subnetwork`
- `gcp.compute.Router`
- `gcp.compute.RouterNat`
- `gcp.compute.RegionalAddress`
- `gcp.compute.PscAddress`
- `gcp.compute.PscEndpoint`
- `gcp.compute.GlobalAddress`
- `gcp.compute.RegionServerlessNeg`
- `gcp.compute.BackendService`
- `gcp.compute.UrlMap`
- `gcp.compute.HttpRedirectUrlMap`
- `gcp.compute.ManagedSslCertificate`
- `gcp.compute.TargetHttpProxy`
- `gcp.compute.TargetHttpsProxy`
- `gcp.compute.GlobalForwardingRule`
- `gcp.dns.ManagedZone`
- `gcp.dns.RecordSet`

### General IAM and federation

- project, folder and organization `Member`, `Binding` and `Policy` resources;
- service-account IAM members and bindings;
- project and organization custom roles;
- Workload Identity Pools and OIDC Providers.

These resources use explicit ownership modes, canonical principals and
conditions, policy-version-3 conditional writes, etag conflict retries and
graph-level overlap validation. Permission intelligence separates deployer from
runtime authority with resource and operation provenance. The native
`testIamPermissions` preflight supports project, folder, organization and
service-account targets. Cloud Asset identity and workbench blast-radius
metadata are synchronized. See `gcp-iam.md` for the safety and recovery model.

### Integrated application platform

`ziac.gcp.ApplicationPlatform` composes Cloud Run, Storage, Pub/Sub, Cloud
Tasks, Eventarc, Scheduler and dedicated identities into one typed application
slice. Its local qualification proves deterministic apply/import/no-op/cleanup;
the separate disposable-project runner preserves the authenticated evidence
boundary. See `gcp-application-platform.md`.

### BigQuery analytics platform

M63 adds 13 managed BigQuery resources across BigQuery v2, Connection v1 and
Reservation v1. `ziac.gcp.AnalyticsWarehouse` composes a retained dataset,
typed tables, views, routines and additive readers/writers. Handwritten
lifecycles provide canonical import, remote drift normalization, method-correct
PATCH/PUT behavior, `If-Match`, field masks, retention guards and commitment
protection.

Permission synthesis separates deployer RPC authority from runtime data access.
Cloud Asset identities, canvas metadata, IAM edge semantics and explicit query,
storage and slot cost assumptions are synchronized. See `gcp-bigquery.md`.

### Firestore document platform

M64 adds five managed Firestore resources: Database, Index, Field,
BackupSchedule and DatabaseIamMember. `ziac.gcp.DocumentStore` composes a
protected database with typed indexes, TTL and index field overrides, daily or
weekly backups, and exact reader/writer access.

The lifecycle adapter resumes Firestore Admin long-running operations,
preserves server-assigned child identities, uses database etags for mutation,
reverts field configuration without deleting data, and normalizes output-only
state before drift comparison. Permission synthesis, supported Cloud Asset
database identity, canvas metadata, IAM edge semantics and explicit operation,
storage and backup estimates are synchronized. See `gcp-firestore.md`.

### Cloud SQL PostgreSQL platform

M65 adds five managed Cloud SQL resources: Instance, ReadReplica, Database,
User and ClientCertificate. `ziac.gcp.ManagedPostgres` composes a protected
PostgreSQL primary, declared databases and identities, optional regional
replicas, exact login/client IAM and a Secret Manager-backed certificate.

The lifecycle adapter resumes SQL Admin operations, uses settings-version
preconditions, normalizes unordered policy fields, preserves write-only secret
references and treats region, engine, allocated range and private-IP removal as
replacement boundaries. Private Services Access is an explicit dependency and
is never synthesized as a hidden side effect. Permission synthesis, Cloud Asset
instance identity, canvas metadata, IAM edges and explicit compute, storage,
backup and egress estimates are synchronized. See `gcp-cloud-sql.md`.

### Spanner and Memorystore data platform

M66 adds eleven managed resources for Spanner instances, databases, backups,
backup schedules and additive IAM; classic Redis, Redis Cluster and secret-safe
ACL policy; and explicit private-service address ranges and connections.

`ziac.gcp.PrivateServiceAccess`, `ziac.gcp.SpannerDatabase` and tagged
`ziac.gcp.MemorystoreCache` expose the opinionated layer without hiding VPC
mutations or mixing classic and cluster settings. Hardened providers resume
LROs, normalize DDL, capacity, maintenance and configuration maps, enforce data
protection and replacement boundaries, and save generated Redis AUTH directly
to Secret Manager.

API and permission synthesis, supported Cloud Asset identities, canvas data and
private-network metadata, runtime IAM edges and explicit configuration cost
assumptions are synchronized. Unsupported Cloud Asset child kinds remain
observed-only. See `gcp-spanner-memorystore.md`.

### Application services

M67 adds eighteen managed resources across Workflows, API Gateway, Identity
Platform and Parameter Manager. `WorkflowProgram`, `ManagedApiGateway`, tagged
`IdentityRealm` and tagged `ParameterBundle` compose orchestration, public API
ingress, customer identity and immutable runtime configuration without hiding
service identities or secret boundaries.

The lifecycle adapters resume Google operations, normalize remote state, use
etags and update masks, protect the project identity singleton and prove API
document and payload digests before mutation. Permission synthesis, supported
Cloud Asset identities, canvas metadata, runtime IAM edges and explicit
Workflows/API Gateway/Identity usage estimates are synchronized. Unsupported
Parameter Manager template assets remain observed-only. See
`gcp-application-services.md`.

### Compute workloads

M68 adds nine managed Compute Engine workload resources:

- `gcp.compute.Disk`
- `gcp.compute.RegionDisk`
- `gcp.compute.Image`
- `gcp.compute.Instance`
- `gcp.compute.InstanceTemplate`
- `gcp.compute.InstanceGroupManager`
- `gcp.compute.RegionInstanceGroupManager`
- `gcp.compute.Autoscaler`
- `gcp.compute.RegionAutoscaler`

`VirtualMachine` composes explicit retained storage and one VM. Tagged
`ManagedInstanceFleet` composes an immutable template, zonal or regional
managed group and matching autoscaler. The lifecycle adapter checkpoints
global, regional and zonal Compute operations, uses native disk resize and
managed-group fingerprints, normalizes remote label drift, and keeps startup
script bytes behind a digest-pinned secret boundary.

Permission synthesis includes exact disk, image, instance, template, group,
autoscaler, network and service-account authority. Supported Cloud Asset
identities, canvas metadata and explicit CPU, memory, accelerator, disk and
image configuration estimates are synchronized. See
`gcp-compute-workloads.md`.

### Network delivery

M69 adds nine managed Compute networking resources:

- `gcp.compute.Firewall`
- `gcp.compute.Route`
- `gcp.compute.HealthCheck`
- `gcp.compute.RegionHealthCheck`
- `gcp.compute.InternalAddress`
- `gcp.compute.RegionBackendService`
- `gcp.compute.RegionUrlMap`
- `gcp.compute.RegionTargetHttpProxy`
- `gcp.compute.ForwardingRule`

`NetworkPolicy` composes explicit VPC policy. `InternalPassthroughLoadBalancer`
and `RegionalInternalApplicationLoadBalancer` compile private L4 and L7 paths
without hidden network mutation. The lifecycle adapter checkpoints global and
regional Compute operations, uses current fingerprints, retries bounded
compare-and-swap conflicts and preserves immutable frontend identity.

Permission synthesis uses exact regional health-check, backend, URL-map and
proxy authority. Property-aware Cloud Asset mapping only adopts addresses and
forwarding rules when their internal scheme is proven. Canvas private-traffic
and health-probe edges and explicit forwarding, data and probe estimates are
synchronized. See `gcp-network-delivery.md`.

### Edge security

M70 adds eight managed global edge resources across Compute and Certificate
Manager: backend buckets, Cloud Armor security policies, SSL policies, DNS
authorizations, managed certificates, certificate maps, map entries and a
certificate-map-aware HTTPS proxy.

`ProtectedCdnBucket` and `ManagedCertificateMap` provide the opinionated layer.
The lifecycle adapters resume Compute and generic Google operations, preserve
canonical AIP identities and retry mutable Compute resources with current
fingerprints. Exact `certs`, `certmaps`, `certmapentries` and
`dnsauthorizations` use permissions are derived from graph wiring.

Cloud Asset adoption proves certificate-map proxy shape from properties.
Canvas cache-origin, security-enforcement, DNS-authorization,
certificate-selection and TLS-policy edges and explicit CDN, Armor and
certificate estimates are synchronized. See `gcp-edge-security.md`.

### Hybrid and cross-network connectivity

M71 adds nine managed connectivity resources across Compute and Network
Connectivity: HA and external VPN gateways, VPN tunnels, Cloud Router
interfaces and BGP peers, reciprocal VPC peering entries, NCC hubs and spokes,
and PSC service connection policies.

`HaVpnConnection`, `BidirectionalVpcPeering`, `VpcConnectivityMesh` and
`PrivateServiceConnectivityPolicy` provide the opinionated layer. VPN secrets
are resolved only for mutation. Router children preserve unowned siblings with
fingerprint retries, peering uses native action methods, and NCC updates use
etags and exact field masks.

Cloud Asset adoption, exact connectivity permissions, VPN/BGP/NCC canvas edges
and explicit VPN tunnel, NCC spoke and data-transfer estimates are
synchronized. See `gcp-connectivity.md`.

### Monitoring and SLOs

M73 adds six managed Cloud Monitoring resources: alert policies, uptime checks,
notification channels, dashboards, services and SLOs. `ServiceObservability`
composes a service-level view, endpoint probe, alerting and dashboard without
hiding notification destinations or SLO policy.

The adapter preserves generated physical IDs, exact update masks and dashboard
etags while keeping channel and probe credentials out of state. Permission
synthesis, official Cloud Asset identities, observability canvas edges and
free-allotment-aware uptime/alert estimates are synchronized. See
`gcp-monitoring.md`.

### Logging storage and routing

M74 adds five managed Cloud Logging resources: protected log buckets,
restricted views, typed sinks, project exclusions and counter or distribution
log metrics. `ApplicationLogPlatform` composes a same-project logging plane
without hiding destination IAM or mutating Google's reserved sinks.

The adapter resumes asynchronous bucket operations, preserves generated sink
writer identities, applies exact update masks and enforces one-way lock,
analytics and immutable metric-schema transitions. Permission synthesis,
supported Cloud Asset identities, canvas routing and derivation edges, and
explicit ingestion, retention and metric estimates are synchronized. See
`gcp-logging.md`.

### Build and artifact delivery

M75 adds six managed resource types and upgrades the existing Artifact
Registry repository contract. Modern Cloud Build coverage includes source
connections, linked repositories, repository-event triggers and private worker
pools. Artifact Registry adds all standard repository formats, canonical
cleanup policies, CMEK and scanning controls, retained project redirection
settings and regional VPC Service Controls configuration.

`ZigBuildPipeline` composes source, private execution, trigger and artifact
storage without hiding SCM credentials or network ownership. The provider
checkpoints Cloud Build long-running operations, applies exact update masks and
etags, treats worker-pool network changes as replacements, preserves
server-generated trigger identity and blocks reversal of finalized Artifact
Registry redirection.

Exact Cloud Build and Artifact Registry permissions, supported Cloud Asset
identities, source/execution/artifact canvas edges and explicit build-minute,
private-disk, storage, transfer and scan estimates are synchronized. See
`gcp-build-delivery.md`.

### Deployment progression

M76 adds delivery pipelines, typed Cloud Run/GKE/Anthos/multi/custom targets,
custom target types, automations and deploy policies. Releases, rollouts,
automation runs and job runs are observed or invoked through governed actions,
not treated as mutable desired state.

`GlobalCloudRunDelivery` composes regional targets, guarded canary progression,
repair automation and production freezes. Lifecycle operations use resumable
Google operations, exact masks, fresh etags and deterministic request IDs.
Release, promotion and recovery actions require payload-bound capabilities.
Exact permissions, managed and observed Cloud Asset identities, delivery canvas
edges and first-free active pipeline pricing are synchronized. See
`gcp-cloud-deploy.md`.

### Security and orchestration

- `gcp.kms.KeyRing`
- `gcp.kms.CryptoKey`
- `gcp.scheduler.Job`

## Next Application-Platform Tranche

M56-M62 adds the provider catalog and generation spine, then completes:

1. general Cloud Storage;
2. authenticated Pub/Sub delivery qualification;
3. Cloud Run jobs and worker pools;
4. general additive and authoritative IAM semantics;
5. one integrated authenticated application-platform qualification.

The subsequent waves cover GKE, Functions, Batch, Monitoring, Logging, Cloud
Deploy, organization governance,
security, analytics, integration and stable Vertex AI resources.

See `roadmap.md` for programme status. The source repository also contains the
full design and checklist at:

- `docs/superpowers/specs/2026-07-13-ziac-gcp-provider-coverage-design.md`
- `docs/superpowers/plans/2026-07-13-ziac-gcp-provider-coverage.md`

## Resource Definition Of Done

A complete resource has typed declarations and outputs, canonical identity,
deterministic CRUD/diff/refresh, import and no-op adoption, normalized server
defaults, compare-and-swap behavior, API/IAM preflight, estate identity, canvas
semantics, honest cost provenance, installed agent documentation and an
authenticated disposable-project receipt.

The first ten local capabilities establish `managed`. Authenticated evidence
establishes `qualified`.
