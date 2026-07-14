const std = @import("std");
const ziac = @import("ziac");

test "ServiceObservability composes service SLOs endpoint alert and dashboard" {
    var observability = try ziac.gcp.ServiceObservability.build(std.testing.allocator, config(), .{
        .name = "global-api",
        .display_name = "Global API",
        .service_kind = .{ .cloud_run = .{
            .service_name = "global-api",
            .location = "europe-west1",
        } },
        .endpoint = .{
            .host = "api.example.com",
            .path = "/healthz",
        },
        .availability_goal = 0.999,
        .latency = .{
            .goal = 0.99,
            .threshold_seconds = 0.5,
        },
        .period = .{ .rolling = 30 * 24 * 60 * 60 },
    });
    defer observability.deinit();

    try std.testing.expectEqual(@as(usize, 6), observability.graph.resources.items.len);
    try std.testing.expectEqualStrings("gcp.monitoring.Service", observability.graph.resources.items[0].type_name);
    try std.testing.expectEqualStrings("gcp.monitoring.ServiceLevelObjective", observability.graph.resources.items[1].type_name);
    try std.testing.expectEqualStrings("gcp.monitoring.ServiceLevelObjective", observability.graph.resources.items[2].type_name);
    try std.testing.expectEqualStrings("gcp.monitoring.UptimeCheck", observability.graph.resources.items[3].type_name);
    try std.testing.expectEqualStrings("gcp.monitoring.AlertPolicy", observability.graph.resources.items[4].type_name);
    try std.testing.expectEqualStrings("gcp.monitoring.Dashboard", observability.graph.resources.items[5].type_name);
    try std.testing.expect(observability.service.referenceOrNull() != null);
    try std.testing.expect(observability.availability_slo.referenceOrNull() != null);
    try std.testing.expect(observability.latency_slo.?.referenceOrNull() != null);
    try std.testing.expect(observability.uptime_check.referenceOrNull() != null);
    try std.testing.expect(observability.alert_policy.referenceOrNull() != null);
    try std.testing.expect(observability.dashboard.referenceOrNull() != null);
    try std.testing.expect(observability.graph.dependencies.items.len >= 7);

    const alert = observability.graph.resources.items[4];
    const conditions = input(alert.inputs, "conditions").list;
    const filter = input(conditions[0], "filter").string;
    try std.testing.expect(std.mem.indexOf(u8, filter, "api.example.com") != null);
}

test "ServiceObservability keeps notification channel output wiring and optional latency explicit" {
    var channel = try ziac.gcp.monitoring.NotificationChannel.build(std.testing.allocator, config(), .{
        .name = "platform-email",
        .display_name = "Platform email",
        .type = "email",
        .labels = &.{.{ .key = "email_address", .value = "platform@example.com" }},
    });
    defer channel.deinit(std.testing.allocator);

    var base = ziac.ResourceGraph.init(std.testing.allocator);
    defer base.deinit();
    try base.addResource(channel.node);

    const channels = [_]ziac.PublicOutput([]const u8){channel.name};
    var observability = try ziac.gcp.ServiceObservability.build(std.testing.allocator, config(), .{
        .base_graph = &base,
        .name = "payments",
        .display_name = "Payments",
        .endpoint = .{ .host = "payments.example.com" },
        .notification_channels = &channels,
    });
    defer observability.deinit();

    try std.testing.expect(observability.latency_slo == null);
    try std.testing.expectEqual(@as(usize, 6), observability.graph.resources.items.len);
    const alert = observability.graph.resources.items[4];
    try std.testing.expectEqual(@as(usize, 1), input(alert.inputs, "notification_channels").list.len);
    try std.testing.expect(observability.graph.dependencies.items.len >= 6);
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
}

fn input(inputs: ziac.value.Value, name: []const u8) ziac.value.Value {
    for (inputs.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    unreachable;
}
