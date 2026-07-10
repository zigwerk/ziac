# Managed CockroachDB Cloud Clusters

`cockroach.cluster.Cluster` creates and manages GCP CockroachDB Cloud clusters
through the pinned `2024-09-16` Cloud API. It supports Basic, Standard, and
Advanced plans while keeping the initial Ziac surface intentionally smaller
than the full Cockroach API.

## Provider Setup

Live commands require Google ADC, `ZIAC_LIVE_PROJECT`, and a Cockroach Cloud
service-account key in `COCKROACH_API_KEY`. The CLI registers both providers
when invoked with `--provider gcp --allow-live`.

The key remains process memory owned by the provider runtime. It is never a
resource input, output, state value, plan value, or diagnostic value.

## Basic

Basic clusters accept optional monthly request-unit and storage limits. A
multi-region cluster requires exactly one primary region.

```zig
var cluster = try ziac.cockroach.cluster.Cluster.build(allocator, .{}, .{
    .name = "ziac-basic",
    .plan = .{ .basic = .{
        .regions = &.{
            .{ .name = "europe-west1", .primary = true },
            .{ .name = "us-central1" },
        },
        .request_unit_limit = 10_000_000,
        .storage_mib_limit = 10_240,
    } },
});
```

Ziac always sends `with_empty_ip_allowlist: true`. The cluster therefore starts
without Cockroach Cloud's otherwise-default unrestricted public allowlist.
Use `PublicStaticEgress` to add only the regional Cloud NAT `/32` addresses.

## Standard

Standard clusters use provisioned vCPUs and the same primary-region rules.

```zig
var cluster = try ziac.cockroach.cluster.Cluster.build(allocator, .{}, .{
    .name = "ziac-standard",
    .plan = .{ .standard = .{
        .regions = &.{.{ .name = "europe-west1" }},
        .provisioned_virtual_cpus = 4,
    } },
});
```

Changing provisioned vCPUs, adding a region, changing the primary region, or
moving between Basic and Standard updates the cluster in place. The pinned API
cannot remove a serverless region, so that change is classified as replacement
and is blocked while protection is enabled.

## Advanced

Advanced clusters expose node count, vCPUs per node, optional storage, and the
GCP private-network creation settings needed by later PSC composition.

```zig
var cluster = try ziac.cockroach.cluster.Cluster.build(allocator, .{}, .{
    .name = "ziac-advanced",
    .plan = .{ .advanced = .{
        .regions = &.{
            .{ .name = "europe-west1", .node_count = 3 },
            .{ .name = "us-central1", .node_count = 3 },
        },
        .num_virtual_cpus = 4,
        .storage_gib = 500,
        .private_network_visibility = true,
        .cidr_range = "172.28.0.0/14",
    } },
});
```

Node count, vCPUs, storage, and region membership update in place. Moving
between serverless and Advanced or changing Advanced network creation settings
requires replacement. CIDRs must be valid IPv4 ranges with a prefix no larger
than `/19`, matching the Cockroach GCP contract.

## Readiness And Outputs

Create and update poll through `CREATING` and `LOCKED` until the API reports
`CREATED`. Polling obeys the resource's two-hour operation timeout,
cancellation, API retry policy, and `Retry-After` values. `CREATION_FAILED` and
`DELETED` stop immediately.

The resource exposes typed outputs for cluster identity, plan, state, deletion
protection, cluster SQL DNS, sorted regions, and the primary region's public,
internal, and Private Service Connect DNS names.

## Protected Destroy

Protection defaults to true in both Ziac lifecycle state and Cockroach Cloud.
Deletion deliberately requires two separate commands:

1. Change the declaration to `protect = false` and deploy it. This PATCHes
   Cockroach Cloud deletion protection and persists unprotected Ziac state.
2. Run the destroy with explicit confirmation:

```sh
ziac destroy --stack <stack> --stage <stage> \
  --provider gcp --allow-live --confirm
```

The provider re-reads the cluster immediately before deletion. It refuses the
request if the declaration is protected, the remote API still reports
protection enabled, the operation lacks confirmation, or the physical ID is
invalid. A missing cluster is treated as already deleted.

For clusters that Ziac must never own, continue using the retained
`ExistingCluster` resource.
