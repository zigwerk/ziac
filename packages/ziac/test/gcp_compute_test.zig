const std = @import("std");
const ziac = @import("ziac");

const regions = [_][]const u8{ "europe-west1", "us-central1" };
const provider = ziac.gcp.config.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
    .service_regions = &regions,
    .network_tier = .premium,
};

test "Compute load balancer resources build stable typed declarations" {
    var address = try ziac.gcp.compute.GlobalAddress.build(std.testing.allocator, provider, .{ .name = "api-ip" });
    defer address.deinit(std.testing.allocator);
    var neg = try ziac.gcp.compute.RegionServerlessNeg.build(std.testing.allocator, provider, .{
        .name = "api-europe-west1",
        .region = "europe-west1",
        .cloud_run_service = "api",
    });
    defer neg.deinit(std.testing.allocator);
    const backends = [_]ziac.gcp.compute.ServerlessBackend{
        .{ .region = "europe-west1", .group = "projects/ziac-dev/regions/europe-west1/networkEndpointGroups/api-europe-west1" },
        .{ .region = "us-central1", .group = "projects/ziac-dev/regions/us-central1/networkEndpointGroups/api-us-central1" },
    };
    var backend = try ziac.gcp.compute.BackendService.build(std.testing.allocator, provider, .{
        .name = "api-backend",
        .backends = &backends,
    });
    defer backend.deinit(std.testing.allocator);
    var url_map = try ziac.gcp.compute.UrlMap.build(std.testing.allocator, provider, .{
        .name = "api-map",
        .default_service = "projects/ziac-dev/global/backendServices/api-backend",
    });
    defer url_map.deinit(std.testing.allocator);
    var proxy = try ziac.gcp.compute.TargetHttpsProxy.build(std.testing.allocator, provider, .{
        .name = "api-https",
        .url_map = "projects/ziac-dev/global/urlMaps/api-map",
        .ssl_certificates = &.{"projects/ziac-dev/global/sslCertificates/api-cert"},
    });
    defer proxy.deinit(std.testing.allocator);
    var forwarding = try ziac.gcp.compute.GlobalForwardingRule.build(std.testing.allocator, provider, .{
        .name = "api-https",
        .address = "203.0.113.10",
        .target = "projects/ziac-dev/global/targetHttpsProxies/api-https",
    });
    defer forwarding.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.compute.GlobalAddress.api-ip", address.node.id);
    try std.testing.expectEqualStrings("gcp.compute.RegionServerlessNeg.europe-west1.api-europe-west1", neg.node.id);
    try std.testing.expectEqualStrings("gcp.compute.BackendService.api-backend", backend.node.id);
    try std.testing.expectEqualStrings("gcp.compute.UrlMap.api-map", url_map.node.id);
    try std.testing.expectEqualStrings("gcp.compute.TargetHttpsProxy.api-https", proxy.node.id);
    try std.testing.expectEqualStrings("gcp.compute.GlobalForwardingRule.api-https", forwarding.node.id);
    try std.testing.expectEqualStrings("address", address.address.resource_ref.field);
    try std.testing.expectEqualStrings("self_link", neg.self_link.resource_ref.field);
    try std.testing.expectEqualStrings("self_link", backend.self_link.resource_ref.field);
    try std.testing.expectEqualStrings("self_link", url_map.self_link.resource_ref.field);
    try std.testing.expectEqualStrings("self_link", proxy.self_link.resource_ref.field);
    try std.testing.expectEqualStrings("ip_address", forwarding.ip_address.resource_ref.field);

    const backend_json = try backend.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(backend_json);
    try std.testing.expectEqualStrings(
        "{\"backends\":[{\"group\":\"projects/ziac-dev/regions/europe-west1/networkEndpointGroups/api-europe-west1\",\"region\":\"europe-west1\"},{\"group\":\"projects/ziac-dev/regions/us-central1/networkEndpointGroups/api-us-central1\",\"region\":\"us-central1\"}],\"load_balancing_scheme\":\"EXTERNAL_MANAGED\",\"name\":\"api-backend\",\"outlier_detection\":{},\"project_id\":\"ziac-dev\",\"protocol\":\"HTTP\"}",
        backend_json,
    );
}

test "Compute global resources require Premium tier and unique backend regions" {
    const standard = ziac.gcp.config.ProviderConfig{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    };
    try std.testing.expectError(
        error.PremiumTierRequired,
        ziac.gcp.compute.GlobalAddress.build(std.testing.allocator, standard, .{ .name = "api-ip" }),
    );
    const duplicate = [_]ziac.gcp.compute.ServerlessBackend{
        .{ .region = "europe-west1", .group = "group-a" },
        .{ .region = "europe-west1", .group = "group-b" },
    };
    try std.testing.expectError(
        error.DuplicateBackendRegion,
        ziac.gcp.compute.BackendService.build(std.testing.allocator, provider, .{
            .name = "api-backend",
            .backends = &duplicate,
        }),
    );
}

test "global forwarding rules retain typed allocated address inputs" {
    const address = ziac.Output([]const u8, .public).fromResource("gcp.compute.GlobalAddress.api-ip", "address");
    var forwarding = try ziac.gcp.compute.GlobalForwardingRule.build(std.testing.allocator, provider, .{
        .name = "api-https",
        .address_output = address,
        .target = "projects/ziac-dev/global/targetHttpsProxies/api-https",
    });
    defer forwarding.deinit(std.testing.allocator);
    const json = try forwarding.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"address\":{\"$output\":{\"field\":\"address\",\"resource\":\"gcp.compute.GlobalAddress.api-ip\"}}") != null);
}

test "backend service retains serverless outlier detection policy" {
    const backends = [_]ziac.gcp.compute.ServerlessBackend{
        .{ .region = "europe-west1", .group = "projects/ziac-dev/regions/europe-west1/networkEndpointGroups/api-eu" },
        .{ .region = "us-central1", .group = "projects/ziac-dev/regions/us-central1/networkEndpointGroups/api-us" },
    };
    var backend = try ziac.gcp.compute.BackendService.build(std.testing.allocator, provider, .{
        .name = "api-backend",
        .backends = &backends,
        .outlier_detection = .{},
    });
    defer backend.deinit(std.testing.allocator);
    const policy = inputValue(backend.node, "outlier_detection").object;
    try std.testing.expectEqual(@as(i64, 5), objectValue(policy, "consecutive_errors").integer);
    try std.testing.expectEqual(@as(i64, 180), objectValue(policy, "base_ejection_time_seconds").integer);
    try std.testing.expectEqual(@as(i64, 100), objectValue(policy, "enforcing_consecutive_errors").integer);
}

fn inputValue(node: ziac.ResourceNode, name: []const u8) ziac.value.Value {
    return objectValue(node.inputs.object, name);
}

fn objectValue(fields: []const ziac.value.Field, name: []const u8) ziac.value.Value {
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    unreachable;
}
