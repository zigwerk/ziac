const std = @import("std");
const ziac = @import("ziac");

test "pinned Cloud Run descriptor is authentic and exposes semantic API facts" {
    const proto = ziac.gcp.proto_contract;
    try proto.verifyEmbeddedLock();
    try proto.verifyGeneratedSnapshot(std.testing.allocator);

    var contract = try proto.inspectCloudRunV2(std.testing.allocator, proto.embedded_descriptor);
    defer contract.deinit(std.testing.allocator);

    try std.testing.expect(contract.file_count >= 20);
    try std.testing.expectEqualStrings("google.cloud.run.v2", contract.package);
    try std.testing.expectEqualStrings("Services", contract.service);
    try std.testing.expectEqualStrings("run.googleapis.com", contract.default_host);
    try std.testing.expectEqualStrings("https://www.googleapis.com/auth/cloud-platform", contract.oauth_scope);
    try std.testing.expectEqualStrings("run.googleapis.com/Service", contract.resource_type);
    try std.testing.expectEqualStrings(
        "projects/{project}/locations/{location}/services/{service}",
        contract.resource_pattern,
    );
    try std.testing.expect(contract.hasMethod("CreateService"));
    try std.testing.expect(contract.hasMethod("UpdateService"));
    try std.testing.expect(contract.hasMethod("TestIamPermissions"));
    try std.testing.expect(contract.hasBinding(
        "CreateService",
        "POST",
        "/v2/{parent=projects/*/locations/*}/services",
        "parent",
    ));
    try std.testing.expect(contract.hasBinding(
        "UpdateService",
        "PATCH",
        "/v2/{service.name=projects/*/locations/*/services/*}",
        "service.name",
    ));
    const update = contract.method("UpdateService").?;
    try std.testing.expectEqualStrings("Service", update.lro_response_type);
    try std.testing.expectEqualStrings("Service", update.lro_metadata_type);
    try std.testing.expect(contract.hasField("Service.multi_region_settings", .optional));
    try std.testing.expect(contract.hasField("Service.MultiRegionSettings.regions", .required));
    try std.testing.expect(contract.hasField("Service.observed_generation", .output_only));
    try std.testing.expect(contract.hasField("Service.reconciling", .output_only));
}

test "proto snapshot generation and semantic upgrade diff are deterministic" {
    const proto = ziac.gcp.proto_contract;
    const first = try proto.snapshotJsonAlloc(std.testing.allocator, proto.embedded_descriptor);
    defer std.testing.allocator.free(first);
    const second = try proto.snapshotJsonAlloc(std.testing.allocator, proto.embedded_descriptor);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "multi_region_settings") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "CreateService") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "72295728") == null);

    const current = [_]proto.SemanticFact{
        .{ .path = "Service.name", .behavior = .identifier },
        .{ .path = "Service.uri", .behavior = .output_only },
    };
    const next = [_]proto.SemanticFact{
        .{ .path = "Service.name", .behavior = .immutable },
        .{ .path = "Service.regions", .behavior = .required },
    };
    var diff = try proto.diffFacts(std.testing.allocator, &current, &next);
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), diff.added.len);
    try std.testing.expectEqual(@as(usize, 1), diff.removed.len);
    try std.testing.expectEqual(@as(usize, 1), diff.changed.len);
    try std.testing.expect(diff.breaking);
}
