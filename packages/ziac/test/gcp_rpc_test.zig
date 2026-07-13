const std = @import("std");
const ziac = @import("ziac");

const rpc = ziac.gcp.rpc;

test "Cloud Run RPC descriptors retain the pinned Google API contract" {
    try rpc.verifyPinnedContract(std.testing.allocator);
    try std.testing.expectEqualStrings(
        "95de37fafded89761dd958268242904a6d893eae",
        rpc.googleapis_revision,
    );
    const create = rpc.cloud_run_v2.create_service;
    try std.testing.expectEqualStrings("run.googleapis.com", create.default_host);
    try std.testing.expectEqualStrings("google.cloud.run.v2.Services", create.service);
    try std.testing.expectEqualStrings("CreateService", create.method);
    try std.testing.expectEqualStrings("google.cloud.run.v2.CreateServiceRequest", create.request_type);
    try std.testing.expectEqualStrings("google.longrunning.Operation", create.response_type);
    try std.testing.expectEqualStrings("/v2/{parent=projects/*/locations/*}/services", create.rest.?.path_template);
    try std.testing.expectEqualStrings("service", create.rest.?.body.?);
    try std.testing.expectEqualStrings("parent", create.routing_field.?);
    try std.testing.expectEqualStrings("google.cloud.run.v2.Service", create.long_running.?.response_type);
    try std.testing.expect(create.semantics.validate_only);
    try std.testing.expect(!create.semantics.update_mask);

    const update = rpc.cloud_run_v2.update_service;
    try std.testing.expectEqual(rpc.HttpMethod.patch, update.rest.?.method);
    try std.testing.expectEqualStrings("service.name", update.routing_field.?);
    try std.testing.expect(update.semantics.update_mask);
    try std.testing.expect(update.semantics.etag);
    try std.testing.expect(update.semantics.reconciling);

    const get_policy = rpc.cloud_run_v2.get_service_iam_policy;
    try std.testing.expectEqual(rpc.HttpMethod.get, get_policy.rest.?.method);
    try std.testing.expectEqualStrings("/v2/{resource=projects/*/locations/*/services/*}:getIamPolicy", get_policy.rest.?.path_template);
    try std.testing.expectEqualStrings("resource", get_policy.routing_field.?);
    const set_policy = rpc.cloud_run_v2.set_service_iam_policy;
    try std.testing.expectEqual(rpc.HttpMethod.post, set_policy.rest.?.method);
    try std.testing.expectEqualStrings("/v2/{resource=projects/*/locations/*/services/*}:setIamPolicy", set_policy.rest.?.path_template);
    try std.testing.expectEqualStrings("*", set_policy.rest.?.body.?);
}

test "RPC REST binding expands validated resource names and query fields" {
    const create_path = try rpc.restPathAlloc(
        std.testing.allocator,
        rpc.cloud_run_v2.create_service,
        &.{.{ .field = "parent", .value = "projects/ziac-dev/locations/europe-west1" }},
        &.{.{ .field = "service_id", .value = "api" }},
    );
    defer std.testing.allocator.free(create_path);
    try std.testing.expectEqualStrings(
        "/v2/projects/ziac-dev/locations/europe-west1/services?serviceId=api",
        create_path,
    );

    const update_path = try rpc.restPathAlloc(
        std.testing.allocator,
        rpc.cloud_run_v2.update_service,
        &.{.{ .field = "service.name", .value = "projects/ziac-dev/locations/europe-west1/services/api" }},
        &.{.{ .field = "update_mask", .value = "labels,ingress,invokerIamDisabled,template" }},
    );
    defer std.testing.allocator.free(update_path);
    try std.testing.expectEqualStrings(
        "/v2/projects/ziac-dev/locations/europe-west1/services/api?updateMask=labels,ingress,invokerIamDisabled,template",
        update_path,
    );

    try std.testing.expectError(error.InvalidResourceName, rpc.restPathAlloc(
        std.testing.allocator,
        rpc.cloud_run_v2.get_service,
        &.{.{ .field = "name", .value = "projects/ziac-dev/zones/europe-west1/services/api" }},
        &.{},
    ));
    try std.testing.expectError(error.MissingPathParameter, rpc.restPathAlloc(
        std.testing.allocator,
        rpc.cloud_run_v2.get_service,
        &.{},
        &.{},
    ));
}

test "RPC transport selection never chooses experimental fallback implicitly" {
    const method = rpc.cloud_run_v2.get_service;
    try std.testing.expectEqual(
        rpc.Transport.grpc,
        try rpc.selectTransport(method, .{ .grpc_http2 = true, .rest_json = true }, .{}),
    );
    try std.testing.expectEqual(
        rpc.Transport.rest_transcoding,
        try rpc.selectTransport(method, .{ .rest_json = true }, .{}),
    );
    try std.testing.expectError(error.NoSupportedTransport, rpc.selectTransport(
        method,
        .{ .experimental_protobuf_http = true },
        .{},
    ));
    try std.testing.expectError(error.NoSupportedTransport, rpc.selectTransport(
        method,
        .{ .experimental_protobuf_http = true },
        .{ .allow_experimental_fallback = true },
    ));
}

test "RPC transport advertises gRPC only after the complete capability audit" {
    const incomplete = rpc.capabilitiesFromAudit(.{
        .http2 = true,
        .tls = true,
        .trailers = true,
        .deadlines = true,
        .cancellation = true,
        .multiplexing = true,
        .connection_reuse = true,
        .flow_control = false,
        .bounded_messages = true,
        .redacted_diagnostics = true,
    }, true);
    try std.testing.expect(!incomplete.grpc_http2);
    try std.testing.expectEqual(rpc.Transport.rest_transcoding, try rpc.selectTransport(
        rpc.cloud_run_v2.get_service,
        incomplete,
        .{},
    ));
}

test "Pub/Sub RPC descriptors retain the pinned v1 transcoding contract" {
    const create_topic = rpc.pubsub_v1.create_topic;
    try std.testing.expectEqual(rpc.HttpMethod.put, create_topic.rest.?.method);
    try std.testing.expectEqualStrings("pubsub.googleapis.com", create_topic.default_host);
    try std.testing.expectEqualStrings("google.pubsub.v1.Publisher", create_topic.service);
    try std.testing.expectEqualStrings("/v1/{name=projects/*/topics/*}", create_topic.rest.?.path_template);
    try std.testing.expectEqualStrings("*", create_topic.rest.?.body.?);
    try std.testing.expectEqualStrings("name", create_topic.routing_field.?);

    const create_schema = rpc.pubsub_v1.create_schema;
    try std.testing.expectEqual(rpc.HttpMethod.post, create_schema.rest.?.method);
    try std.testing.expectEqualStrings("/v1/{parent=projects/*}/schemas", create_schema.rest.?.path_template);
    try std.testing.expectEqualStrings("schema", create_schema.rest.?.body.?);

    const create_subscription = rpc.pubsub_v1.create_subscription;
    try std.testing.expectEqual(rpc.HttpMethod.put, create_subscription.rest.?.method);
    try std.testing.expectEqualStrings("/v1/{name=projects/*/subscriptions/*}", create_subscription.rest.?.path_template);

    const create_snapshot = rpc.pubsub_v1.create_snapshot;
    try std.testing.expectEqual(rpc.HttpMethod.put, create_snapshot.rest.?.method);
    try std.testing.expectEqualStrings("/v1/{name=projects/*/snapshots/*}", create_snapshot.rest.?.path_template);
}

test "Pub/Sub REST bindings expand canonical resource names and query fields" {
    const topic_path = try rpc.restPathAlloc(
        std.testing.allocator,
        rpc.pubsub_v1.create_topic,
        &.{.{ .field = "name", .value = "projects/ziac-dev/topics/orders" }},
        &.{},
    );
    defer std.testing.allocator.free(topic_path);
    try std.testing.expectEqualStrings("/v1/projects/ziac-dev/topics/orders", topic_path);

    const schema_path = try rpc.restPathAlloc(
        std.testing.allocator,
        rpc.pubsub_v1.create_schema,
        &.{.{ .field = "parent", .value = "projects/ziac-dev" }},
        &.{.{ .field = "schema_id", .value = "orders-v1" }},
    );
    defer std.testing.allocator.free(schema_path);
    try std.testing.expectEqualStrings("/v1/projects/ziac-dev/schemas?schemaId=orders-v1", schema_path);

    const update_path = try rpc.restPathAlloc(
        std.testing.allocator,
        rpc.pubsub_v1.update_subscription,
        &.{.{ .field = "subscription.name", .value = "projects/ziac-dev/subscriptions/orders-worker" }},
        &.{.{ .field = "update_mask", .value = "ackDeadlineSeconds,retryPolicy" }},
    );
    defer std.testing.allocator.free(update_path);
    try std.testing.expectEqualStrings(
        "/v1/projects/ziac-dev/subscriptions/orders-worker?updateMask=ackDeadlineSeconds,retryPolicy",
        update_path,
    );

    try std.testing.expectError(error.InvalidResourceName, rpc.restPathAlloc(
        std.testing.allocator,
        rpc.pubsub_v1.get_topic,
        &.{.{ .field = "topic", .value = "projects/ziac-dev/subscriptions/orders" }},
        &.{},
    ));
    try std.testing.expectEqual(
        rpc.Transport.rest_transcoding,
        try rpc.selectTransport(rpc.pubsub_v1.get_topic, .{ .rest_json = true }, .{}),
    );
}

test "Cloud Tasks and Eventarc RPC descriptors retain AIP lifecycle semantics" {
    try std.testing.expectEqualStrings("cloudtasks.googleapis.com", rpc.cloud_tasks_v2.create_queue.default_host);
    try std.testing.expectEqual(rpc.HttpMethod.post, rpc.cloud_tasks_v2.create_queue.rest.?.method);
    try std.testing.expectEqualStrings("/v2/{parent=projects/*/locations/*}/queues", rpc.cloud_tasks_v2.create_queue.rest.?.path_template);
    try std.testing.expect(rpc.cloud_tasks_v2.update_queue.semantics.update_mask);
    try std.testing.expectEqualStrings("queue.name", rpc.cloud_tasks_v2.update_queue.routing_field.?);

    try std.testing.expectEqualStrings("eventarc.googleapis.com", rpc.eventarc_v1.create_trigger.default_host);
    try std.testing.expectEqualStrings("google.longrunning.Operation", rpc.eventarc_v1.create_trigger.response_type);
    try std.testing.expectEqualStrings("google.cloud.eventarc.v1.Trigger", rpc.eventarc_v1.create_trigger.long_running.?.response_type);
    try std.testing.expect(rpc.eventarc_v1.create_trigger.semantics.validate_only);
    try std.testing.expect(rpc.eventarc_v1.update_trigger.semantics.update_mask);
    try std.testing.expect(rpc.eventarc_v1.update_trigger.semantics.etag);
    try std.testing.expect(rpc.eventarc_v1.delete_trigger.semantics.etag);
}

test "Cloud Tasks and Eventarc REST bindings expand canonical paths and masks" {
    const queue_path = try rpc.restPathAlloc(
        std.testing.allocator,
        rpc.cloud_tasks_v2.update_queue,
        &.{.{ .field = "queue.name", .value = "projects/ziac-dev/locations/europe-west1/queues/invoice-worker" }},
        &.{.{ .field = "update_mask", .value = "rateLimits,retryConfig" }},
    );
    defer std.testing.allocator.free(queue_path);
    try std.testing.expectEqualStrings(
        "/v2/projects/ziac-dev/locations/europe-west1/queues/invoice-worker?updateMask=rateLimits,retryConfig",
        queue_path,
    );
    const trigger_path = try rpc.restPathAlloc(
        std.testing.allocator,
        rpc.eventarc_v1.create_trigger,
        &.{.{ .field = "parent", .value = "projects/ziac-dev/locations/europe-west1" }},
        &.{
            .{ .field = "trigger_id", .value = "orders-created" },
            .{ .field = "validate_only", .value = "true" },
        },
    );
    defer std.testing.allocator.free(trigger_path);
    try std.testing.expectEqualStrings(
        "/v1/projects/ziac-dev/locations/europe-west1/triggers?triggerId=orders-created&validateOnly=true",
        trigger_path,
    );
}
