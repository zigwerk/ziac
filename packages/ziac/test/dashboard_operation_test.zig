const std = @import("std");
const ziac = @import("ziac");

test "dashboard operations construct fixed argv and bind apply to the saved digest" {
    var request = try ziac.dashboard_operation.Request.parseAlloc(std.testing.allocator,
        \\{"schema":"ziac.dashboard-operation-request.v1","operation":"plan","project":"control-plane","stack":"control-plane","stage":"prod","provider":"gcp"}
    );
    defer request.deinit();

    var plan = try ziac.dashboard_operation.planCommandAlloc(std.testing.allocator, .{
        .executable = "/opt/ziac/bin/ziac",
        .project_root = "/repo/platform/control-plane",
        .plan_root = "/repo/.ziac/dashboard/plans",
    }, request);
    defer plan.deinit();
    try std.testing.expectEqualStrings("/repo/platform/control-plane", plan.cwd);
    try std.testing.expectEqualStrings("/opt/ziac/bin/ziac", plan.argv[0]);
    try std.testing.expectEqualStrings("plan", plan.argv[1]);
    try std.testing.expect(std.mem.indexOf(u8, plan.plan_path.?, "control-plane-prod") != null);
    try std.testing.expectEqualStrings("--allow-live", plan.argv[plan.argv.len - 1]);

    var apply_request = try ziac.dashboard_operation.Request.parseAlloc(std.testing.allocator,
        \\{"schema":"ziac.dashboard-operation-request.v1","operation":"apply","project":"control-plane","stack":"control-plane","stage":"prod","provider":"gcp","plan_digest":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","confirm_destructive":true}
    );
    defer apply_request.deinit();
    var apply = try ziac.dashboard_operation.applyCommandAlloc(std.testing.allocator, .{
        .executable = "/opt/ziac/bin/ziac",
        .project_root = "/repo/platform/control-plane",
        .plan_root = "/repo/.ziac/dashboard/plans",
    }, apply_request);
    defer apply.deinit();
    try std.testing.expect(containsPair(apply.argv, "--approval", apply_request.plan_digest.?));
    try std.testing.expect(containsPair(apply.argv, "--plan", apply.plan_path.?));
    try std.testing.expect(contains(apply.argv, "--confirm"));
}

test "dashboard operations reject shell and path injection" {
    try std.testing.expectError(error.InvalidOperationRequest, ziac.dashboard_operation.Request.parseAlloc(std.testing.allocator,
        \\{"schema":"ziac.dashboard-operation-request.v1","operation":"plan","project":"../../etc","stack":"x; rm -rf /","stage":"prod","provider":"gcp"}
    ));
    try std.testing.expectError(error.InvalidOperationRequest, ziac.dashboard_operation.Request.parseAlloc(std.testing.allocator,
        \\{"schema":"ziac.dashboard-operation-request.v1","operation":"apply","project":"api","stack":"api","stage":"prod","provider":"gcp"}
    ));
}

test "dashboard operation lifecycle is explicit and cancellation is capability scoped" {
    var registry = ziac.dashboard_operation.Registry.init(std.testing.allocator);
    defer registry.deinit();

    const id = try registry.register(.watch, "control-plane", "control-plane", "prod", 42);
    defer std.testing.allocator.free(id);
    try registry.markRunning(id, 43);
    const running = try registry.serializeAlloc(id);
    defer std.testing.allocator.free(running);
    try std.testing.expect(std.mem.indexOf(u8, running, "\"schema\":\"ziac.dashboard-operation.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, running, "\"phase\":\"running\"") != null);
    try std.testing.expect(try registry.requestCancel(id));
    try std.testing.expect(!try registry.requestCancel("op-unknown"));
    try registry.finish(id, .cancelled, 44, null, "terminated by user");
    const cancelled = try registry.serializeAlloc(id);
    defer std.testing.allocator.free(cancelled);
    try std.testing.expect(std.mem.indexOf(u8, cancelled, "\"phase\":\"cancelled\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cancelled, "\"finished_at_millis\":44") != null);
}

test "dashboard operation diagnostics are bounded and credential material is redacted" {
    var registry = ziac.dashboard_operation.Registry.init(std.testing.allocator);
    defer registry.deinit();
    const id = try registry.register(.apply, "api", "api", "prod", 1);
    defer std.testing.allocator.free(id);
    const noisy = ("x" ** 5000) ++ " Authorization: Bearer secret";
    try registry.finish(id, .failed, 2, 1, noisy);
    const projection = try registry.serializeAlloc(id);
    defer std.testing.allocator.free(projection);
    try std.testing.expect(projection.len < 5000);
    try std.testing.expect(std.mem.indexOf(u8, projection, "Bearer secret") == null);
}

fn contains(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, expected)) return true;
    return false;
}

fn containsPair(values: []const []const u8, name: []const u8, value: []const u8) bool {
    for (values[0..values.len -| 1], 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, name) and std.mem.eql(u8, values[index + 1], value)) return true;
    }
    return false;
}
