const std = @import("std");
const contract = @import("agent_contract.zig");
const resource = @import("resource.zig");

pub const Authority = enum { read, plan, process };

pub const ToolSpec = struct {
    name: []const u8,
    description: []const u8,
    authority: Authority,
    input_schema: []const u8,
};

const registry = [_]ToolSpec{
    .{ .name = "ziac_context", .description = "Compile one bounded evidence-derived development context for a task", .authority = .read, .input_schema = "{\"type\":\"object\",\"properties\":{\"task\":{\"type\":\"string\"},\"budget\":{\"type\":\"integer\",\"minimum\":512,\"maximum\":4194304},\"changed_paths\":{\"type\":\"array\",\"maxItems\":256,\"items\":{\"type\":\"string\"}}},\"required\":[\"task\"],\"additionalProperties\":false}" },
    .{ .name = "ziac_simulate", .description = "Run a deterministic infrastructure scenario without mutation", .authority = .read, .input_schema = "{\"type\":\"object\",\"properties\":{\"scenario_id\":{\"type\":\"string\"},\"kind\":{\"type\":\"string\"},\"seed\":{\"type\":\"integer\"},\"max_steps\":{\"type\":\"integer\"},\"target_resource\":{\"type\":\"string\"},\"requirement\":{\"type\":\"string\"},\"acceptance_check\":{\"type\":\"string\"}},\"required\":[\"scenario_id\",\"kind\",\"seed\",\"max_steps\",\"target_resource\",\"requirement\",\"acceptance_check\"],\"additionalProperties\":false}" },
    .{ .name = "ziac_propose", .description = "Create an immutable evidence-backed repair proposal", .authority = .plan, .input_schema = "{\"type\":\"object\",\"properties\":{\"scenario_id\":{\"type\":\"string\"},\"requirement\":{\"type\":\"string\"},\"resource_id\":{\"type\":\"string\"},\"finding_id\":{\"type\":\"string\"},\"operation\":{\"type\":\"string\"},\"verification\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}},\"required\":[\"scenario_id\",\"requirement\",\"resource_id\",\"finding_id\",\"operation\",\"verification\"],\"additionalProperties\":false}" },
    .{ .name = "ziac_verify", .description = "Run one manifest-declared fixed-argv acceptance check", .authority = .process, .input_schema = "{\"type\":\"object\",\"properties\":{\"acceptance_check\":{\"type\":\"string\"}},\"required\":[\"acceptance_check\"],\"additionalProperties\":false}" },
};

pub fn tools() []const ToolSpec {
    return &registry;
}

/// Best-effort extraction used only to seed fiber-local causal correlation.
/// Protocol validation and authorization still happen in the normal request
/// handler; failure to extract never grants authority or changes semantics.
pub fn developmentTaskAlloc(allocator: std.mem.Allocator, request_json: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, request_json, .{}) catch return null;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return null,
    };
    const method = switch (root.get("method") orelse return null) {
        .string => |value| value,
        else => return null,
    };
    if (!std.mem.eql(u8, method, "tools/call")) return null;
    const params = switch (root.get("params") orelse return null) {
        .object => |value| value,
        else => return null,
    };
    const name = switch (params.get("name") orelse return null) {
        .string => |value| value,
        else => return null,
    };
    if (!std.mem.eql(u8, name, "ziac_context")) return null;
    const arguments = switch (params.get("arguments") orelse return null) {
        .object => |value| value,
        else => return null,
    };
    const task = switch (arguments.get("task") orelse return null) {
        .string => |value| value,
        else => return null,
    };
    if (task.len == 0 or task.len > 4096) return null;
    return try allocator.dupe(u8, task);
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
        .read => .read,
        .plan => .plan,
        .process => .process,
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

pub const protocol_version = "2025-11-25";

pub fn handleProtocolRequestAlloc(
    allocator: std.mem.Allocator,
    request_json: []const u8,
    envelope: contract.CapabilityEnvelope,
    context: AuthorizationContext,
    kernel: Kernel,
) !?[]u8 {
    if (request_json.len == 0 or request_json.len > 1024 * 1024 or std.mem.indexOfScalar(u8, request_json, '\n') != null) return error.InvalidMcpRequest;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, request_json, .{}) catch return error.InvalidMcpRequest;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidMcpRequest,
    };
    const jsonrpc = switch (root.get("jsonrpc") orelse return error.InvalidMcpRequest) {
        .string => |value| value,
        else => return error.InvalidMcpRequest,
    };
    if (!std.mem.eql(u8, jsonrpc, "2.0")) return error.InvalidMcpRequest;
    const method = switch (root.get("method") orelse return error.InvalidMcpRequest) {
        .string => |value| value,
        else => return error.InvalidMcpRequest,
    };
    if (std.mem.eql(u8, method, "notifications/initialized")) {
        if (root.get("id") != null) return error.InvalidMcpRequest;
        return null;
    }
    const request_id = switch (root.get("id") orelse return error.InvalidMcpRequest) {
        .integer => |value| std.math.cast(u64, value) orelse return error.InvalidMcpRequest,
        else => return error.InvalidMcpRequest,
    };
    if (std.mem.eql(u8, method, "initialize")) return try initializeResponseAlloc(allocator, request_id);
    if (std.mem.eql(u8, method, "tools/list")) return try toolsListResponseAlloc(allocator, request_id);
    if (std.mem.eql(u8, method, "tools/call")) {
        return handleRequestAlloc(allocator, request_json, envelope, context, kernel) catch |err|
            return try toolErrorResponseAlloc(allocator, request_id, @errorName(err));
    }
    return try protocolErrorResponseAlloc(allocator, request_id, -32601, "Method not found");
}

fn initializeResponseAlloc(allocator: std.mem.Allocator, request_id: u64) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = request_id,
        .result = .{
            .protocolVersion = protocol_version,
            .capabilities = .{ .tools = .{ .listChanged = false } },
            .serverInfo = .{ .name = "ziac", .version = "0.1.0" },
            .instructions = "Use deterministic simulation and proposal tools first. Verification requires explicit process authority.",
        },
    }, .{});
}

fn toolsListResponseAlloc(allocator: std.mem.Allocator, request_id: u64) ![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.print(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{{\"tools\":[", .{request_id});
    for (registry, 0..) |tool, index| {
        if (index != 0) try output.append(allocator, ',');
        const name = try std.json.Stringify.valueAlloc(allocator, tool.name, .{});
        defer allocator.free(name);
        const description = try std.json.Stringify.valueAlloc(allocator, tool.description, .{});
        defer allocator.free(description);
        try output.print(allocator, "{{\"name\":{s},\"description\":{s},\"inputSchema\":{s},\"annotations\":{{\"readOnlyHint\":{},\"destructiveHint\":false}}}}", .{
            name,
            description,
            tool.input_schema,
            tool.authority == .read,
        });
    }
    try output.appendSlice(allocator, "]}}}");
    return output.toOwnedSlice(allocator);
}

fn toolErrorResponseAlloc(allocator: std.mem.Allocator, request_id: u64, message: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = request_id,
        .result = .{ .content = &.{.{ .type = "text", .text = message }}, .isError = true },
    }, .{});
}

fn protocolErrorResponseAlloc(allocator: std.mem.Allocator, request_id: u64, code: i64, message: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = request_id,
        .@"error" = .{ .code = code, .message = message },
    }, .{});
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
    output.writer.writeAll("\nVerification requires explicit process authority and runs only manifest-declared fixed-argv checks. No shell command strings are accepted.\n") catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

fn findTool(name: []const u8) ?ToolSpec {
    for (registry) |tool| if (std.mem.eql(u8, tool.name, name)) return tool;
    return null;
}
