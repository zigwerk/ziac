const std = @import("std");
const ziac = @import("ziac");

test "artifact registry docker repository builds stable resource and url" {
    const provider = ziac.gcp.config.ProviderConfig{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    };

    var repo = try ziac.gcp.artifact_registry.DockerRepository.build(std.testing.allocator, provider, .{
        .name = "hello-global",
    });
    defer repo.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.artifact.Repository.europe-west1.hello-global", repo.node.id);
    try std.testing.expectEqualStrings("gcp.artifact.Repository", repo.node.type_name);
    try std.testing.expectEqualStrings("hello-global", repo.node.logical_id);
    try std.testing.expectEqualStrings("europe-west1-docker.pkg.dev/ziac-dev/hello-global", repo.repository_url);
}

test "artifact registry docker repository can override location" {
    const provider = ziac.gcp.config.ProviderConfig{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    };

    var repo = try ziac.gcp.artifact_registry.DockerRepository.build(std.testing.allocator, provider, .{
        .name = "api-images",
        .location = "us-central1",
    });
    defer repo.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.artifact.Repository.us-central1.api-images", repo.node.id);
    try std.testing.expectEqualStrings("us-central1-docker.pkg.dev/ziac-dev/api-images", repo.repository_url);
}

test "artifact registry docker repository rejects missing name" {
    const provider = ziac.gcp.config.ProviderConfig{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    };

    try std.testing.expectError(error.MissingName, ziac.gcp.artifact_registry.DockerRepository.build(std.testing.allocator, provider, .{
        .name = "",
    }));
}
