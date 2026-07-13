# Ziac Comprehensive GCP Provider Coverage Design

Date: 2026-07-13
Status: accepted direction; M56-M62 first tranche in delivery

## Objective

Ziac must be useful as the primary infrastructure provider for a Google Cloud
developer, infrastructure engineer, or platform team. Cloud Run and global load
balancing remain an opinionated strength, but they are not the provider
boundary. A user must be able to declare, import, plan, manage, inspect, cost,
and visualize the common resources surrounding an application without dropping
into Terraform or an untracked script.

The target is broad practical GCP coverage, followed by systematic expansion
toward the complete public resource surface. Ziac does not need to duplicate
every historical or preview API before it is useful, but unsupported common
resources must be treated as product gaps with visible ownership and delivery
status.

## Product Layers

Every service family can expose three complementary layers.

### Level 1: Google resource primitives

Primitives closely model a Google resource and preserve its important API
semantics. They provide the escape surface required by platform engineers:

- typed Zig arguments and typed outputs;
- canonical Google resource names;
- immutable, required, output-only, etag, field-mask, pagination and long-running
  operation semantics derived from Google contracts;
- create, read, update, delete, diff, import and refresh behavior;
- explicit lifecycle and ownership policy;
- no untyped JSON escape hatch in a normal resource declaration.

### Level 2: Hardened Ziac resources

Hardened resources add safe defaults and cross-resource validation while keeping
the underlying Google controls available. Examples include an encrypted asset
bucket, an authenticated Pub/Sub push subscription, a private Cloud Run job,
and a monitored task queue.

### Level 3: Architecture components

Components compile intent into multiple primitives, bindings, IAM, monitoring,
cost assumptions and topology. Examples include `ZigService`, `ZigJob`,
`ZigSubscriber`, `StaticSite`, `EventPipeline`, and `GlobalDataApi`.

Broad primitive coverage and high-level components are not alternatives. The
primitives make Ziac generally useful; the components are where Ziac can be
materially better than a one-resource-at-a-time provider.

## Coverage Contract

The provider catalog is machine-readable and versioned. Every resource records:

- stable Ziac type name and Google service family;
- API and transport contract source;
- scope: organization, folder, project, global, region, zone, or location;
- support stage: `planned`, `contract`, `managed`, or `qualified`;
- create, read, update, delete, import, IAM, cost, estate and visual capability;
- preview or deprecation status;
- the milestone that owns the next missing capability.

`managed` means deterministic local tests prove the provider lifecycle against
scripted Google responses. `qualified` additionally requires an authenticated,
disposable-project lifecycle receipt. No documentation may call a resource
qualified merely because its request serializer compiles.

The catalog drives generated provider documentation, agent discovery, coverage
reports, roadmap gaps and release checks. A resource type supported by the live
dispatcher but absent from the catalog is a release failure. A catalog entry
marked managed without a lifecycle test is also a release failure.

## Contract And Generation Architecture

Hand-writing hundreds of unrelated REST adapters will not scale and will create
inconsistent drift behavior. Ziac uses one normalized Google resource
descriptor pipeline:

1. Pin `googleapis/googleapis` protobuf descriptors for proto-first services.
2. Pin Google Discovery contracts for supported REST-first services such as
   Compute Engine and Cloud Storage.
3. Normalize methods, resource names, field behaviors, schemas, update masks,
   etags, pagination, LROs and IAM policy surfaces into a Ziac descriptor.
4. Generate typed Zig messages, validation, canonical request construction,
   response normalization and mechanical CRUD adapters.
5. Add a small handwritten policy module for semantic diff, defaults,
   readiness, deletion safety, import identity, cost and topology.
6. Compare descriptor upgrades semantically before generated code changes are
   accepted.

Generated code owns repetition. Handwritten code owns product judgment. A
generic runtime JSON resource is not the public API because it would discard
the compile-time validation that justifies Ziac.

## Lifecycle Semantics

Every managed primitive must define all of the following:

- stable logical and physical identity;
- create collision and adoption behavior;
- normalized observed inputs that do not drift on server defaults;
- update versus replacement fields;
- etag or fingerprint compare-and-swap where Google exposes one;
- deterministic request IDs and resumable LRO checkpoints where supported;
- absence, reconciliation and terminal readiness states;
- deletion preconditions, retention defaults and non-empty resource behavior;
- import parsing and a zero-change import proof;
- redaction for secrets and sensitive outputs.

Destructive child cleanup is never hidden inside ordinary deletion. For example,
deleting a non-empty bucket fails unless an explicitly authorized force-cleanup
workflow owns the object deletion plan.

## Cross-Cutting GCP Capabilities

Resource count alone is not provider completeness. The following capabilities
apply across service families:

- resource-level and project-level IAM members, bindings and policies, including
  conditions and authoritative-versus-additive ownership;
- labels, annotations, tags and organization policy inheritance;
- service enablement, quota, billing, location and organization-policy preflight;
- VPC Service Controls, CMEK and service-agent dependencies;
- import, observed/reference-only resources and selective adoption;
- least-privilege deployer and runtime IAM synthesis;
- configuration estimates, billing attribution and change-based cost deltas;
- Cloud Asset Inventory mapping and dependency inference;
- first-class canvas icons, scope, locality and permission edges;
- official-documentation references for generated agents.

## Current Baseline

The existing provider has a strong but narrow production path. It manages
roughly thirty resource types across:

- Service Usage, service accounts, project IAM, Artifact Registry and Secret
  Manager;
- Cloud Build source/image flow and Cloud Run services;
- VPC, subnetworks, routers, NAT, addresses, serverless NEGs, load-balancer
  resources, managed certificates, DNS and Private Service Connect;
- retained KMS key rings/keys and Cloud Scheduler jobs;
- specialized retained build buckets and content-addressed source objects.

At programme start the baseline lacked a general `gcp.storage.Bucket` and most
messaging, data, compute, operations, security, organization and developer-
platform resources. The first M57 slice now adds the general bucket lifecycle
and additive bucket IAM while the remaining M57 product integrations stay open.
Cloud Asset Inventory can observe more resource kinds than the live provider can
manage; observation must not be presented as provisioning coverage.

## First Tranche: Application Platform Foundation

M56-M62 closes the most common gaps around modern Cloud Run and Zig backends.

### M56 Provider catalog and generation spine

- machine-readable resource catalog and capability status;
- coverage validation and generated reference documentation;
- pinned descriptor provenance and semantic upgrade report contract;
- generated adapter boundary for proto and Discovery resources.

### M57 General Cloud Storage

- `gcp.storage.Bucket` with location, class, versioning, uniform access, public
  access prevention, lifecycle, retention, soft delete, CORS, labels and CMEK;
- additive `gcp.storage.BucketIamMember` with etag-safe policy updates;
- general object metadata/upload support after the bucket lifecycle is stable;
- import, adoption, cost assumptions, estate identity and canvas representation;
- high-level `AssetBucket`, `UploadBucket` and `StaticAssetBucket` components.

### M58 Pub/Sub

- topics, subscriptions, schemas and snapshots;
- push, pull, retry, filtering, ordering, retention and dead-letter policy;
- topic/subscription IAM and service-agent preflight;
- high-level authenticated `ZigSubscriber` with a Cloud Run service, OIDC push,
  dead-letter topic and least-privilege identities.

### M59 Cloud Tasks And Eventarc

- queues with rate, retry and routing controls;
- Eventarc triggers and channels for supported Google event sources;
- OIDC/OAuth targets and exact invoker IAM synthesis;
- high-level `ZigTaskWorker` and `EventPipeline`.

### M60 Cloud Run Workload Completion

- jobs, executions as governed actions, worker pools and revisions as observed
  children;
- task count, parallelism, retries, timeouts, GPU, volumes, VPC and secrets;
- `ZigJob`, `ScheduledZigJob` and `ZigWorkerPool` components;
- workload-specific rollout, logs, cancellation and cost models.

### M61 General IAM Foundation

- project, folder, organization and resource IAM members/bindings/policies;
- conditions, custom roles, service-account IAM and Workload Identity Federation;
- additive and authoritative ownership made explicit in the type name and plan;
- deployer/runtime permission synthesis and permission preflight.

### M62 Integrated Platform Gate

- a fresh external project provisions an upload bucket, event topic,
  authenticated subscriber, task queue, scheduled job and monitored Cloud Run
  workload;
- resources import to a no-op plan, update without unrelated policy churn, render
  in one local canvas and clean up under explicit authority;
- the gate publishes redacted request, LRO, cost and causal receipts.

## Subsequent Coverage Waves

### Data and application services

- BigQuery datasets, tables, views, routines, connections, reservations and IAM;
- Firestore databases, indexes, fields, backups and IAM;
- Cloud SQL instances, databases, users, SSL, replicas and private connectivity;
- Spanner instances, databases, schemas, backups and IAM;
- Memorystore Redis instances/clusters and private networking;
- API Gateway, Identity Platform, Parameter Manager and Workflows.

CockroachDB remains Ziac's preferred global application database, while native
GCP databases remain fully valid provider resources.

### Compute, networking and containers

- Compute instances, disks, images, templates, managed instance groups,
  autoscalers, health checks, firewalls and routes;
- internal and external regional load balancing, Cloud CDN and backend buckets;
- Cloud Armor policies, Certificate Manager and network endpoint groups;
- VPN, HA VPN, Network Connectivity Center, service networking and peering;
- GKE clusters, node pools, fleets, workload identity and supporting IAM;
- Cloud Functions v2 and Batch.

### Operations and delivery

- Monitoring alert policies, uptime checks, notification channels, dashboards
  and service-level objectives;
- Logging sinks, buckets, views, exclusions and log-based metrics;
- Error Reporting and trace-linked diagnostic resources where configurable;
- Cloud Build triggers, connections, worker pools and repositories;
- Cloud Deploy delivery pipelines, targets and automation;
- Artifact Registry formats, cleanup policies and IAM.

### Security, governance and organization

- KMS IAM, key versions and rotation policy;
- Secret Manager replication, rotation, topics and IAM policy coverage;
- folders, projects, billing association, liens and service identities;
- organization policies, tags, access policies and VPC Service Controls;
- Security Command Center notification/configuration resources;
- Certificate Authority Service, Binary Authorization and attestors.

### Analytics, integration and AI

- Dataflow templates/jobs, Dataproc clusters/batches and Dataform repositories;
- Eventarc advanced, Integration Connectors and Application Integration;
- Vertex AI endpoints, indexes, deployments, feature stores and pipelines;
- Document AI, Speech and other resources with durable provisioning surfaces.

Preview services are cataloged but do not become default high-level components
until Google declares an appropriate stability level and Ziac has a migration
policy.

## Resource Definition Of Done

A resource is complete only when it has:

1. typed declaration, validation and outputs;
2. canonical names and dependency-producing output wiring;
3. deterministic CRUD, diff, refresh and replacement tests;
4. import/adoption and a zero-change proof;
5. normalized server defaults, etag/fingerprint and field-mask behavior;
6. provider/API enablement and least-privilege permission metadata;
7. estate discovery identity and ownership behavior;
8. canvas scope, icon, locality and dependency semantics;
9. cost model or an explicit unavailable reason;
10. agent reference, examples and failure repair hints;
11. authenticated disposable-project create/update/import/delete evidence.

The first ten establish `managed`; all eleven establish `qualified`.

## Success Measures

- A representative application platform can remain entirely in Ziac code.
- The CLI can answer exactly which resources and lifecycle capabilities the
  installed version supports.
- Every unsupported resource discovered in an estate names its owning roadmap
  milestone instead of degrading silently.
- Provider contract upgrades produce reviewable semantic diffs.
- At least 80 percent of resources in first-party reference architectures are
  qualified before public beta, then coverage expands by measured user demand.
- High-level components use the same public primitives available to users.
