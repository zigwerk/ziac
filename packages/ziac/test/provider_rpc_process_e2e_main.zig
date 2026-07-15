const std = @import("std");
const ziac = @import("ziac");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.MissingFixturePath;
    var process = try ziac.provider_rpc.ProcessProvider.init(init.gpa, init.io, &.{args[1]}, .{
        .package_name = "ziac/provider-fixture",
        .package_version = "1.2.3",
        .provider = .gcp,
    });
    defer process.deinit();

    var node = try ziac.ResourceNode.initOwned(init.gpa, .{
        .id = "gcp.fixture.Service.process-api",
        .provider = .gcp,
        .type_name = "gcp.fixture.Service",
        .schema_version = 3,
        .logical_id = "process-api",
        .inputs = .{ .object = &.{
            .{ .name = "image", .value = .{ .string = "example/process:v1" } },
        } },
    });
    defer node.deinit(init.gpa);
    const rpc_provider = process.provider();

    var before = try rpc_provider.read(init.gpa, node);
    defer before.deinit();
    if (before != .absent) return error.ExpectedAbsent;
    var created = try rpc_provider.create(init.gpa, node);
    defer created.deinit();
    if (!std.mem.eql(u8, created.physical_id, "fake/gcp.fixture.Service.process-api")) return error.InvalidPhysicalId;
    var after = try rpc_provider.read(init.gpa, node);
    defer after.deinit();
    if (after != .present) return error.ExpectedPresent;
    var diff = try rpc_provider.diff(init.gpa, node, &after.present);
    defer diff.deinit();
    if (diff.kind != .noop) return error.ExpectedNoop;
    try rpc_provider.delete(node, created.physical_id);
}
