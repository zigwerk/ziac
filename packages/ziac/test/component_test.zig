const std = @import("std");
const ziac = @import("ziac");

const descriptor = ziac.component.Descriptor{
    .package = "ziac-gcpx",
    .name = "AssetBucket",
    .version = "0.1.0",
    .source_digest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    .providers = &.{.gcp},
    .resource_types = &.{ "gcp.storage.Bucket", "gcp.storage.BucketIamMember" },
};

test "component stamping owns provenance without changing provider inputs" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.addResource(.{ .id = "base", .provider = .gcp, .type_name = "gcp.compute.Network", .logical_id = "base" });
    const start = graph.resources.items.len;
    try graph.addResource(.{
        .id = "bucket",
        .provider = .gcp,
        .type_name = "gcp.storage.Bucket",
        .logical_id = "assets",
        .inputs = .{ .object = &.{.{ .name = "location", .value = .{ .string = "EU" } }} },
    });
    const before = graph.resources.items[1].inputs_hash;

    try ziac.component.stampRange(&graph, start, descriptor, "web-assets");

    try std.testing.expect(graph.resources.items[0].component == null);
    const origin = graph.resources.items[1].component.?;
    try std.testing.expectEqualStrings("ziac-gcpx", origin.package);
    try std.testing.expectEqualStrings("AssetBucket", origin.name);
    try std.testing.expectEqualStrings("web-assets", origin.instance);
    try std.testing.expectEqual(before, graph.resources.items[1].inputs_hash);
    try ziac.component.stampRange(&graph, start, descriptor, "web-assets");

    const conflicting = ziac.component.Descriptor{
        .package = "community/example",
        .name = "OtherBucket",
        .version = "1.0.0",
        .source_digest = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .providers = &.{.gcp},
        .resource_types = &.{"gcp.storage.Bucket"},
    };
    try std.testing.expectError(error.ComponentOwnershipConflict, ziac.component.stampRange(&graph, start, conflicting, "other"));
}

test "component provenance round trips through program and visual artifacts" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    try graph.addResource(.{ .id = "bucket", .provider = .gcp, .type_name = "gcp.storage.Bucket", .logical_id = "assets" });
    try ziac.component.stampRange(&graph, 0, descriptor, "web-assets");
    const outputs = std.ArrayList(ziac.stack_registry.OutputDefinition).empty;
    var program = ziac.stack_registry.StackProgram{ .allocator = std.testing.allocator, .graph = graph, .outputs = outputs };
    defer program.deinit();

    const encoded = try ziac.program_format.encodeAlloc(std.testing.allocator, "assets", "dev", &program);
    defer std.testing.allocator.free(encoded);
    var decoded = try ziac.program_format.decodeAlloc(std.testing.allocator, encoded, .{ .stack = "assets", .stage = "dev" });
    defer decoded.deinit();
    try std.testing.expectEqualStrings("AssetBucket", decoded.graph.resources.items[0].component.?.name);
    try std.testing.expectEqualStrings("web-assets", decoded.graph.resources.items[0].component.?.instance);

    var artifact = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &decoded.graph, null, .{
        .stack = "assets",
        .stage = "dev",
        .created_at_millis = 7,
    });
    defer artifact.deinit();
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"component\":{\"package\":\"ziac-gcpx\",\"name\":\"AssetBucket\",\"version\":\"0.1.0\",\"instance\":\"web-assets\",\"source_digest\":\"aaaaaaaa") != null);
}
