const std = @import("std");
const contract = @import("agent_contract.zig");
const resource = @import("resource.zig");

pub const Authority = enum { read, plan, proposal, verification, apply };

pub const ToolSpec = struct {
    name: []const u8,
    description: []const u8,
    authority: Authority,
};

const registry = [_]ToolSpec{
    .{ .name = "ziac_status", .description = "Read durable agent session status", .authority = .read },
    .{ .name = "ziac_graph_query", .description = "Read one resource and its graph neighborhood", .authority = .read },
    .{ .name = "ziac_evidence_query", .description = "Read bounded causal evidence", .authority = .read },
    .{ .name = "ziac_plan", .description = "Create a non-mutating infrastructure plan", .authority = .plan },
    .{ .name = "ziac_simulate", .description = "Run a deterministic infrastructure scenario", .authority = .read },
    .{ .name = "ziac_propose", .description = "Save an evidence-backed repair proposal", .authority = .proposal },
    .{ .name = "ziac_verify", .description = "Run declared requirement verification", .authority = .verification },
    .{ .name = "ziac_apply_saved_plan", .description = "Apply only an exact saved plan", .authority = .apply },
    .{ .name = "ziac_handoff", .description = "Create a redacted portable handoff", .authority = .read },
};

pub fn tools() []const ToolSpec {
    return &registry;
}

pub const Call = struct {
    tool: []const u8,
    now_millis: u64,
    started_at_millis: u64 = 0,
    stage: []const u8,
    project: []const u8,
    provider: resource.ProviderId,
    plan_digest: ?[]const u8 = null,
    creates: usize = 0,
    updates: usize = 0,
    deletes: usize = 0,
    regions: usize = 0,
    monthly_cost_minor: u64 = 0,
};

pub fn authorize(envelope: contract.CapabilityEnvelope, call: Call) !void {
    const tool = findTool(call.tool) orelse return error.UnknownMcpTool;
    const action: contract.Action = switch (tool.authority) {
        .read, .verification => .read,
        .plan, .proposal => .plan,
        .apply => .apply,
    };
    try envelope.require(.{
        .now_millis = call.now_millis,
        .started_at_millis = call.started_at_millis,
        .stage = call.stage,
        .project = call.project,
        .provider = call.provider,
        .action = action,
        .creates = call.creates,
        .updates = call.updates,
        .deletes = call.deletes,
        .regions = call.regions,
        .monthly_cost_minor = call.monthly_cost_minor,
        .plan_digest = call.plan_digest,
    });
}

pub fn responseJsonAlloc(allocator: std.mem.Allocator, request_id: u64, kernel_artifact: []const u8) std.mem.Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = request_id,
        .result = .{
            .content = &.{.{ .type = "text", .text = kernel_artifact }},
            .artifact = kernel_artifact,
            .isError = false,
        },
    }, .{}) catch return error.OutOfMemory;
}

pub const AuthorizationContext = struct {
    now_millis: u64,
    started_at_millis: u64 = 0,
    stage: []const u8,
    project: []const u8,
    provider: resource.ProviderId,
    plan_digest: ?[]const u8 = null,
    creates: usize = 0,
    updates: usize = 0,
    deletes: usize = 0,
    regions: usize = 0,
    monthly_cost_minor: u64 = 0,
};

pub const Kernel = struct {
    ptr: *anyopaque,
    invoke_fn: *const fn (*anyopaque, []const u8, []const u8) anyerror![]const u8,

    pub fn invoke(self: Kernel, tool: []const u8, arguments_json: []const u8) ![]const u8 {
        return self.invoke_fn(self.ptr, tool, arguments_json);
    }
};

const RpcRequest = struct {
    jsonrpc: []const u8,
    id: u64,
    method: []const u8,
    params: struct {
        name: []const u8,
        arguments: std.json.Value,
    },
};

pub fn handleRequestAlloc(
    allocator: std.mem.Allocator,
    request_json: []const u8,
    envelope: contract.CapabilityEnvelope,
    context: AuthorizationContext,
    kernel: Kernel,
) ![]u8 {
    var parsed = std.json.parseFromSlice(RpcRequest, allocator, request_json, .{}) catch return error.InvalidMcpRequest;
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.jsonrpc, "2.0") or !std.mem.eql(u8, parsed.value.method, "tools/call")) return error.InvalidMcpRequest;
    const tool = findTool(parsed.value.params.name) orelse return error.UnknownMcpTool;
    try authorize(envelope, .{
        .tool = tool.name,
        .now_millis = context.now_millis,
        .started_at_millis = context.started_at_millis,
        .stage = context.stage,
        .project = context.project,
        .provider = context.provider,
        .plan_digest = context.plan_digest,
        .creates = context.creates,
        .updates = context.updates,
        .deletes = context.deletes,
        .regions = context.regions,
        .monthly_cost_minor = context.monthly_cost_minor,
    });
    const arguments_json = std.json.Stringify.valueAlloc(allocator, parsed.value.params.arguments, .{}) catch return error.OutOfMemory;
    defer allocator.free(arguments_json);
    const artifact = try kernel.invoke(tool.name, arguments_json);
    return responseJsonAlloc(allocator, parsed.value.id, artifact);
}

pub const ScriptedKernel = struct {
    artifact: []const u8,
    call_count: usize = 0,
    last_tool: ?[]const u8 = null,

    pub fn init(artifact: []const u8) ScriptedKernel {
        return .{ .artifact = artifact };
    }

    pub fn kernel(self: *ScriptedKernel) Kernel {
        return .{ .ptr = self, .invoke_fn = invoke };
    }

    fn invoke(raw: *anyopaque, tool: []const u8, _: []const u8) ![]const u8 {
        const self: *ScriptedKernel = @ptrCast(@alignCast(raw));
        self.call_count += 1;
        self.last_tool = tool;
        return self.artifact;
    }
};

pub fn skillMarkdownAlloc(allocator: std.mem.Allocator, agent_name: []const u8) std.mem.Allocator.Error![]u8 {
    var output = try std.Io.Writer.Allocating.initCapacity(allocator, 2048);
    defer output.deinit();
    output.writer.print(
        "# Ziac for {s}\n\nUse Ziac's structured kernel; do not parse terminal prose. Ambient credentials never grant authority.\n\n",
        .{agent_name},
    ) catch return error.OutOfMemory;
    for (registry) |tool| {
        output.writer.print("- `{s}`: {s} ({s})\n", .{ tool.name, tool.description, @tagName(tool.authority) }) catch return error.OutOfMemory;
    }
    output.writer.writeAll("\nMutation requires an explicit capability. Apply accepts only an exact saved plan and matching digest.\n") catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

fn findTool(name: []const u8) ?ToolSpec {
    for (registry) |tool| if (std.mem.eql(u8, tool.name, name)) return tool;
    return null;
}
