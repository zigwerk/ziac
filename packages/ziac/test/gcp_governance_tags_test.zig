const std = @import("std");
const ziac = @import("ziac");

const governance = ziac.gcp.governance;

test "tag declarations preserve server identities and explicit deletion guards" {
    var key = try governance.TagKey.build(std.testing.allocator, config(), .{
        .name = "environment",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .short_name = "environment",
        .description = "Deployment environment",
    });
    defer key.deinit(std.testing.allocator);
    var tag_value = try governance.TagValue.build(std.testing.allocator, config(), .{
        .name = "production",
        .parent = key.name,
        .short_name = "production",
    });
    defer tag_value.deinit(std.testing.allocator);
    var binding = try governance.TagBinding.build(std.testing.allocator, config(), .{
        .name = "platform-production",
        .parent = ziac.PublicOutput([]const u8).known("//cloudresourcemanager.googleapis.com/projects/987654321"),
        .tag_value = tag_value.name,
    });
    defer binding.deinit(std.testing.allocator);
    var hold = try governance.TagHold.build(std.testing.allocator, config(), .{
        .name = "platform-database",
        .parent = tag_value.name,
        .holder = "//run.googleapis.com/projects/ziac-platform-prod/locations/europe-west1/services/api",
        .origin = "ziac",
        .help_link = "https://example.com/runbook/tag-hold",
    });
    defer hold.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.tags.TagKey.environment", key.node.id);
    try std.testing.expectEqualStrings("gcp.tags.TagValue.production", tag_value.node.id);
    try std.testing.expectEqualStrings("gcp.tags.TagBinding.platform-production", binding.node.id);
    try std.testing.expectEqualStrings("gcp.tags.TagHold.platform-database", hold.node.id);
    try std.testing.expect(key.node.lifecycle.retain_on_delete);
    try std.testing.expect(tag_value.node.lifecycle.retain_on_delete);
    try std.testing.expect(binding.node.lifecycle.retain_on_delete);
    try std.testing.expect(hold.node.lifecycle.retain_on_delete);
}

test "tags reject non-canonical names and ambiguous purpose data" {
    try std.testing.expectError(error.InvalidShortName, governance.TagKey.build(std.testing.allocator, config(), .{
        .name = "invalid",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .short_name = "-invalid",
    }));
    try std.testing.expectError(error.InvalidPurpose, governance.TagKey.build(std.testing.allocator, config(), .{
        .name = "firewall",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .short_name = "firewall",
        .purpose = .gce_firewall,
    }));
    try std.testing.expectError(error.InvalidParent, governance.TagBinding.build(std.testing.allocator, config(), .{
        .name = "invalid",
        .parent = ziac.PublicOutput([]const u8).known("projects/987654321"),
        .tag_value = ziac.PublicOutput([]const u8).known("tagValues/456"),
    }));
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "host-project", .primary_region = "europe-west1" };
}
