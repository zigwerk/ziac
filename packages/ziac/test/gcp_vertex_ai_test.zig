const std = @import("std");
const ziac = @import("ziac");

const vertex = ziac.gcp.vertex_ai;

test "Vertex AI declarations build stable prediction vector feature and lineage resources" {
    var dataset = try vertex.Dataset.build(std.testing.allocator, provider(), .{
        .name = "orders-training",
        .location = "europe-west4",
        .display_name = "Orders training",
        .metadata_schema_uri = "gs://google-cloud-aiplatform/schema/dataset/metadata/tabular_1.0.0.yaml",
        .metadata_json = "{\"inputConfig\":{\"gcsSource\":{\"uri\":\"gs://ml-prod/training/orders.csv\"}}}",
    });
    defer dataset.deinit(std.testing.allocator);
    var model = try vertex.Model.build(std.testing.allocator, provider(), .{
        .name = "orders-model",
        .location = "europe-west4",
        .display_name = "Orders model",
        .artifact_uri = "gs://ml-prod/models/orders/v3",
        .container = .{
            .image_uri = "europe-west4-docker.pkg.dev/ml-prod/models/orders@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            .ports = &.{8080},
            .predict_route = "/predict",
            .health_route = "/health",
        },
    });
    defer model.deinit(std.testing.allocator);
    var endpoint = try vertex.Endpoint.build(std.testing.allocator, provider(), .{
        .name = "orders-online",
        .location = "europe-west4",
        .display_name = "Orders online",
        .connectivity = .{ .vpc = .{ .value = "projects/123456789/global/networks/ml" } },
    });
    defer endpoint.deinit(std.testing.allocator);
    var index = try vertex.Index.build(std.testing.allocator, provider(), .{
        .name = "product-embeddings",
        .location = "europe-west4",
        .display_name = "Product embeddings",
        .metadata_schema_uri = "gs://google-cloud-aiplatform/schema/matchingengine/metadata/config_1.0.0.yaml",
        .metadata_json = "{\"config\":{\"dimensions\":768,\"distanceMeasureType\":\"DOT_PRODUCT_DISTANCE\"}}",
        .update_method = .stream_update,
    });
    defer index.deinit(std.testing.allocator);
    var index_endpoint = try vertex.IndexEndpoint.build(std.testing.allocator, provider(), .{
        .name = "product-search",
        .location = "europe-west4",
        .display_name = "Product search",
        .connectivity = .public,
    });
    defer index_endpoint.deinit(std.testing.allocator);
    var group = try vertex.FeatureGroup.build(std.testing.allocator, provider(), .{
        .name = "customers",
        .location = "europe-west4",
        .bigquery_source = "bq://ml-prod.features.customer_features",
        .entity_id_columns = &.{"customer_id"},
    });
    defer group.deinit(std.testing.allocator);
    var feature = try vertex.Feature.build(std.testing.allocator, provider(), .{
        .name = "lifetime_value",
        .location = "europe-west4",
        .feature_group = group.name,
        .description = "Customer lifetime value",
    });
    defer feature.deinit(std.testing.allocator);
    var store = try vertex.FeatureOnlineStore.build(std.testing.allocator, provider(), .{
        .name = "customer-serving",
        .location = "europe-west4",
        .storage = .{ .bigtable = .{ .min_nodes = 1, .max_nodes = 3 } },
    });
    defer store.deinit(std.testing.allocator);
    var view = try vertex.FeatureView.build(std.testing.allocator, provider(), .{
        .name = "customer-overview",
        .location = "europe-west4",
        .online_store = store.name,
        .source = .{ .feature_registry = .{ .feature_group = group.name, .features = &.{feature.name} } },
        .sync_interval_seconds = 3600,
    });
    defer view.deinit(std.testing.allocator);
    var tensorboard = try vertex.Tensorboard.build(std.testing.allocator, provider(), .{
        .name = "experiments",
        .location = "europe-west4",
        .display_name = "ML experiments",
    });
    defer tensorboard.deinit(std.testing.allocator);
    var metadata = try vertex.MetadataStore.build(std.testing.allocator, provider(), .{
        .name = "default",
        .location = "europe-west4",
        .description = "Production lineage",
    });
    defer metadata.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.vertex.Dataset.europe-west4.orders-training", dataset.node.id);
    try std.testing.expectEqualStrings("gcp.vertex.Model.europe-west4.orders-model", model.node.id);
    try std.testing.expectEqualStrings("gcp.vertex.Endpoint.europe-west4.orders-online", endpoint.node.id);
    try std.testing.expectEqualStrings("gcp.vertex.Index.europe-west4.product-embeddings", index.node.id);
    try std.testing.expectEqualStrings("gcp.vertex.IndexEndpoint.europe-west4.product-search", index_endpoint.node.id);
    try std.testing.expectEqualStrings("gcp.vertex.Feature.europe-west4.customers-lifetime_value", feature.node.id);
    try std.testing.expectEqual(@as(usize, 3), countOutputRefs(view.node.inputs));
    try std.testing.expectEqualStrings("gcp.vertex.Tensorboard.europe-west4.experiments", tensorboard.node.id);
    try std.testing.expectEqualStrings("gcp.vertex.MetadataStore.europe-west4.default", metadata.node.id);
}

test "Vertex AI rejects invalid regional and immutable source boundaries" {
    try std.testing.expectError(error.InvalidRegion, vertex.Endpoint.build(std.testing.allocator, provider(), .{
        .name = "wrong-region",
        .location = "asia-northeast1",
        .display_name = "Wrong region",
    }));
    try std.testing.expectError(error.InvalidArtifact, vertex.Model.build(std.testing.allocator, provider(), .{
        .name = "floating-image",
        .location = "europe-west4",
        .display_name = "Floating image",
        .artifact_uri = "gs://ml-prod/models/floating",
        .container = .{ .image_uri = "europe-west4-docker.pkg.dev/ml-prod/models/orders:latest" },
    }));
    try std.testing.expectError(error.InvalidMetadata, vertex.Index.build(std.testing.allocator, provider(), .{
        .name = "bad-index",
        .location = "europe-west4",
        .display_name = "Bad index",
        .metadata_schema_uri = "http://example.com/schema.yaml",
        .metadata_json = "not-json",
    }));
    try std.testing.expectError(error.InvalidConnectivity, vertex.IndexEndpoint.build(std.testing.allocator, provider(), .{
        .name = "bad-network",
        .location = "europe-west4",
        .display_name = "Bad network",
        .connectivity = .{ .vpc = .{ .value = "projects/123456789/regions/europe-west4/subnetworks/ml" } },
    }));
}

test "Vertex AI additive IAM is limited to native stable IAM surfaces" {
    var model_member = try vertex.ModelIamMember.build(std.testing.allocator, provider(), .{
        .location = "europe-west4",
        .model = .{ .value = "projects/ml-prod/locations/europe-west4/models/123456" },
        .role = "roles/aiplatform.user",
        .member = "serviceAccount:api@ml-prod.iam.gserviceaccount.com",
    });
    defer model_member.deinit(std.testing.allocator);
    var view_member = try vertex.FeatureViewIamMember.build(std.testing.allocator, provider(), .{
        .location = "europe-west4",
        .feature_view = .{ .value = "projects/ml-prod/locations/europe-west4/featureOnlineStores/customer-serving/featureViews/customer-overview" },
        .role = "roles/aiplatform.featurestoreOnlineServingViewer",
        .member = "serviceAccount:api@ml-prod.iam.gserviceaccount.com",
    });
    defer view_member.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.startsWith(u8, model_member.node.id, "gcp.vertex.ModelIamMember.europe-west4."));
    try std.testing.expect(std.mem.startsWith(u8, view_member.node.id, "gcp.vertex.FeatureViewIamMember.europe-west4."));
}

fn provider() ziac.gcp.ProviderConfig {
    return .{ .project_id = "ml-prod", .primary_region = "europe-west4", .service_regions = &.{ "europe-west4", "us-central1" }, .network_tier = .premium };
}

fn countOutputRefs(input: ziac.value.Value) usize {
    return switch (input) {
        .output_ref => 1,
        .list => |items| blk: {
            var count: usize = 0;
            for (items) |item| count += countOutputRefs(item);
            break :blk count;
        },
        .object => |fields| blk: {
            var count: usize = 0;
            for (fields) |field| count += countOutputRefs(field.value);
            break :blk count;
        },
        else => 0,
    };
}
