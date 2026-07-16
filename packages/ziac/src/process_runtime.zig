const std = @import("std");
const zstd = @import("zigeffect_std");

pub const max_process_name_bytes: usize = 64;

pub const ProcessInputsApi = struct {
    pub const operations: []const []const u8 = &.{"ProcessInputs.read"};
    init: std.process.Init,
    process_name: []const u8,
};
pub const ProcessInputs = zstd.fx.kernel.Service("ziac/ProcessInputs", ProcessInputsApi);

pub fn processLayer(init: std.process.Init, process_name: []const u8) @TypeOf(zstd.fx.kernel.Layer.succeed(ProcessInputs, .{ .init = init, .process_name = process_name })) {
    return zstd.fx.kernel.Layer.succeed(ProcessInputs, .{ .init = init, .process_name = process_name });
}

/// Run one process program through the canonical durable ZigEffect runtime.
/// The caller supplies an ordinary canonical Effect; services are composed in
/// `runWithLayer` when a process has external capabilities.
pub fn run(
    init: std.process.Init,
    process_name: []const u8,
    program: anytype,
) !@TypeOf(program).SuccessType {
    return runWithLayer(init, process_name, zstd.fx.kernel.Layer.empty(), program, .{});
}

pub fn runWithLayer(
    init: std.process.Init,
    process_name: []const u8,
    root_layer: anytype,
    program: anytype,
    options: zstd.CausalRuntime.Options,
) !@TypeOf(program).SuccessType {
    try validateProcessName(process_name);
    const graph_path = try graphPathAlloc(init.gpa, process_name);
    defer init.gpa.free(graph_path);

    var runtime_options = options;
    runtime_options.graph.path = graph_path;
    const main_layer = zstd.fx.kernel.Layer.mergeAll(.{ processLayer(init, process_name), root_layer });
    var runtime = try zstd.ManagedRuntime(@TypeOf(main_layer)).make(
        init.gpa,
        init.io,
        std.Io.Dir.cwd(),
        main_layer,
        runtime_options,
    );
    defer runtime.deinit();

    const result = try runtime.run(program.named(process_name));
    const health = runtime.causalHealth();
    if (health.status != .healthy or health.durable_records == 0) return error.CausalRuntimeUnhealthy;
    try runtime.shutdown();
    return result;
}

fn validateProcessName(name: []const u8) !void {
    if (name.len == 0 or name.len > max_process_name_bytes) return error.InvalidProcessName;
    for (name) |char| {
        if (!(std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '-')) return error.InvalidProcessName;
    }
}

fn graphPathAlloc(allocator: std.mem.Allocator, process_name: []const u8) ![]u8 {
    return if (std.mem.eql(u8, process_name, "ziac-cli"))
        allocator.dupe(u8, ".zigeffect/graph")
    else
        std.fmt.allocPrint(allocator, ".zigeffect/graphs/{s}", .{process_name});
}

test "process names are stable graph path components" {
    try validateProcessName("ziac-provider-gcp");
    try std.testing.expectError(error.InvalidProcessName, validateProcessName("../provider"));
    try std.testing.expectError(error.InvalidProcessName, validateProcessName("Provider"));
}

test "the CLI is the agent-queryable graph and daemons retain isolated locks" {
    const cli = try graphPathAlloc(std.testing.allocator, "ziac-cli");
    defer std.testing.allocator.free(cli);
    try std.testing.expectEqualStrings(".zigeffect/graph", cli);
    const provider = try graphPathAlloc(std.testing.allocator, "ziac-provider-gcp");
    defer std.testing.allocator.free(provider);
    try std.testing.expectEqualStrings(".zigeffect/graphs/ziac-provider-gcp", provider);
}
