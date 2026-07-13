const std = @import("std");
const ziac = @import("ziac");

const config = ziac.gcp.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
    .labels = &.{.{ .key = "managed-by", .value = "ziac" }},
};

test "Cloud Run service IAM member owns one exact invoker principal" {
    var service = try ziac.gcp.cloud_run.Service.build(std.testing.allocator, config, .{
        .name = "orders-worker",
        .image = "europe-west1-docker.pkg.dev/ziac-dev/apps/orders@sha256:abc",
    });
    defer service.deinit(std.testing.allocator);

    var invoker = try ziac.gcp.cloud_run.ServiceIamMember.build(std.testing.allocator, config, .{
        .name = "orders-push-invoker",
        .service = service.name,
        .role = "roles/run.invoker",
        .member = "serviceAccount:orders-push@ziac-dev.iam.gserviceaccount.com",
    });
    defer invoker.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.run.ServiceIamMember", invoker.node.type_name);
    try std.testing.expectEqualStrings("binding_id", invoker.binding_id.resource_ref.field);
    const inputs = try invoker.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(inputs);
    try std.testing.expect(std.mem.indexOf(u8, inputs, "gcp.run.Service.europe-west1.orders-worker") != null);
    try std.testing.expect(std.mem.indexOf(u8, inputs, "roles/run.invoker") != null);
    try std.testing.expect(ziac.gcp.live_provider.supports(invoker.node));
}

test "ZigSubscriber compiles authenticated push delivery and dead-letter authority" {
    var base = ziac.ResourceGraph.init(std.testing.allocator);
    defer base.deinit();
    var service = try ziac.gcp.cloud_run.Service.build(std.testing.allocator, config, .{
        .name = "orders-worker",
        .image = "europe-west1-docker.pkg.dev/ziac-dev/apps/orders@sha256:abc",
    });
    defer service.deinit(std.testing.allocator);
    try base.addResource(service.node);

    var subscriber = try ziac.gcp.ZigSubscriber.build(std.testing.allocator, config, .{
        .base_graph = &base,
        .name = "orders",
        .project_number = "123456789012",
        .service = service.name,
        .push_endpoint = "https://orders-worker.example.run.app/events/orders",
        .oidc_audience = "https://orders-worker.example.run.app",
        .publishers = &.{"serviceAccount:orders-api@ziac-dev.iam.gserviceaccount.com"},
        .allowed_persistence_regions = &.{ "europe-west1", "europe-west4" },
        .enable_message_ordering = true,
        .max_delivery_attempts = 12,
    });
    defer subscriber.deinit();

    try std.testing.expectEqual(@as(usize, 9), subscriber.graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 2), countType(&subscriber.graph, "gcp.pubsub.Topic"));
    try std.testing.expectEqual(@as(usize, 1), countType(&subscriber.graph, "gcp.pubsub.Subscription"));
    try std.testing.expectEqual(@as(usize, 2), countType(&subscriber.graph, "gcp.pubsub.TopicIamMember"));
    try std.testing.expectEqual(@as(usize, 1), countType(&subscriber.graph, "gcp.pubsub.SubscriptionIamMember"));
    try std.testing.expectEqual(@as(usize, 1), countType(&subscriber.graph, "gcp.run.ServiceIamMember"));
    try std.testing.expectEqual(@as(usize, 1), countType(&subscriber.graph, "gcp.iam.ServiceAccount"));

    const subscription = findType(&subscriber.graph, "gcp.pubsub.Subscription");
    try std.testing.expectEqualStrings("push", inputString(subscription, "delivery_kind"));
    try std.testing.expectEqualStrings("orders-push@ziac-dev.iam.gserviceaccount.com", inputString(subscription, "push_service_account"));
    try std.testing.expectEqual(@as(i64, 12), inputInteger(subscription, "max_delivery_attempts"));

    const run_invoker = findType(&subscriber.graph, "gcp.run.ServiceIamMember");
    try std.testing.expectEqualStrings("roles/run.invoker", inputString(run_invoker, "role"));
    try std.testing.expectEqualStrings("serviceAccount:orders-push@ziac-dev.iam.gserviceaccount.com", inputString(run_invoker, "member"));
    try expectDependency(&subscriber.graph, run_invoker.id, service.node.id);

    const service_agent = "serviceAccount:service-123456789012@gcp-sa-pubsub.iam.gserviceaccount.com";
    const dead_letter_access = findMember(&subscriber.graph, "gcp.pubsub.TopicIamMember", service_agent);
    try std.testing.expectEqualStrings("roles/pubsub.publisher", inputString(dead_letter_access, "role"));
    const acknowledge_access = findMember(&subscriber.graph, "gcp.pubsub.SubscriptionIamMember", service_agent);
    try std.testing.expectEqualStrings("roles/pubsub.subscriber", inputString(acknowledge_access, "role"));
    try subscriber.graph.validateAcyclic();
}

test "ZigSubscriber rejects an invalid project number and unsafe endpoint" {
    try std.testing.expectError(error.InvalidProjectNumber, ziac.gcp.ZigSubscriber.build(std.testing.allocator, config, .{
        .name = "orders",
        .project_number = "ziac-dev",
        .service = ziac.PublicOutput([]const u8).known("projects/ziac-dev/locations/europe-west1/services/orders-worker"),
        .push_endpoint = "https://orders-worker.example.run.app/events/orders",
    }));
    try std.testing.expectError(error.InvalidPushEndpoint, ziac.gcp.ZigSubscriber.build(std.testing.allocator, config, .{
        .name = "orders",
        .project_number = "123456789012",
        .service = ziac.PublicOutput([]const u8).known("projects/ziac-dev/locations/europe-west1/services/orders-worker"),
        .push_endpoint = "http://orders-worker.internal/events/orders",
    }));
}

fn countType(graph: *const ziac.ResourceGraph, type_name: []const u8) usize {
    var count: usize = 0;
    for (graph.resources.items) |node| {
        if (std.mem.eql(u8, node.type_name, type_name)) count += 1;
    }
    return count;
}

fn findType(graph: *const ziac.ResourceGraph, type_name: []const u8) ziac.ResourceNode {
    for (graph.resources.items) |node| if (std.mem.eql(u8, node.type_name, type_name)) return node;
    unreachable;
}

fn findMember(graph: *const ziac.ResourceGraph, type_name: []const u8, member: []const u8) ziac.ResourceNode {
    for (graph.resources.items) |node| {
        if (std.mem.eql(u8, node.type_name, type_name) and std.mem.eql(u8, inputString(node, "member"), member)) return node;
    }
    unreachable;
}

fn inputString(node: ziac.ResourceNode, name: []const u8) []const u8 {
    for (node.inputs.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value.string;
    unreachable;
}

fn inputInteger(node: ziac.ResourceNode, name: []const u8) i64 {
    for (node.inputs.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value.integer;
    unreachable;
}

fn expectDependency(graph: *const ziac.ResourceGraph, from: []const u8, to: []const u8) !void {
    for (graph.dependencies.items) |edge| {
        if (std.mem.eql(u8, edge.from, from) and std.mem.eql(u8, edge.to, to)) return;
    }
    return error.TestExpectedEqual;
}
