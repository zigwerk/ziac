# Ziac M76 Cloud Deploy Provider Design

Date: 2026-07-14
Status: accepted for implementation

## Objective

M76 makes Cloud Deploy a first-class continuation of Ziac's source and build
graph. A platform engineer must be able to declare, import, update, inspect and
visualize regional or global Cloud Run and GKE delivery topology without losing
Google's rollout, approval, automation and policy semantics.

The pinned source is the official Cloud Deploy v1 Discovery document, revision
`20260706`, SHA-256
`1ad7831e467cc5aeae81c49bac3726de166d864afa9d68cf3ce558fae1d52e56`.
The API is stable v1 and uses Google long-running operations for durable
configuration mutations.

## Ownership Boundary

Five durable resources are managed:

- `gcp.deploy.DeliveryPipeline`
- `gcp.deploy.Target`
- `gcp.deploy.CustomTargetType`
- `gcp.deploy.Automation`
- `gcp.deploy.DeployPolicy`

Release, Rollout, AutomationRun and JobRun are execution history, not ordinary
desired state. Ziac observes them and exposes governed actions for creating a
release, promoting it, approving or advancing a rollout, rolling a target back,
cancelling a rollout and abandoning a release. Every mutation requires an
action digest and a capability envelope and returns a redacted causal receipt.

This prevents a declarative refresh from promoting production merely because a
child execution resource differs.

## Level 1: Typed Google Primitives

### Delivery pipeline

A pipeline owns an ordered, non-empty serial progression. Every stage contains
an output-aware target reference, Skaffold profiles, deploy parameters and one
typed strategy:

- standard with verify, predeploy and postdeploy actions;
- percentage canary with strictly increasing percentages below 100;
- custom canary with stable phase IDs, percentages and per-phase profiles.

The declaration validates unique target stages and phase IDs, target locality,
percentage order, hook names, labels and descriptions. Suspension is mutable.

### Target

Target kind is a closed union:

- GKE cluster, including private-IP or DNS endpoint selection;
- Fleet/Anthos membership;
- Cloud Run location;
- multi-target containing at least two unique child targets;
- custom target backed by a CustomTargetType output.

Execution environments cover render, deploy, verify, predeploy, postdeploy and
analysis usage. A usage can appear only once. A private Cloud Build worker pool,
service account, artifact location, timeout and verbose logging remain explicit.
Output references create graph dependencies rather than being flattened early.

### Custom target type

Custom targets support Skaffold custom render/deploy actions. The initial stable
surface rejects the newer arbitrary task payload unless it can be represented
as a typed task; no JSON escape hatch is added.

### Automation

Automation is a child of one pipeline and has a user-managed service account,
target selectors and one or more unique rules:

- promote release after success;
- timed promote using a validated five-field cron and IANA time zone;
- advance rollout from selected phases;
- repair failed rollout with bounded retry and optional rollback.

Rules are canonicalized by ID because Google does not define declaration order
as execution order. Automation is suspended by default in the high-level
component until the user explicitly enables it.

### Deploy policy

Deploy policies select pipelines and targets by ID and labels and apply rollout
restrictions by invoker, action and time window. Weekly and one-time windows are
typed, validated and canonical. A policy has at least one selector and one rule.
The resource is retained and protected by default because deletion removes a
production safety boundary.

## Level 2: Hardened Lifecycle

All five resources use canonical names under one project and location. Create,
patch and delete include deterministic request IDs, `validateOnly=false`, exact
changed top-level field masks and the latest etag. Long-running operations are
checkpointed and resumed through the shared Google operation waiter.

Refresh normalizes only writable fields. Output-only UID, timestamps,
conditions and derived state never create drift. Nested maps and orderless rule
sets are canonicalized. Target kind changes and custom-target-type action-kind
changes are replacements; ordinary labels, descriptions, suspension, strategy,
execution configuration, selectors and rules update in place.

Import accepts only canonical full resource names. Automation import includes
its delivery-pipeline parent. A second-state import must refresh to no-op.

Delete is fail-closed:

- pipelines and targets are protected by default;
- custom target types are protected when referenced;
- deploy policies are protected and retained by default;
- automation deletion is ordinary only after explicit lifecycle authority;
- execution history is never recursively deleted by a config resource adapter.

## Level 3: Global Cloud Run Delivery

`GlobalCloudRunDelivery` compiles:

- one Cloud Run target per declared region;
- one ordered delivery pipeline with standard or canary stage policy;
- an optional promotion/advance/repair automation;
- an optional production rollout-restriction policy.

It accepts a base graph so existing Cloud Run services, build artifacts,
service accounts and private worker pools remain visible dependencies. The
component never creates a hidden runtime service, VPC or broad IAM role.

Comptime validation proves region uniqueness, pipeline ordering, target output
wiring, approval placement, canary phase compatibility, automation selector
coverage and policy overlap before preview.

## Governed Release And Rollout Actions

`DeliveryRunner` supports:

1. `create_release` from a GCS Skaffold archive and immutable image artifacts;
2. `promote_release` to the next or named target;
3. `approve_rollout` or rejection with an explicit decision;
4. `advance_rollout` to the next phase;
5. `rollback_target` to a prior release/phase;
6. `cancel_rollout`;
7. `abandon_release`.

The action digest includes stage, project, location, pipeline, release, rollout,
target and immutable source identity. Receipts record Google operation/resource
names, pipeline/target/release/rollout identity, state, approval state, phase,
failure cause, plan digest and timestamps without source credentials or build
payloads.

## Product Integration

Permission synthesis adds exact Cloud Deploy CRUD permissions plus act-as and
runtime release/rollout permissions when graph wiring requires them. Cloud Asset
Inventory maps all five managed types and observes Release, Rollout,
AutomationRun and JobRun without claiming ownership.

The canvas uses delivery-pipeline, deployment-target, automation and policy
metadata with edges for stage progression, target runtime, automation control,
policy guard and observed rollout history. Global Cloud Run stages remain
attached to their regional slabs.

Cost estimates separate active multi-target pipeline fees from Cloud Build
render/deploy minutes, private worker execution, artifact storage and logging.
The first active multi-target pipeline allowance is an explicit input because
Ziac cannot infer billing-account-wide use from one project graph. Estimates
never masquerade as billed cost.

## Qualification

Local deterministic qualification proves create, update, operation resume,
import, refreshed no-op, action authority and cleanup. The local receipt is
always `authenticated=false` and states that no workload was deployed.

The authenticated runner requires ADC, a project ending in
`-ziac-disposable`, a cleanup-enabled stack, immutable release inputs and a real
Cloud Run probe. It must apply configuration, create a release, observe a
successful rollout, exercise guarded progression, import to no-op and clean up
before it can emit a pass. Missing authority produces exit 77 and a structured
skip.

## Definition Of Done

M76 is locally complete when all five resources satisfy the provider definition
of done, governed actions are receipt-backed, `GlobalCloudRunDelivery` compiles,
catalog/estate/canvas/cost/docs are synchronized, the qualification runner is
fail-closed and all credential-free release gates pass.
