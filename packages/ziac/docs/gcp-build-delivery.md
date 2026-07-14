# GCP Build And Artifact Delivery

Ziac manages modern Cloud Build source connections, linked repositories,
repository-event triggers, private worker pools and Artifact Registry through
one typed delivery graph. The high-level `ZigBuildPipeline` component compiles
the common path from source to a protected artifact repository while the
low-level resources remain independently usable.

## Managed Resources

- `gcp.cloudbuild.Connection`
- `gcp.cloudbuild.Repository`
- `gcp.cloudbuild.WorkerPool`
- `gcp.cloudbuild.Trigger`
- `gcp.artifact.Repository`
- `gcp.artifact.ProjectSettings`
- `gcp.artifact.VpcscConfig`

Connections support GitHub, GitHub Enterprise, GitLab, Bitbucket Data Center
and Bitbucket Cloud. Repository triggers use the Cloud Build v2 repository
event contract. Private worker pools support VPC peering and Private Service
Connect. Artifact repositories cover every standard format, deterministic
cleanup policies, CMEK, vulnerability scanning and explicit dry-run behavior.

## Component

```zig
var pipeline = try ziac.gcp.ZigBuildPipeline.build(allocator, provider, .{
    .name = "global-api",
    .location = "europe-west1",
    .connection = .{ .github = .{
        .oauth_token_secret_version = "projects/acme/secrets/github/versions/1",
        .app_installation_id = "12345678",
    } },
    .remote_uri = "https://github.com/acme/global-api.git",
    .event = .{ .push = .{ .branch = "^main$" } },
    .filename = "platform/cloudbuild.yaml",
    .private_pool = .{ .network = .{ .peered = .{
        .network = "projects/123/global/networks/build",
        .egress = .no_public,
    } } },
});
defer pipeline.deinit();
```

The component emits explicit source-connection, trigger-source,
private-execution and build-artifact edges. These edges drive dependency order,
permission synthesis, Cloud Asset ownership mapping and the local 3D canvas.

## Lifecycle And Safety

- Cloud Build v2 create and delete operations checkpoint Google long-running
  operations and resume them after interruption.
- Updates use exact field masks and current etags where the API exposes them.
- Worker-pool network changes are replacements; mutable machine and disk fields
  update in place.
- SCM credentials remain secret references and are resolved only while forming
  the authorized mutation request. They are never persisted in state, plans,
  receipts or visual artifacts.
- Artifact cleanup policies are canonicalized by policy name, so declaration
  order cannot create false drift.
- Artifact project redirection finalization cannot be reversed. Project
  settings and VPC Service Controls configuration are retained by default.
- Connections, worker pools and artifact repositories are protected by default.

## Cost And Observability

Ziac separates default build minutes, private-pool minutes, private disk,
artifact storage, transfer and vulnerability scans. These values are labelled
configuration estimates until authoritative Cloud Billing export attribution is
connected. Canvas resources expose build-delivery kind and ownership without
including credentials.

## Qualification Boundary

The deterministic suite records an unauthenticated local receipt proving graph
identity, apply, import, refreshed no-op and cleanup. It explicitly states that
SCM webhooks, builds and artifact uploads were not exercised.

`scripts/qualify-build-delivery.sh` is the separate authenticated gate. It only
runs against a project ending in `-ziac-disposable`, checks Application Default
Credentials, applies a cleanup-enabled stack from a saved plan, probes every
remote resource, runs a real repository trigger to a successful Cloud Build,
imports the graph into a second state, proves no-op and deletes the first state.
Missing credentials or configuration produce exit code 77 and a structured
skip receipt; they never produce a qualification pass.

The qualification stack must set `protect = false` and `retain_on_delete =
false` for every managed resource. The repository and branch must contain the
declared Cloud Build configuration.

## Contract Provenance

The implementation is pinned to the official Google API contracts:

- Cloud Build v1, revision `20260627`
- Cloud Build v2, revision `20260627`
- Artifact Registry v1, revision `20260702`

The discovery contract records the source URL, revision and SHA-256 digest for
each surface so upgrades are reviewable semantic changes rather than implicit
SDK drift.
