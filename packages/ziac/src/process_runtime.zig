const std = @import("std");
const zstd = @import("zigeffect_std");

pub const max_process_name_bytes: usize = 64;

/// Run one process program through the canonical durable ZigEffect runtime.
/// The caller supplies an ordinary canonical Effect; services are composed in
/// `runWithLayer` when a process has external capabilities.
pub fn run(
    init: std.process.Init,
    process_name: []const u8,
    program: anytype,
) !@TypeOf(program).SuccessType {
    const empty = zstd.fx.kernel.Layer.empty();
    return runWithLayer(init, process_name, empty, program, .{});
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
    var runtime = try zstd.ManagedRuntime(@TypeOf(root_layer)).make(
        init.gpa,
        init.io,
        std.Io.Dir.cwd(),
        root_layer,
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
