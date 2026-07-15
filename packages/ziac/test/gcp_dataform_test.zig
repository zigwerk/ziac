const std = @import("std");
const ziac = @import("ziac");

test "Dataform declarations compose repository workspace release workflow and IAM" {
    const dataform = ziac.gcp.dataform;
    var repository = try dataform.Repository.build(std.testing.allocator, config(), .{
        .name = "analytics",
        .location = "europe-west1",
        .display_name = "Analytics",
        .service_account = "dataform@analytics-prod.iam.gserviceaccount.com",
        .kms_key_name = ziac.PublicOutput([]const u8).known("projects/analytics-prod/locations/europe-west1/keyRings/data/cryptoKeys/dataform"),
        .git_remote = .{
            .url = "https://github.com/acme/analytics.git",
            .default_branch = "main",
            .authentication = .{ .token_secret_version = "projects/analytics-prod/secrets/dataform-git/versions/1" },
        },
        .default_database = "analytics-prod",
        .default_schema = "warehouse",
    });
    defer repository.deinit(std.testing.allocator);

    var repository_iam = try dataform.RepositoryIamMember.build(std.testing.allocator, config(), .{
        .name = "developers",
        .resource = repository.name,
        .role = "roles/dataform.editor",
        .member = "group:data@example.com",
    });
    defer repository_iam.deinit(std.testing.allocator);
    var workspace = try dataform.Workspace.build(std.testing.allocator, config(), .{
        .name = "production",
        .repository = repository.name,
    });
    defer workspace.deinit(std.testing.allocator);
    var release = try dataform.ReleaseConfig.build(std.testing.allocator, config(), .{
        .name = "production",
        .repository = repository.name,
        .git_commitish = "main",
        .cron_schedule = "0 4 * * *",
        .time_zone = "Europe/London",
        .schema_suffix = "prod",
    });
    defer release.deinit(std.testing.allocator);
    var workflow = try dataform.WorkflowConfig.build(std.testing.allocator, config(), .{
        .name = "production",
        .repository = repository.name,
        .release_config = release.name,
        .cron_schedule = "30 4 * * *",
        .time_zone = "Europe/London",
        .included_tags = &.{"hourly"},
        .transitive_dependencies_included = true,
        .service_account = "dataform@analytics-prod.iam.gserviceaccount.com",
    });
    defer workflow.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.dataform.Repository.europe-west1.analytics", repository.node.id);
    try std.testing.expectEqualStrings("gcp.dataform.WorkflowConfig.europe-west1.analytics.production", workflow.node.id);
    try std.testing.expect(repository.node.lifecycle.protect);
}

test "Dataform rejects raw or non-versioned credentials and partial schedules" {
    const dataform = ziac.gcp.dataform;
    try std.testing.expectError(error.InvalidSecretVersion, dataform.Repository.build(std.testing.allocator, config(), .{
        .name = "analytics",
        .location = "europe-west1",
        .git_remote = .{
            .url = "https://github.com/acme/analytics.git",
            .authentication = .{ .token_secret_version = "plain-token" },
        },
    }));
    try std.testing.expectError(error.InvalidSchedule, dataform.ReleaseConfig.build(std.testing.allocator, config(), .{
        .name = "production",
        .repository = ziac.PublicOutput([]const u8).known("projects/analytics-prod/locations/europe-west1/repositories/analytics"),
        .git_commitish = "main",
        .cron_schedule = "0 4 * * *",
    }));
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "analytics-prod", .primary_region = "europe-west1", .service_regions = &.{"europe-west1"} };
}
