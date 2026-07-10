const std = @import("std");
const ziac = @import("ziac");

const rpc = ziac.gcp.rpc;

test "Cloud Run RPC descriptors retain the pinned Google API contract" {
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
