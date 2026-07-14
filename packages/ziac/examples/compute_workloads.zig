const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{
    .project_id = "example-project",
    .primary_region = "europe-west1",
};

fn build(allocator: std.mem.Allocator) !ziac.gcp.ManagedInstanceFleet {
    return ziac.gcp.ManagedInstanceFleet.build(allocator, provider, .{
        .name = "global-api",
        .scope = .{ .regional = .{
            .region = "europe-west1",
            .zones = &.{ "europe-west1-b", "europe-west1-c" },
        } },
        .machine_type = "e2-standard-2",
        .source_image = ziac.PublicOutput([]const u8).known("projects/example-project/global/images/global-api"),
        .network_interfaces = &.{.{
            .network = ziac.PublicOutput([]const u8).known("projects/example-project/global/networks/platform"),
            .subnetwork = ziac.PublicOutput([]const u8).known("projects/example-project/regions/europe-west1/subnetworks/platform"),
        }},
        .service_account = ziac.PublicOutput([]const u8).known("global-api@example-project.iam.gserviceaccount.com"),
        .startup_script = ziac.SecretOutput(ziac.value.SecretReference).known(.{
            .provider = "gcp-secret-manager",
            .resource = "projects/example-project/secrets/global-api-startup",
            .version = "1",
        }),
        .startup_script_sha256 = "52e6a26d1835b1d555a7701bf98e54d67f74fef5ea39c7f4422351137eab3cbd",
        .target_size = 2,
        .min_replicas = 2,
        .max_replicas = 12,
        .named_ports = &.{.{ .name = "http", .port = 8080 }},
    });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var fleet = try build(allocator);
    defer fleet.deinit();
    var permissions = try ziac.gcp.intelligence.synthesizePermissionPlan(allocator, &fleet.graph);
    defer permissions.deinit(allocator);
    std.debug.print("Compute fleet: {d} resources, {d} exact deployer permissions\n", .{
        fleet.graph.resources.items.len,
        permissions.deployer_permissions.len,
    });
}

test "compute-workloads example compiles a regional managed fleet" {
    var fleet = try build(std.testing.allocator);
    defer fleet.deinit();
    try fleet.graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 3), fleet.graph.resources.items.len);
}
