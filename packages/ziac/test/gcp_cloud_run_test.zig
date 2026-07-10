const std = @import("std");
const ziac = @import("ziac");

test "cloud run service builds stable resource and typed provider outputs" {
    const provider = ziac.gcp.config.ProviderConfig{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
        .service_account = "runtime@ziac-dev.iam.gserviceaccount.com",
    };

    var service = try ziac.gcp.cloud_run.Service.build(std.testing.allocator, provider, .{
        .name = "api",
        .image = "europe-west1-docker.pkg.dev/ziac-dev/hello-global/api:latest",
    });
    defer service.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.run.Service.europe-west1.api", service.node.id);
    try std.testing.expectEqual(ziac.resource.ProviderId.gcp, service.node.provider);
    try std.testing.expectEqualStrings("gcp.run.Service", service.node.type_name);
    try std.testing.expectEqual(@as(u32, 2), service.node.schema_version);
    try std.testing.expectEqualStrings("api", service.node.logical_id);
    try std.testing.expectEqualStrings("service_url", service.service_url.resource_ref.field);
    try std.testing.expectEqualStrings("service_account", service.service_account.resource_ref.field);
    try std.testing.expectEqualStrings("latest_revision", service.latest_revision.resource_ref.field);

    const inputs = try service.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(inputs);
    try std.testing.expectEqualStrings(
        "{\"allow_unauthenticated\":false,\"args\":[],\"command\":[],\"concurrency\":80,\"cpu\":\"1\",\"env\":[],\"image\":\"europe-west1-docker.pkg.dev/ziac-dev/hello-global/api:latest\",\"ingress\":\"INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER\",\"labels\":{},\"liveness_probe\":{},\"max_instances\":100,\"memory\":\"512Mi\",\"min_instances\":0,\"name\":\"api\",\"port\":8080,\"project_id\":\"ziac-dev\",\"readiness_probe\":{},\"region\":\"europe-west1\",\"secret_volumes\":[],\"service_account\":\"runtime@ziac-dev.iam.gserviceaccount.com\",\"startup_probe\":{},\"timeout_seconds\":300,\"vpc_access\":{}}",
        inputs,
    );
}

test "cloud run desired inputs retain full runtime network probe and secret configuration" {
    const provider = ziac.gcp.config.ProviderConfig{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    };
    const command = [_][]const u8{"/app/server"};
    const args = [_][]const u8{ "serve", "--json" };
    const tags = [_][]const u8{ "cloud-run", "database" };
    const env = [_]ziac.gcp.cloud_run.EnvVar{
        .{ .name = "MODE", .value = "production" },
        .{
            .name = "DATABASE_URL",
            .value = "ignored-plaintext",
            .secret = true,
            .secret_name = "projects/ziac-dev/secrets/database-url",
            .secret_version = "7",
        },
    };
    const volumes = [_]ziac.gcp.cloud_run.SecretVolume{.{
        .name = "database-ca",
        .secret = "projects/ziac-dev/secrets/database-ca",
        .version = "3",
        .path = "ca.crt",
        .mount_path = "/var/run/secrets/database",
    }};

    var service = try ziac.gcp.cloud_run.Service.build(std.testing.allocator, provider, .{
        .name = "api",
        .image = "europe-west1-docker.pkg.dev/ziac-dev/hello-global/api@sha256:abc",
        .command = &command,
        .args = &args,
        .cpu = "2",
        .memory = "1Gi",
        .concurrency = 40,
        .timeout_seconds = 90,
        .min_instances = 2,
        .max_instances = 20,
        .startup_probe = .{ .path = "/startup", .initial_delay_seconds = 1, .failure_threshold = 10 },
        .liveness_probe = .{ .path = "/live", .period_seconds = 15 },
        .readiness_probe = .{ .path = "/ready", .timeout_seconds = 2 },
        .ingress = .internal_and_cloud_load_balancing,
        .allow_unauthenticated = false,
        .env = &env,
        .secret_volumes = &volumes,
        .direct_vpc = .{
            .network = "projects/ziac-dev/global/networks/runtime",
            .subnetwork = "projects/ziac-dev/regions/europe-west1/subnetworks/runtime",
            .tags = &tags,
            .egress = .all_traffic,
        },
    });
    defer service.deinit(std.testing.allocator);

    const inputs = try service.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(inputs);
    for ([_][]const u8{
        "\"command\":[\"/app/server\"]",
        "\"args\":[\"serve\",\"--json\"]",
        "\"cpu\":\"2\"",
        "\"memory\":\"1Gi\"",
        "\"min_instances\":2",
        "\"max_instances\":20",
        "\"readiness_probe\":{\"failure_threshold\":3,\"initial_delay_seconds\":0,\"path\":\"/ready\"",
        "\"provider\":\"gcp-secret-manager\"",
        "\"version\":\"7\"",
        "\"mount_path\":\"/var/run/secrets/database\"",
        "\"network\":\"projects/ziac-dev/global/networks/runtime\"",
        "\"egress\":\"ALL_TRAFFIC\"",
    }) |expected| try std.testing.expect(std.mem.indexOf(u8, inputs, expected) != null);
    try std.testing.expect(std.mem.indexOf(u8, inputs, "ignored-plaintext") == null);
}

test "cloud run desired inputs retain plain env and redact secret env" {
    const provider = ziac.gcp.config.ProviderConfig{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    };
    const env = [_]ziac.gcp.cloud_run.EnvVar{
        .{ .name = "MODE", .value = "production" },
        .{ .name = "DATABASE_URL", .value = "sentinel-secret-for-tests", .secret = true },
    };

    var service = try ziac.gcp.cloud_run.Service.build(std.testing.allocator, provider, .{
        .name = "api",
        .image = "example/api:v1",
        .env = env[0..],
    });
    defer service.deinit(std.testing.allocator);

    const inputs = try service.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(inputs);
    try std.testing.expect(std.mem.indexOf(u8, inputs, "production") != null);
    try std.testing.expect(std.mem.indexOf(u8, inputs, "DATABASE_URL") != null);
    try std.testing.expect(std.mem.indexOf(u8, inputs, "\"$secret\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, inputs, "sentinel-secret-for-tests") == null);
}

test "cloud run service can override region and service account" {
    const provider = ziac.gcp.config.ProviderConfig{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    };

    var service = try ziac.gcp.cloud_run.Service.build(std.testing.allocator, provider, .{
        .name = "api",
        .image = "us-central1-docker.pkg.dev/ziac-dev/hello-global/api:latest",
        .region = "us-central1",
        .service_account = "api@ziac-dev.iam.gserviceaccount.com",
    });
    defer service.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.run.Service.us-central1.api", service.node.id);
    try std.testing.expectEqualStrings("service_account", service.service_account.resource_ref.field);
}

test "cloud run service rejects missing image invalid port and duplicate env" {
    const provider = ziac.gcp.config.ProviderConfig{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    };

    try std.testing.expectError(error.MissingImage, ziac.gcp.cloud_run.Service.build(std.testing.allocator, provider, .{
        .name = "api",
        .image = "",
    }));

    try std.testing.expectError(error.InvalidPort, ziac.gcp.cloud_run.Service.build(std.testing.allocator, provider, .{
        .name = "api",
        .image = "image",
        .port = 0,
    }));

    const env = [_]ziac.gcp.cloud_run.EnvVar{
        .{ .name = "DATABASE_URL", .value = "secret", .secret = true },
        .{ .name = "DATABASE_URL", .value = "duplicate" },
    };
    try std.testing.expectError(error.DuplicateEnvVar, ziac.gcp.cloud_run.Service.build(std.testing.allocator, provider, .{
        .name = "api",
        .image = "image",
        .env = env[0..],
    }));

    try std.testing.expectError(error.InvalidScaling, ziac.gcp.cloud_run.Service.build(std.testing.allocator, provider, .{
        .name = "api",
        .image = "image",
        .min_instances = 3,
        .max_instances = 2,
    }));
    try std.testing.expectError(error.InvalidVpcAccess, ziac.gcp.cloud_run.Service.build(std.testing.allocator, provider, .{
        .name = "api",
        .image = "image",
        .direct_vpc = .{},
    }));
}
