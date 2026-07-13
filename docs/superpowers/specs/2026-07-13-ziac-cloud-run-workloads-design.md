# Ziac Cloud Run Workloads Design

## Purpose

Complete Ziac's Cloud Run specialization across request-driven services,
run-to-completion jobs and pull-based worker pools while preserving each
workload's actual Google lifecycle semantics.

## Resource Boundary

- `gcp.run.Job` and `gcp.run.WorkerPool` are managed desired-state resources.
- Cloud Run Executions and WorkerPool revisions are immutable observed children.
- Running a job and cancelling an execution are governed actions, not resource
  creation or deletion in Ziac state.
- `gcp.scheduler.Job` gains an explicit OAuth Google API target mode so a
  schedule can call `Jobs.RunJob` correctly.

This prevents a job run from appearing in an infrastructure plan and prevents
an old immutable Execution from generating drift against its parent Job.

## Typed Workload Model

Jobs and WorkerPools share a typed container model: immutable image references
or resource outputs, command, arguments, environment, CPU and memory. Workload
templates also model secret volumes, direct VPC access, service identity, CMEK,
execution environment and GPU node selection.

Jobs add task count, parallelism, per-task retries and per-attempt timeout.
WorkerPools add manual instance count, revision identity, force-new-revision and
instance splits whose percentages must total 100.

Comptime/declaration validation rejects empty containers, duplicate names and
environment variables, mutable or missing image identities, invalid resource
limits, parallelism greater than task count, invalid GPU controls, malformed
service accounts, duplicate split revisions and split totals other than 100.

## Provider Lifecycle

Both resources use Cloud Run v2 REST transcoding from the pinned Google proto
contract. Create, update and delete are long-running operations. Pending results
persist the Google operation name. Refresh resumes the operation before reading
the canonical resource.

Reads normalize writable Google fields into Ziac's input shape. Output-only
generation, readiness, revisions, executions, conditions and server defaults do
not cause drift. Update bodies preserve etags; WorkerPool updates use an explicit
field mask and optional force-new-revision flag. Delete reads the current etag
before starting a validated LRO.

## Governed Executions

`RunActions` requires a `CapabilityEnvelope`:

- run requires `.apply`, a matching approved action digest and live GCP scope;
- cancel requires `.delete`, a matching approved action digest and the current
  execution etag;
- inspect requires `.read`.

The action digest includes operation, project, stage and canonical resource
name. A receipt records capability id, action digest, Google operation
handle, execution name, counters, timestamps, status, log URI and etag. Payloads
and secrets are not retained.

## Components

- `ZigJob` creates a dedicated runtime service account and private typed Job.
- `ScheduledZigJob` adds a dedicated scheduler identity, exact Job runner IAM and
  an OAuth Cloud Scheduler call to `Jobs.RunJob`.
- `ZigWorkerPool` creates a dedicated runtime identity and a typed WorkerPool
  with guarded revision rollout controls.

Components emit ordinary graphs. Agents can inspect, plan and visualize every
resource and permission before deployment.

## Product Surfaces

Cloud Asset Inventory maps Jobs and WorkerPools to the same physical identities
used by managed state. Visual artifacts identify workload kind, task/instance
scale, image, revision or latest execution and readiness. Cost estimates retain
explicit vCPU, memory, GPU and execution/instance duration assumptions. Execution
receipts expose Cloud Run's log URI without claiming that logs are stored by
Ziac.

## Qualification Boundary

Deterministic scripted lifecycle and action tests establish `managed`. A real
image migration job, parallel execution, scheduled OAuth invocation, cancellation
and WorkerPool rollout in a disposable billing-enabled project establish
`qualified`. Local evidence never substitutes for that authenticated receipt.
