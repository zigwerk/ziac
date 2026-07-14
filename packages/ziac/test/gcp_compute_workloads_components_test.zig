const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
};

test "VirtualMachine compiles retained storage and a dependent zonal instance" {
    var machine = try ziac.gcp.VirtualMachine.build(std.testing.allocator, provider, .{
        .name = "api-admin",
        .zone = "europe-west1-b",
        .machine_type = "e2-standard-2",
        .source_image = ziac.PublicOutput([]const u8).known("projects/debian-cloud/global/images/family/debian-12"),
        .disk_size_gb = 40,
        .network_interfaces = &.{networkInterface()},
        .service_account = ziac.PublicOutput([]const u8).known("api@ziac-dev.iam.gserviceaccount.com"),
        .protect = false,
        .retain_disk = true,
    });
    defer machine.deinit();

    try std.testing.expectEqual(@as(usize, 2), machine.graph.resources.items.len);
    const disk_id = findType(&machine.graph, "gcp.compute.Disk");
    const instance_id = findType(&machine.graph, "gcp.compute.Instance");
    try std.testing.expect(hasDependency(&machine.graph, instance_id, disk_id));
    try std.testing.expect(findNode(&machine.graph, disk_id).lifecycle.retain_on_delete);
    try std.testing.expect(machine.internal_ip == .resource_ref);
    try std.testing.expect(machine.disk == .resource_ref);
}

test "ManagedInstanceFleet compiles one regional template group and autoscaler" {
    var fleet = try ziac.gcp.ManagedInstanceFleet.build(std.testing.allocator, provider, .{
        .name = "api",
        .scope = .{ .regional = .{ .region = "europe-west1", .zones = &.{ "europe-west1-b", "europe-west1-c" } } },
        .machine_type = "e2-standard-2",
        .source_image = ziac.PublicOutput([]const u8).known("projects/ziac-dev/global/images/api-image"),
        .network_interfaces = &.{networkInterface()},
        .service_account = ziac.PublicOutput([]const u8).known("api@ziac-dev.iam.gserviceaccount.com"),
        .target_size = 2,
        .min_replicas = 2,
        .max_replicas = 12,
        .named_ports = &.{.{ .name = "http", .port = 8080 }},
        .protect = false,
    });
    defer fleet.deinit();

    try std.testing.expectEqual(@as(usize, 3), fleet.graph.resources.items.len);
    const template_id = findType(&fleet.graph, "gcp.compute.InstanceTemplate");
    const group_id = findType(&fleet.graph, "gcp.compute.RegionInstanceGroupManager");
    const autoscaler_id = findType(&fleet.graph, "gcp.compute.RegionAutoscaler");
    try std.testing.expect(hasDependency(&fleet.graph, group_id, template_id));
    try std.testing.expect(hasDependency(&fleet.graph, autoscaler_id, group_id));
    try std.testing.expect(fleet.instance_group == .resource_ref);
    try std.testing.expect(fleet.recommended_size == .resource_ref);
}

test "ManagedInstanceFleet keeps zonal topology and scale bounds explicit" {
    var fleet = try ziac.gcp.ManagedInstanceFleet.build(std.testing.allocator, provider, .{
        .name = "worker",
        .scope = .{ .zonal = "us-central1-a" },
        .machine_type = "c4-standard-4",
        .source_image = ziac.PublicOutput([]const u8).known("projects/ziac-dev/global/images/worker"),
        .network_interfaces = &.{networkInterface()},
        .service_account = ziac.PublicOutput([]const u8).known("worker@ziac-dev.iam.gserviceaccount.com"),
        .target_size = 1,
        .min_replicas = 1,
        .max_replicas = 4,
        .protect = false,
    });
    defer fleet.deinit();
    _ = findType(&fleet.graph, "gcp.compute.InstanceGroupManager");
    _ = findType(&fleet.graph, "gcp.compute.Autoscaler");

    try std.testing.expectError(error.InvalidScaling, ziac.gcp.ManagedInstanceFleet.build(std.testing.allocator, provider, .{
        .name = "invalid",
        .scope = .{ .zonal = "us-central1-a" },
        .machine_type = "e2-standard-2",
        .source_image = ziac.PublicOutput([]const u8).known("projects/ziac-dev/global/images/api"),
        .network_interfaces = &.{networkInterface()},
        .service_account = ziac.PublicOutput([]const u8).known("api@ziac-dev.iam.gserviceaccount.com"),
        .target_size = 5,
        .min_replicas = 1,
        .max_replicas = 4,
    }));
}

fn networkInterface() ziac.gcp.compute_workloads.NetworkInterface {
    return .{
        .network = ziac.PublicOutput([]const u8).known("projects/ziac-dev/global/networks/platform"),
        .subnetwork = ziac.PublicOutput([]const u8).known("projects/ziac-dev/regions/europe-west1/subnetworks/platform"),
    };
}

fn hasDependency(graph: *const ziac.ResourceGraph, from: []const u8, to: []const u8) bool {
    for (graph.dependencies.items) |edge| if (std.mem.eql(u8, edge.from, from) and std.mem.eql(u8, edge.to, to)) return true;
    return false;
}

fn findType(graph: *const ziac.ResourceGraph, type_name: []const u8) []const u8 {
    for (graph.resources.items) |node| if (std.mem.eql(u8, node.type_name, type_name)) return node.id;
    unreachable;
}

fn findNode(graph: *const ziac.ResourceGraph, id: []const u8) ziac.ResourceNode {
    for (graph.resources.items) |node| if (std.mem.eql(u8, node.id, id)) return node;
    unreachable;
}
