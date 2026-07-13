const std = @import("std");
const ziac = @import("ziac");

test "paid Google estate scan consumes pages and emits mutation-isolated observed topology" {
    var client = ziac.estate.ScriptedClient.init(std.testing.allocator);
    defer client.deinit();
    try client.addPage(
        \\{"results":[
        \\{"name":"//run.googleapis.com/projects/acme-prod/locations/europe-west1/services/api","assetType":"run.googleapis.com/Service","project":"projects/123","location":"europe-west1","displayName":"api","relationships":{"NETWORK":{"relatedResources":["//compute.googleapis.com/projects/acme-prod/global/networks/main"]}}},
        \\{"name":"//compute.googleapis.com/projects/acme-prod/global/networks/main","assetType":"compute.googleapis.com/Network","project":"projects/123","location":"global","displayName":"main"}
        \\],"nextPageToken":"next-2"}
    );
    try client.addPage(
        \\{"results":[
        \\{"name":"//sqladmin.googleapis.com/projects/acme-prod/instances/orders","assetType":"sqladmin.googleapis.com/Instance","project":"projects/123","location":"europe-west1","displayName":"orders"},
        \\{"name":"//storage.googleapis.com/ziac-assets","assetType":"storage.googleapis.com/Bucket","project":"projects/123","location":"EU","displayName":"ziac-assets"}
        \\]}
    );

    var scan = try ziac.estate.scanAlloc(std.testing.allocator, client.client(), .{
        .identity = .{ .provider = .google, .verified = true, .subject = "google-subject-42" },
        .entitlement = .pro,
        .connection = .{ .status = .connected, .project_id = "acme-prod" },
        .observed_at_millis = 1_783_764_000_000,
    });
    defer scan.deinit();

    try std.testing.expectEqual(@as(usize, 2), client.call_count);
    try std.testing.expectEqual(@as(usize, 4), scan.resource_count);
    try std.testing.expectEqual(@as(usize, 1), scan.edge_count);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "\"ownership\":\"observed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "\"operation\":\"read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.run.Service") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.sql.Instance") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.compute.Network") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.storage.Bucket") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "\"physical_id\":\"buckets/ziac-assets\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "cloud_asset_inventory") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "google-subject-42") == null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "access_token") == null);
}

test "estate scan fails closed before provider access" {
    var client = ziac.estate.ScriptedClient.init(std.testing.allocator);
    defer client.deinit();
    try std.testing.expectError(error.GoogleIdentityRequired, ziac.estate.scanAlloc(
        std.testing.allocator,
        client.client(),
        .{
            .identity = .{ .provider = .google, .verified = false, .subject = "" },
            .entitlement = .pro,
            .connection = .{ .status = .connected, .project_id = "acme-prod" },
            .observed_at_millis = 1,
        },
    ));
    try std.testing.expectEqual(@as(usize, 0), client.call_count);
}

test "estate scan maps Pub/Sub topics subscriptions and event relationships" {
    var client = ziac.estate.ScriptedClient.init(std.testing.allocator);
    defer client.deinit();
    try client.addPage(
        \\{"results":[
        \\{"name":"//pubsub.googleapis.com/projects/acme-prod/topics/orders","assetType":"pubsub.googleapis.com/Topic","project":"projects/123","location":"global","displayName":"orders"},
        \\{"name":"//pubsub.googleapis.com/projects/acme-prod/subscriptions/orders-worker","assetType":"pubsub.googleapis.com/Subscription","project":"projects/123","location":"global","displayName":"orders-worker","relationships":{"PUBSUB_SUBSCRIPTION_TO_TOPIC":{"relatedResources":["//pubsub.googleapis.com/projects/acme-prod/topics/orders"]}}}
        \\]}
    );
    var scan = try ziac.estate.scanAlloc(std.testing.allocator, client.client(), .{
        .identity = .{ .provider = .google, .verified = true, .subject = "subject" },
        .entitlement = .pro,
        .connection = .{ .status = .connected, .project_id = "acme-prod" },
        .observed_at_millis = 1_783_764_000_000,
    });
    defer scan.deinit();
    try std.testing.expectEqual(@as(usize, 2), scan.resource_count);
    try std.testing.expectEqual(@as(usize, 1), scan.edge_count);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.pubsub.Topic") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.pubsub.Subscription") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "projects/acme-prod/topics/orders") != null);
}
