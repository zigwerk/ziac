const std = @import("std");
const ziac = @import("ziac");

test "GCP provider catalog is valid and covers every managed live type" {
    try ziac.gcp.coverage.validate();

    var managed_count: usize = 0;
    for (ziac.gcp.coverage.resources) |entry| {
        if (entry.stage != .managed and entry.stage != .qualified) continue;
        managed_count += 1;
        const node = ziac.ResourceNode{
            .id = entry.type_name,
            .provider = .gcp,
            .type_name = entry.type_name,
            .logical_id = "coverage-check",
        };
        try std.testing.expect(ziac.gcp.live_provider.supports(node));
    }

    try std.testing.expectEqual(@as(usize, 35), managed_count);
}

test "every live provider type is registered as managed coverage" {
    var catalog_managed_count: usize = 0;
    for (ziac.gcp.coverage.resources) |entry| {
        if (entry.stage == .managed or entry.stage == .qualified) catalog_managed_count += 1;
    }

    try std.testing.expectEqual(catalog_managed_count, ziac.gcp.live_provider.managed_type_names.len);
    for (ziac.gcp.live_provider.managed_type_names) |type_name| {
        const entry = ziac.gcp.coverage.find(type_name) orelse return error.LiveProviderTypeMissingFromCoverage;
        try std.testing.expect(entry.stage == .managed or entry.stage == .qualified);
    }
}

test "GCP provider catalog exposes current and next-tranche coverage honestly" {
    const cloud_run = ziac.gcp.coverage.find("gcp.run.Service") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(ziac.gcp.coverage.Stage.managed, cloud_run.stage);
    try std.testing.expect(cloud_run.capabilities.create);
    try std.testing.expect(cloud_run.capabilities.import_resource);

    const bucket = ziac.gcp.coverage.find("gcp.storage.Bucket") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(ziac.gcp.coverage.Stage.managed, bucket.stage);
    try std.testing.expectEqualStrings("M57", bucket.milestone);
    try std.testing.expect(bucket.capabilities.create);

    const object = ziac.gcp.coverage.find("gcp.storage.Object") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(ziac.gcp.coverage.Stage.managed, object.stage);
    try std.testing.expect(object.capabilities.import_resource);
    try std.testing.expect(object.capabilities.visual);
    try std.testing.expect(object.capabilities.cost);

    const topic = ziac.gcp.coverage.find("gcp.pubsub.Topic") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(ziac.gcp.coverage.Stage.planned, topic.stage);
    try std.testing.expectEqualStrings("M58", topic.milestone);

    try std.testing.expect(ziac.gcp.coverage.find("gcp.not.a.Resource") == null);
}

test "GCP provider coverage reports are deterministic filterable and provenance pinned" {
    const json_first = try ziac.gcp.coverage.jsonAlloc(std.testing.allocator, .{ .service = .storage });
    defer std.testing.allocator.free(json_first);
    const json_second = try ziac.gcp.coverage.jsonAlloc(std.testing.allocator, .{ .service = .storage });
    defer std.testing.allocator.free(json_second);
    try std.testing.expectEqualStrings(json_first, json_second);
    try std.testing.expect(std.mem.indexOf(u8, json_first, "\"schema\":\"ziac.gcp.provider-coverage.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_first, ziac.gcp.proto_contract.googleapis_revision) != null);
    try std.testing.expect(std.mem.indexOf(u8, json_first, ziac.gcp.proto_contract.descriptor_sha256) != null);
    try std.testing.expect(std.mem.indexOf(u8, json_first, "compute:v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_first, "dns:v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_first, "storage:v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_first, "gcp.storage.Bucket") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_first, "gcp.pubsub.Topic") == null);

    const markdown = try ziac.gcp.coverage.markdownAlloc(std.testing.allocator, .{ .service = .pubsub });
    defer std.testing.allocator.free(markdown);
    try std.testing.expect(std.mem.startsWith(u8, markdown, "# Ziac GCP Provider Resources\n"));
    try std.testing.expect(std.mem.indexOf(u8, markdown, "`gcp.pubsub.Topic`") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "`gcp.storage.Bucket`") == null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, ziac.gcp.proto_contract.googleapis_revision) != null);
}

test "Google contract upgrades emit deterministic semantic diff artifacts" {
    try ziac.gcp.discovery_contract.validate();
    var next_sources = ziac.gcp.discovery_contract.sources;
    next_sources[0].revision = "20990101";
    next_sources[0].document_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const discovery_diff = try ziac.gcp.discovery_contract.semanticDiffJsonAlloc(
        std.testing.allocator,
        &ziac.gcp.discovery_contract.sources,
        &next_sources,
    );
    defer std.testing.allocator.free(discovery_diff);
    try std.testing.expect(std.mem.indexOf(u8, discovery_diff, "ziac.google.discovery-semantic-diff.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, discovery_diff, "\"changed\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, discovery_diff, "20990101") != null);

    const current = [_]ziac.gcp.proto_contract.SemanticFact{
        .{ .path = "google.cloud.run.v2.Service.template", .behavior = .required },
    };
    const next = [_]ziac.gcp.proto_contract.SemanticFact{
        .{ .path = "google.cloud.run.v2.Service.template", .behavior = .immutable },
    };
    const proto_diff = try ziac.gcp.proto_contract.semanticDiffJsonAlloc(std.testing.allocator, &current, &next);
    defer std.testing.allocator.free(proto_diff);
    try std.testing.expect(std.mem.indexOf(u8, proto_diff, "ziac.google.proto-semantic-diff.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, proto_diff, "\"breaking\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, proto_diff, "google.cloud.run.v2.Service.template") != null);
}
