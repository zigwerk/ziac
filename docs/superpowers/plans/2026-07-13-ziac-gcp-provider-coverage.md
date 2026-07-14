# Ziac Comprehensive GCP Provider Coverage Plan

Date: 2026-07-13
Design: `docs/superpowers/specs/2026-07-13-ziac-gcp-provider-coverage-design.md`

## Delivery Rules

- Implement one complete vertical slice before opening the next service family.
- Add deterministic failing declaration and provider lifecycle tests first.
- Reuse pinned Google proto or Discovery contracts; do not hand-copy API paths
  when normalized descriptor metadata exists.
- Keep low-level primitives public and build high-level components from them.
- Never mark authenticated qualification complete without a disposable-project
  receipt.
- Keep generated code, provider catalog, estate mapping, visual mapping and
  installed agent documentation synchronized.

## M56: Provider Catalog And Generation Spine

- [x] Audit current live provider dispatch and distinguish managed resources
  from observed-only Cloud Asset kinds.
- [x] Add `gcp/coverage.zig` with service family, scope, support stage,
  capability flags, milestone and contract provenance.
- [x] Register every currently managed GCP resource.
- [x] Add planned entries for M57-M61 so agents can explain unsupported gaps.
- [x] Reject duplicate type names and invalid capability/stage combinations.
- [x] Verify every managed catalog entry is accepted by the live provider.
- [x] Add a reverse dispatcher-to-catalog generation check so an implemented
  live type cannot be omitted from the catalog.
- [x] Emit deterministic JSON and Markdown reference artifacts.
- [x] Add `ziac provider resources [--service <name>] [--json]`.
- [x] Include the catalog in the relocatable installation and generated skills.
- [x] Add pinned proto/Discovery descriptor provenance and semantic diff output.

M56 evidence: `zig build test --summary failures` completed with the Testing v2
`ziac-tests` receipt reporting 491 discovered and executed, 490 passed, one
credential-gated skip, and zero failures, pending tests, leaks or logged errors.
The scaffold E2E gate installed Ziac into fresh repositories and queried the
installed catalog without project state or Google credentials.

Gate: installed Ziac reports the exact managed and planned GCP surface, and CI
fails when implementation, documentation and catalog disagree.

## M57: General Cloud Storage

### Primitive declaration

- [x] Add typed `Bucket` arguments and outputs.
- [x] Validate bucket names, location, storage class, retention, soft-delete,
  single delete TTL and KMS key names.
- [x] Add typed multi-rule lifecycle transitions and CORS policy.
- [x] Keep identity fields immutable and ordinary policy fields updateable.
- [x] Add explicit retain/delete lifecycle choices; default to retained.
- [x] Add additive `BucketIamMember` without IAM conditions in the first slice.
- [x] Add optional IAM conditions to `BucketIamMember`.
- [x] Add a general immutable/uploaded `Object` after bucket lifecycle closure.

### Live provider

- [x] Create/read/update/delete general buckets through Cloud Storage JSON API.
- [x] Normalize location casing and managed server defaults.
- [x] Use metageneration preconditions for mutable bucket changes.
- [x] Fail deletion of non-empty buckets without force-cleanup authority.
- [x] Implement import from `buckets/<name>` and `gs://<name>`.
- [x] Implement etag-safe additive IAM policy updates without owning unrelated
  bindings or members.
- [x] Preserve the specialized retained `BuildBucket` behavior.

### Product integration

- [x] Map managed/observed bucket identities in estate reconciliation.
- [x] Add storage-class, region, retention, soft-delete and IAM details to the
  visual artifact and inspector.
- [x] Add configuration-based storage/operations/egress cost assumptions.
- [x] Generate official-doc references and agent examples.
- [x] Add `AssetBucket`, `UploadBucket` and `StaticAssetBucket` components.
- [ ] Run authenticated create/update/import/no-op/delete qualification.

Gate: a user can manage a normal application bucket and additive access policy
without using the build-bucket abstraction or causing unrelated IAM drift.

## M58: Pub/Sub

- [x] Topic CRUD/import with labels, KMS and retention.
- [x] Schema CRUD/import and topic schema settings.
- [x] Subscription CRUD/import for pull and push, including ack deadline,
  retention, expiration, ordering, filter, retry and dead-letter policy.
- [x] Snapshot CRUD/import.
- [x] Topic/subscription additive IAM and service-agent permission preflight.
- [x] Pub/Sub cost assumptions, estate mapping, topology and event edges.
- [x] `ZigSubscriber` component with Cloud Run OIDC push, dead-letter topic,
  runtime identity and exact invoker/publisher permissions.
- [ ] Authenticated publish, delivery, retry and cleanup qualification.

M58 local evidence: typed resources, the Pub/Sub and Cloud Run IAM lifecycle
adapters, `ZigSubscriber`, graph-derived preflight, estate/cost/visual mappings
and official icon packaging pass deterministic tests. `gcp.run.ServiceIamMember`
uses v2 service IAM with policy version 3, etags and bounded conflict retries.
The remaining item requires ADC and a disposable billing-enabled GCP project;
local evidence is not promoted to authenticated delivery proof.

Latest local gate: the Testing v2 `ziac-tests` receipt is complete with 518
discovered and executed tests, 517 passed, one credential-gated skip, and zero
failures, pending tests, leaks or logged errors.

Gate: one typed component deploys a Zig event consumer and proves authenticated
delivery and dead-letter behavior.

## M59: Cloud Tasks And Eventarc

- [x] Cloud Tasks Queue CRUD/import with rate, retry and routing controls.
- [x] Eventarc Trigger CRUD/import with event filters, channels, destinations,
  service identity and transport topic ownership.
- [x] OIDC/OAuth target identity and least-privilege IAM synthesis.
- [x] `ZigTaskWorker` and `EventPipeline` components.
- [x] Deterministic retry, duplicate-delivery and cancellation scenarios.
- [ ] Authenticated enqueue/event delivery and cleanup qualification.

M59 local evidence: 45 managed resources now include Cloud Tasks Queue, exact
Queue IAM and Eventarc Trigger. Deterministic lifecycle tests cover create,
normalized read/diff, update, import, etag-safe IAM mutation, resumable Eventarc
operations and explicit deletion. Cost, Cloud Asset, canvas, RPC and permission
synthesis contracts are synchronized with `ZigTaskWorker` and `EventPipeline`.
The authenticated gate remains open because no disposable billing-enabled GCP
project or ADC is available in this environment.

Latest local gate: the Testing v2 `ziac-tests` receipt is complete with 538
discovered and executed tests, 537 passed, one credential-gated skip, and zero
failures, pending tests, leaks or logged errors.

Gate: asynchronous HTTP work and Google-originated events can be provisioned,
observed and debugged without manual IAM assembly.

## M60: Cloud Run Workload Completion

- [x] Job CRUD/import with containers, tasks, parallelism, retries, timeout,
  VPC, secrets, volumes, service identity and GPU controls.
- [x] Governed job execution and cancellation actions with execution receipts.
- [x] WorkerPool CRUD/import with revision rollout and instance split semantics.
- [x] `ZigJob`, `ScheduledZigJob` and `ZigWorkerPool` components.
- [x] Workload-specific receipts, cost models, canvas shapes and status.
- [ ] Authenticated migration job, parallel job and worker rollout qualification.

M60 local implementation includes 48 managed catalog resources, pinned Cloud
Run v2 RPC paths, resumable LROs, etag-safe Job IAM, OAuth Scheduler targets,
explicit execution authority, graph-derived preflight, CAI identity, separate
canvas groups and configuration estimates. The authenticated gate remains open
because local scripted evidence is not live Google Cloud proof.

Latest local gate: the Testing v2 `ziac-tests` receipt is complete with 564
discovered and executed tests, 563 passed, one credential-gated skip, and zero
failures, pending tests, leaks or logged errors. The dashboard's 54 tests,
typecheck and production build also pass.

Gate: services, jobs and worker pools all use the shared typed Cloud Run contract
while preserving workload-specific lifecycle semantics.

## M61: General IAM Foundation

- [x] Add explicit additive member, authoritative binding and authoritative
  policy resource families.
- [x] Add IAM conditions and canonical principal validation.
- [x] Add project, folder, organization, service-account and common resource IAM.
- [x] Add custom roles and Workload Identity Federation pools/providers.
- [x] Derive deployer and runtime permission sets from graph operations.
- [x] Preflight `testIamPermissions`, service agents, organization policy and VPC
  Service Controls where available.
- [x] Render permission edges and ownership mode in the canvas.
- [x] Qualify concurrent unrelated IAM edits without policy loss in deterministic
  concurrent transport tests.

M61 is locally complete with 62 managed resources. IAM authority is explicit at
member, binding or policy scope; custom roles and workload federation recover
from Google soft deletion; permission plans separate deployer and runtime
authority; and Cloud Asset identities plus workbench blast-radius metadata are
synchronized. Project/folder/organization live qualification remains external.

Gate: Ziac plans make IAM ownership explicit and cannot silently overwrite an
unowned member or binding.

## M62: First-Tranche Integrated Qualification

- [ ] Provision all required APIs and service agents in a fresh project.
- [x] Compile upload bucket, topic/subscription, task queue, event trigger,
  scheduled Zig job and Cloud Run subscriber/worker as one owned graph.
- [x] Verify application Env/resource bindings at comptime.
- [ ] Exercise uploads, events, retries, job execution and logs.
- [x] Import the full graph into a second deterministic state and require a
  refreshed no-op plan.
- [x] Render managed topology with IAM edges and configuration-estimate cost
  provenance.
- [x] Delete under explicit destructive authority and prove retained resources
  remain at the provider boundary.
- [x] Publish a redacted local qualification receipt and a fail-closed remote
  qualification runner.

M62 local evidence composes more than twenty resources through the public
high-level component boundary, then applies, imports, refreshes, plans and
destroys the graph under the testing allocator. The local receipt is always
`authenticated=false`; the remote runner emits a structured skip when ADC,
tools or disposable-project configuration is absent. The two unchecked items
require a real billing-enabled project and application image that records the
delivery probe IDs.

Gate: the first tranche works together as one real application platform, not as
isolated serializer tests.

## M63-M67: Data And Application Services

- [x] M63 BigQuery: Dataset, Table, View, Routine, Connection, Reservation, IAM.
- [x] M64 Firestore: Database, Index, Field, BackupSchedule, IAM.
- [x] M65 Cloud SQL: Instance, Database, User, replica, private IP, SSL and IAM.
- [x] M66 Spanner and Memorystore primitives plus private connectivity.
- [x] M67 Workflows, API Gateway, Identity Platform and Parameter Manager.

## M68-M72: Compute, Network And Container Platform

- [x] M68 Compute instance, disk, image, template and managed instance group.
- [x] M69 firewalls, routes, health checks, regional/internal load balancing.
- [x] M70 Cloud CDN, backend buckets, Cloud Armor and Certificate Manager.
- [x] M71 VPN, HA VPN, peering, Network Connectivity Center and service networking.
- [x] M72 GKE clusters, node pools, fleets, workload identity, Functions v2 and
  Batch.

## M73-M76: Operations And Delivery

- [ ] M73 Monitoring alerts, uptime checks, channels, dashboards and SLOs.
- [ ] M74 Logging sinks, buckets, views, exclusions and log metrics.
- [ ] M75 Cloud Build triggers/connections/worker pools and Artifact policies.
- [ ] M76 Cloud Deploy pipelines, targets and automation.

## M77-M80: Security, Governance And Organization

- [ ] M77 KMS IAM/version lifecycle, Secret Manager replication/rotation/IAM.
- [ ] M78 folders, projects, billing association, service identities and liens.
- [ ] M79 organization policy, tags, access policies and VPC Service Controls.
- [ ] M80 Security Command Center, Binary Authorization and CA Service.

## M81+: Analytics, Integration And AI

- [ ] Prioritize stable provisioning resources from Dataflow, Dataproc, Dataform,
  Eventarc Advanced, Integration Connectors and Vertex AI using estate telemetry
  and user requests.
- [ ] Keep preview resources opt-in and attach explicit migration policy.
- [ ] Continue descriptor-driven expansion until every supported public GCP
  resource is either managed, intentionally observed-only, or carries a visible
  exclusion reason.

## M68 Evidence

M68 is locally complete with 123 managed resources. Nine Compute workload
types cover zonal and regional disks, images, instances, immutable templates,
zonal and regional managed instance groups, and zonal and regional
autoscalers. The provider checkpoints operations at all three Compute scopes,
grows disks through native resize, uses fingerprint-safe group updates,
normalizes remote label drift, resolves digest-pinned startup scripts only in
mutation scope, and clears instance deletion protection before deletion.

`VirtualMachine` and tagged `ManagedInstanceFleet` provide the opinionated
layer. Exact deployer/runtime permissions, supported Cloud Asset identities,
canvas metadata, explicit configuration estimates, installed documentation and
the fail-closed qualification runner are synchronized. The Testing v2 gate
reports 688 discovered/executed tests, 687 passed, one credential-gated skip,
and zero failures, pending tests, leaks or logged errors. The full release gate,
all public examples, migration guard and root typecheck pass. Authenticated
qualification remains a disposable-project gate and is not represented as
local proof.

## M69 Evidence

M69 is locally complete with 132 managed resources. Nine network-delivery
types cover explicit firewall and route policy, global and regional health
checks, internal addresses, regional backends, regional URL maps and HTTP
proxies, and immutable regional forwarding rules. The provider checkpoints
global and regional operations, uses current fingerprints for mutable policy,
retries bounded 412 conflicts and keeps route, VIP and frontend replacement
boundaries explicit.

`NetworkPolicy`, `InternalPassthroughLoadBalancer` and
`RegionalInternalApplicationLoadBalancer` provide the opinionated layer
without hidden ingress, routes or proxy-only subnet creation. Exact regional
Compute permissions, property-aware Cloud Asset adoption, private-traffic and
health-probe canvas edges, explicit configuration estimates, installed
documentation and the fail-closed qualification runner are synchronized. The
Testing v2 package gate reports 703 discovered/executed tests, 702 passed, one
credential-gated skip, and zero failures, pending tests, leaks or logged
errors. Authenticated backend health and private probes remain a disposable-
project gate and are not represented as local proof.

## M71 Evidence

M71 is locally complete with 149 managed resources. Nine connectivity types
cover HA and external VPN gateways, VPN tunnels, router interfaces and BGP
peers, VPC peering, Network Connectivity Center hubs and spokes, and Private
Service Connect service-connection policies. The provider resumes Compute and
generic operations, resolves VPN secrets only in mutation scope, preserves
unowned router children under fingerprint-safe retries, and uses native
peering actions plus NCC etags and field masks.

Four opinionated components provide HA VPN, bidirectional peering, VPC mesh and
PSC policy without hiding ownership. Exact API and IAM synthesis, supported
Cloud Asset identities, canvas topology, explicit configuration estimates,
installed documentation and the fail-closed qualification runner are
synchronized. The Testing v2 package gate reports 737 discovered/executed
tests, 736 passed, one credential-gated skip, and zero failures, pending tests,
leaks or logged errors. Authenticated tunnel, route and NCC qualification
remains a disposable-project gate and is not represented as local proof.

## M72 Evidence

M72 is locally complete with 156 managed resources. Seven container-platform
types cover Standard and Autopilot GKE clusters, explicit node pools, Fleet and
membership registration, Cloud Run functions v2 with additive IAM, and
immutable Batch jobs. Standard cluster creation removes Google's implicit
default node pool, Container mutations select native update actions, and Fleet,
Functions and Batch operations checkpoint and resume through their respective
Google operation protocols.

`GkePlatform`, `ZigFunction` and `ZigBatchJob` compose dedicated identities and
typed workload wiring without hidden broad project roles. Exact permission
synthesis, supported Cloud Asset identities, canvas topology, explicit
configuration estimates, installed documentation and the fail-closed
qualification runner are synchronized. The Testing v2 package gate reports 759
discovered/executed tests, 758 passed, one credential-gated skip, and zero
failures, pending tests, leaks or logged errors. Public examples, migration,
root TypeScript and static secret gates pass. Authenticated GKE, Fleet,
Function and Batch qualification remains a disposable-project gate and is not
represented as local proof.
