const std = @import("std");
const ziac = @import("ziac");

const organization = ziac.gcp.organization;

test "organization declarations model retained hierarchy billing and service identities" {
    var folder = try organization.Folder.build(std.testing.allocator, config(), .{
        .name = "platform",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .display_name = "Platform",
    });
    defer folder.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("gcp.resourcemanager.Folder.platform", folder.node.id);
    try std.testing.expect(folder.node.lifecycle.protect);
    try std.testing.expect(folder.node.lifecycle.retain_on_delete);

    var project = try organization.Project.build(std.testing.allocator, config(), .{
        .project_id = "ziac-platform-prod",
        .parent = folder.name,
        .display_name = "Ziac Platform Production",
        .labels = &.{.{ .key = "owner", .value = "platform" }},
    });
    defer project.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("gcp.resourcemanager.Project.ziac-platform-prod", project.node.id);
    try std.testing.expect(project.node.lifecycle.retain_on_delete);

    var billing = try organization.ProjectBillingAssociation.build(std.testing.allocator, config(), .{
        .project = project.name,
        .billing_account = "billingAccounts/000000-111111-222222",
    });
    defer billing.deinit(std.testing.allocator);
    try std.testing.expect(billing.node.lifecycle.retain_on_delete);

    var identity = try organization.ServiceIdentity.build(std.testing.allocator, config(), .{
        .project_number = project.project_number,
        .service = "run.googleapis.com",
    });
    defer identity.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("gcp.serviceusage.ServiceIdentity.run.googleapis.com", identity.node.id);
    try std.testing.expect(identity.node.lifecycle.retain_on_delete);

    var lien = try organization.Lien.build(std.testing.allocator, config(), .{
        .name = "production-protection",
        .parent = project.name,
        .reason = "Prevent accidental deletion of the production project",
        .origin = "ziac",
        .restrictions = &.{"resourcemanager.projects.delete"},
    });
    defer lien.deinit(std.testing.allocator);
    try std.testing.expect(lien.node.lifecycle.retain_on_delete);
}

test "organization declarations reject unsafe and non-canonical boundaries" {
    try std.testing.expectError(error.InvalidParent, organization.Folder.build(std.testing.allocator, config(), .{
        .name = "platform",
        .parent = ziac.PublicOutput([]const u8).known("projects/not-a-folder-parent"),
        .display_name = "Platform",
    }));
    try std.testing.expectError(error.InvalidProjectId, organization.Project.build(std.testing.allocator, config(), .{
        .project_id = "Invalid_Project",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
    }));
    try std.testing.expectError(error.InvalidName, organization.Folder.build(std.testing.allocator, config(), .{
        .name = "invalid-folder",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .display_name = " Platform",
    }));
    try std.testing.expectError(error.InvalidName, organization.Project.build(std.testing.allocator, config(), .{
        .project_id = "valid-project-123",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .display_name = "abc",
    }));
    try std.testing.expectError(error.InvalidName, organization.Project.build(std.testing.allocator, config(), .{
        .project_id = "valid-project-123",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .labels = &.{.{ .key = "Owner", .value = "platform" }},
    }));
    try std.testing.expectError(error.InvalidBillingAccount, organization.ProjectBillingAssociation.build(std.testing.allocator, config(), .{
        .project = ziac.PublicOutput([]const u8).known("projects/123456789"),
        .billing_account = "000000-111111-222222",
    }));
    try std.testing.expectError(error.InvalidService, organization.ServiceIdentity.build(std.testing.allocator, config(), .{
        .project_number = ziac.PublicOutput([]const u8).known("123456789"),
        .service = "run",
    }));
    try std.testing.expectError(error.DuplicateRestriction, organization.Lien.build(std.testing.allocator, config(), .{
        .name = "duplicate",
        .parent = ziac.PublicOutput([]const u8).known("projects/123456789"),
        .reason = "Protect the project",
        .origin = "ziac",
        .restrictions = &.{ "resourcemanager.projects.delete", "resourcemanager.projects.delete" },
    }));
    try std.testing.expectError(error.InvalidParent, organization.Lien.build(std.testing.allocator, config(), .{
        .name = "folder-lien",
        .parent = ziac.PublicOutput([]const u8).known("folders/123456789"),
        .reason = "Unsupported lien parent",
        .origin = "ziac",
        .restrictions = &.{"resourcemanager.projects.delete"},
    }));
}

test "project labels accept Google's empty value representation" {
    var project = try organization.Project.build(std.testing.allocator, config(), .{
        .project_id = "valid-project-123",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .labels = &.{.{ .key = "owner", .value = "" }},
    });
    defer project.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("gcp.resourcemanager.Project.valid-project-123", project.node.id);
}

test "destructive hierarchy intent is explicit in declaration state" {
    var project = try organization.Project.build(std.testing.allocator, config(), .{
        .project_id = "ziac-sandbox-123",
        .parent = ziac.PublicOutput([]const u8).known("folders/123456789"),
        .request_delete = true,
        .protect = false,
        .retain_on_delete = false,
    });
    defer project.deinit(std.testing.allocator);
    try std.testing.expectEqual(ziac.value.Value{ .boolean = true }, input(project.node.inputs, "request_delete"));
    try std.testing.expect(!project.node.lifecycle.protect);
    try std.testing.expect(!project.node.lifecycle.retain_on_delete);
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "host-project", .primary_region = "europe-west1" };
}

fn input(source: ziac.value.Value, name: []const u8) ziac.value.Value {
    if (source != .object) return .{ .unknown_reason = "not-object" };
    for (source.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return .{ .unknown_reason = "missing" };
}
