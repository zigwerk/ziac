const std = @import("std");
const ziac = @import("ziac");

const governance = ziac.gcp.governance;

test "access governance models conditions enforced perimeters and dry-run changes" {
    var access_policy = try governance.AccessPolicy.build(std.testing.allocator, config(), .{
        .name = "platform",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .title = "Platform access",
        .scope = ziac.PublicOutput([]const u8).known("folders/222222222"),
    });
    defer access_policy.deinit(std.testing.allocator);
    var level = try governance.AccessLevel.build(std.testing.allocator, config(), .{
        .name = "trusted_engineers",
        .policy = access_policy.name,
        .title = "Trusted engineers",
        .description = "EU engineers on corporate addresses",
        .level = .{ .basic = .{
            .combining_function = .and_all,
            .conditions = &.{.{
                .ip_subnetworks = &.{"192.0.2.0/24"},
                .members = &.{"user:platform@example.com"},
                .regions = &.{ "DE", "GB" },
            }},
        } },
    });
    defer level.deinit(std.testing.allocator);
    var perimeter = try governance.ServicePerimeter.build(std.testing.allocator, config(), .{
        .name = "production_data",
        .policy = access_policy.name,
        .title = "Production data",
        .status = .{
            .resources = &.{ziac.PublicOutput([]const u8).known("projects/987654321")},
            .restricted_services = &.{ "bigquery.googleapis.com", "storage.googleapis.com" },
            .access_levels = &.{level.name},
            .vpc_accessible_services = .{ .enabled = true, .allowed_services = &.{"RESTRICTED-SERVICES"} },
        },
        .dry_run = .{
            .resources = &.{ziac.PublicOutput([]const u8).known("projects/987654321")},
            .restricted_services = &.{ "bigquery.googleapis.com", "storage.googleapis.com", "secretmanager.googleapis.com" },
            .access_levels = &.{level.name},
        },
    });
    defer perimeter.deinit(std.testing.allocator);
    var binding = try governance.GcpUserAccessBinding.build(std.testing.allocator, config(), .{
        .name = "platform-engineers",
        .organization = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .group_key = "01d520gv4vjcrht",
        .access_level = level.name,
    });
    defer binding.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.accesscontextmanager.AccessPolicy.platform", access_policy.node.id);
    try std.testing.expectEqualStrings("gcp.accesscontextmanager.AccessLevel.trusted_engineers", level.node.id);
    try std.testing.expectEqualStrings("gcp.accesscontextmanager.ServicePerimeter.production_data", perimeter.node.id);
    try std.testing.expectEqualStrings("gcp.accesscontextmanager.GcpUserAccessBinding.platform-engineers", binding.node.id);
    try std.testing.expect(perimeter.node.lifecycle.retain_on_delete);
}

test "access governance rejects invalid levels and bridge restrictions" {
    try std.testing.expectError(error.InvalidAccessLevel, governance.AccessLevel.build(std.testing.allocator, config(), .{
        .name = "9invalid",
        .policy = ziac.PublicOutput([]const u8).known("accessPolicies/123"),
        .title = "Invalid",
        .level = .{ .custom = "request.auth != null" },
    }));
    try std.testing.expectError(error.InvalidPerimeter, governance.ServicePerimeter.build(std.testing.allocator, config(), .{
        .name = "bridge",
        .policy = ziac.PublicOutput([]const u8).known("accessPolicies/123"),
        .title = "Bridge",
        .perimeter_type = .bridge,
        .status = .{
            .resources = &.{ziac.PublicOutput([]const u8).known("projects/987654321")},
            .restricted_services = &.{"storage.googleapis.com"},
        },
    }));
    try std.testing.expectError(error.InvalidCondition, governance.AccessLevel.build(std.testing.allocator, config(), .{
        .name = "invalid_cidr",
        .policy = ziac.PublicOutput([]const u8).known("accessPolicies/123"),
        .title = "Invalid CIDR",
        .level = .{ .basic = .{ .conditions = &.{.{ .ip_subnetworks = &.{"192.0.2.1/24"} }} } },
    }));
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "host-project", .primary_region = "europe-west1" };
}
