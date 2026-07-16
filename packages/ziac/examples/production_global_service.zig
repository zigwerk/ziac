const std = @import("std");
const ziac = @import("ziac");

const cluster_id = "8e9f4f46-example-cluster-id";
const regions = [_][]const u8{ "europe-west1", "us-central1" };
const region_policies = [_]ziac.cockroach.private_service_connect.RegionPolicy{
    .{ .region = regions[0], .subnet_cidr = "10.42.0.0/24" },
    .{ .region = regions[1], .subnet_cidr = "10.42.1.0/24" },
};
const google = ziac.gcp.ProviderConfig{
    .project_id = "example-project",
    .primary_region = regions[0],
    .service_regions = &regions,
    .network_tier = .premium,
};
const Providers = ziac.stack.ProviderSet(.{
    ziac.resource.ProviderId.gcp,
    ziac.resource.ProviderId.cockroach,
});

const DeploymentContract = struct {
    database_url: ziac.binding.Secret([]const u8),
    release: ziac.binding.Value([]const u8),
};

const Bindings = struct {
    database_url: ziac.SecretOutput(ziac.value.SecretReference),
    release: ziac.PublicOutput([]const u8),
};

const Service = ziac.gcp.global.ZigService(DeploymentContract, Bindings, Providers);
const migrations = [_]ziac.cockroach.migration.Spec{.{
    .id = "001_health_events",
    .sql = "CREATE TABLE health_events (id UUID PRIMARY KEY DEFAULT gen_random_uuid(), created_at TIMESTAMPTZ NOT NULL DEFAULT now())",
}};

pub fn buildProductionService(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_dir: std.Io.Dir,
) !Service {
    var database = try ziac.cockroach.application_database.ApplicationDatabase.build(
        allocator,
        google,
        .{},
        .{
            .name = "production",
            .cluster_id = cluster_id,
            .plan = .standard,
            .regions = &regions,
            .database = "app",
            .username = "app_user",
            .secret_id = "app-database-url",
            .admin_connection = .{
                .provider = "gcp-secret-manager",
                .resource = "projects/example-project/secrets/cockroach-admin-url",
                .version = "1",
            },
            .migrations = &migrations,
        },
    );
    defer database.deinit();

    var private = try ziac.cockroach.private_service_connect.PrivateServiceConnect.build(
        allocator,
        google,
        .{},
        .{
            .name = "api-db",
            .cluster_id = ziac.PublicOutput([]const u8).known(cluster_id),
            .plan = .standard,
            .regions = &region_policies,
        },
    );
    defer private.deinit();

    var foundation = ziac.ResourceGraph.init(allocator);
    defer foundation.deinit();
    try foundation.appendGraph(&database.graph);
    try foundation.appendGraph(&private.graph);

    var direct_vpc: [regions.len]ziac.gcp.global.RegionalDirectVpc = undefined;
    for (private.regions, 0..) |binding, index| direct_vpc[index] = .{
        .region = binding.region,
        .config = binding.direct_vpc,
    };

    return Service.build(allocator, google, .{
        .base_graph = &foundation,
        .source = .{ .io = io, .root = source_dir },
        .name = "api",
        .artifact_name = "ziac-sample-api",
        .regions = &regions,
        .domain = "api.example.com",
        .dns_zone = "example-com",
        .regional_direct_vpc = &direct_vpc,
        .health_mode = .production,
        .min_instances = 1,
        .bindings = .{
            .database_url = database.connection_secret,
            .release = .{ .value = "production" },
        },
    });
}

pub fn main(init: std.process.Init) !void {
    var source_dir = try std.Io.Dir.cwd().openDir(init.io, "examples/zig-service-app", .{ .iterate = true });
    defer source_dir.close(init.io);
    var service = try buildProductionService(std.heap.page_allocator, init.io, source_dir);
    defer service.deinit();
    std.debug.print("{s}: {d} resources across {d} regions\n", .{
        service.url.value,
        service.graph.resources.items.len,
        regions.len,
    });
}

test "production example wires Cockroach privately into a global Zig Env" {
    var source_dir = try std.Io.Dir.cwd().openDir(std.testing.io, "examples/zig-service-app", .{ .iterate = true });
    defer source_dir.close(std.testing.io);
    var service = try buildProductionService(std.testing.allocator, std.testing.io, source_dir);
    defer service.deinit();

    try std.testing.expectEqualStrings("https://api.example.com", service.url.value);
    try std.testing.expectEqual(@as(usize, regions.len), countType(&service.graph, "gcp.run.Service"));
    try std.testing.expectEqual(@as(usize, regions.len), countType(&service.graph, "cockroach.PrivateEndpointConnection"));
    try std.testing.expectEqual(@as(usize, 0), countType(&service.graph, "cockroach.AuthorizedNetwork"));
    try std.testing.expect(hasSecretDatabaseBinding(&service.graph));
    try service.graph.validateAcyclic();
}

fn countType(graph: *const ziac.ResourceGraph, type_name: []const u8) usize {
    var count: usize = 0;
    for (graph.resources.items) |node| {
        if (std.mem.eql(u8, node.type_name, type_name)) count += 1;
    }
    return count;
}

fn hasSecretDatabaseBinding(graph: *const ziac.ResourceGraph) bool {
    for (graph.resources.items) |node| {
        if (!std.mem.eql(u8, node.type_name, "gcp.run.Service")) continue;
        const fields = node.inputs.object;
        for (fields) |field| {
            if (!std.mem.eql(u8, field.name, "env")) continue;
            for (field.value.list) |entry| {
                var name: ?[]const u8 = null;
                var secret = false;
                var output_bound = false;
                for (entry.object) |env_field| {
                    if (std.mem.eql(u8, env_field.name, "name")) name = env_field.value.string;
                    if (std.mem.eql(u8, env_field.name, "secret")) secret = env_field.value.boolean;
                    if (std.mem.eql(u8, env_field.name, "value")) output_bound = env_field.value == .output_ref;
                }
                if (name != null and std.mem.eql(u8, name.?, "DATABASE_URL") and secret and output_bound) return true;
            }
        }
    }
    return false;
}
