const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{
    .project_id = "ml-prod",
    .primary_region = "europe-west4",
    .service_regions = &.{"europe-west4"},
    .network_tier = .premium,
};

fn build(allocator: std.mem.Allocator) !ziac.gcp.vertex_ai_components.FeaturePlatform {
    var prediction = try ziac.gcp.vertex_ai_components.OnlinePredictionPlatform.build(allocator, provider, .{
        .model = .{
            .name = "orders-model",
            .location = "europe-west4",
            .display_name = "Orders model",
            .artifact_uri = "gs://ml-prod-models/orders/v3",
            .container = .{ .image_uri = "europe-west4-docker.pkg.dev/ml-prod/models/orders@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" },
        },
        .endpoint = .{ .name = "orders-online", .location = "europe-west4", .display_name = "Orders online" },
        .deployment = .{ .deployed_model_id = "orders-v3", .machine_type = "n1-standard-4", .min_replicas = 1, .max_replicas = 3 },
    });
    defer prediction.deinit();
    var search = try ziac.gcp.vertex_ai_components.VectorSearchPlatform.build(allocator, provider, .{
        .base_graph = &prediction.graph,
        .index = .{
            .name = "products",
            .location = "europe-west4",
            .display_name = "Product vectors",
            .metadata_schema_uri = "gs://google-cloud-aiplatform/schema/matchingengine/metadata/config_1.0.0.yaml",
            .metadata_json = "{\"config\":{\"dimensions\":768}}",
        },
        .endpoint = .{ .name = "product-search", .location = "europe-west4", .display_name = "Product search" },
        .deployment = .{ .deployed_index_id = "products-v2" },
    });
    defer search.deinit();
    return ziac.gcp.vertex_ai_components.FeaturePlatform.build(allocator, provider, .{
        .base_graph = &search.graph,
        .group = .{ .name = "customers", .location = "europe-west4", .bigquery_source = "bq://ml-prod.features.customer_features", .entity_id_columns = &.{"customer_id"} },
        .features = &.{.{ .name = "lifetime_value", .description = "Customer lifetime value" }},
        .store = .{ .name = "customer-serving", .location = "europe-west4", .storage = .{ .bigtable = .{ .min_nodes = 1, .max_nodes = 3 } } },
        .view_name = "customer-overview",
        .sync_interval_seconds = 3600,
    });
}

pub fn main() !void {
    var platform = try build(std.heap.page_allocator);
    defer platform.deinit();
    var permissions = try ziac.gcp.intelligence.synthesizePermissionPlan(std.heap.page_allocator, &platform.graph);
    defer permissions.deinit(std.heap.page_allocator);
    std.debug.print("Vertex AI: {d} resources, {d} dependencies, {d} deployer permissions\n", .{
        platform.graph.resources.items.len,
        platform.graph.dependencies.items.len,
        permissions.deployer_permissions.len,
    });
}

test "Vertex AI example composes prediction vector search and feature serving" {
    var platform = try build(std.testing.allocator);
    defer platform.deinit();
    try platform.graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 8), platform.graph.resources.items.len);
    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &platform.graph);
    defer requirements.deinit(std.testing.allocator);
    try std.testing.expect(requirements.hasPermission("aiplatform.models.upload"));
    try std.testing.expect(requirements.hasPermission("aiplatform.indexEndpoints.create"));
    try std.testing.expect(requirements.hasPermission("aiplatform.featureOnlineStores.create"));
}
