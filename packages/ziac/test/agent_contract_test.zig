const std = @import("std");
const ziac = @import("ziac");

const fixture = @embedFile("fixtures/agent/ziac.project.json");

test "agent project contract validates requirements acceptance and adaptations" {
    var project = try ziac.agent_contract.Project.parseAlloc(std.testing.allocator, fixture);
    defer project.deinit();

    try std.testing.expectEqualStrings("agent-api", project.id);
    try std.testing.expectEqual(@as(usize, 1), project.requirements.len);
    try std.testing.expectEqualStrings("global-api-healthy", project.requirements[0].id);
    try std.testing.expectEqual(ziac.agent_contract.AdaptationStrategy.local_process, project.adaptationFor("gcp.run.Service").?);
    try std.testing.expectEqual(ziac.agent_contract.AdaptationStrategy.remote_only, project.adaptationFor("gcp.psc.Endpoint").?);
    try std.testing.expect(project.requirement("global-api-healthy") != null);
    try std.testing.expect(project.acceptanceCheck("check-global-api") != null);
    try std.testing.expectEqualStrings("zig", project.acceptanceCheck("check-global-api").?.argv[0]);
    try std.testing.expect(project.authority.process);
}

test "legacy shell acceptance checks parse for migration but cannot be executed" {
    const legacy =
        \\{"schema":"ziac.project.v1","project":"legacy","source_roots":["src"],"components":[{"id":"api","resources":[]}],"requirements":[{"id":"r","summary":"x","component":"api","required":true}],"acceptance_checks":[{"id":"check","requirement":"r","command":"zig build test"}],"environments":[],"adaptations":[],"scenarios":[{"id":"s","requirement":"r","acceptance_check":"check","seed":1,"required":true}],"authority":{"read":true,"plan":true,"apply":false,"delete":false,"secret_read":false,"live_network":false,"process":true}}
    ;
    var project = try ziac.agent_contract.Project.parseAlloc(std.testing.allocator, legacy);
    defer project.deinit();
    try std.testing.expectEqual(@as(usize, 0), project.acceptanceCheck("check").?.argv.len);
    try std.testing.expect(project.acceptanceCheck("check").?.legacy_command != null);
}

test "agent project contract rejects dangling and unsafe declarations" {
    const dangling =
        \\{"schema":"ziac.project.v1","project":"bad","source_roots":["src"],"components":[{"id":"api","resources":[]}],"requirements":[{"id":"r","summary":"x","component":"missing","required":true}],"acceptance_checks":[],"environments":[],"adaptations":[],"scenarios":[],"authority":{"read":true,"plan":true,"apply":false,"delete":false,"secret_read":false,"live_network":false}}
    ;
    try std.testing.expectError(error.DanglingComponent, ziac.agent_contract.Project.parseAlloc(std.testing.allocator, dangling));

    const unsafe =
        \\{"schema":"ziac.project.v1","project":"bad","source_roots":["../escape"],"components":[],"requirements":[],"acceptance_checks":[],"environments":[],"adaptations":[],"scenarios":[],"authority":{"read":true,"plan":true,"apply":true,"delete":true,"secret_read":true,"live_network":true}}
    ;
    try std.testing.expectError(error.InvalidSourceRoot, ziac.agent_contract.Project.parseAlloc(std.testing.allocator, unsafe));

    const unsafe_authority =
        \\{"schema":"ziac.project.v1","project":"bad","source_roots":["src"],"components":[],"requirements":[],"acceptance_checks":[],"environments":[],"adaptations":[],"scenarios":[],"authority":{"read":true,"plan":true,"apply":true,"delete":true,"secret_read":true,"live_network":true}}
    ;
    try std.testing.expectError(error.UnsafeDefaultAuthority, ziac.agent_contract.Project.parseAlloc(std.testing.allocator, unsafe_authority));
}

test "agent project contract owns the native development commands and stable proxy settings" {
    const manifest =
        \\{"schema":"ziac.project.v1","project":"dev-app","source_roots":["src"],"components":[],"requirements":[],"acceptance_checks":[],"environments":[],"adaptations":[],"scenarios":[],"development":{"source_root":".","build_argv":["zig","build"],"process_argv":["./zig-out/bin/app"],"health_path":"/health","proxy_port":4318,"generation_base_port":45000,"poll_millis":75},"authority":{"read":true,"plan":true,"apply":false,"delete":false,"secret_read":false,"live_network":false}}
    ;
    var project = try ziac.agent_contract.Project.parseAlloc(std.testing.allocator, manifest);
    defer project.deinit();

    try std.testing.expectEqualStrings("zig", project.development.?.build_argv[0]);
    try std.testing.expectEqualStrings("./zig-out/bin/app", project.development.?.process_argv[0]);
    try std.testing.expectEqual(@as(u16, 4318), project.development.?.proxy_port);
    try std.testing.expectEqual(@as(u64, 75), project.development.?.poll_millis);
}

test "capability envelope enforces target expiry budgets and exact plan authority" {
    const envelope = ziac.agent_contract.CapabilityEnvelope{
        .id = "cap-dev-42",
        .stages = &.{"dev_sean"},
        .projects = &.{"agent-api-ziac-disposable"},
        .providers = &.{ .gcp, .cockroach },
        .permissions = .{ .read = true, .plan = true, .apply = true },
        .budget = .{
            .max_creates = 3,
            .max_updates = 5,
            .max_deletes = 0,
            .max_regions = 2,
            .max_monthly_cost_minor = 8000,
        },
        .expires_at_millis = 20_000,
        .approved_plan_digest = "abc123",
    };
    try envelope.require(.{
        .now_millis = 10_000,
        .stage = "dev_sean",
        .project = "agent-api-ziac-disposable",
        .provider = .gcp,
        .action = .apply,
        .creates = 2,
        .updates = 1,
        .regions = 2,
        .monthly_cost_minor = 7000,
        .plan_digest = "abc123",
    });
    try std.testing.expectError(error.CapabilityExpired, envelope.require(.{
        .now_millis = 20_001,
        .stage = "dev_sean",
        .project = "agent-api-ziac-disposable",
        .provider = .gcp,
        .action = .apply,
        .plan_digest = "abc123",
    }));
    try std.testing.expectError(error.BudgetExceeded, envelope.require(.{
        .now_millis = 10_000,
        .stage = "dev_sean",
        .project = "agent-api-ziac-disposable",
        .provider = .gcp,
        .action = .apply,
        .creates = 4,
        .plan_digest = "abc123",
    }));
    try std.testing.expectError(error.PlanDigestMismatch, envelope.require(.{
        .now_millis = 10_000,
        .stage = "dev_sean",
        .project = "agent-api-ziac-disposable",
        .provider = .gcp,
        .action = .apply,
        .plan_digest = "different",
    }));
}
