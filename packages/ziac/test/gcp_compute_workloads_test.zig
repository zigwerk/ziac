const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
};

test "Compute workload declarations cover VM storage images templates groups and autoscaling" {
    var disk = try ziac.gcp.compute.Disk.build(std.testing.allocator, provider, .{
        .name = "api-boot",
        .zone = "europe-west1-b",
        .size_gb = 40,
        .source_image = ziac.PublicOutput([]const u8).known("projects/debian-cloud/global/images/family/debian-12"),
    });
    defer disk.deinit(std.testing.allocator);
    var instance = try ziac.gcp.compute.Instance.build(std.testing.allocator, provider, .{
        .name = "api-1",
        .zone = "europe-west1-b",
        .machine_type = "e2-small",
        .boot_disk = disk.self_link,
        .network_interfaces = &.{.{
            .network = ziac.PublicOutput([]const u8).known("projects/ziac-dev/global/networks/platform"),
            .subnetwork = ziac.PublicOutput([]const u8).known("projects/ziac-dev/regions/europe-west1/subnetworks/app"),
        }},
        .service_account = ziac.PublicOutput([]const u8).known("api@ziac-dev.iam.gserviceaccount.com"),
        .startup_script = secretReference("vm-startup"),
        .startup_script_sha256 = payload_digest,
    });
    defer instance.deinit(std.testing.allocator);
    var image = try ziac.gcp.compute.Image.build(std.testing.allocator, provider, .{
        .name = "api-release-1",
        .source_disk = disk.self_link,
        .family = "api",
    });
    defer image.deinit(std.testing.allocator);
    var template = try ziac.gcp.compute.InstanceTemplate.build(std.testing.allocator, provider, .{
        .name = "api-release-1",
        .machine_type = "e2-small",
        .source_image = image.self_link,
        .network_interfaces = &.{.{
            .network = ziac.PublicOutput([]const u8).known("projects/ziac-dev/global/networks/platform"),
            .subnetwork = ziac.PublicOutput([]const u8).known("projects/ziac-dev/regions/europe-west1/subnetworks/app"),
        }},
        .service_account = ziac.PublicOutput([]const u8).known("api@ziac-dev.iam.gserviceaccount.com"),
    });
    defer template.deinit(std.testing.allocator);
    var group = try ziac.gcp.compute.InstanceGroupManager.build(std.testing.allocator, provider, .{
        .name = "api",
        .zone = "europe-west1-b",
        .instance_template = template.self_link,
        .base_instance_name = "api",
        .target_size = 2,
    });
    defer group.deinit(std.testing.allocator);
    var autoscaler = try ziac.gcp.compute.Autoscaler.build(std.testing.allocator, provider, .{
        .name = "api",
        .zone = "europe-west1-b",
        .target = group.self_link,
        .min_replicas = 2,
        .max_replicas = 10,
        .cpu_utilization_target = 0.65,
    });
    defer autoscaler.deinit(std.testing.allocator);
    var regional_disk = try ziac.gcp.compute.RegionDisk.build(std.testing.allocator, provider, .{
        .name = "state",
        .region = "europe-west1",
        .replica_zones = &.{ "europe-west1-b", "europe-west1-c" },
        .size_gb = 100,
    });
    defer regional_disk.deinit(std.testing.allocator);
    var regional_group = try ziac.gcp.compute.RegionInstanceGroupManager.build(std.testing.allocator, provider, .{
        .name = "api-global",
        .region = "europe-west1",
        .distribution_zones = &.{ "europe-west1-b", "europe-west1-c" },
        .instance_template = template.self_link,
        .base_instance_name = "api",
        .target_size = 4,
    });
    defer regional_group.deinit(std.testing.allocator);
    var regional_autoscaler = try ziac.gcp.compute.RegionAutoscaler.build(std.testing.allocator, provider, .{
        .name = "api-global",
        .region = "europe-west1",
        .target = regional_group.self_link,
        .min_replicas = 4,
        .max_replicas = 40,
        .cpu_utilization_target = 0.7,
    });
    defer regional_autoscaler.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.compute.Disk.europe-west1-b.api-boot", disk.node.id);
    try std.testing.expectEqualStrings("gcp.compute.Instance.europe-west1-b.api-1", instance.node.id);
    try std.testing.expectEqualStrings("gcp.compute.Image.api-release-1", image.node.id);
    try std.testing.expectEqualStrings("gcp.compute.InstanceTemplate.api-release-1", template.node.id);
    try std.testing.expectEqualStrings("gcp.compute.InstanceGroupManager.europe-west1-b.api", group.node.id);
    try std.testing.expectEqualStrings("gcp.compute.Autoscaler.europe-west1-b.api", autoscaler.node.id);
    try std.testing.expectEqualStrings("gcp.compute.RegionDisk.europe-west1.state", regional_disk.node.id);
    try std.testing.expectEqualStrings("gcp.compute.RegionInstanceGroupManager.europe-west1.api-global", regional_group.node.id);
    try std.testing.expectEqualStrings("gcp.compute.RegionAutoscaler.europe-west1.api-global", regional_autoscaler.node.id);
    try std.testing.expect(input(instance.node, "startup_script") == .secret_ref);
    try std.testing.expect(input(group.node, "instance_template") == .output_ref);
}

test "Compute workload declarations reject unsafe topology and scaling" {
    try std.testing.expectError(error.InvalidReplicaZones, ziac.gcp.compute.RegionDisk.build(std.testing.allocator, provider, .{
        .name = "state",
        .region = "europe-west1",
        .replica_zones = &.{ "europe-west1-b", "us-central1-a" },
        .size_gb = 100,
    }));
    try std.testing.expectError(error.InvalidStartupScript, ziac.gcp.compute.InstanceTemplate.build(std.testing.allocator, provider, .{
        .name = "api",
        .machine_type = "e2-small",
        .source_image = ziac.PublicOutput([]const u8).known("projects/debian-cloud/global/images/family/debian-12"),
        .network_interfaces = &.{.{ .network = ziac.PublicOutput([]const u8).known("projects/ziac-dev/global/networks/platform") }},
        .service_account = ziac.PublicOutput([]const u8).known("api@ziac-dev.iam.gserviceaccount.com"),
        .startup_script = secretReference("vm-startup"),
        .startup_script_sha256 = "not-a-digest",
    }));
    try std.testing.expectError(error.InvalidScaling, ziac.gcp.compute.Autoscaler.build(std.testing.allocator, provider, .{
        .name = "api",
        .zone = "europe-west1-b",
        .target = ziac.PublicOutput([]const u8).known("projects/ziac-dev/zones/europe-west1-b/instanceGroupManagers/api"),
        .min_replicas = 11,
        .max_replicas = 10,
    }));
}

const payload_digest = "344e4b2f7f15b76b5606be45d8031fc43f473f8d63f0e02c61dbf89a97f85e69";

fn secretReference(name: []const u8) ziac.SecretOutput(ziac.value.SecretReference) {
    return .known(.{ .provider = "gcp-secret-manager", .resource = name, .version = "1" });
}

fn input(node: ziac.resource.ResourceNode, name: []const u8) ziac.value.Value {
    for (node.inputs.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    unreachable;
}
