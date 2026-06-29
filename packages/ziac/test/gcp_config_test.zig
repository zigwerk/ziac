const std = @import("std");
const ziac = @import("ziac");

test "gcp provider config validates project region labels and service regions" {
    const regions = [_][]const u8{ "europe-west1", "us-central1" };
    const labels = [_]ziac.gcp.config.Label{
        .{ .key = "app", .value = "hello-global" },
    };
    const config = ziac.gcp.config.ProviderConfig{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
        .service_regions = regions[0..],
        .network_tier = .premium,
        .service_account = "hello-global@ziac-dev.iam.gserviceaccount.com",
        .labels = labels[0..],
    };

    try config.validate();
    try std.testing.expectEqual(@as(usize, 2), config.regionCount());
}

test "gcp provider config rejects missing project id" {
    try std.testing.expectError(error.MissingProjectId, (ziac.gcp.config.ProviderConfig{
        .project_id = "",
        .primary_region = "europe-west1",
    }).validate());
}

test "gcp provider config rejects missing primary region" {
    try std.testing.expectError(error.MissingRegion, (ziac.gcp.config.ProviderConfig{
        .project_id = "ziac-dev",
        .primary_region = "",
    }).validate());
}

test "gcp provider config requires premium tier for multiple regions" {
    const regions = [_][]const u8{ "europe-west1", "us-central1" };
    try std.testing.expectError(error.PremiumTierRequired, (ziac.gcp.config.ProviderConfig{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
        .service_regions = regions[0..],
        .network_tier = .standard,
    }).validate());
}

test "gcp provider config rejects empty labels" {
    const labels = [_]ziac.gcp.config.Label{
        .{ .key = "", .value = "hello-global" },
    };
    try std.testing.expectError(error.MissingLabel, (ziac.gcp.config.ProviderConfig{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
        .labels = labels[0..],
    }).validate());
}
