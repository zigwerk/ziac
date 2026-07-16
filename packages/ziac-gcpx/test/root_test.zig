const std = @import("std");
const ziac = @import("ziac");
const gcpx = @import("ziac_gcpx");
const zstd = @import("zigeffect_std");

const provider = ziac.gcp.ProviderConfig{ .project_id = "ziac-dev", .primary_region = "europe-west1" };

test "official AssetBucket expands into cataloged resources with component provenance" {
    var context = try zstd.Testing.TestContext.init(std.testing.allocator, .{
        .project = "ziac-gcpx",
        .suite = "ziac-gcpx-tests",
        .scenario = .{
            .id = "asset-bucket-provenance",
            .label = "AssetBucket compiles deterministic typed provenance",
            .requirement = "official-component-provenance",
            .acceptance_check = "check-asset-bucket-provenance",
            .component = "ziac-gcpx",
            .command = "zig-build-test",
        },
        .seed = 42,
    });
    defer context.deinit();
    const assertions = zstd.Testing.AssertionRecorder.init(&context);

    var bucket = try gcpx.AssetBucket.build(std.testing.allocator, provider, .{
        .name = "team-assets",
        .location = "EU",
        .readers = &.{"serviceAccount:api@ziac-dev.iam.gserviceaccount.com"},
    });
    defer bucket.deinit();

    try std.testing.expectEqual(@as(usize, 2), bucket.graph.resources.items.len);
    for (bucket.graph.resources.items) |node| {
        try std.testing.expectEqualStrings("ziac-gcpx", node.component.?.package);
        try std.testing.expectEqualStrings("AssetBucket", node.component.?.name);
        try std.testing.expectEqualStrings("team-assets", node.component.?.instance);
        try std.testing.expectEqualStrings("66a60519ef2ed3a41617362258b381437650ed9e6bbaeffb6d74311e8d735b95", node.component.?.source_digest);
    }
    try std.testing.expect(bucket.name == .resource_ref);
    try std.testing.expect(bucket.url == .resource_ref);
    try assertions.boolean(.{
        .id = "asset-bucket.resource-count",
        .label = "AssetBucket emits the governed resource set",
        .repair_hint = "preserve the bucket and IAM graph contract",
    }, bucket.graph.resources.items.len == 2);
    try assertions.boolean(.{
        .id = "asset-bucket.provenance",
        .label = "AssetBucket resource provenance is queryable",
        .repair_hint = "stamp every component-owned resource with package provenance",
    }, std.mem.eql(u8, bucket.graph.resources.items[0].component.?.package, "ziac-gcpx"));
    try assertions.noFindings(.{
        .id = "asset-bucket.no-findings",
        .label = "pure component compilation has no causal findings",
        .repair_hint = "keep component compilation deterministic and side-effect free",
    });
}

test "official AssetBucket leaves a caller base graph unattributed" {
    var base = ziac.ResourceGraph.init(std.testing.allocator);
    defer base.deinit();
    try base.addResource(.{ .id = "shared-network", .provider = .gcp, .type_name = "gcp.compute.Network", .logical_id = "shared-network" });
    var bucket = try gcpx.AssetBucket.build(std.testing.allocator, provider, .{
        .base_graph = &base,
        .name = "team-assets",
        .location = "EU",
    });
    defer bucket.deinit();
    try std.testing.expect(bucket.graph.resources.items[0].component == null);
    try std.testing.expectEqualStrings("AssetBucket", bucket.graph.resources.items[1].component.?.name);
}

test "official HermesDesktop expands its complete Compute product graph" {
    var deployment = try gcpx.HermesDesktop.build(std.testing.allocator, provider, .{
        .name = "hermes",
        .region = "europe-west1",
        .zone = "europe-west1-b",
        .domain = "hermes.example.com",
        .dns_zone = "example-com",
        .oauth_client_id = "agent:ziac-hermes-test",
        .environment_source = .{ .provider = "env", .resource = "HERMES_ENV_FILE", .version = "1" },
        .startup_script = .known(.{ .provider = "env", .resource = "ZIAC_HERMES_STARTUP_SCRIPT", .version = "1" }),
        .startup_script_sha256 = ziac.gcp.hermes_compute.reviewed_startup_script_sha256,
    });
    defer deployment.deinit();
    try std.testing.expectEqual(@as(usize, 12), deployment.graph.resources.items.len);
    for (deployment.graph.resources.items) |node| {
        try std.testing.expectEqualStrings("HermesDesktop", node.component.?.name);
        try std.testing.expectEqualStrings("hermes", node.component.?.instance);
        try std.testing.expectEqualStrings("fbdbd78c1f14bb43135a2f8adfb1a9b6ea2eac2583febdf4ae80c690e421a236", node.component.?.source_digest);
    }
    try std.testing.expectEqualStrings("https://hermes.example.com", deployment.desktop_url.value);
}
