const std = @import("std");
const ziac = @import("ziac");

const delivery = ziac.gcp.build_delivery;

test "build delivery declarations compose modern source private execution and artifacts" {
    const provider = config();
    var connection = try delivery.Connection.build(std.testing.allocator, provider, .{
        .name = "github",
        .location = "europe-west1",
        .config = .{ .github = .{
            .oauth_token_secret_version = "projects/ziac-dev/secrets/github-oauth/versions/1",
            .app_installation_id = "12345",
        } },
    });
    defer connection.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("gcp.cloudbuild.Connection.europe-west1.github", connection.node.id);

    var source = try delivery.Repository.build(std.testing.allocator, provider, .{
        .name = "api",
        .location = "europe-west1",
        .connection_name = "github",
        .connection = connection.name,
        .remote_uri = "https://github.com/acme/api.git",
    });
    defer source.deinit(std.testing.allocator);

    var pool = try delivery.WorkerPool.build(std.testing.allocator, provider, .{
        .name = "zig-builds",
        .location = "europe-west1",
        .machine_type = "e2-standard-4",
        .disk_size_gb = 200,
        .network = .{ .peered = .{
            .network = "projects/123456789/global/networks/build",
            .ip_range = "10.40.0.0/24",
            .egress = .no_public,
        } },
    });
    defer pool.deinit(std.testing.allocator);
    try std.testing.expect(pool.node.lifecycle.protect);

    var trigger = try delivery.Trigger.build(std.testing.allocator, provider, .{
        .name = "api-main",
        .location = "europe-west1",
        .repository = source.name,
        .event = .{ .push = .{ .branch = "^main$" } },
        .filename = "platform/cloudbuild.yaml",
        .service_account = "projects/ziac-dev/serviceAccounts/build@ziac-dev.iam.gserviceaccount.com",
        .require_approval = true,
        .worker_pool = pool.name,
        .substitutions = &.{.{ .key = "_ENV", .value = "production" }},
    });
    defer trigger.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("gcp.cloudbuild.Trigger.europe-west1.api-main", trigger.node.id);

    const cleanup = [_]delivery.artifact.CleanupPolicy{
        .{ .name = "keep-release", .rule = .{ .keep_most_recent = .{ .package_prefixes = &.{"api"}, .count = 10 } } },
        .{ .name = "delete-old", .rule = .{ .delete_condition = .{ .tag_state = .untagged, .older_than_seconds = 2_592_000 } } },
    };
    var artifacts = try delivery.artifact.Repository.build(std.testing.allocator, provider, .{
        .name = "zig-images",
        .location = "europe-west1",
        .format = .docker,
        .description = "Immutable Zig service images",
        .cleanup_policies = &cleanup,
        .cleanup_policy_dry_run = true,
        .vulnerability_scanning = .inherited,
        .protect = true,
    });
    defer artifacts.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("gcp.artifact.Repository.europe-west1.zig-images", artifacts.node.id);

    var settings = try delivery.ArtifactProjectSettings.build(std.testing.allocator, provider, .{
        .redirection = .partial_and_copying,
        .pull_percent = 25,
    });
    defer settings.deinit(std.testing.allocator);
    try std.testing.expect(settings.node.lifecycle.retain_on_delete);

    var vpcsc = try delivery.ArtifactVpcscConfig.build(std.testing.allocator, provider, .{
        .location = "europe-west1",
        .policy = .deny,
    });
    defer vpcsc.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("gcp.artifact.VpcscConfig.europe-west1", vpcsc.node.id);
}

test "build delivery validates locality event unions and artifact policy shape" {
    const provider = config();
    const repository = ziac.PublicOutput([]const u8).known("projects/ziac-dev/locations/europe-west1/connections/github/repositories/api");

    try std.testing.expectError(error.InvalidRegion, delivery.Trigger.build(std.testing.allocator, provider, .{
        .name = "api-main",
        .location = "asia-east1",
        .repository = repository,
        .event = .{ .push = .{ .branch = "^main$" } },
        .filename = "cloudbuild.yaml",
    }));
    try std.testing.expectError(error.InvalidPattern, delivery.Trigger.build(std.testing.allocator, provider, .{
        .name = "api-main",
        .location = "europe-west1",
        .repository = repository,
        .event = .{ .push = .{ .branch = "" } },
        .filename = "cloudbuild.yaml",
    }));
    try std.testing.expectError(error.InvalidDiskSize, delivery.WorkerPool.build(std.testing.allocator, provider, .{
        .name = "builds",
        .location = "europe-west1",
        .disk_size_gb = 99,
        .network = .{ .peered = .{ .network = "projects/123/global/networks/build" } },
    }));

    const bad_cleanup = [_]delivery.artifact.CleanupPolicy{
        .{ .name = "keep-none", .rule = .{ .keep_most_recent = .{ .count = 0 } } },
    };
    try std.testing.expectError(error.InvalidCleanupPolicy, delivery.artifact.Repository.build(std.testing.allocator, provider, .{
        .name = "images",
        .location = "europe-west1",
        .format = .docker,
        .cleanup_policies = &bad_cleanup,
    }));
    try std.testing.expectError(error.InvalidRedirection, delivery.ArtifactProjectSettings.build(std.testing.allocator, provider, .{
        .redirection = .enabled,
        .pull_percent = 20,
    }));
}

test "artifact cleanup policy declaration order is canonical" {
    const first = [_]delivery.artifact.CleanupPolicy{
        .{ .name = "keep-release", .rule = .{ .keep_most_recent = .{ .count = 10 } } },
        .{ .name = "delete-old", .rule = .{ .delete_condition = .{ .tag_state = .untagged, .older_than_seconds = 2_592_000 } } },
    };
    const second = [_]delivery.artifact.CleanupPolicy{ first[1], first[0] };
    var left = try delivery.artifact.Repository.build(std.testing.allocator, config(), .{
        .name = "images",
        .location = "europe-west1",
        .format = .docker,
        .cleanup_policies = &first,
    });
    defer left.deinit(std.testing.allocator);
    var right = try delivery.artifact.Repository.build(std.testing.allocator, config(), .{
        .name = "images",
        .location = "europe-west1",
        .format = .docker,
        .cleanup_policies = &second,
    });
    defer right.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &left.node.inputs_hash, &right.node.inputs_hash);
}

test "GitHub Enterprise API key remains a secret reference" {
    const api_key = ziac.SecretOutput(ziac.value.SecretReference).known(.{
        .provider = "gcp-secret-manager",
        .resource = "projects/ziac-dev/secrets/github-api-key",
        .version = "1",
    });
    var connection = try delivery.Connection.build(std.testing.allocator, config(), .{
        .name = "enterprise",
        .location = "europe-west1",
        .config = .{ .github_enterprise = .{
            .host_uri = "https://github.acme.example",
            .api_key = api_key,
            .private_key_secret_version = "projects/ziac-dev/secrets/github-private-key/versions/1",
            .webhook_secret_version = "projects/ziac-dev/secrets/github-webhook/versions/1",
        } },
    });
    defer connection.deinit(std.testing.allocator);
    try std.testing.expect(input(connection.node.inputs, "config") == .object);
    try std.testing.expect(input(input(connection.node.inputs, "config"), "api_key") == .secret_ref);
}

fn config() ziac.gcp.ProviderConfig {
    return .{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
        .service_regions = &.{ "europe-west1", "us-central1" },
        .network_tier = .premium,
    };
}

fn input(source: ziac.value.Value, name: []const u8) ziac.value.Value {
    if (source != .object) return .{ .unknown_reason = "not-object" };
    for (source.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return .{ .unknown_reason = "missing" };
}
