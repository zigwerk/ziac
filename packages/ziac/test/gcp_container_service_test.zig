const std = @import("std");
const ziac = @import("ziac");

const regions = [_][]const u8{ "europe-west1", "us-central1" };
const provider = ziac.gcp.config.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
    .service_regions = &regions,
    .network_tier = .premium,
    .service_account = "api@ziac-dev.iam.gserviceaccount.com",
};

test "global ContainerService builds regional services and singleton routing resources" {
    var component = try ziac.gcp.global.ContainerService.build(std.testing.allocator, provider, .{
        .name = "api",
        .image = "europe-west1-docker.pkg.dev/ziac-dev/apps/api@sha256:abc",
        .regions = &regions,
        .domain = "api.example.com",
        .dns_zone = "example-com",
    });
    defer component.deinit();

    try std.testing.expectEqualStrings("https://api.example.com", component.url.value);
    try std.testing.expectEqual(@as(usize, 14), component.graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 13), component.graph.dependencies.items.len);
    try std.testing.expectEqual(@as(usize, 2), countType(&component.graph, "gcp.run.Service"));
    try std.testing.expectEqual(@as(usize, 2), countType(&component.graph, "gcp.compute.RegionServerlessNeg"));
    try std.testing.expectEqual(@as(usize, 1), countType(&component.graph, "gcp.compute.GlobalAddress"));
    try std.testing.expectEqual(@as(usize, 1), countType(&component.graph, "gcp.compute.BackendService"));
    try std.testing.expectEqual(@as(usize, 1), countType(&component.graph, "gcp.compute.ManagedSslCertificate"));
    try std.testing.expectEqual(@as(usize, 1), countType(&component.graph, "gcp.dns.RecordSet"));

    for (component.graph.resources.items) |node| {
        if (!std.mem.eql(u8, node.type_name, "gcp.run.Service")) continue;
        try std.testing.expectEqualStrings("INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER", inputString(node, "ingress"));
        try std.testing.expect(inputBool(node, "allow_unauthenticated"));
    }
    const dns = findType(&component.graph, "gcp.dns.RecordSet");
    const rrdatas = inputValue(dns, "rrdatas").list;
    try std.testing.expectEqual(@as(usize, 1), rrdatas.len);
    try std.testing.expect(rrdatas[0] == .output_ref);
    try std.testing.expectEqualStrings("gcp.compute.GlobalAddress.api-ip", rrdatas[0].output_ref.resource_id);
    const backend = findType(&component.graph, "gcp.compute.BackendService");
    const outlier = inputValue(backend, "outlier_detection").object;
    try std.testing.expectEqual(@as(i64, 180), objectValue(outlier, "base_ejection_time_seconds").integer);
    for (component.graph.resources.items) |node| {
        if (!std.mem.eql(u8, node.type_name, "gcp.compute.GlobalForwardingRule")) continue;
        try std.testing.expect(inputValue(node, "address") == .output_ref);
        try std.testing.expectEqualStrings("gcp.compute.GlobalAddress.api-ip", inputValue(node, "address").output_ref.resource_id);
    }
    try component.graph.validateAcyclic();
}

test "global ContainerService omits optional DNS and HTTP redirect resources" {
    var component = try ziac.gcp.global.ContainerService.build(std.testing.allocator, provider, .{
        .name = "api",
        .image = "example/api@sha256:abc",
        .regions = &regions,
        .domain = "api.example.com",
        .http_redirect = false,
    });
    defer component.deinit();

    try std.testing.expectEqual(@as(usize, 0), countType(&component.graph, "gcp.dns.RecordSet"));
    try std.testing.expectEqual(@as(usize, 0), countType(&component.graph, "gcp.compute.TargetHttpProxy"));
    try std.testing.expectEqual(@as(usize, 0), countPort(&component.graph, 80));
    try std.testing.expectEqual(@as(usize, 10), component.graph.resources.items.len);
}

test "global ContainerService validates global and production availability constraints" {
    const standard = ziac.gcp.config.ProviderConfig{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    };
    try std.testing.expectError(
        error.PremiumTierRequired,
        ziac.gcp.global.ContainerService.build(std.testing.allocator, standard, .{
            .name = "api",
            .image = "example/api@sha256:abc",
            .regions = &regions,
            .domain = "api.example.com",
        }),
    );
    try std.testing.expectError(
        error.DuplicateRegion,
        ziac.gcp.global.ContainerService.build(std.testing.allocator, provider, .{
            .name = "api",
            .image = "example/api@sha256:abc",
            .regions = &.{ "europe-west1", "europe-west1" },
            .domain = "api.example.com",
        }),
    );
    try std.testing.expectError(
        error.InsufficientRegions,
        ziac.gcp.global.ContainerService.build(std.testing.allocator, provider, .{
            .name = "api",
            .image = "example/api@sha256:abc",
            .regions = &.{"europe-west1"},
            .domain = "api.example.com",
        }),
    );
    try std.testing.expectError(
        error.ProductionMinInstancesRequired,
        ziac.gcp.global.ContainerService.build(std.testing.allocator, provider, .{
            .name = "api",
            .image = "example/api@sha256:abc",
            .regions = &regions,
            .domain = "api.example.com",
            .health_mode = .production,
        }),
    );
    try std.testing.expectError(
        error.ProductionProbeRequired,
        ziac.gcp.global.ContainerService.build(std.testing.allocator, provider, .{
            .name = "api",
            .image = "example/api@sha256:abc",
            .regions = &regions,
            .domain = "api.example.com",
            .health_mode = .production,
            .min_instances = 1,
        }),
    );
}

test "global ContainerService graph is deterministic" {
    const args = ziac.gcp.global.ContainerServiceArgs{
        .name = "api",
        .image = "example/api@sha256:abc",
        .regions = &regions,
        .domain = "api.example.com",
        .dns_zone = "example-com",
    };
    var first = try ziac.gcp.global.ContainerService.build(std.testing.allocator, provider, args);
    defer first.deinit();
    var second = try ziac.gcp.global.ContainerService.build(std.testing.allocator, provider, args);
    defer second.deinit();

    try std.testing.expectEqual(first.graph.resources.items.len, second.graph.resources.items.len);
    try std.testing.expectEqual(first.graph.dependencies.items.len, second.graph.dependencies.items.len);
    for (first.graph.resources.items, second.graph.resources.items) |left, right| {
        try std.testing.expectEqualStrings(left.id, right.id);
        try std.testing.expectEqual(left.inputs_hash, right.inputs_hash);
    }
    for (first.graph.dependencies.items, second.graph.dependencies.items) |left, right| {
        try std.testing.expectEqualStrings(left.from, right.from);
        try std.testing.expectEqualStrings(left.to, right.to);
    }
}

test "global ContainerService applies the matching Direct VPC subnet per region" {
    const regional_vpc = [_]ziac.gcp.global.container_service.RegionalDirectVpc{
        .{ .region = "europe-west1", .config = .{
            .network_output = ziac.PublicOutput([]const u8).known("projects/ziac-dev/global/networks/api-db"),
            .subnetwork_output = ziac.PublicOutput([]const u8).known("projects/ziac-dev/regions/europe-west1/subnetworks/api-db-eu"),
        } },
        .{ .region = "us-central1", .config = .{
            .network_output = ziac.PublicOutput([]const u8).known("projects/ziac-dev/global/networks/api-db"),
            .subnetwork_output = ziac.PublicOutput([]const u8).known("projects/ziac-dev/regions/us-central1/subnetworks/api-db-us"),
        } },
    };
    var component = try ziac.gcp.global.ContainerService.build(std.testing.allocator, provider, .{
        .name = "api",
        .image = "example/api@sha256:abc",
        .regions = &regions,
        .domain = "api.example.com",
        .regional_direct_vpc = &regional_vpc,
    });
    defer component.deinit();

    for (component.graph.resources.items) |node| {
        if (!std.mem.eql(u8, node.type_name, "gcp.run.Service")) continue;
        const region = inputString(node, "region");
        const vpc = inputValue(node, "vpc_access").object;
        const subnetwork = objectValue(vpc, "subnetwork").string;
        try std.testing.expect(std.mem.indexOf(u8, subnetwork, region) != null);
        try std.testing.expectEqualStrings("PRIVATE_RANGES_ONLY", objectValue(vpc, "egress").string);
    }

    try std.testing.expectError(error.RegionalVpcMismatch, ziac.gcp.global.ContainerService.build(std.testing.allocator, provider, .{
        .name = "api",
        .image = "example/api@sha256:abc",
        .regions = &regions,
        .domain = "api.example.com",
        .regional_direct_vpc = regional_vpc[0..1],
    }));
}

fn countType(graph: *const ziac.ResourceGraph, type_name: []const u8) usize {
    var count: usize = 0;
    for (graph.resources.items) |node| if (std.mem.eql(u8, node.type_name, type_name)) {
        count += 1;
    };
    return count;
}

fn countPort(graph: *const ziac.ResourceGraph, port: i64) usize {
    var count: usize = 0;
    for (graph.resources.items) |node| {
        if (!std.mem.eql(u8, node.type_name, "gcp.compute.GlobalForwardingRule")) continue;
        if (inputValue(node, "port").integer == port) count += 1;
    }
    return count;
}

fn findType(graph: *const ziac.ResourceGraph, type_name: []const u8) ziac.ResourceNode {
    for (graph.resources.items) |node| if (std.mem.eql(u8, node.type_name, type_name)) return node;
    unreachable;
}

fn inputValue(node: ziac.ResourceNode, name: []const u8) ziac.value.Value {
    return objectValue(node.inputs.object, name);
}

fn objectValue(fields: []const ziac.value.Field, name: []const u8) ziac.value.Value {
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    unreachable;
}

fn inputString(node: ziac.ResourceNode, name: []const u8) []const u8 {
    return inputValue(node, name).string;
}

fn inputBool(node: ziac.ResourceNode, name: []const u8) bool {
    return inputValue(node, name).boolean;
}
