const std = @import("std");
const ziac = @import("ziac");

test "AIP planner suppresses output drift and classifies immutable changes" {
    const aip = ziac.gcp.aip;
    const fields = [_]aip.FieldChange{
        .{ .path = "name", .behavior = .identifier, .changed = false },
        .{ .path = "template.containers.image", .behavior = .optional, .changed = true },
        .{ .path = "uri", .behavior = .output_only, .changed = true },
        .{ .path = "launch_stage", .behavior = .immutable, .changed = true },
    };
    var result = try aip.planChanges(std.testing.allocator, &fields);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(aip.ChangeKind.replace, result.kind);
    try std.testing.expectEqualStrings("template.containers.image", result.update_mask);
    try std.testing.expectEqual(@as(usize, 1), result.ignored_output_fields.len);
    try std.testing.expectEqualStrings("uri", result.ignored_output_fields[0]);
    try std.testing.expectEqualStrings("launch_stage", result.replacement_fields[0]);
}

test "AIP mutation identity is stable and list/readiness failures remain visible" {
    const aip = ziac.gcp.aip;
    var first: [36]u8 = undefined;
    var second: [36]u8 = undefined;
    aip.requestId("stack-prod", "gcp.run.Service.global.api", "update", &first);
    aip.requestId("stack-prod", "gcp.run.Service.global.api", "update", &second);
    try std.testing.expectEqualStrings(&first, &second);
    try std.testing.expectEqual(@as(u8, '4'), first[14]);

    try std.testing.expectError(error.PartialDiscovery, aip.requireCompleteList(.{
        .next_page_token = "",
        .@"unreachable" = &.{"asia-south1"},
    }));
    try std.testing.expectEqual(aip.Readiness.ready, try aip.serviceReadiness(.{
        .generation = 7,
        .observed_generation = 7,
        .reconciling = false,
        .terminal_state = "CONDITION_SUCCEEDED",
        .latest_created_revision = "api-00007",
        .latest_ready_revision = "api-00007",
    }));
    try std.testing.expectError(error.ReconciliationFailed, aip.serviceReadiness(.{
        .generation = 7,
        .observed_generation = 7,
        .reconciling = false,
        .terminal_state = "CONDITION_FAILED",
        .latest_created_revision = "api-00007",
        .latest_ready_revision = "api-00006",
    }));
}

test "google rpc Status details become typed provider causes" {
    const cause = try ziac.gcp.aip.parseStatusJson(
        std.testing.allocator,
        "{\"code\":8,\"message\":\"regional quota exceeded\",\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.QuotaFailure\"}]}",
    );
    defer cause.deinit(std.testing.allocator);
    try std.testing.expectEqual(ziac.gcp.aip.CauseKind.quota_exhausted, cause.kind);
    try std.testing.expectEqualStrings("google.rpc.QuotaFailure", cause.detail_type.?);
}
