# GCP Container Platform

Ziac M72 manages GKE, Fleet, Cloud Run functions v2 and Google Cloud Batch
through typed declarations, handwritten lifecycle adapters and components that
compile identity and topology into the resource graph.

## Managed Resources

- `gcp.container.Cluster`
- `gcp.container.NodePool`
- `gcp.gkehub.Fleet`
- `gcp.gkehub.Membership`
- `gcp.functions.FunctionV2`
- `gcp.functions.FunctionIamMember`
- `gcp.batch.Job`

The adapters use Container operations for GKE and Google long-running
operations for Fleet, Functions and Batch. Standard GKE creation removes the
implicit default node pool so every node pool in the resulting cluster has a
typed Ziac owner. Cluster and node-pool updates select the native Google action
for the changed field; Batch jobs replace because a submitted job is immutable.

## Components

`ziac.gcp.GkePlatform` creates a dedicated service account, a Standard or
Autopilot cluster, typed Standard node pools, optional Fleet registration and
exact Workload Identity IAM members. Autopilot rejects node pools at compile
time. The component never manages Kubernetes objects or exports credentials.

`ziac.gcp.ZigFunction` creates a source-backed function and its identity.
Invoker access is an explicit additive IAM member; public invocation is never
implicit. `ziac.gcp.ZigBatchJob` creates a dedicated runtime identity and an
immutable container execution.

Components do not hide broad project roles. Build, runtime and service-agent
permissions remain visible in the graph or are supplied by the platform owner.

## Estate And Canvas

Cloud Asset Inventory can classify and adopt these official asset types:

- `container.googleapis.com/Cluster`
- `container.googleapis.com/NodePool`
- `gkehub.googleapis.com/Fleet`
- `gkehub.googleapis.com/Membership`
- `cloudfunctions.googleapis.com/CloudFunction`

The current Cloud Asset catalog does not expose Batch jobs. Canvas artifacts
still render Ziac-managed Batch executions and show node-pool, Fleet membership,
runtime identity, Workload Identity and event-trigger relationships.

## Permissions And Costs

Permission synthesis emits exact `container.clusters.*`,
`gkehub.fleet.*`, `gkehub.memberships.*`, `cloudfunctions.functions.*` and
`batch.jobs.*` permissions, plus `iam.serviceAccounts.actAs` only where an
identity is wired into a workload.

Configuration estimates keep GKE management, node CPU and memory, Function
invocation/CPU/memory and Batch CPU/memory dimensions separate. Batch has no
service premium. These figures are estimates, not Cloud Billing export data.

## Qualification

`scripts/qualify-container-platform.sh` is the authenticated boundary. It
requires ADC, an explicitly disposable project, a customer-owned qualification
stack and exact probe names. It must observe a running GKE cluster, ready Fleet
membership, active and invokable function, successful Batch execution,
second-state no-op import and complete cleanup before emitting
`authenticated=true`.

Without that environment it exits `77` with a structured skip. Deterministic
tests cover the same create, checkpoint, read, import, no-op and cleanup
contracts without claiming cloud evidence.
