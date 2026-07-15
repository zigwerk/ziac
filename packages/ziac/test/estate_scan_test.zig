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
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "\"physical_id\":\"projects/acme-prod/instances/orders\"") != null);
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

test "estate scan maps Cloud Tasks queues and Eventarc triggers to managed identities" {
    var client = ziac.estate.ScriptedClient.init(std.testing.allocator);
    defer client.deinit();
    try client.addPage(
        \\{"results":[
        \\{"name":"//cloudtasks.googleapis.com/projects/acme-prod/locations/europe-west1/queues/invoice-worker","assetType":"cloudtasks.googleapis.com/Queue","project":"projects/123","location":"europe-west1","displayName":"invoice-worker"},
        \\{"name":"//eventarc.googleapis.com/projects/acme-prod/locations/europe-west1/triggers/orders-created","assetType":"eventarc.googleapis.com/Trigger","project":"projects/123","location":"europe-west1","displayName":"orders-created","relationships":{"EVENTARC_TRIGGER_TO_DESTINATION":{"relatedResources":["//run.googleapis.com/projects/acme-prod/locations/europe-west1/services/orders-worker"]}}}
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
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.tasks.Queue") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.eventarc.Trigger") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "\"physical_id\":\"projects/acme-prod/locations/europe-west1/queues/invoice-worker\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "\"physical_id\":\"projects/acme-prod/locations/europe-west1/triggers/orders-created\"") != null);
}

test "estate scan maps Cloud Run Jobs and Worker Pools to adoptable identities" {
    var client = ziac.estate.ScriptedClient.init(std.testing.allocator);
    defer client.deinit();
    try client.addPage(
        \\{"results":[
        \\{"name":"//run.googleapis.com/projects/acme-prod/locations/europe-west1/jobs/nightly-report","assetType":"run.googleapis.com/Job","project":"projects/123","location":"europe-west1","displayName":"nightly-report"},
        \\{"name":"//run.googleapis.com/projects/acme-prod/locations/europe-west1/workerPools/events","assetType":"run.googleapis.com/WorkerPool","project":"projects/123","location":"europe-west1","displayName":"events"}
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
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.run.Job") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.run.WorkerPool") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "\"physical_id\":\"projects/acme-prod/locations/europe-west1/jobs/nightly-report\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "\"physical_id\":\"projects/acme-prod/locations/europe-west1/workerPools/events\"") != null);
}

test "estate scan maps IAM identities roles and workload federation to managed identities" {
    var client = ziac.estate.ScriptedClient.init(std.testing.allocator);
    defer client.deinit();
    try client.addPage(
        \\{"results":[
        \\{"name":"//iam.googleapis.com/projects/acme-prod/serviceAccounts/runtime@acme-prod.iam.gserviceaccount.com","assetType":"iam.googleapis.com/ServiceAccount","project":"projects/123","location":"global","displayName":"runtime"},
        \\{"name":"//iam.googleapis.com/projects/acme-prod/roles/ziacDeployer","assetType":"iam.googleapis.com/Role","project":"projects/123","location":"global","displayName":"ziacDeployer"},
        \\{"name":"//iam.googleapis.com/organizations/456/roles/ziacAuditor","assetType":"iam.googleapis.com/Role","project":"projects/123","location":"global","displayName":"ziacAuditor"},
        \\{"name":"//iam.googleapis.com/projects/123/locations/global/workloadIdentityPools/github","assetType":"iam.googleapis.com/WorkloadIdentityPool","project":"projects/123","location":"global","displayName":"github"},
        \\{"name":"//iam.googleapis.com/projects/123/locations/global/workloadIdentityPools/github/providers/actions","assetType":"iam.googleapis.com/WorkloadIdentityPoolProvider","project":"projects/123","location":"global","displayName":"actions"}
        \\]}
    );
    var scan = try ziac.estate.scanAlloc(std.testing.allocator, client.client(), .{
        .identity = .{ .provider = .google, .verified = true, .subject = "subject" },
        .entitlement = .pro,
        .connection = .{ .status = .connected, .project_id = "acme-prod" },
        .observed_at_millis = 1_783_764_000_000,
    });
    defer scan.deinit();

    try std.testing.expectEqual(@as(usize, 5), scan.resource_count);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.iam.ServiceAccount") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.iam.ProjectCustomRole") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.iam.OrganizationCustomRole") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.iam.WorkloadIdentityPool") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.iam.WorkloadIdentityPoolProvider") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "\"physical_id\":\"projects/123/locations/global/workloadIdentityPools/github/providers/actions\"") != null);
}

test "estate scan maps BigQuery datasets tables routines and reservations to managed identities" {
    var client = ziac.estate.ScriptedClient.init(std.testing.allocator);
    defer client.deinit();
    try client.addPage(
        \\{"results":[
        \\{"name":"//bigquery.googleapis.com/projects/acme-prod/datasets/analytics","assetType":"bigquery.googleapis.com/Dataset","project":"projects/123","location":"EU","displayName":"analytics"},
        \\{"name":"//bigquery.googleapis.com/projects/acme-prod/datasets/analytics/tables/events","assetType":"bigquery.googleapis.com/Table","project":"projects/123","location":"EU","displayName":"events"},
        \\{"name":"//bigquery.googleapis.com/projects/acme-prod/datasets/analytics/routines/normalize","assetType":"bigquery.googleapis.com/Routine","project":"projects/123","location":"EU","displayName":"normalize"},
        \\{"name":"//bigqueryreservation.googleapis.com/projects/acme-prod/locations/EU/reservations/analytics","assetType":"bigqueryreservation.googleapis.com/Reservation","project":"projects/123","location":"EU","displayName":"analytics-slots"}
        \\]}
    );
    var scan = try ziac.estate.scanAlloc(std.testing.allocator, client.client(), .{
        .identity = .{ .provider = .google, .verified = true, .subject = "subject" },
        .entitlement = .pro,
        .connection = .{ .status = .connected, .project_id = "acme-prod" },
        .observed_at_millis = 1_783_764_000_000,
    });
    defer scan.deinit();
    try std.testing.expectEqual(@as(usize, 4), scan.resource_count);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.bigquery.Dataset") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.bigquery.Table") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.bigquery.Routine") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.bigquery.Reservation") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "\"physical_id\":\"projects/acme-prod/datasets/analytics/tables/events\"") != null);
}

test "estate scan maps Firestore databases without claiming unsupported child discovery" {
    var client = ziac.estate.ScriptedClient.init(std.testing.allocator);
    defer client.deinit();
    try client.addPage(
        \\{"results":[
        \\{"name":"//firestore.googleapis.com/projects/acme-prod/databases/documents","assetType":"firestore.googleapis.com/Database","project":"projects/123","location":"eur3","displayName":"documents"}
        \\]}
    );
    var scan = try ziac.estate.scanAlloc(std.testing.allocator, client.client(), .{
        .identity = .{ .provider = .google, .verified = true, .subject = "subject" },
        .entitlement = .pro,
        .connection = .{ .status = .connected, .project_id = "acme-prod" },
        .observed_at_millis = 1_783_764_000_000,
    });
    defer scan.deinit();
    try std.testing.expectEqual(@as(usize, 1), scan.resource_count);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.firestore.Database") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "\"physical_id\":\"projects/acme-prod/databases/documents\"") != null);
}

test "estate scan maps security foundations to managed identities" {
    var client = ziac.estate.ScriptedClient.init(std.testing.allocator);
    defer client.deinit();
    try client.addPage(
        \\{"results":[
        \\{"name":"//securitycenter.googleapis.com/organizations/123/locations/global/notificationConfigs/critical","assetType":"securitycenter.googleapis.com/NotificationConfig","project":"projects/123","location":"global","displayName":"critical"},
        \\{"name":"//binaryauthorization.googleapis.com/projects/acme-prod/attestors/release","assetType":"binaryauthorization.googleapis.com/Attestor","project":"projects/123","location":"global","displayName":"release"},
        \\{"name":"//privateca.googleapis.com/projects/acme-prod/locations/europe-west1/caPools/workload","assetType":"privateca.googleapis.com/CaPool","project":"projects/123","location":"europe-west1","displayName":"workload"}
        \\]}
    );
    var scan = try ziac.estate.scanAlloc(std.testing.allocator, client.client(), .{
        .identity = .{ .provider = .google, .verified = true, .subject = "subject" },
        .entitlement = .pro,
        .connection = .{ .status = .connected, .project_id = "acme-prod" },
        .observed_at_millis = 1_783_764_000_000,
    });
    defer scan.deinit();
    try std.testing.expectEqual(@as(usize, 3), scan.resource_count);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.securitycenter.NotificationConfig") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.binaryauthorization.Attestor") != null);
    try std.testing.expect(std.mem.indexOf(u8, scan.artifact, "gcp.privateca.CaPool") != null);
}
