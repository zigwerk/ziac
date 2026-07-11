const std = @import("std");
const ziac = @import("ziac");

test "watch deploy coalesces rapid saves and converges to newest digest" {
    var controller = ziac.watch_deploy.Controller.init(std.testing.allocator);
    defer controller.deinit();
    try controller.submit("sha256:first");
    try std.testing.expectEqualStrings("sha256:first", (try controller.startNext()).?);
    try controller.submit("sha256:second");
    try controller.submit("sha256:newest");
    try std.testing.expect(controller.cancelRequested());
    try std.testing.expectEqualStrings("sha256:newest", controller.pendingDigest().?);
    try controller.finishActive(.cancelled);
    try std.testing.expectEqualStrings("sha256:newest", (try controller.startNext()).?);
    try controller.finishActive(.complete);
    try std.testing.expectEqual(@as(?[]const u8, null), controller.pendingDigest());
    try std.testing.expectEqual(@as(?[]const u8, null), controller.activeDigest());
    try std.testing.expectEqual(@as(u64, 1), controller.superseded_count);
    try std.testing.expectEqual(@as(u64, 1), controller.cancelled_count);
}

test "watch deployment is capability gated and promotes only ready immutable revisions" {
    const envelope = ziac.agent_contract.CapabilityEnvelope{
        .id = "watch-dev",
        .stages = &.{"dev_sean"},
        .projects = &.{"project-dev"},
        .providers = &.{.gcp},
        .permissions = .{ .read = true, .plan = true, .apply = true },
        .budget = .{ .max_updates = 1, .max_regions = 2, .max_monthly_cost_minor = 1000 },
        .expires_at_millis = 20_000,
        .approved_plan_digest = "watch-plan",
    };
    var runtime = ziac.watch_deploy.ScriptedRuntime.init();
    const receipt = try ziac.watch_deploy.execute(runtime.runtime(), envelope, .{
        .now_millis = 10_000,
        .stage = "dev_sean",
        .project = "project-dev",
        .plan_digest = "watch-plan",
        .image_ref = "europe-west1-docker.pkg.dev/project-dev/apps/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .regions = 2,
    });
    try std.testing.expectEqual(ziac.watch_deploy.Status.complete, receipt.status);
    try std.testing.expectEqual(@as(usize, 1), runtime.push_count);
    try std.testing.expectEqual(@as(usize, 1), runtime.revision_count);
    try std.testing.expectEqual(@as(usize, 1), runtime.readiness_count);
    try std.testing.expectEqual(@as(usize, 1), runtime.traffic_count);
    try std.testing.expect(receipt.no_traffic_verified);

    try std.testing.expectError(error.WatchProductionForbidden, ziac.watch_deploy.execute(runtime.runtime(), envelope, .{
        .now_millis = 10_000,
        .stage = "prod",
        .project = "project-dev",
        .plan_digest = "watch-plan",
        .image_ref = "repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .regions = 1,
    }));
    try std.testing.expectError(error.WatchDestructiveChange, ziac.watch_deploy.execute(runtime.runtime(), envelope, .{
        .now_millis = 10_000,
        .stage = "dev_sean",
        .project = "project-dev",
        .plan_digest = "watch-plan",
        .image_ref = "repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .regions = 1,
        .destructive = true,
    }));
}

test "watch deployment preserves traffic when readiness fails" {
    const envelope = ziac.agent_contract.CapabilityEnvelope{
        .id = "watch-dev",
        .stages = &.{"dev"},
        .projects = &.{"project-dev"},
        .providers = &.{.gcp},
        .permissions = .{ .apply = true },
        .budget = .{ .max_updates = 1, .max_regions = 1, .max_monthly_cost_minor = 1000 },
        .expires_at_millis = 20_000,
        .approved_plan_digest = "watch-plan",
    };
    var runtime = ziac.watch_deploy.ScriptedRuntime.init();
    runtime.ready = false;
    const receipt = try ziac.watch_deploy.execute(runtime.runtime(), envelope, .{
        .now_millis = 10_000,
        .stage = "dev",
        .project = "project-dev",
        .plan_digest = "watch-plan",
        .image_ref = "repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .regions = 1,
    });
    try std.testing.expectEqual(ziac.watch_deploy.Status.readiness_failed, receipt.status);
    try std.testing.expectEqual(@as(usize, 0), runtime.traffic_count);
}

test "watch deployment records phase timings and emits a JSON event stream" {
    const envelope = ziac.agent_contract.CapabilityEnvelope{
        .id = "watch-timed",
        .stages = &.{"dev"},
        .projects = &.{"project-dev"},
        .providers = &.{.gcp},
        .permissions = .{ .apply = true },
        .budget = .{ .max_updates = 1, .max_regions = 1 },
        .expires_at_millis = 20_000,
        .approved_plan_digest = "watch-plan",
    };
    var runtime = ziac.watch_deploy.ScriptedRuntime.init();
    runtime.now_millis = 1_000;
    runtime.push_millis = 120;
    runtime.revision_millis = 300;
    runtime.readiness_millis = 500;
    runtime.traffic_millis = 80;
    const receipt = try ziac.watch_deploy.execute(runtime.runtime(), envelope, .{
        .now_millis = 1_000,
        .stage = "dev",
        .project = "project-dev",
        .plan_digest = "watch-plan",
        .image_ref = "repo@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .regions = 1,
    });

    try std.testing.expectEqual(@as(u64, 1_000), receipt.timings.total_millis);
    try std.testing.expectEqual(@as(u64, 120), receipt.timings.push_millis);
    try std.testing.expectEqual(@as(u64, 300), receipt.timings.revision_millis);
    try std.testing.expectEqual(@as(u64, 500), receipt.timings.readiness_millis);
    try std.testing.expectEqual(@as(u64, 80), receipt.timings.traffic_millis);
    try std.testing.expect(!receipt.slo_miss);

    const events = try ziac.watch_deploy.eventStreamJsonAlloc(std.testing.allocator, receipt);
    defer std.testing.allocator.free(events);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"phase\":\"push\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "\"phase\":\"traffic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, events, "ziac.watch-deploy.v1") != null);
}
