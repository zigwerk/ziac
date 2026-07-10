const std = @import("std");
const ziac = @import("ziac");

test "artifact registry docker repository builds stable resource and typed output" {
    const provider = ziac.gcp.config.ProviderConfig{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    };

    var repo = try ziac.gcp.artifact_registry.DockerRepository.build(std.testing.allocator, provider, .{
        .name = "hello-global",
    });
    defer repo.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.artifact.Repository.europe-west1.hello-global", repo.node.id);
    try std.testing.expectEqual(ziac.resource.ProviderId.gcp, repo.node.provider);
    try std.testing.expectEqualStrings("gcp.artifact.Repository", repo.node.type_name);
    try std.testing.expectEqual(@as(u32, 1), repo.node.schema_version);
    try std.testing.expectEqualStrings("hello-global", repo.node.logical_id);
    try std.testing.expect(repo.repository_url == .resource_ref);
    try std.testing.expectEqualStrings(repo.node.id, repo.repository_url.resource_ref.resource_id);
    try std.testing.expectEqualStrings("repository_url", repo.repository_url.resource_ref.field);

    const inputs = try repo.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(inputs);
    try std.testing.expectEqualStrings(
        "{\"format\":\"DOCKER\",\"labels\":{},\"location\":\"europe-west1\",\"name\":\"hello-global\",\"project_id\":\"ziac-dev\"}",
        inputs,
    );
    try std.testing.expectEqual(try repo.node.inputs.sha256(std.testing.allocator), repo.node.inputs_hash);
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
    try std.testing.expectEqualStrings("repository_url", repo.repository_url.resource_ref.field);
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
