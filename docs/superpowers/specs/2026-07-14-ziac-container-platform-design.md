# Ziac M72 Container Platform Design

Date: 2026-07-14
Status: approved for implementation by the provider-coverage roadmap
Roadmap: `docs/superpowers/plans/2026-07-13-ziac-gcp-provider-coverage.md`

## Objective

Make GKE, Fleet, Cloud Run functions v2 and Google Cloud Batch useful through
the same three-layer provider model as the preceding GCP tranches:

1. typed low-level declarations that mirror stable Google contracts;
2. handwritten lifecycle adapters for operations, drift, import and safety;
3. opinionated components that compile application intent, identity and
   topology into a reviewable graph.

M72 adds seven managed resource types:

- `gcp.container.Cluster`
- `gcp.container.NodePool`
- `gcp.gkehub.Fleet`
- `gcp.gkehub.Membership`
- `gcp.functions.FunctionV2`
- `gcp.functions.FunctionIamMember`
- `gcp.batch.Job`

Workload Identity Federation for GKE is not represented as a fictional Google
resource. It is compiled from the cluster workload pool, Kubernetes namespace
and service account into an existing additive
`gcp.iam.ServiceAccountIamMember` with
`roles/iam.workloadIdentityUser`.

## Contract Sources

The implementation pins the exact Discovery documents used to design and test
the adapters:

| API | Revision | SHA-256 |
| --- | --- | --- |
| Container v1 | `20260630` | `a9af9378a7849d351c538136e06d3006ca6dec81c89f9ef22b2198981a332312` |
| GKE Hub v1 | `20260706` | `b939847af952d89c80f6f4e3dd76e7bdbe1c6078e04c99b7faa0cc97f03ba573` |
| Cloud Functions v2 | `20260709` | `8c0b2977432d0c8ce30afee8f891b5a494585839de086b2e0c6bb7660150a19b` |
| Batch v1 | `20260702` | `a1d4bccc0c316e9de358a7289fffcd91fb29dbc6b44bf3f9a1e10b9474440296` |

These are Google Discovery contracts, not generated Terraform schemas. Provider
upgrades must produce a semantic provenance diff before changing the pin.

## Typed Declarations

### GKE

`Cluster` is a location-scoped declaration with an explicit `autopilot` or
`standard` mode. It models VPC-native IP allocation, private nodes and control
plane access, release channel, Workload Identity pool, logging/monitoring,
Binary Authorization, labels and deletion protection. The provider never
exports master credentials or kubeconfig data. Public outputs are limited to
the canonical resource name, endpoint, CA certificate digest-safe metadata,
status and workload pool.

`NodePool` is valid only for Standard clusters. It models machine, image, disk,
service identity, locations, Spot policy, autoscaling, repair/upgrade and node
count. Cluster identity, location and pool name are immutable. Size,
autoscaling and mutable node configuration use their native Container methods;
the adapter performs one checkpointable mutation at a time and converges on a
subsequent plan.

### Fleet

`Fleet` owns the project fleet at `projects/{project}/locations/global/fleets`.
`Membership` registers a GKE cluster through `endpoint.gkeCluster.resourceLink`.
Both use generic Google long-running operations, update masks and canonical
imports. Their current resource schemas do not expose etags. Fleet membership
never receives a kubeconfig or Connect gateway credential.

### Cloud Run Functions v2

`FunctionV2` supports storage-backed source, typed runtime and entry point,
HTTP or Eventarc trigger, build/runtime service identities, public and Secret
Manager environment variables, VPC egress, concurrency, min/max instances,
memory, CPU, timeout, ingress, KMS and labels. Secret values are represented by
Secret Manager coordinates and are never resolved into Ziac state.

`FunctionIamMember` owns one additive function IAM member and preserves policy
etags and unrelated bindings. Public HTTP access is explicit; components never
grant it implicitly.

### Batch

`Batch.Job` models one immutable execution: container runnable, command,
variables, Secret Manager variable URIs, task count and parallelism, retry and
run duration, machine/provisioning model, service identity, network/subnetwork,
Cloud Logging, priority and labels. Batch has no service premium, so cost
estimates attribute only the declared Compute resources. Job changes replace;
deletion and cancellation remain separately authorized operations.

## Lifecycle And Recovery

Container operations use
`projects/{project}/locations/{location}/operations/{operation}` and complete
only when `status == DONE`; embedded Google status errors fail the operation.
Fleet and Functions use generic `google.longrunning.Operation` polling. Batch
creation returns a Job synchronously while delete/cancel return generic LROs.

Every create/update/delete returns or consumes a durable operation handle.
Reads after resume poll first, then normalize only declared mutable fields and
Google defaults. Canonical physical IDs are recomputed from typed identity and
noncanonical imports fail closed.

Cluster updates use `ClusterUpdate` for release channel, authorized networks,
Workload Identity, logging, monitoring and Binary Authorization, and
`setResourceLabels` with the current label fingerprint for labels. Network,
subnetwork, mode, private master range and IP allocation identities replace.
Node pools select native `setSize`, `setAutoscaling` or `update` from the
semantic diff. Fleet, Membership and Function use field masks; Function IAM
policy mutation uses the current policy etag. Batch jobs are immutable.

## Components

`GkePlatform` composes:

- a dedicated Google service account;
- one Autopilot cluster or Standard cluster plus typed node pools;
- an optional project Fleet and GKE membership;
- zero or more Kubernetes-service-account Workload Identity bindings.

`ZigFunction` composes runtime identity, source-backed Function v2 and optional
explicit invoker IAM. `ZigBatchJob` composes runtime identity and an immutable
Batch execution. Components expose graph outputs and dependencies without
hiding ownership or granting broad project roles.

## Product Integration

Permission synthesis emits exact Container, GKE Hub, Functions and Batch
methods plus `iam.serviceAccounts.actAs` only when graph wiring requires it.
Runtime permissions remain separate from deployer permissions.

Cloud Asset mapping adopts supported `container.googleapis.com/Cluster`,
`container.googleapis.com/NodePool`, `gkehub.googleapis.com/Fleet`,
`gkehub.googleapis.com/Membership` and
`cloudfunctions.googleapis.com/CloudFunction` assets. Batch jobs are observed-only
because the current Cloud Asset catalog does not expose `batch.googleapis.com/Job`.

Canvas artifacts render cluster/fleet, node-pool, function and batch workload
groups with membership, workload-identity, invocation, event and execution
edges. Cost surfaces distinguish configuration estimates from billing data:
GKE management hours and node resources, Functions invocations/compute, and
Batch Compute usage with zero Batch service premium.

## Qualification

Local deterministic qualification proves create, operation resume, read,
normalized no-op, import and retention-aware cleanup across all four APIs. The
authenticated runner requires a disposable project, ADC, source object and
probe image; it enables APIs, provisions one small private cluster, registers
Fleet membership, deploys/invokes a function, runs a Batch job, imports into a
second state, requires no-op, then cleans up. Missing authority exits with a
structured skip and never counts as live proof.

## Non-Goals

- Kubernetes object management, Helm releases and in-cluster secrets.
- GKE Enterprise feature-specific specs, multi-cloud clusters or Connect agent
  credentials.
- Cloud Functions source upload or local archive construction.
- Hiding Batch's execution semantics behind a persistent service abstraction.
- Claiming pricing estimates as actual billed cost.
