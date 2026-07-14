const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{
    .project_id = "example-project",
    .primary_region = "europe-west1",
};

const Platform = struct {
    graph: ziac.ResourceGraph,

    fn deinit(self: *Platform) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

fn build(allocator: std.mem.Allocator) !Platform {
    var gke = try ziac.gcp.GkePlatform.build(allocator, provider, .{
        .cluster = .{
            .name = "global-api",
            .location = "europe-west1",
            .mode = .standard,
            .network = ziac.PublicOutput([]const u8).known("projects/example-project/global/networks/platform"),
            .subnetwork = ziac.PublicOutput([]const u8).known("projects/example-project/regions/europe-west1/subnetworks/platform"),
            .ip_allocation = .{
                .cluster_secondary_range = "pods",
                .services_secondary_range = "services",
            },
            .private_cluster = .{
                .private_nodes = true,
                .master_ipv4_cidr = "172.16.0.0/28",
            },
        },
        .node_pools = &.{.{
            .name = "api",
            .machine_type = "e2-standard-2",
            .autoscaling = .{ .min_nodes = 1, .max_nodes = 3 },
        }},
        .fleet = .{ .membership_name = "global-api" },
        .workload_identities = &.{.{
            .namespace = "api",
            .kubernetes_service_account = "global-api",
        }},
    });
    defer gke.deinit();

    var function = try ziac.gcp.ZigFunction.build(allocator, provider, .{
        .base_graph = &gke.graph,
        .name = "edge-hook",
        .location = "europe-west1",
        .runtime = "nodejs22",
        .entry_point = "handler",
        .source = .{
            .bucket = "example-function-source",
            .object = "edge-hook.zip",
        },
        .invokers = &.{"serviceAccount:caller@example-project.iam.gserviceaccount.com"},
    });
    defer function.deinit();

    var batch = try ziac.gcp.ZigBatchJob.build(allocator, provider, .{
        .base_graph = &function.graph,
        .name = "daily-rollup",
        .location = "europe-west1",
        .image = "europe-west1-docker.pkg.dev/example-project/jobs/rollup@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
        .commands = &.{ "rollup", "--once" },
        .machine_type = "e2-standard-2",
        .provisioning_model = .spot,
    });
    defer batch.deinit();

    var graph = ziac.ResourceGraph.init(allocator);
    errdefer graph.deinit();
    try graph.appendGraph(&batch.graph);
    return .{ .graph = graph };
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var platform = try build(allocator);
    defer platform.deinit();
    var permissions = try ziac.gcp.intelligence.synthesizePermissionPlan(allocator, &platform.graph);
    defer permissions.deinit(allocator);
    std.debug.print("Container platform: {d} resources, {d} causal edges, {d} exact permissions\n", .{
        platform.graph.resources.items.len,
        platform.graph.dependencies.items.len,
        permissions.deployer_permissions.len,
    });
}

test "container platform example compiles GKE Function and Batch topology" {
    var platform = try build(std.testing.allocator);
    defer platform.deinit();
    try platform.graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 11), platform.graph.resources.items.len);
}
