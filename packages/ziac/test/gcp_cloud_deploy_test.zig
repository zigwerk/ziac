const std = @import("std");
const ziac = @import("ziac");

const deploy = ziac.gcp.cloud_deploy;

test "Cloud Deploy declarations compose pipeline targets automation custom actions and policy" {
    const provider = config();
    var dev = try deploy.Target.build(std.testing.allocator, provider, .{
        .name = "dev-eu",
        .location = "europe-west1",
        .runtime = .{ .cloud_run = .{ .location = "europe-west1" } },
        .execution = &.{.{ .usages = &.{ .render, .deploy }, .service_account = "deploy@ziac-dev.iam.gserviceaccount.com" }},
    });
    defer dev.deinit(std.testing.allocator);
    var prod = try deploy.Target.build(std.testing.allocator, provider, .{
        .name = "prod-us",
        .location = "europe-west1",
        .runtime = .{ .cloud_run = .{ .location = "us-central1" } },
        .require_approval = true,
    });
    defer prod.deinit(std.testing.allocator);

    const stages = [_]deploy.Stage{
        .{ .target = dev.name, .profiles = &.{"dev"}, .strategy = .{ .standard = .{ .verify = true } } },
        .{ .target = prod.name, .profiles = &.{"prod"}, .strategy = .{ .canary = .{ .percentages = &.{ 10, 50 }, .verify = true } } },
    };
    var pipeline = try deploy.DeliveryPipeline.build(std.testing.allocator, provider, .{
        .name = "global-api",
        .location = "europe-west1",
        .description = "Global Cloud Run progression",
        .stages = &stages,
    });
    defer pipeline.deinit(std.testing.allocator);

    var custom_type = try deploy.CustomTargetType.build(std.testing.allocator, provider, .{
        .name = "edge-runtime",
        .location = "europe-west1",
        .actions = .{ .deploy = "deploy-edge", .render = "render-edge" },
    });
    defer custom_type.deinit(std.testing.allocator);
    var custom_target = try deploy.Target.build(std.testing.allocator, provider, .{
        .name = "edge",
        .location = "europe-west1",
        .runtime = .{ .custom = .{ .target_type = custom_type.name } },
    });
    defer custom_target.deinit(std.testing.allocator);

    const rules = [_]deploy.AutomationRule{
        .{ .promote = .{ .id = "promote-prod", .destination_target_id = "prod-us", .wait_seconds = 300 } },
        .{ .timed_promote = .{ .id = "promote-nightly", .schedule = "0 2 * * *", .time_zone = "UTC", .destination_target_id = "prod-us" } },
        .{ .advance = .{ .id = "advance-canary", .source_phases = &.{ "canary-10", "canary-50" }, .wait_seconds = 60 } },
        .{ .repair = .{ .id = "repair-prod", .retry = .{ .attempts = 3, .wait_seconds = 60, .backoff = .exponential }, .rollback = .{} } },
    };
    var automation = try deploy.Automation.build(std.testing.allocator, provider, .{
        .name = "safe-progress",
        .location = "europe-west1",
        .pipeline_name = "global-api",
        .pipeline = pipeline.name,
        .service_account = "automation@ziac-dev.iam.gserviceaccount.com",
        .target_ids = &.{"dev-eu"},
        .rules = &rules,
        .suspended = true,
    });
    defer automation.deinit(std.testing.allocator);

    const policy_rules = [_]deploy.RolloutRestriction{.{
        .id = "prod-freeze",
        .invokers = &.{ .user, .automation },
        .actions = &.{ .create, .advance, .approve, .rollback },
        .time_zone = "Europe/London",
        .weekly_windows = &.{.{ .days = &.{ .friday, .saturday, .sunday }, .start = .{ .hour = 18 }, .end = .{ .hour = 24 } }},
    }};
    var policy = try deploy.DeployPolicy.build(std.testing.allocator, provider, .{
        .name = "production-guard",
        .location = "europe-west1",
        .selectors = &.{.{ .pipeline_id = "global-api", .target_id = "prod-us" }},
        .rules = &policy_rules,
    });
    defer policy.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.deploy.DeliveryPipeline.europe-west1.global-api", pipeline.node.id);
    try std.testing.expectEqualStrings("gcp.deploy.Automation.europe-west1.global-api.safe-progress", automation.node.id);
    try std.testing.expect(policy.node.lifecycle.protect);
    try std.testing.expect(policy.node.lifecycle.retain_on_delete);
}

test "Cloud Deploy rejects invalid progression target and policy contracts" {
    const provider = config();
    const target = ziac.PublicOutput([]const u8).known("projects/ziac-dev/locations/europe-west1/targets/dev");
    try std.testing.expectError(error.InvalidCanary, deploy.DeliveryPipeline.build(std.testing.allocator, provider, .{
        .name = "api",
        .location = "europe-west1",
        .stages = &.{.{ .target = target, .strategy = .{ .canary = .{ .percentages = &.{ 50, 10 } } } }},
    }));
    try std.testing.expectError(error.InvalidTarget, deploy.Target.build(std.testing.allocator, provider, .{
        .name = "gke",
        .location = "europe-west1",
        .runtime = .{ .gke = .{ .cluster = ziac.PublicOutput([]const u8).known("projects/ziac-dev/locations/europe-west1/clusters/api"), .internal_ip = true, .dns_endpoint = true } },
    }));
    try std.testing.expectError(error.DuplicateUsage, deploy.Target.build(std.testing.allocator, provider, .{
        .name = "run",
        .location = "europe-west1",
        .runtime = .{ .cloud_run = .{ .location = "europe-west1" } },
        .execution = &.{
            .{ .usages = &.{.render} },
            .{ .usages = &.{.render} },
        },
    }));
    try std.testing.expectError(error.InvalidAutomation, deploy.Automation.build(std.testing.allocator, provider, .{
        .name = "empty",
        .location = "europe-west1",
        .pipeline_name = "api",
        .pipeline = ziac.PublicOutput([]const u8).known("projects/ziac-dev/locations/europe-west1/deliveryPipelines/api"),
        .service_account = "automation@ziac-dev.iam.gserviceaccount.com",
        .target_ids = &.{"dev"},
        .rules = &.{},
    }));
    try std.testing.expectError(error.InvalidPolicy, deploy.DeployPolicy.build(std.testing.allocator, provider, .{
        .name = "empty",
        .location = "europe-west1",
        .selectors = &.{},
        .rules = &.{},
    }));
}

fn config() ziac.gcp.ProviderConfig {
    return .{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
        .service_regions = &.{ "europe-west1", "us-central1" },
        .network_tier = .premium,
    };
}
