const std = @import("std");
const ziac = @import("ziac");

const project_fixture = @embedFile("fixtures/agent/ziac.project.json");

test "shared agent tool kernel executes declared verification through MCP" {
    var project = try ziac.agent_contract.Project.parseAlloc(std.testing.allocator, project_fixture);
    defer project.deinit();
    var runner = ziac.agent_tools.ScriptedVerificationRunner.init("all checks passed");
    var kernel = ziac.agent_tools.Kernel.init(std.testing.allocator, project, runner.runner());
    defer kernel.deinit();
    const envelope = ziac.agent_contract.CapabilityEnvelope{
        .id = "mcp-verify",
        .stages = &.{"dev"},
        .projects = &.{"project-dev"},
        .providers = &.{.gcp},
        .permissions = .{ .read = true },
        .budget = .{},
        .expires_at_millis = 20_000,
    };
    const response = try ziac.mcp.handleRequestAlloc(
        std.testing.allocator,
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"ziac_verify\",\"arguments\":{\"acceptance_check\":\"check-global-api\"}}}",
        envelope,
        .{ .now_millis = 10_000, .stage = "dev", .project = "project-dev", .provider = .gcp },
        kernel.kernel(),
    );
    defer std.testing.allocator.free(response);

    try std.testing.expectEqual(@as(usize, 1), runner.call_count);
    try std.testing.expect(std.mem.indexOf(u8, response, "ziac.verification-receipt.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "all checks passed") != null);
}

test "shared agent tool kernel simulates deterministic scenarios without mutation" {
    var project = try ziac.agent_contract.Project.parseAlloc(std.testing.allocator, project_fixture);
    defer project.deinit();
    var runner = ziac.agent_tools.ScriptedVerificationRunner.init("unused");
    var kernel = ziac.agent_tools.Kernel.init(std.testing.allocator, project, runner.runner());
    defer kernel.deinit();
    const artifact = try kernel.invoke("ziac_simulate", "{\"scenario_id\":\"missing-iam\",\"kind\":\"iam_denied\",\"seed\":42,\"max_steps\":8,\"target_resource\":\"gcp.run.Service.europe-west1.api\",\"requirement\":\"global-api-healthy\",\"acceptance_check\":\"check-global-api\"}");
    try std.testing.expect(std.mem.indexOf(u8, artifact, "ziac.scenario-receipt.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "\"complete\":true") != null);
}
