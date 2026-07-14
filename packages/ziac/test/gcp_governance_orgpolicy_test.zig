const std = @import("std");
const ziac = @import("ziac");

const governance = ziac.gcp.governance;

test "organization policy declarations distinguish enforced and dry-run rules" {
    var policy = try governance.Policy.build(std.testing.allocator, config(), .{
        .name = "allowed-regions",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .constraint = "gcp.resourceLocations",
        .spec = .{
            .inherit_from_parent = false,
            .rules = &.{.{ .effect = .{ .values = .{ .allowed = &.{ "in:eu-locations", "in:us-locations" } } } }},
        },
        .dry_run_spec = .{
            .rules = &.{.{ .effect = .{ .values = .{ .allowed = &.{"in:eu-locations"} } } }},
        },
    });
    defer policy.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.orgpolicy.Policy.allowed-regions", policy.node.id);
    try std.testing.expect(policy.node.lifecycle.retain_on_delete);
    try std.testing.expect(!policy.node.lifecycle.protect);
}

test "custom constraints validate immutable CEL and operation contracts" {
    var constraint = try governance.CustomConstraint.build(std.testing.allocator, config(), .{
        .name = "require-cmek",
        .organization = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .constraint_id = "custom.requireCmek",
        .resource_types = &.{"storage.googleapis.com/Bucket"},
        .method_types = &.{ .create, .update },
        .action = .deny,
        .condition = "!has(resource.encryption.defaultKmsKeyName)",
        .display_name = "Require customer-managed encryption",
        .description = "Reject buckets without a default KMS key.",
    });
    defer constraint.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.orgpolicy.CustomConstraint.require-cmek", constraint.node.id);
    try std.testing.expect(constraint.node.lifecycle.retain_on_delete);

    try std.testing.expectError(error.InvalidPolicy, governance.Policy.build(std.testing.allocator, config(), .{
        .name = "invalid-reset",
        .parent = ziac.PublicOutput([]const u8).known("projects/ziac-platform-prod"),
        .constraint = "compute.disableSerialPortAccess",
        .spec = .{ .reset = true, .rules = &.{.{ .effect = .{ .enforce = true } }} },
    }));
    try std.testing.expectError(error.InvalidConstraint, governance.CustomConstraint.build(std.testing.allocator, config(), .{
        .name = "invalid",
        .organization = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .constraint_id = "requireCmek",
        .resource_types = &.{"storage.googleapis.com/Bucket"},
        .method_types = &.{.create},
        .action = .deny,
        .condition = "true",
        .display_name = "Invalid custom constraint",
    }));
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "host-project", .primary_region = "europe-west1" };
}
