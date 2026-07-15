const std = @import("std");
const ziac = @import("ziac");

test "Vertex AI component graph synthesizes exact API and deployer permissions" {
    var platform = try onlinePredictionPlatform();
    defer platform.deinit();

    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &platform.graph);
    defer requirements.deinit(std.testing.allocator);

    try std.testing.expect(contains(requirements.apis, "aiplatform.googleapis.com"));
    try std.testing.expect(requirements.hasPermission("aiplatform.models.upload"));
    try std.testing.expect(requirements.hasPermission("aiplatform.endpoints.create"));
    try std.testing.expectEqual(@as(usize, 7), ziac.gcp.intelligence.vertexAiActionUsages().len);
}

test "estate scan maps only official Vertex AI Cloud Asset identities" {
    var client = ziac.estate.ScriptedClient.init(std.testing.allocator);
    defer client.deinit();
    try client.addPage(
        \\{"results":[
        \\{"name":"//aiplatform.googleapis.com/projects/vertex-prod/locations/europe-west1/datasets/catalog","assetType":"aiplatform.googleapis.com/Dataset","project":"projects/123","location":"europe-west1"},
        \\{"name":"//aiplatform.googleapis.com/projects/vertex-prod/locations/europe-west1/endpoints/predict","assetType":"aiplatform.googleapis.com/Endpoint","project":"projects/123","location":"europe-west1"},
        \\{"name":"//aiplatform.googleapis.com/projects/vertex-prod/locations/europe-west1/featureGroups/customer","assetType":"aiplatform.googleapis.com/FeatureGroup","project":"projects/123","location":"europe-west1"},
        \\{"name":"//aiplatform.googleapis.com/projects/vertex-prod/locations/europe-west1/featureOnlineStores/customer","assetType":"aiplatform.googleapis.com/FeatureOnlineStore","project":"projects/123","location":"europe-west1"},
        \\{"name":"//aiplatform.googleapis.com/projects/vertex-prod/locations/europe-west1/indexes/catalog","assetType":"aiplatform.googleapis.com/Index","project":"projects/123","location":"europe-west1"},
        \\{"name":"//aiplatform.googleapis.com/projects/vertex-prod/locations/europe-west1/indexEndpoints/catalog","assetType":"aiplatform.googleapis.com/IndexEndpoint","project":"projects/123","location":"europe-west1"},
        \\{"name":"//aiplatform.googleapis.com/projects/vertex-prod/locations/europe-west1/metadataStores/default","assetType":"aiplatform.googleapis.com/MetadataStore","project":"projects/123","location":"europe-west1"},
        \\{"name":"//aiplatform.googleapis.com/projects/vertex-prod/locations/europe-west1/models/recommender","assetType":"aiplatform.googleapis.com/Model","project":"projects/123","location":"europe-west1"},
        \\{"name":"//aiplatform.googleapis.com/projects/vertex-prod/locations/europe-west1/tensorboards/training","assetType":"aiplatform.googleapis.com/Tensorboard","project":"projects/123","location":"europe-west1"},
        \\{"name":"//aiplatform.googleapis.com/projects/vertex-prod/locations/europe-west1/featureGroups/customer/features/tier","assetType":"aiplatform.googleapis.com/Feature","project":"projects/123","location":"europe-west1"},
        \\{"name":"//aiplatform.googleapis.com/projects/vertex-prod/locations/europe-west1/featureOnlineStores/customer/featureViews/profile","assetType":"aiplatform.googleapis.com/FeatureView","project":"projects/123","location":"europe-west1"}
        \\]}
    );
    var scan = try ziac.estate.scanAlloc(std.testing.allocator, client.client(), .{
        .identity = .{ .provider = .google, .verified = true, .subject = "subject" },
        .entitlement = .pro,
        .connection = .{ .status = .connected, .project_id = "vertex-prod" },
        .observed_at_millis = 1,
    });
    defer scan.deinit();

    try std.testing.expectEqual(@as(usize, 11), scan.resource_count);
    inline for (.{
        "gcp.vertex.Dataset",
        "gcp.vertex.Endpoint",
        "gcp.vertex.FeatureGroup",
        "gcp.vertex.FeatureOnlineStore",
        "gcp.vertex.Index",
        "gcp.vertex.IndexEndpoint",
        "gcp.vertex.MetadataStore",
        "gcp.vertex.Model",
        "gcp.vertex.Tensorboard",
    }) |type_name| try std.testing.expect(std.mem.indexOf(u8, scan.artifact, type_name) != null);
    try std.testing.expectEqual(@as(usize, 2), count(scan.artifact, "\"type\":\"gcp.asset.Resource\""));
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "\"physical_id\":\"projects/vertex-prod/locations/europe-west1/models/recommender\"") != null);
}

test "visual artifact projects Vertex AI topology and honest cost basis" {
    var platform = try onlinePredictionPlatform();
    defer platform.deinit();
    var artifact = try ziac.visual_artifact.serializeAlloc(std.testing.allocator, &platform.graph, null, .{
        .stack = "vertex",
        .stage = "prod",
        .created_at_millis = 1,
    });
    defer artifact.deinit();

    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"vertex_ai\":{\"kind\":\"model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"vertex_ai\":{\"kind\":\"prediction_endpoint\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.bytes, "\"basis\":\"usage_assumptions_required\"") != null);
}

test "Vertex AI cost estimates require explicit usage and matching rates" {
    const prices = [_]ziac.cost.SkuPrice{
        .{ .sku_id = "vertex-prediction", .region = "europe-west1", .unit = "prediction", .unit_quantity = 1_000, .unit_price_micros = 2_000 },
        .{ .sku_id = "vertex-endpoint", .region = "europe-west1", .unit = "node-hour", .unit_quantity = 1, .unit_price_micros = 125_000 },
    };
    const usage = [_]ziac.cost.UsageAssumption{
        .{ .sku_id = "vertex-prediction", .region = "europe-west1", .quantity = 2_000_000 },
        .{ .sku_id = "vertex-endpoint", .region = "europe-west1", .quantity = 10 },
    };
    const estimate = try ziac.cost.vertexAiConfigurationEstimate(&prices, .{
        .resource_id = "gcp.vertex.Endpoint.europe-west1.predict",
        .usage = &usage,
        .observed_at_millis = 1,
    });
    try std.testing.expectEqual(@as(?i64, 5_250_000), estimate.amount_micros);
    try std.testing.expectEqual(ziac.cost.Confidence.explicit_usage, estimate.confidence);
    try std.testing.expectError(error.InvalidUsageAssumption, ziac.cost.vertexAiConfigurationEstimate(&prices, .{
        .resource_id = "gcp.vertex.Endpoint.europe-west1.predict",
        .usage = &.{},
        .observed_at_millis = 1,
    }));
    try std.testing.expectError(error.PricingUnavailable, ziac.cost.vertexAiConfigurationEstimate(&.{}, .{
        .resource_id = "gcp.vertex.Endpoint.europe-west1.predict",
        .usage = &usage,
        .observed_at_millis = 1,
    }));
}

fn onlinePredictionPlatform() !ziac.gcp.vertex_ai_components.OnlinePredictionPlatform {
    return ziac.gcp.vertex_ai_components.OnlinePredictionPlatform.build(std.testing.allocator, provider(), .{
        .model = .{
            .name = "recommender",
            .location = "europe-west1",
            .display_name = "Global recommender",
            .artifact_uri = "gs://vertex-prod-models/recommender",
            .container = .{ .image_uri = "europe-west1-docker.pkg.dev/vertex-prod/models/recommender@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" },
        },
        .endpoint = .{
            .name = "predict",
            .location = "europe-west1",
            .display_name = "Prediction endpoint",
        },
        .deployment = .{
            .deployed_model_id = "recommender-v1",
            .machine_type = "n1-standard-4",
            .min_replicas = 1,
            .max_replicas = 4,
        },
    });
}

fn provider() ziac.gcp.ProviderConfig {
    return .{ .project_id = "vertex-prod", .primary_region = "europe-west1", .service_regions = &.{"europe-west1"} };
}

fn contains(values: []const []const u8, expected: []const u8) bool {
    for (values) |item| if (std.mem.eql(u8, item, expected)) return true;
    return false;
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var remaining = haystack;
    while (std.mem.indexOf(u8, remaining, needle)) |index| {
        total += 1;
        remaining = remaining[index + needle.len ..];
    }
    return total;
}
