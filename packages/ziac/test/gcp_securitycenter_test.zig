const std = @import("std");
const ziac = @import("ziac");

test "SCC declarations preserve finding routes mute intent and resource value" {
    const parent = ziac.PublicOutput([]const u8).known("organizations/123456789");
    var source = try ziac.gcp.securitycenter.Source.build(std.testing.allocator, config(), .{
        .name = "platform-detector",
        .organization = parent,
        .display_name = "Platform detector",
        .description = "Findings emitted by the platform security agent",
    });
    defer source.deinit(std.testing.allocator);
    try std.testing.expect(source.node.lifecycle.retain_on_delete);

    var notification = try ziac.gcp.securitycenter.NotificationConfig.build(std.testing.allocator, config(), .{
        .name = "critical-findings",
        .parent = parent,
        .location = "eu",
        .pubsub_topic = ziac.PublicOutput([]const u8).known("projects/security-prod/topics/scc-critical"),
        .filter = "severity=\"CRITICAL\"",
    });
    defer notification.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("gcp.securitycenter.NotificationConfig.critical-findings", notification.node.id);

    var mute = try ziac.gcp.securitycenter.MuteConfig.build(std.testing.allocator, config(), .{
        .name = "accepted-dev-finding",
        .parent = parent,
        .location = "eu",
        .config_type = .dynamic,
        .filter = "resource.project_display_name:\"sandbox\"",
        .expiry_time = "2026-08-01T00:00:00Z",
    });
    defer mute.deinit(std.testing.allocator);

    var finding_export = try ziac.gcp.securitycenter.BigQueryExport.build(std.testing.allocator, config(), .{
        .name = "security-lake",
        .parent = parent,
        .location = "eu",
        .dataset = ziac.PublicOutput([]const u8).known("projects/security-prod/datasets/security_findings"),
        .filter = "state=\"ACTIVE\"",
    });
    defer finding_export.deinit(std.testing.allocator);
    try std.testing.expect(finding_export.principal.referenceOrNull() != null);

    var value = try ziac.gcp.securitycenter.ResourceValueConfig.build(std.testing.allocator, config(), .{
        .name = "production-databases",
        .organization = parent,
        .location = "eu",
        .resource_value = .high,
        .resource_type = "sqladmin.googleapis.com/Instance",
        .tag_values = &.{"tagValues/222"},
    });
    defer value.deinit(std.testing.allocator);
}

test "SCC declarations reject ambiguous scope and invalid dynamic mute expiry" {
    try std.testing.expectError(error.InvalidParent, ziac.gcp.securitycenter.NotificationConfig.build(std.testing.allocator, config(), .{
        .name = "invalid",
        .parent = ziac.PublicOutput([]const u8).known("billingAccounts/123"),
        .location = "global",
        .pubsub_topic = ziac.PublicOutput([]const u8).known("projects/p/topics/t"),
        .filter = "severity=\"HIGH\"",
    }));
    try std.testing.expectError(error.InvalidExpiry, ziac.gcp.securitycenter.MuteConfig.build(std.testing.allocator, config(), .{
        .name = "invalid",
        .parent = ziac.PublicOutput([]const u8).known("projects/security-prod"),
        .location = "global",
        .config_type = .static,
        .filter = "severity=\"LOW\"",
        .expiry_time = "2026-08-01T00:00:00Z",
    }));
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "security-host", .primary_region = "europe-west1" };
}
