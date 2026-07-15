const std = @import("std");
const ziac = @import("ziac");
const gcpx = @import("ziac_gcpx");

pub fn build(allocator: std.mem.Allocator, init: std.process.Init, args: ziac.stack_registry.StackArgs) !ziac.stack_registry.StackProgram {
    if (!std.mem.eql(u8, args.stack, "event-worker")) return error.UnknownStack;
    const project = init.environ_map.get("ZIAC_GCP_PROJECT") orelse "ziac-dev";
    const provider = ziac.gcp.ProviderConfig{ .project_id = project, .primary_region = "europe-west1" };
    var bucket = try gcpx.AssetBucket.build(allocator, provider, .{ .name = "event-payloads", .location = "EU" });
    defer bucket.deinit();
    var topic = try ziac.gcp.pubsub.Topic.build(allocator, provider, .{ .name = "application-events" });
    defer topic.deinit(allocator);
    try bucket.graph.addResource(topic.node);
    var outputs = std.ArrayList(ziac.stack_registry.OutputDefinition).empty;
    errdefer outputs.deinit(allocator);
    try appendRef(allocator, &outputs, "bucket_url", bucket.url.resource_ref);
    try appendRef(allocator, &outputs, "topic", topic.name.resource_ref);
    return .{ .allocator = allocator, .graph = bucket.takeGraph(), .outputs = outputs };
}

fn appendRef(allocator: std.mem.Allocator, outputs: *std.ArrayList(ziac.stack_registry.OutputDefinition), name: []const u8, reference: ziac.OutputRef) !void {
    try outputs.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .source = .{ .resource_ref = .{ .resource_id = try allocator.dupe(u8, reference.resource_id), .field = try allocator.dupe(u8, reference.field) } },
    });
}
