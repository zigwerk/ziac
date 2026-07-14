const std = @import("std");
const ziac = @import("ziac");

const monitoring = ziac.gcp.monitoring;

test "notification channels preserve secret label references" {
    var channel = try monitoring.NotificationChannel.build(std.testing.allocator, config(), .{
        .name = "platform-slack",
        .display_name = "Platform Slack",
        .type = "slack",
        .labels = &.{.{ .key = "channel_name", .value = "#platform" }},
        .secret_labels = &.{.{
            .key = "auth_token",
            .value = secret("projects/ziac-dev/secrets/slack-token"),
        }},
        .user_labels = &.{.{ .key = "environment", .value = "prod" }},
    });
    defer channel.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.monitoring.NotificationChannel", channel.node.type_name);
    const canonical = try channel.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(canonical);
    try std.testing.expect(std.mem.indexOf(u8, canonical, "slack-token") != null);
    try std.testing.expect(std.mem.indexOf(u8, canonical, "xoxb-") == null);
}

test "uptime checks model HTTP probes without persisting credentials" {
    var check = try monitoring.UptimeCheck.build(std.testing.allocator, config(), .{
        .name = "global-api",
        .display_name = "Global API",
        .target = .{ .http = .{
            .host = "api.example.com",
            .path = "/health",
            .use_ssl = true,
            .validate_ssl = true,
            .headers = &.{.{ .key = "x-probe", .value = "ziac" }},
            .secret_headers = &.{.{
                .key = "authorization",
                .value = secret("projects/ziac-dev/secrets/probe-token"),
            }},
        } },
        .period_seconds = 60,
        .timeout_seconds = 10,
        .selected_regions = &.{ "EUROPE", "USA" },
        .content_matchers = &.{.{ .content = "ok", .matcher = .contains_string }},
    });
    defer check.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.monitoring.UptimeCheck", check.node.type_name);
    try std.testing.expectEqualStrings("HTTP", input(check.node.inputs, "protocol").string);
    const canonical = try check.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(canonical);
    try std.testing.expect(std.mem.indexOf(u8, canonical, "probe-token") != null);
    try std.testing.expect(std.mem.indexOf(u8, canonical, "Bearer live-secret") == null);
    try std.testing.expectError(error.InvalidPeriod, monitoring.UptimeCheck.build(std.testing.allocator, config(), .{
        .name = "bad",
        .display_name = "Bad check",
        .target = .{ .tcp = .{ .host = "db.example.com", .port = 26257 } },
        .period_seconds = 30,
    }));
}

test "alert policies use typed PromQL threshold absence and log conditions" {
    var policy = try monitoring.AlertPolicy.build(std.testing.allocator, config(), .{
        .name = "global-api-health",
        .display_name = "Global API health",
        .combiner = .or_conditions,
        .severity = .critical,
        .documentation = .{ .content = "Global API requires intervention." },
        .conditions = &.{
            .{ .id = "latency", .display_name = "Latency", .condition = .{ .threshold = .{
                .filter = "metric.type=\"run.googleapis.com/request_latencies\"",
                .comparison = .greater_than,
                .threshold = 1000,
                .duration_seconds = 300,
                .alignment_period_seconds = 60,
                .per_series_aligner = "ALIGN_PERCENTILE_99",
            } } },
            .{ .id = "availability", .display_name = "Availability", .condition = .{ .promql = .{
                .query = "sum(rate(requests_total{code=~\"5..\"}[5m])) > 0",
                .duration_seconds = 60,
                .evaluation_interval_seconds = 30,
            } } },
            .{ .id = "missing", .display_name = "No traffic", .condition = .{ .absence = .{
                .filter = "metric.type=\"run.googleapis.com/request_count\"",
                .duration_seconds = 600,
            } } },
            .{ .id = "panic", .display_name = "Panic log", .condition = .{ .log_match = .{
                .filter = "resource.type=\"cloud_run_revision\" severity>=ERROR textPayload:\"panic\"",
            } } },
        },
        .notification_channels = &.{known("projects/ziac-dev/notificationChannels/123")},
        .auto_close_seconds = 1800,
        .user_labels = &.{.{ .key = "service", .value = "global-api" }},
    });
    defer policy.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.monitoring.AlertPolicy", policy.node.type_name);
    try std.testing.expectEqual(@as(usize, 4), input(policy.node.inputs, "conditions").list.len);
    try std.testing.expect(input(policy.node.inputs, "notification_channels").list[0] == .string);
    try std.testing.expectError(error.InvalidCondition, monitoring.AlertPolicy.build(std.testing.allocator, config(), .{
        .name = "empty",
        .display_name = "No conditions",
        .conditions = &.{},
    }));
}

test "dashboards use structured mosaic widgets and output references" {
    var dashboard = try monitoring.Dashboard.build(std.testing.allocator, config(), .{
        .name = "global-api",
        .display_name = "Global API",
        .columns = 48,
        .tiles = &.{
            .{ .x = 0, .y = 0, .width = 24, .height = 8, .widget = .{ .text = .{
                .title = "Runbook",
                .content = "## Global API\nFollow the linked runbook.",
            } } },
            .{ .x = 24, .y = 0, .width = 24, .height = 16, .widget = .{ .xy_chart = .{
                .title = "Requests",
                .series = &.{.{
                    .filter = "metric.type=\"run.googleapis.com/request_count\"",
                    .legend = "requests",
                    .per_series_aligner = "ALIGN_RATE",
                    .alignment_period_seconds = 60,
                }},
            } } },
            .{ .x = 0, .y = 8, .width = 24, .height = 8, .widget = .{ .alert_chart = .{
                .title = "Availability alert",
                .alert_policy = known("projects/ziac-dev/alertPolicies/123"),
            } } },
        },
        .labels = &.{.{ .key = "service", .value = "global-api" }},
    });
    defer dashboard.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.monitoring.Dashboard", dashboard.node.type_name);
    try std.testing.expectEqual(@as(i64, 48), input(dashboard.node.inputs, "columns").integer);
    try std.testing.expectEqual(@as(usize, 3), input(dashboard.node.inputs, "tiles").list.len);
}

test "Monitoring services and SLOs encode stable identity and periods" {
    var service = try monitoring.Service.build(std.testing.allocator, config(), .{
        .name = "global-api",
        .display_name = "Global API",
        .kind = .{ .cloud_run = .{ .service_name = "global-api", .location = "europe-west1" } },
        .user_labels = &.{.{ .key = "tier", .value = "edge" }},
    });
    defer service.deinit(std.testing.allocator);
    var availability = try monitoring.ServiceLevelObjective.build(std.testing.allocator, config(), .{
        .name = "availability-999",
        .service_name = "global-api",
        .service = service.name,
        .display_name = "99.9% availability",
        .goal = 0.999,
        .period = .{ .rolling = 2_592_000 },
        .indicator = .{ .request_ratio = .{
            .good_service_filter = "metric.type=\"run.googleapis.com/request_count\" metric.label.response_code_class!=\"5xx\"",
            .total_service_filter = "metric.type=\"run.googleapis.com/request_count\"",
        } },
    });
    defer availability.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.monitoring.Service", service.node.type_name);
    try std.testing.expectEqualStrings("gcp.monitoring.ServiceLevelObjective", availability.node.type_name);
    try std.testing.expect(input(availability.node.inputs, "service") == .output_ref);
    try std.testing.expectError(error.InvalidGoal, monitoring.ServiceLevelObjective.build(std.testing.allocator, config(), .{
        .name = "invalid",
        .service_name = "global-api",
        .service = service.name,
        .display_name = "Impossible",
        .goal = 1.1,
        .period = .{ .calendar = .month },
        .indicator = .{ .basic = .availability },
    }));
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
}

fn known(text: []const u8) ziac.PublicOutput([]const u8) {
    return .known(text);
}

fn secret(resource_name: []const u8) ziac.SecretOutput(ziac.value.SecretReference) {
    return .known(.{ .provider = "gcp-secret-manager", .resource = resource_name, .version = "1" });
}

fn input(inputs: ziac.value.Value, name: []const u8) ziac.value.Value {
    for (inputs.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    unreachable;
}
