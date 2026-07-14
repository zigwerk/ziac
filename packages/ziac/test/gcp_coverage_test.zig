const std = @import("std");
const ziac = @import("ziac");

test "GCP provider catalog is valid and covers every managed live type" {
    try ziac.gcp.coverage.validate();

    var managed_count: usize = 0;
    for (ziac.gcp.coverage.resources) |entry| {
        if (entry.stage != .managed and entry.stage != .qualified) continue;
        managed_count += 1;
        const node = ziac.ResourceNode{
            .id = entry.type_name,
            .provider = .gcp,
            .type_name = entry.type_name,
            .logical_id = "coverage-check",
        };
        try std.testing.expect(ziac.gcp.live_provider.supports(node));
    }

    try std.testing.expectEqual(@as(usize, 114), managed_count);
}

test "every live provider type is registered as managed coverage" {
    var catalog_managed_count: usize = 0;
    for (ziac.gcp.coverage.resources) |entry| {
        if (entry.stage == .managed or entry.stage == .qualified) catalog_managed_count += 1;
    }

    try std.testing.expectEqual(catalog_managed_count, ziac.gcp.live_provider.managed_type_names.len);
    for (ziac.gcp.live_provider.managed_type_names, 0..) |type_name, index| {
        if (index > 0) try std.testing.expect(std.mem.order(u8, ziac.gcp.live_provider.managed_type_names[index - 1], type_name) == .lt);
        const entry = ziac.gcp.coverage.find(type_name) orelse return error.LiveProviderTypeMissingFromCoverage;
        try std.testing.expect(entry.stage == .managed or entry.stage == .qualified);
    }
}

test "GCP provider catalog exposes current and next-tranche coverage honestly" {
    const cloud_run = ziac.gcp.coverage.find("gcp.run.Service") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(ziac.gcp.coverage.Stage.managed, cloud_run.stage);
    try std.testing.expect(cloud_run.capabilities.create);
    try std.testing.expect(cloud_run.capabilities.import_resource);

    const run_invoker = ziac.gcp.coverage.find("gcp.run.ServiceIamMember") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(ziac.gcp.coverage.Stage.managed, run_invoker.stage);
    try std.testing.expect(run_invoker.capabilities.iam);

    const run_job = ziac.gcp.coverage.find("gcp.run.Job") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(ziac.gcp.coverage.Stage.managed, run_job.stage);
    try std.testing.expect(run_job.capabilities.update);
    try std.testing.expect(run_job.capabilities.import_resource);
    try std.testing.expect(run_job.capabilities.estate);
    try std.testing.expect(run_job.capabilities.visual);
    try std.testing.expect(run_job.capabilities.cost);

    const job_invoker = ziac.gcp.coverage.find("gcp.run.JobIamMember") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(ziac.gcp.coverage.Stage.managed, job_invoker.stage);
    try std.testing.expect(job_invoker.capabilities.iam);
    try std.testing.expect(job_invoker.capabilities.visual);

    const worker_pool = ziac.gcp.coverage.find("gcp.run.WorkerPool") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(ziac.gcp.coverage.Stage.managed, worker_pool.stage);
    try std.testing.expect(worker_pool.capabilities.update);
    try std.testing.expect(worker_pool.capabilities.estate);
    try std.testing.expect(worker_pool.capabilities.visual);
    try std.testing.expect(worker_pool.capabilities.cost);

    const bucket = ziac.gcp.coverage.find("gcp.storage.Bucket") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(ziac.gcp.coverage.Stage.managed, bucket.stage);
    try std.testing.expectEqualStrings("M57", bucket.milestone);
    try std.testing.expect(bucket.capabilities.create);

    const object = ziac.gcp.coverage.find("gcp.storage.Object") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(ziac.gcp.coverage.Stage.managed, object.stage);
    try std.testing.expect(object.capabilities.import_resource);
    try std.testing.expect(object.capabilities.visual);
    try std.testing.expect(object.capabilities.cost);

    const topic = ziac.gcp.coverage.find("gcp.pubsub.Topic") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(ziac.gcp.coverage.Stage.managed, topic.stage);
    try std.testing.expectEqualStrings("M58", topic.milestone);
    try std.testing.expect(topic.capabilities.create);
    try std.testing.expect(topic.capabilities.update);
    try std.testing.expect(topic.capabilities.import_resource);
    try std.testing.expect(topic.capabilities.estate);
    try std.testing.expect(topic.capabilities.visual);
    try std.testing.expect(topic.capabilities.cost);

    const firestore_database = ziac.gcp.coverage.find("gcp.firestore.Database") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(ziac.gcp.coverage.Stage.managed, firestore_database.stage);
    try std.testing.expectEqualStrings("M64", firestore_database.milestone);
    try std.testing.expect(firestore_database.capabilities.estate);
    try std.testing.expect(firestore_database.capabilities.visual);
    try std.testing.expect(firestore_database.capabilities.cost);

    const firestore_index = ziac.gcp.coverage.find("gcp.firestore.Index") orelse return error.TestExpectedEqual;
    try std.testing.expect(firestore_index.capabilities.create);
    try std.testing.expect(!firestore_index.capabilities.update);
    try std.testing.expect(firestore_index.capabilities.import_resource);

    const firestore_member = ziac.gcp.coverage.find("gcp.firestore.DatabaseIamMember") orelse return error.TestExpectedEqual;
    try std.testing.expect(firestore_member.capabilities.iam);
    try std.testing.expect(firestore_member.capabilities.visual);

    const sql_instance = ziac.gcp.coverage.find("gcp.sql.Instance") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("M65", sql_instance.milestone);
    try std.testing.expect(sql_instance.capabilities.estate);
    try std.testing.expect(sql_instance.capabilities.visual);
    try std.testing.expect(sql_instance.capabilities.cost);

    const sql_certificate = ziac.gcp.coverage.find("gcp.sql.ClientCertificate") orelse return error.TestExpectedEqual;
    try std.testing.expect(!sql_certificate.capabilities.update);
    try std.testing.expect(sql_certificate.capabilities.import_resource);

    const spanner = ziac.gcp.coverage.find("gcp.spanner.Database") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("M66", spanner.milestone);
    try std.testing.expect(spanner.capabilities.estate);
    try std.testing.expect(spanner.capabilities.visual);
    try std.testing.expect(spanner.capabilities.cost);

    const redis = ziac.gcp.coverage.find("gcp.redis.Cluster") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(ziac.gcp.coverage.Service.redis, redis.service);
    try std.testing.expect(redis.capabilities.update);
    try std.testing.expect(redis.capabilities.import_resource);

    const private_connection = ziac.gcp.coverage.find("gcp.servicenetworking.Connection") orelse return error.TestExpectedEqual;
    try std.testing.expect(private_connection.capabilities.visual);
    try std.testing.expect(!private_connection.capabilities.cost);

    const workflow = ziac.gcp.coverage.find("gcp.workflows.Workflow") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("M67", workflow.milestone);
    try std.testing.expect(workflow.capabilities.update);
    try std.testing.expect(workflow.capabilities.estate);

    const api_config = ziac.gcp.coverage.find("gcp.apigateway.ApiConfig") orelse return error.TestExpectedEqual;
    try std.testing.expect(!api_config.capabilities.update);
    try std.testing.expect(api_config.capabilities.import_resource);

    const project_config = ziac.gcp.coverage.find("gcp.identity.ProjectConfig") orelse return error.TestExpectedEqual;
    try std.testing.expect(project_config.capabilities.update);
    try std.testing.expect(!project_config.capabilities.delete_resource);

    const parameter_version = ziac.gcp.coverage.find("gcp.parametermanager.ParameterVersion") orelse return error.TestExpectedEqual;
    try std.testing.expect(parameter_version.capabilities.create);
    try std.testing.expect(parameter_version.capabilities.import_resource);

    try std.testing.expect(ziac.gcp.coverage.find("gcp.not.a.Resource") == null);
}

test "GCP provider coverage reports are deterministic filterable and provenance pinned" {
    const json_first = try ziac.gcp.coverage.jsonAlloc(std.testing.allocator, .{ .service = .storage });
    defer std.testing.allocator.free(json_first);
    const json_second = try ziac.gcp.coverage.jsonAlloc(std.testing.allocator, .{ .service = .storage });
    defer std.testing.allocator.free(json_second);
    try std.testing.expectEqualStrings(json_first, json_second);
    try std.testing.expect(std.mem.indexOf(u8, json_first, "\"schema\":\"ziac.gcp.provider-coverage.v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_first, ziac.gcp.proto_contract.googleapis_revision) != null);
    try std.testing.expect(std.mem.indexOf(u8, json_first, ziac.gcp.proto_contract.descriptor_sha256) != null);
    try std.testing.expect(std.mem.indexOf(u8, json_first, "compute:v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_first, "dns:v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_first, "sqladmin:v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_first, "storage:v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_first, "workflows:v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_first, "apigateway:v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_first, "gcp.storage.Bucket") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_first, "gcp.pubsub.Topic") == null);

    const markdown = try ziac.gcp.coverage.markdownAlloc(std.testing.allocator, .{ .service = .pubsub });
    defer std.testing.allocator.free(markdown);
    try std.testing.expect(std.mem.startsWith(u8, markdown, "# Ziac GCP Provider Resources\n"));
    try std.testing.expect(std.mem.indexOf(u8, markdown, "`gcp.pubsub.Topic`") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "`gcp.storage.Bucket`") == null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, ziac.gcp.proto_contract.googleapis_revision) != null);
}

test "Google contract upgrades emit deterministic semantic diff artifacts" {
    try ziac.gcp.discovery_contract.validate();
    var next_sources = ziac.gcp.discovery_contract.sources;
    next_sources[0].revision = "20990101";
    next_sources[0].document_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const discovery_diff = try ziac.gcp.discovery_contract.semanticDiffJsonAlloc(
        std.testing.allocator,
        &ziac.gcp.discovery_contract.sources,
        &next_sources,
    );
    defer std.testing.allocator.free(discovery_diff);
    try std.testing.expect(std.mem.indexOf(u8, discovery_diff, "ziac.google.discovery-semantic-diff.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, discovery_diff, "\"changed\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, discovery_diff, "20990101") != null);

    const current = [_]ziac.gcp.proto_contract.SemanticFact{
        .{ .path = "google.cloud.run.v2.Service.template", .behavior = .required },
    };
    const next = [_]ziac.gcp.proto_contract.SemanticFact{
        .{ .path = "google.cloud.run.v2.Service.template", .behavior = .immutable },
    };
    const proto_diff = try ziac.gcp.proto_contract.semanticDiffJsonAlloc(std.testing.allocator, &current, &next);
    defer std.testing.allocator.free(proto_diff);
    try std.testing.expect(std.mem.indexOf(u8, proto_diff, "ziac.google.proto-semantic-diff.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, proto_diff, "\"breaking\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, proto_diff, "google.cloud.run.v2.Service.template") != null);
}
