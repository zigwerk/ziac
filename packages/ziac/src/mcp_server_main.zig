const std = @import("std");
const ziac = @import("ziac");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const raw_args = try init.minimal.args.toSlice(init.arena.allocator());
    const project_path = optionValue(raw_args[1..], "--project") orelse "ziac.project.json";
    const stack = optionValue(raw_args[1..], "--stack") orelse return error.MissingStack;
    const stage = optionValue(raw_args[1..], "--stage") orelse return error.MissingStage;
    const project_id = optionValue(raw_args[1..], "--project-id") orelse stack;
    const provider = std.meta.stringToEnum(ziac.resource.ProviderId, optionValue(raw_args[1..], "--provider") orelse "gcp") orelse return error.InvalidProvider;

    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, project_path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(bytes);
    var project = try ziac.agent_contract.Project.parseAlloc(allocator, bytes);
    defer project.deinit();
    var verification_runner = ziac.agent_tools.NativeVerificationRunner{ .io = init.io };
    var kernel = ziac.agent_tools.Kernel.init(allocator, project, verification_runner.runner());
    defer kernel.deinit();

    const now: u64 = @intCast(std.Io.Clock.real.now(init.io).toMilliseconds());
    const envelope = ziac.agent_contract.CapabilityEnvelope{
        .id = "ziac-mcp-local",
        .stages = &.{stage},
        .projects = &.{project_id},
        .providers = &.{provider},
        .permissions = project.authority,
        .budget = .{},
        .expires_at_millis = now +| 24 * 60 * 60 * 1000,
    };

    const read_buffer = try allocator.alloc(u8, 1024 * 1024 + 1);
    defer allocator.free(read_buffer);
    var reader = std.Io.File.stdin().reader(init.io, read_buffer);
    var write_buffer: [16 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &write_buffer);
    while (reader.interface.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => return error.McpMessageTooLarge,
        else => return err,
    }) |line| {
        if (line.len == 0) continue;
        const request_now: u64 = @intCast(std.Io.Clock.real.now(init.io).toMilliseconds());
        const response = ziac.mcp.handleProtocolRequestAlloc(allocator, line, envelope, .{
            .now_millis = request_now,
            .stage = stackStage(stage),
            .project = project_id,
            .provider = provider,
        }, kernel.kernel()) catch {
            try writer.interface.writeAll("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"Invalid Request\"}}\n");
            try writer.interface.flush();
            continue;
        };
        if (response) |payload| {
            defer allocator.free(payload);
            try writer.interface.writeAll(payload);
            try writer.interface.writeByte('\n');
            try writer.interface.flush();
        }
    }
}

fn optionValue(args: []const [:0]const u8, name: []const u8) ?[]const u8 {
    for (args, 0..) |arg, index| if (std.mem.eql(u8, arg, name) and index + 1 < args.len) return args[index + 1];
    return null;
}

fn stackStage(stage: []const u8) []const u8 {
    return stage;
}
