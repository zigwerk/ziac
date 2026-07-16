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
        .permissions = .{ .read = true, .process = true },
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

test "shared agent tool kernel delegates the context endpoint to one injected provider" {
    var project = try ziac.agent_contract.Project.parseAlloc(std.testing.allocator, project_fixture);
    defer project.deinit();
    var runner = ziac.agent_tools.ScriptedVerificationRunner.init("unused");
    var context = ziac.agent_tools.ScriptedContextProvider.init("{\"schema\":\"zigeffect.agent.development-context.v1\"}");
    var kernel = ziac.agent_tools.Kernel.init(std.testing.allocator, project, runner.runner()).withContextProvider(context.provider());
    defer kernel.deinit();
    const artifact = try kernel.invoke("ziac_context", "{\"task\":\"task-ziac\",\"budget\":4096}");
    try std.testing.expectEqual(@as(usize, 1), context.call_count);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "zigeffect.agent.development-context.v1") != null);
}

test "native verification accepts fixed argv and rejects shell or traversal executables" {
    try ziac.agent_tools.validateVerificationArgv(&.{ "zig", "build", "test" });
    try std.testing.expectError(error.ShellVerificationDenied, ziac.agent_tools.validateVerificationArgv(&.{ "/bin/sh", "-c", "echo unsafe" }));
    try std.testing.expectError(error.ShellVerificationDenied, ziac.agent_tools.validateVerificationArgv(&.{ "bash", "script.sh" }));
    try std.testing.expectError(error.VerificationTraversalDenied, ziac.agent_tools.validateVerificationArgv(&.{"../outside/check"}));
}

test "legacy acceptance command is never passed to a verification runner" {
    const legacy =
        \\{"schema":"ziac.project.v1","project":"legacy","source_roots":["src"],"components":[{"id":"api","resources":[]}],"requirements":[{"id":"r","summary":"x","component":"api","required":true}],"acceptance_checks":[{"id":"check","requirement":"r","command":"touch /tmp/unsafe"}],"environments":[],"adaptations":[],"scenarios":[{"id":"s","requirement":"r","acceptance_check":"check","seed":1,"required":true}],"authority":{"read":true,"plan":true,"apply":false,"delete":false,"secret_read":false,"live_network":false,"process":true}}
    ;
    var project = try ziac.agent_contract.Project.parseAlloc(std.testing.allocator, legacy);
    defer project.deinit();
    var runner = ziac.agent_tools.ScriptedVerificationRunner.init("must not run");
    var kernel = ziac.agent_tools.Kernel.init(std.testing.allocator, project, runner.runner());
    defer kernel.deinit();
    try std.testing.expectError(error.LegacyAcceptanceCommandDenied, kernel.invoke("ziac_verify", "{\"acceptance_check\":\"check\"}"));
    try std.testing.expectEqual(@as(usize, 0), runner.call_count);
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
