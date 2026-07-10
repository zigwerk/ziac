const std = @import("std");
const ziac = @import("ziac");

test "preview stage is deterministic repository-bound and exactly parseable" {
    const first = try ziac.ci.previewStageAlloc(std.testing.allocator, .{
        .repository = "Acme/Platform",
        .change_number = 42,
    });
    defer std.testing.allocator.free(first);
    const second = try ziac.ci.previewStageAlloc(std.testing.allocator, .{
        .repository = "acme/platform",
        .change_number = 42,
    });
    defer std.testing.allocator.free(second);
    const other = try ziac.ci.previewStageAlloc(std.testing.allocator, .{
        .repository = "acme/other",
        .change_number = 42,
    });
    defer std.testing.allocator.free(other);

    try std.testing.expectEqualStrings("pr-42-9333e523", first);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(!std.mem.eql(u8, first, other));
    try std.testing.expect(ziac.ci.isPreviewStage(first));
    try std.testing.expect(!ziac.ci.isPreviewStage("pr-42"));
    try std.testing.expect(!ziac.ci.isPreviewStage("pr-042-9333e523"));
    try std.testing.expect(!ziac.ci.isPreviewStage("pr-42-9333E523"));
    try std.testing.expect(!ziac.ci.isPreviewStage("production"));
}

test "preview stage rejects unsafe repository and change identities" {
    try std.testing.expectError(error.InvalidRepository, ziac.ci.previewStageAlloc(std.testing.allocator, .{
        .repository = "missing-slash",
        .change_number = 1,
    }));
    try std.testing.expectError(error.InvalidRepository, ziac.ci.previewStageAlloc(std.testing.allocator, .{
        .repository = "owner/repo/extra",
        .change_number = 1,
    }));
    try std.testing.expectError(error.InvalidChangeNumber, ziac.ci.previewStageAlloc(std.testing.allocator, .{
        .repository = "owner/repo",
        .change_number = 0,
    }));
}

test "preview resource names are bounded stable and preserve the full stage" {
    const stage = "pr-42-9333e523";
    const short = try ziac.ci.scopedResourceNameAlloc(std.testing.allocator, "api", stage, 49);
    defer std.testing.allocator.free(short);
    try std.testing.expectEqualStrings("api-pr-42-9333e523", short);

    const first = try ziac.ci.scopedResourceNameAlloc(
        std.testing.allocator,
        "this-is-a-very-long-cloud-run-service-name",
        stage,
        49,
    );
    defer std.testing.allocator.free(first);
    const second = try ziac.ci.scopedResourceNameAlloc(
        std.testing.allocator,
        "this-is-a-very-long-cloud-run-service-name",
        stage,
        49,
    );
    defer std.testing.allocator.free(second);
    const other = try ziac.ci.scopedResourceNameAlloc(
        std.testing.allocator,
        "this-is-another-very-long-cloud-run-service-name",
        stage,
        49,
    );
    defer std.testing.allocator.free(other);

    try std.testing.expect(first.len <= 49);
    try std.testing.expect(std.mem.endsWith(u8, first, stage));
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(!std.mem.eql(u8, first, other));
    for (first) |character| try std.testing.expect(std.ascii.isLower(character) or std.ascii.isDigit(character) or character == '-');

    const persistent = try ziac.ci.scopedResourceNameAlloc(std.testing.allocator, "api", "prod", 49);
    defer std.testing.allocator.free(persistent);
    try std.testing.expectEqualStrings("api", persistent);
    try std.testing.expectError(
        error.InvalidPreviewStage,
        ziac.ci.scopedResourceNameAlloc(std.testing.allocator, "api", "pr-production", 49),
    );
}

test "preview domains and cleanup policy fail closed" {
    const domain = try ziac.ci.previewDomainAlloc(
        std.testing.allocator,
        "api.example.com",
        "pr-42-9333e523",
    );
    defer std.testing.allocator.free(domain);
    try std.testing.expectEqualStrings("pr-42-9333e523.api.example.com", domain);

    const production_domain = try ziac.ci.previewDomainAlloc(std.testing.allocator, "api.example.com", "prod");
    defer std.testing.allocator.free(production_domain);
    try std.testing.expectEqualStrings("api.example.com", production_domain);

    try ziac.ci.validatePreviewCleanup("pr-42-9333e523");
    try std.testing.expectError(error.ProductionPreviewCleanupForbidden, ziac.ci.validatePreviewCleanup("prod"));
    try std.testing.expectError(error.ProductionPreviewCleanupForbidden, ziac.ci.validatePreviewCleanup("production"));
    try std.testing.expectError(error.InvalidPreviewStage, ziac.ci.validatePreviewCleanup("dev"));
    try std.testing.expectError(error.InvalidPreviewStage, ziac.ci.validatePreviewCleanup("pr-42"));
    try std.testing.expectError(
        error.InvalidDomain,
        ziac.ci.previewDomainAlloc(std.testing.allocator, "invalid domain", "pr-42-9333e523"),
    );
}
