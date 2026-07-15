const std = @import("std");
const ziac = @import("ziac");

const components = ziac.gcp.vertex_ai_components;

test "OnlinePredictionPlatform wires an immutable model to a regional endpoint" {
    var built = try components.OnlinePredictionPlatform.build(std.testing.allocator, config(), .{
        .model = modelArgs(),
        .endpoint = .{ .name = "orders-online", .location = "europe-west4", .display_name = "Orders online" },
        .deployment = .{ .deployed_model_id = "orders-v3", .machine_type = "n1-standard-4", .min_replicas = 1, .max_replicas = 3 },
    });
    defer built.deinit();
    try std.testing.expectEqual(@as(usize, 2), built.graph.resources.items.len);
    try std.testing.expectEqualStrings("orders-v3", built.deployment.deployed_model_id);
    try built.graph.validateAcyclic();
}

test "VectorSearchPlatform composes index and serving endpoint in one region" {
    var built = try components.VectorSearchPlatform.build(std.testing.allocator, config(), .{
        .index = .{ .name = "products", .location = "europe-west4", .display_name = "Products", .metadata_schema_uri = "gs://google-cloud-aiplatform/schema/matchingengine/metadata/config_1.0.0.yaml", .metadata_json = "{\"config\":{\"dimensions\":768}}" },
        .endpoint = .{ .name = "product-search", .location = "europe-west4", .display_name = "Product search" },
        .deployment = .{ .deployed_index_id = "products-v2" },
    });
    defer built.deinit();
    try std.testing.expectEqual(@as(usize, 2), built.graph.resources.items.len);
    try built.graph.validateAcyclic();
}

test "FeaturePlatform wires registry features into the online view" {
    var built = try components.FeaturePlatform.build(std.testing.allocator, config(), .{
        .group = .{ .name = "customers", .location = "europe-west4", .bigquery_source = "bq://ml-prod.features.customer_features", .entity_id_columns = &.{"customer_id"} },
        .features = &.{
            .{ .name = "lifetime_value", .description = "Customer lifetime value" },
            .{ .name = "orders_30d", .description = "Orders in the last 30 days" },
        },
        .store = .{ .name = "customer-serving", .location = "europe-west4", .storage = .{ .bigtable = .{ .min_nodes = 1, .max_nodes = 3 } } },
        .view_name = "customer-overview",
        .sync_interval_seconds = 3600,
    });
    defer built.deinit();
    try std.testing.expectEqual(@as(usize, 5), built.graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 2), countType(&built.graph, "gcp.vertex.Feature"));
    try std.testing.expectEqual(@as(usize, 6), built.graph.dependencies.items.len);
    try built.graph.validateAcyclic();
}

test "Vertex AI components reject cross-region placement" {
    const endpoint = ziac.gcp.vertex_ai.EndpointArgs{ .name = "orders-online", .location = "us-central1", .display_name = "Orders online" };
    try std.testing.expectError(error.InvalidComponent, components.OnlinePredictionPlatform.build(std.testing.allocator, config(), .{
        .model = modelArgs(),
        .endpoint = endpoint,
        .deployment = .{ .deployed_model_id = "orders-v3", .machine_type = "n1-standard-4", .min_replicas = 1, .max_replicas = 3 },
    }));
}

fn modelArgs() ziac.gcp.vertex_ai.ModelArgs {
    return .{ .name = "orders-model", .location = "europe-west4", .display_name = "Orders model", .artifact_uri = "gs://ml-prod/models/orders/v3", .container = .{ .image_uri = "europe-west4-docker.pkg.dev/ml-prod/models/orders@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" } };
}
fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "ml-prod", .primary_region = "europe-west4", .service_regions = &.{ "europe-west4", "us-central1" }, .network_tier = .premium };
}
fn countType(graph: *const ziac.ResourceGraph, type_name: []const u8) usize {
    var count: usize = 0;
    for (graph.resources.items) |node| {
        if (std.mem.eql(u8, node.type_name, type_name)) count += 1;
    }
    return count;
}
