# GCP Application Platform

`ziac.gcp.ApplicationPlatform` is the first integrated application-platform
component. It compiles a private Cloud Run API, a versioned upload bucket,
Pub/Sub push and dead-letter delivery, Cloud Tasks, Eventarc, a scheduled Cloud
Run Job and a Worker Pool into one typed graph.

```zig
var platform = try ziac.gcp.ApplicationPlatform.build(allocator, provider, .{
    .name = "platform",
    .project_number = "123456789012",
    .image = "europe-west1-docker.pkg.dev/project/apps/platform@sha256:...",
    .service_origin = "https://platform-api.example.run.app",
    .bucket_name = "project-platform-uploads",
    .location = "EU",
    .allowed_persistence_regions = &.{ "europe-west1", "europe-west4" },
});
defer platform.deinit();
```

The runtime service account receives only object creation, topic publishing and
task enqueue authority. Pub/Sub, Tasks, Eventarc and Scheduler each use a
separate invocation identity. Cloud Run remains private and each invoker is an
explicit graph edge. The service, Job and Worker Pool require an immutable image
digest.

The component exposes typed outputs for the service, service URL, bucket, topic,
subscription, queue, trigger, Job, schedule, Worker Pool and runtime identity.
These can be passed to an application's binding struct and checked with
`ziac.binding.validateBindings` before a plan exists.

One image digest may serve all three Cloud Run workload types while separate
`service_command`, `job_command` and `worker_command` arguments select the
entrypoint behavior. This keeps supply-chain identity singular without assuming
that an HTTP server is also a terminating batch process.

## Qualification

The deterministic local gate proves graph identity, permission synthesis,
visual projection, full fake-provider apply, import into an empty second state,
refreshed no-op and dependency-ordered cleanup. Its receipt always includes
`authenticated: false` and labels costs as `configuration_estimate`.

`scripts/qualify-application-platform.sh` is the separate authenticated gate.
It accepts only a project ending in `-ziac-disposable`, Application Default
Credentials, an immutable image and a prepared Ziac workspace. It exercises
Storage, Pub/Sub, Tasks, Eventarc, Scheduler, Jobs, Worker Pools, log delivery,
second-state import and retained-resource behavior. Missing configuration emits
a skipped receipt with exit code 77. A remote failure emits a failed receipt and
never becomes local proof.

The runner uses the documented Google Cloud CLI surfaces for
[Pub/Sub publish](https://docs.cloud.google.com/sdk/gcloud/reference/pubsub/topics/publish),
[Cloud Tasks HTTP tasks](https://cloud.google.com/sdk/gcloud/reference/tasks/create-http-task),
[Cloud Run Job execution](https://docs.cloud.google.com/sdk/gcloud/reference/run/jobs/execute)
and [Worker Pool inspection](https://docs.cloud.google.com/run/docs/managing/workerpools).
