const std = @import("std");
const ziac = @import("ziac");

const MainProgram = ziac.zstd.fx.kernel.Effect(void, anyerror, .{ziac.agent_tools.ContextService}).Stateful(std.process.Init);

pub fn main(init: std.process.Init) !void {
    const raw_args = try init.minimal.args.toSlice(init.arena.allocator());
    var native_context = ziac.agent_tools.NativeContextProvider{
        .io = init.io,
        .project_dir = std.Io.Dir.cwd(),
        .manifest_path = optionValue(raw_args[1..], "--development-project") orelse "zigeffect.project.json",
    };
    const root_layer = ziac.agent_tools.contextLayer(native_context.provider());
    return ziac.process_runtime.runWithLayer(init, "ziac-mcp", root_layer, MainProgram.init(init, runMain), .{});
}

fn runMain(init: std.process.Init, ctx: *MainProgram.Context) !void {
    _ = ctx.recordCausal(.{
        .kind = .service_provided,
        .service_key = "ziac/ProcessSpawner",
        .label = "mcp-verification-runner",
        .status = "ready",
        .redacted_detail = "manifest-fixed-argv-only",
    });
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
    const context_provider = ctx.service(ziac.agent_tools.ContextService).*;
    var kernel = ziac.agent_tools.Kernel.init(allocator, project, verification_runner.runner()).withContextProvider(context_provider);
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
        const development_task = try ziac.mcp.developmentTaskAlloc(allocator, line);
        defer if (development_task) |task| allocator.free(task);
        var handle = ctx.runtime().withCausalContext(.{
            .agent_id = ziac.fx.stableCausalContextId(envelope.id),
            .development_task_id = if (development_task) |task| ziac.fx.stableCausalContextId(task) else null,
        });
        const response = handle.run(requestEffect(.{
            .line = line,
            .envelope = envelope,
            .authorization = .{
                .now_millis = request_now,
                .stage = stackStage(stage),
                .project = project_id,
                .provider = provider,
            },
            .kernel = kernel.kernel(),
        }).named("mcp.request")) catch {
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

const RequestState = struct {
    line: []const u8,
    envelope: ziac.agent_contract.CapabilityEnvelope,
    authorization: ziac.mcp.AuthorizationContext,
    kernel: ziac.mcp.Kernel,
};
const RequestProgram = ziac.zstd.fx.kernel.Effect(?[]u8, anyerror, .{}).Stateful(RequestState);

fn requestEffect(state: RequestState) RequestProgram {
    return RequestProgram.init(state, struct {
        fn run(request: RequestState, ctx: *RequestProgram.Context) anyerror!?[]u8 {
            _ = ctx.recordCausal(.{
                .kind = .workflow_event_recorded,
                .service_key = "ziac/McpServer",
                .label = "mcp.request",
                .status = "received",
                .redacted_detail = "bounded-jsonrpc-line",
            });
            return ziac.mcp.handleProtocolRequestAlloc(
                ctx.allocator(),
                request.line,
                request.envelope,
                request.authorization,
                request.kernel,
            );
        }
    }.run);
}

fn optionValue(args: []const [:0]const u8, name: []const u8) ?[]const u8 {
    for (args, 0..) |arg, index| if (std.mem.eql(u8, arg, name) and index + 1 < args.len) return args[index + 1];
    return null;
}

fn stackStage(stage: []const u8) []const u8 {
    return stage;
}
