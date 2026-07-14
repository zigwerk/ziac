# GCP Cloud Deploy

Ziac manages Cloud Deploy delivery pipelines, targets, custom target types,
automations and rollout-restriction policies as typed infrastructure. Releases,
rollouts, automation runs and job runs remain governed actions or observed
history: they are not mutable desired-state resources.

## Managed Resources

- `gcp.deploy.DeliveryPipeline`
- `gcp.deploy.Target`
- `gcp.deploy.CustomTargetType`
- `gcp.deploy.Automation`
- `gcp.deploy.DeployPolicy`

Targets support Cloud Run, GKE, Anthos, multi-target and custom runtimes.
Pipelines support serial standard, canary and custom-canary progression.
Automations cover promote, timed promote, phase advance and repair rules.

## Global Cloud Run Delivery

```zig
var delivery = try ziac.gcp.GlobalCloudRunDelivery.build(allocator, provider, .{
    .name = "global-api",
    .location = "europe-west1",
    .regions = &.{
        .{ .region = "europe-west1", .profile = "europe" },
        .{ .region = "us-central1", .profile = "americas" },
        .{ .region = "asia-northeast1", .profile = "asia", .require_approval = true },
    },
    .service_account = "deploy@acme.iam.gserviceaccount.com",
    .canary_percentages = &.{ 10, 50 },
    .automation = .{ .enabled = true, .wait_seconds = 300, .repair_attempts = 3 },
    .production_freeze = .{
        .target_region = "asia-northeast1",
        .time_zone = "UTC",
        .days = &.{ .saturday, .sunday },
    },
});
defer delivery.deinit();
```

The component emits one target per region, a serial pipeline, optional guarded
automation and an optional deploy policy. Output references create explicit
`delivery_stage` and `pipeline_automation` canvas edges.

## Governed Actions

`cloud_deploy_actions.Runner` provides create-release, promote, approve,
advance, rollback, cancel and abandon operations. Every action requires a
time-bounded capability envelope. Its approved digest binds the stage, project,
canonical Google resource name and every mutable payload field. Cancel and
abandon require delete authority; the other mutations require apply authority.

Release and rollout creation wait on resumable Google long-running operations.
Receipts preserve action, normalized status, resource and operation names,
provider state, etag and approved plan digest without recording credentials.

## Lifecycle And Drift

- Creates, updates and deletes use deterministic AIP-155 request IDs.
- Updates send only semantically changed fields and the current etag.
- Deletes refresh immediately before mutation and send the latest etag.
- Long-running operations checkpoint and resume after interruption.
- Output-only conditions and timestamps never create drift.
- Target runtime-union changes are replacements.
- Pipeline stages, automation rules and policy collections are canonicalized.
- Protected resources and retained deploy policies keep their declared safety
  behavior through normal plan and destroy authority checks.

## Estate, Canvas And Cost

Cloud Asset Inventory maps pipelines, targets, custom target types, automations
and policies to managed Ziac types. Releases, rollouts, automation runs and job
runs are imported as read-only `gcp.asset.Resource` history. The canvas exposes
delivery kind, location, approval, suspension, execution, stage, target, rule
and selector counts.

The cost model separates active multi-target pipeline months from underlying
Cloud Build minutes. The first active multi-target pipeline per billing account
is represented as a free allowance. Values remain configuration estimates until
authoritative Cloud Billing attribution is connected.

## Qualification Boundary

The deterministic suite proves declaration, apply, import, refreshed no-op,
cleanup, permission synthesis, estate mapping, visual topology and cost
semantics. Its receipt is explicitly unauthenticated.

`scripts/qualify-cloud-deploy.sh` is the fail-closed live gate. It requires a
disposable project, Application Default Credentials and explicit resource/action
identifiers. It applies a cleanup-enabled stack from a saved plan, probes the
remote pipeline and targets, creates a real release and rollout with fixed argv,
imports the managed graph into a second state, proves no-op and cleans up.
Missing credentials or configuration return exit code 77 and a structured skip,
never a pass.

## Contract Provenance

The provider is pinned to Cloud Deploy v1 Discovery revision `20260706`, SHA-256
`1ad7831e467cc5aeae81c49bac3726de166d864afa9d68cf3ce558fae1d52e56`.
Provider upgrades must update this reviewed contract before changing behavior.
