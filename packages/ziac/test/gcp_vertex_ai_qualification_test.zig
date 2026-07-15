const std = @import("std");
const ziac = @import("ziac");

test "local Vertex AI qualification proves bounded deterministic evidence" {
    var graph = try qualificationGraph();
    defer graph.deinit();
    var retained: usize = 0;
    var base_resources: usize = 0;
    for (graph.resources.items) |node| {
        if (node.lifecycle.retain_on_delete) retained += 1;
        if (std.mem.startsWith(u8, node.type_name, "gcp.vertex.") and std.mem.indexOf(u8, node.type_name, "IamMember") == null) base_resources += 1;
    }
    var receipt = try ziac.gcp.vertex_ai_qualification.serializeLocalAlloc(std.testing.allocator, &graph, .{
        .created = graph.resources.items.len,
        .imported = graph.resources.items.len,
        .no_op = graph.resources.items.len,
        .retained = retained,
        .resumable_operations = base_resources,
        .hardened_resource_types = 16,
        .supported_asset_identities = 9,
        .governed_action_boundaries = ziac.gcp.intelligence.vertexAiActionUsages().len,
        .high_level_components = 3,
        .estimates_requiring_usage = base_resources,
    });
    defer receipt.deinit();
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"schema\":\"ziac.gcp.vertex-ai-qualification.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"provider_contract_id\":\"aiplatform:v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"provider_contract_revision\":\"20260704\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "\"provider_contract_sha256\":\"d71d9b40a874d02185acad480058d99d280749a219f2b6a85e36c61e8a7e431a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt.bytes, "authenticated_vertex_ai_mutation_not_exercised") != null);
}

fn qualificationGraph() !ziac.ResourceGraph {
    const allocator = std.testing.allocator;
    const provider = config();
    var prediction = try ziac.gcp.vertex_ai_components.OnlinePredictionPlatform.build(allocator, provider, .{
        .model = .{
            .name = "orders-model",
            .location = "europe-west4",
            .display_name = "Orders model",
            .artifact_uri = "gs://ml-prod/models/orders/v3",
            .container = .{ .image_uri = "europe-west4-docker.pkg.dev/ml-prod/models/orders@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" },
        },
        .endpoint = .{ .name = "orders-online", .location = "europe-west4", .display_name = "Orders online" },
        .deployment = .{ .deployed_model_id = "orders-v3", .machine_type = "n1-standard-4", .min_replicas = 1, .max_replicas = 3 },
    });
    defer prediction.deinit();
    var search = try ziac.gcp.vertex_ai_components.VectorSearchPlatform.build(allocator, provider, .{
        .base_graph = &prediction.graph,
        .index = .{ .name = "products", .location = "europe-west4", .display_name = "Products", .metadata_schema_uri = "gs://google-cloud-aiplatform/schema/matchingengine/metadata/config_1.0.0.yaml", .metadata_json = "{\"config\":{\"dimensions\":768}}" },
        .endpoint = .{ .name = "product-search", .location = "europe-west4", .display_name = "Product search" },
        .deployment = .{ .deployed_index_id = "products-v2" },
    });
    defer search.deinit();
    var features = try ziac.gcp.vertex_ai_components.FeaturePlatform.build(allocator, provider, .{
        .base_graph = &search.graph,
        .group = .{ .name = "customers", .location = "europe-west4", .bigquery_source = "bq://ml-prod.features.customer_features", .entity_id_columns = &.{"customer_id"} },
        .features = &.{.{ .name = "lifetime_value", .description = "Customer lifetime value" }},
        .store = .{ .name = "customer-serving", .location = "europe-west4", .storage = .{ .bigtable = .{ .min_nodes = 1, .max_nodes = 3 } } },
        .view_name = "customer-overview",
        .sync_interval_seconds = 3600,
    });
    errdefer features.deinit();
    var model_member = try ziac.gcp.vertex_ai.ModelIamMember.build(allocator, provider, .{
        .location = "europe-west4",
        .model = prediction.model,
        .role = "roles/aiplatform.user",
        .member = "serviceAccount:api@ml-prod.iam.gserviceaccount.com",
    });
    defer model_member.deinit(allocator);
    try features.graph.addResource(model_member.node);
    var view_member = try ziac.gcp.vertex_ai.FeatureViewIamMember.build(allocator, provider, .{
        .location = "europe-west4",
        .feature_view = features.view,
        .role = "roles/aiplatform.featurestoreOnlineServingViewer",
        .member = "serviceAccount:api@ml-prod.iam.gserviceaccount.com",
    });
    defer view_member.deinit(allocator);
    try features.graph.addResource(view_member.node);
    try features.graph.validateAcyclic();
    return features.graph;
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "ml-prod", .primary_region = "europe-west4", .service_regions = &.{"europe-west4"}, .network_tier = .premium };
}
