const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{
    .project_id = "example-project",
    .primary_region = "europe-west1",
};

fn build(allocator: std.mem.Allocator) !ziac.gcp.ServiceObservability {
    var channel = try ziac.gcp.monitoring.NotificationChannel.build(allocator, provider, .{
        .name = "platform-email",
        .display_name = "Platform email",
        .type = "email",
        .labels = &.{.{ .key = "email_address", .value = "platform@example.com" }},
    });
    defer channel.deinit(allocator);
    var base = ziac.ResourceGraph.init(allocator);
    defer base.deinit();
    try base.addResource(channel.node);
    const channels = [_]ziac.PublicOutput([]const u8){channel.name};
    return ziac.gcp.ServiceObservability.build(allocator, provider, .{
        .base_graph = &base,
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
        .notification_channels = &channels,
        .availability_goal = 0.999,
        .latency = .{ .goal = 0.99, .threshold_seconds = 0.5 },
    });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var observability = try build(allocator);
    defer observability.deinit();
    var permissions = try ziac.gcp.intelligence.synthesizePermissionPlan(allocator, &observability.graph);
    defer permissions.deinit(allocator);
    std.debug.print("Monitoring: {d} resources, {d} causal edges, {d} exact permissions\n", .{
        observability.graph.resources.items.len,
        observability.graph.dependencies.items.len,
        permissions.deployer_permissions.len,
    });
}

test "monitoring example compiles service SLO probe alert and dashboard" {
    var observability = try build(std.testing.allocator);
    defer observability.deinit();
    try observability.graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 7), observability.graph.resources.items.len);
}
