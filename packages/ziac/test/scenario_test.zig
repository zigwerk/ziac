const std = @import("std");
const ziac = @import("ziac");

test "infrastructure scenarios are deterministic bounded and replayable" {
    const definition = ziac.scenario.Definition{
        .id = "missing-secret-access",
        .kind = .iam_denied,
        .seed = 42,
        .max_steps = 8,
        .target_resource = "gcp.run.Service.europe-west1.api",
        .requirement = "global-api-healthy",
        .acceptance_check = "check-global-api",
    };
    var first = try ziac.scenario.runAlloc(std.testing.allocator, definition);
    defer first.deinit();
    var second = try ziac.scenario.runAlloc(std.testing.allocator, definition);
    defer second.deinit();
    try std.testing.expectEqualStrings(first.replay_token, second.replay_token);
    try std.testing.expectEqualSlices(u8, first.json, second.json);
    try std.testing.expectEqual(@as(usize, 1), first.findings.len);
    try std.testing.expectEqual(ziac.scenario.FindingKind.missing_iam_permission, first.findings[0].kind);
    try std.testing.expect(first.steps <= definition.max_steps);
    try std.testing.expect(std.mem.indexOf(u8, first.json, "ziac scenario replay") != null);
}

test "scenario catalog covers provider dev database recovery and cleanup faults" {
    const kinds = ziac.scenario.catalog();
    try std.testing.expect(contains(kinds, .region_loss));
    try std.testing.expect(contains(kinds, .quota_exhausted));
    try std.testing.expect(contains(kinds, .iam_denied));
    try std.testing.expect(contains(kinds, .stale_etag));
    try std.testing.expect(contains(kinds, .interrupted_apply));
    try std.testing.expect(contains(kinds, .lro_stalled));
    try std.testing.expect(contains(kinds, .cockroach_gateway_loss));
    try std.testing.expect(contains(kinds, .secret_rotation));
    try std.testing.expect(contains(kinds, .reload_failed));
    try std.testing.expect(contains(kinds, .rollback_failed));
    try std.testing.expect(contains(kinds, .ttl_cleanup));
}

test "repair proposals are immutable evidence artifacts and cannot grant apply" {
    var proposal = try ziac.scenario.proposalAlloc(std.testing.allocator, .{
        .scenario_id = "missing-secret-access",
        .requirement = "global-api-healthy",
        .resource_id = "gcp.run.Service.europe-west1.api",
        .finding_id = "finding-missing-iam",
        .operation = "grant roles/secretmanager.secretAccessor to runtime identity",
        .verification = &.{"check-global-api"},
    });
    defer proposal.deinit();
    try std.testing.expectEqual(@as(usize, 64), proposal.digest.len);
    try std.testing.expect(std.mem.indexOf(u8, proposal.json, "ziac.repair-proposal.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, proposal.json, "apply_authorized\":false") != null);
}

fn contains(kinds: []const ziac.scenario.Kind, expected: ziac.scenario.Kind) bool {
    for (kinds) |kind| if (kind == expected) return true;
    return false;
}
