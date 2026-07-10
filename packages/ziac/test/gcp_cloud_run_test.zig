const std = @import("std");
const ziac = @import("ziac");

test "cloud run service builds stable resource url and default service account" {
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
    try std.testing.expectEqual(@as(u32, 1), service.node.schema_version);
    try std.testing.expectEqualStrings("api", service.node.logical_id);
    try std.testing.expectEqualStrings("https://api-europe-west1-ziac-dev.run.app", service.service_url);
    try std.testing.expectEqualStrings("runtime@ziac-dev.iam.gserviceaccount.com", service.service_account);

    const inputs = try service.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(inputs);
    try std.testing.expectEqualStrings(
        "{\"env\":[],\"image\":\"europe-west1-docker.pkg.dev/ziac-dev/hello-global/api:latest\",\"labels\":{},\"name\":\"api\",\"port\":8080,\"project_id\":\"ziac-dev\",\"region\":\"europe-west1\",\"service_account\":\"runtime@ziac-dev.iam.gserviceaccount.com\"}",
        inputs,
    );
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
    try std.testing.expectEqualStrings("api@ziac-dev.iam.gserviceaccount.com", service.service_account);
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
}
