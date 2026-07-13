# Cloud Run Jobs And Worker Pools

Ziac models all three Cloud Run workload shapes without pretending they share
the same lifecycle:

- `gcp.run.Service` serves request traffic;
- `gcp.run.Job` is desired configuration for run-to-completion executions;
- `gcp.run.WorkerPool` runs continuously without a load-balanced endpoint.

Executions and Worker Pool revisions are observed immutable children. Running a
Job and cancelling an Execution are governed actions, not stateful resource
creation or deletion.

## Typed Resources

Jobs and Worker Pools share typed multi-container declarations with immutable
image references, command and arguments, CPU and memory limits, environment,
Secret Manager volumes, service identity, Direct VPC access, CMEK and GPU node
selection. Jobs add task count, parallelism, retries, timeout and execution
environment. Worker Pools add manual instance count, revision selection and
instance splits.

Declaration validation rejects ambiguous secret-volume targets, duplicate
containers or environment variables, mutable image identities, malformed
service accounts, impossible parallelism and invalid revision split totals.

```zig
var job = try ziac.gcp.ZigJob.build(allocator, provider, .{
    .workload = .{
        .name = "nightly-report",
        .containers = &.{.{
            .name = "main",
            .image = "europe-west1-docker.pkg.dev/acme/apps/report@sha256:...",
        }},
        .task_count = 12,
        .parallelism = 3,
        .timeout_seconds = 900,
    },
});
defer job.deinit();
```

`ZigJob` creates a dedicated runtime service account and Job. `ZigWorkerPool`
does the same for continuous background workers. User-supplied workload service
accounts are rejected by these components because the component owns that
identity boundary; use the low-level resources when integrating an existing
identity intentionally.

## Scheduled Jobs

`ScheduledZigJob` creates the runtime identity, Job, scheduler identity, exact
resource-scoped Job invoker member and Cloud Scheduler Job. Scheduler calls the
Google Cloud Run Admin API with OAuth, not OIDC:

```zig
var scheduled = try ziac.gcp.ScheduledZigJob.build(allocator, provider, .{
    .workload = .{
        .name = "nightly-report",
        .containers = &.{.{ .name = "main", .image = image_ref }},
    },
    .schedule = "0 2 * * *",
});
defer scheduled.deinit();
```

The generated target is
`https://run.googleapis.com/v2/projects/<project>/locations/<region>/jobs/<job>:run`
with the Cloud Platform OAuth scope. Graph preflight includes Cloud Run,
Scheduler and IAM APIs, workload CRUD permissions, exact Job IAM policy access
and `iam.serviceAccounts.actAs`.

## Lifecycle And Recovery

Job and Worker Pool create, update and delete operations use Cloud Run v2
long-running operations. Ziac checkpoints the operation name and resumes it on
refresh rather than issuing a duplicate mutation. Reads normalize writable
fields, preserve output references, ignore server-only readiness and generation
fields, and retain the current etag for compare-and-swap updates and deletion.

Worker Pool updates use an explicit field mask. Job and Worker Pool import use
canonical names such as
`projects/acme/locations/europe-west1/jobs/nightly-report`. Cloud Asset
Inventory discovery emits the same identity, allowing observed resources to be
visualized before selective adoption.

## Governed Execution

`gcp.run_actions.Runner` exposes run, inspect and cancel operations. Run needs
`.apply`; inspect needs `.read`; cancel needs `.delete`. Run and cancel also
require an approved SHA-256 action digest covering the action, stage, project
and exact Google resource name. Both read the current etag before mutation.

The redacted `ziac.gcp.run-execution-receipt.v1` receipt records execution and
operation names, status, task counters, retry count, log URI and etag. Failed,
cancelled, pending and running executions remain distinct. Provider deadlines,
Google operation errors and etag conflicts stay failures rather than being
translated into successful receipts.

Execution authority is not inferred from the presence of a Job in a graph. Use
`gcp.intelligence.jobExecutionUsages()` when an agent or workflow is requesting
run/inspect/cancel authority; it adds `run.jobs.run`, `run.executions.get` and
`run.executions.cancel` explicitly.

## Canvas And Cost

The visual artifact identifies Job, Job IAM and Worker Pool kinds plus
container, task, parallelism, retry, timeout, instance and split counts. The 3D
canvas renders Jobs and Worker Pools as distinct Cloud Run groups with the
official Cloud Run product mark. Existing CAI-discovered workloads remain
observed and read-only until adopted.

Configuration estimates never claim to be live spend:

- Job estimates multiply declared tasks and expected monthly executions by
  explicit average duration, vCPU, memory and optional GPU assumptions.
- Worker Pool estimates multiply instance count and explicit active seconds by
  per-instance vCPU, memory and optional GPU assumptions.

Actual billed and projected month-end cost still require the detailed Cloud
Billing export and preserve separate provenance.

## Qualification Boundary

Scripted lifecycle, action, estate, cost, intelligence and dashboard tests
establish the local `managed` stage. `qualified` remains separate until a
disposable billing-enabled project proves a real migration Job, parallel Job,
scheduled OAuth invocation, cancellation and Worker Pool rollout with cleanup.

Official contracts:

- [Cloud Run Jobs REST API](https://cloud.google.com/run/docs/reference/rest/v2/projects.locations.jobs)
- [Cloud Run Executions REST API](https://cloud.google.com/run/docs/reference/rest/v2/projects.locations.jobs.executions)
- [Cloud Run Worker Pools](https://cloud.google.com/run/docs/deploy-worker-pools)
- [Cloud Run IAM permissions](https://cloud.google.com/run/docs/reference/iam/permissions)
- [Cloud Asset Inventory asset types](https://cloud.google.com/asset-inventory/docs/asset-types)
