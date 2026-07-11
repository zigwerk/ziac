const std = @import("std");
const ziac = @import("ziac");

test "MCP registry is read only first and contains no arbitrary shell" {
    const tools = ziac.mcp.tools();
    try std.testing.expectEqualStrings("ziac_status", tools[0].name);
    try std.testing.expectEqual(ziac.mcp.Authority.read, tools[0].authority);
    for (tools) |tool| {
        try std.testing.expect(std.mem.indexOf(u8, tool.name, "shell") == null);
        try std.testing.expect(std.mem.indexOf(u8, tool.name, "exec") == null);
    }
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
        .tool = "ziac_status",
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
    try std.testing.expectError(error.PlanDigestMismatch, ziac.mcp.authorize(envelope, .{
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
    try std.testing.expect(std.mem.indexOf(u8, skill, "ziac_status") != null);
    try std.testing.expect(std.mem.indexOf(u8, skill, "exact saved plan") != null);
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
        "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"ziac_status\",\"arguments\":{}}}",
        envelope,
        .{ .now_millis = 10_000, .stage = "dev", .project = "project-dev", .provider = .gcp },
        kernel.kernel(),
    );
    defer std.testing.allocator.free(response);
    try std.testing.expectEqual(@as(usize, 1), kernel.call_count);
    try std.testing.expectEqualStrings("ziac_status", kernel.last_tool.?);
    try std.testing.expect(std.mem.indexOf(u8, response, "ziac.agent-status.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "planning") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"id\":7") != null);
}
