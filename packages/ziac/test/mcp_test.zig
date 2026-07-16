const std = @import("std");
const ziac = @import("ziac");

test "MCP registry is read only first and contains no arbitrary shell" {
    const tools = ziac.mcp.tools();
    try std.testing.expectEqualStrings("ziac_context", tools[0].name);
    try std.testing.expectEqual(ziac.mcp.Authority.read, tools[0].authority);
    for (tools) |tool| {
        try std.testing.expect(std.mem.indexOf(u8, tool.name, "shell") == null);
        try std.testing.expect(std.mem.indexOf(u8, tool.name, "exec") == null);
    }
}

test "MCP extracts development task identity for runtime causal correlation" {
    const task = (try ziac.mcp.developmentTaskAlloc(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"ziac_context\",\"arguments\":{\"task\":\"task-proof-context\"}}}")).?;
    defer std.testing.allocator.free(task);
    try std.testing.expectEqualStrings("task-proof-context", task);
    try std.testing.expect((try ziac.mcp.developmentTaskAlloc(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/list\"}")) == null);
}

test "MCP protocol initializes and lists only production-backed tools" {
    var kernel = ziac.mcp.ScriptedKernel.init("{}");
    const envelope = ziac.agent_contract.CapabilityEnvelope{
        .id = "mcp-read",
        .stages = &.{"dev"},
        .projects = &.{"project-dev"},
        .providers = &.{.gcp},
        .permissions = .{ .read = true, .plan = true, .process = true },
        .budget = .{},
        .expires_at_millis = 20_000,
    };
    const initialized = (try ziac.mcp.handleProtocolRequestAlloc(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1\"}}}", envelope, .{ .now_millis = 10_000, .stage = "dev", .project = "project-dev", .provider = .gcp }, kernel.kernel())).?;
    defer std.testing.allocator.free(initialized);
    try std.testing.expect(std.mem.indexOf(u8, initialized, "ziac") != null);
    const listed = (try ziac.mcp.handleProtocolRequestAlloc(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}", envelope, .{ .now_millis = 10_000, .stage = "dev", .project = "project-dev", .provider = .gcp }, kernel.kernel())).?;
    defer std.testing.allocator.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "ziac_verify") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "ziac_context") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "ziac_apply_saved_plan") == null);
    try std.testing.expect((try ziac.mcp.handleProtocolRequestAlloc(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}", envelope, .{ .now_millis = 10_000, .stage = "dev", .project = "project-dev", .provider = .gcp }, kernel.kernel())) == null);
}

test "MCP cannot expand capability authority and exact plan apply remains gated" {
    const envelope = ziac.agent_contract.CapabilityEnvelope{
        .id = "mcp-dev",
        .stages = &.{"dev"},
        .projects = &.{"project-dev"},
        .providers = &.{.gcp},
        .permissions = .{ .read = true, .plan = true, .apply = true },
        .budget = .{ .max_updates = 1, .max_regions = 1, .max_monthly_cost_minor = 1000 },
        .expires_at_millis = 20_000,
        .approved_plan_digest = "approved-plan",
    };
    try ziac.mcp.authorize(envelope, .{
        .tool = "ziac_context",
        .now_millis = 10_000,
        .stage = "dev",
        .project = "project-dev",
        .provider = .gcp,
    });
    try ziac.mcp.authorize(envelope, .{
        .tool = "ziac_propose",
        .now_millis = 10_000,
        .stage = "dev",
        .project = "project-dev",
        .provider = .gcp,
    });
    try std.testing.expectError(error.ActionDenied, ziac.mcp.authorize(envelope, .{
        .tool = "ziac_verify",
        .now_millis = 10_000,
        .stage = "dev",
        .project = "project-dev",
        .provider = .gcp,
    }));
    try std.testing.expectError(error.UnknownMcpTool, ziac.mcp.authorize(envelope, .{
        .tool = "ziac_apply_saved_plan",
        .now_millis = 10_000,
        .stage = "dev",
        .project = "project-dev",
        .provider = .gcp,
        .plan_digest = "different",
        .updates = 1,
        .regions = 1,
    }));
    try std.testing.expectError(error.UnknownMcpTool, ziac.mcp.authorize(envelope, .{
        .tool = "run_shell",
        .now_millis = 10_000,
        .stage = "dev",
        .project = "project-dev",
        .provider = .gcp,
    }));
}

test "MCP responses preserve kernel artifacts and generated skills grant no authority" {
    const artifact = "{\"schema\":\"ziac.agent-status.v1\",\"state\":\"planning\"}";
    const response = try ziac.mcp.responseJsonAlloc(std.testing.allocator, 42, artifact);
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "ziac.agent-status.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "planning") != null);

    const skill = try ziac.mcp.skillMarkdownAlloc(std.testing.allocator, "Codex");
    defer std.testing.allocator.free(skill);
    try std.testing.expect(std.mem.indexOf(u8, skill, "ziac_simulate") != null);
    try std.testing.expect(std.mem.indexOf(u8, skill, "ziac_context") != null);
    try std.testing.expect(std.mem.indexOf(u8, skill, "fixed-argv") != null);
    try std.testing.expect(std.mem.indexOf(u8, skill, "ambient credentials grant authority") == null);
}

test "MCP tools call the same injected kernel and return its artifact unchanged" {
    const envelope = ziac.agent_contract.CapabilityEnvelope{
        .id = "mcp-read",
        .stages = &.{"dev"},
        .projects = &.{"project-dev"},
        .providers = &.{.gcp},
        .permissions = .{ .read = true },
        .budget = .{},
        .expires_at_millis = 20_000,
    };
    var kernel = ziac.mcp.ScriptedKernel.init("{\"schema\":\"ziac.agent-status.v1\",\"state\":\"planning\"}");
    const response = try ziac.mcp.handleRequestAlloc(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"ziac_simulate\",\"arguments\":{}}}",
        envelope,
        .{ .now_millis = 10_000, .stage = "dev", .project = "project-dev", .provider = .gcp },
        kernel.kernel(),
    );
    defer std.testing.allocator.free(response);
    try std.testing.expectEqual(@as(usize, 1), kernel.call_count);
    try std.testing.expectEqualStrings("ziac_simulate", kernel.last_tool.?);
    try std.testing.expect(std.mem.indexOf(u8, response, "ziac.agent-status.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "planning") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":7") != null);
}
