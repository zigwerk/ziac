const std = @import("std");
const ziac = @import("ziac");

const config = ziac.gcp.config.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
};

test "GCP project service builds stable desired state" {
    var service = try ziac.gcp.project_service.Service.build(std.testing.allocator, config, .{
        .service = "run.googleapis.com",
    });
    defer service.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.project.Service.run.googleapis.com", service.node.id);
    try std.testing.expectEqualStrings("gcp.project.Service", service.node.type_name);
    try std.testing.expectEqualStrings("resource_name", service.resource_name.resource_ref.field);
    const inputs = try service.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(inputs);
    try std.testing.expectEqualStrings(
        "{\"project_id\":\"ziac-dev\",\"service\":\"run.googleapis.com\"}",
        inputs,
    );
}

test "GCP IAM service account builds typed email and unique ID outputs" {
    var account = try ziac.gcp.iam.ServiceAccount.build(std.testing.allocator, config, .{
        .account_id = "ziac-runtime",
        .display_name = "Ziac runtime",
        .description = "Runs globally deployed Zig services",
    });
    defer account.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.iam.ServiceAccount.ziac-runtime", account.node.id);
    try std.testing.expectEqualStrings("email", account.email.resource_ref.field);
    try std.testing.expectEqualStrings("unique_id", account.unique_id.resource_ref.field);
    const inputs = try account.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(inputs);
    try std.testing.expectEqualStrings(
        "{\"account_id\":\"ziac-runtime\",\"description\":\"Runs globally deployed Zig services\",\"display_name\":\"Ziac runtime\",\"project_id\":\"ziac-dev\"}",
        inputs,
    );
}

test "GCP IAM project member builds stable policy binding state" {
    var member = try ziac.gcp.iam.ProjectMember.build(std.testing.allocator, config, .{
        .name = "runtime-artifact-reader",
        .role = "roles/artifactregistry.reader",
        .member = "serviceAccount:ziac-runtime@ziac-dev.iam.gserviceaccount.com",
    });
    defer member.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.iam.ProjectMember.runtime-artifact-reader", member.node.id);
    try std.testing.expectEqualStrings("binding_id", member.binding_id.resource_ref.field);
    const inputs = try member.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(inputs);
    try std.testing.expectEqualStrings(
        "{\"condition_description\":\"\",\"condition_expression\":\"\",\"condition_title\":\"\",\"member\":\"serviceAccount:ziac-runtime@ziac-dev.iam.gserviceaccount.com\",\"name\":\"runtime-artifact-reader\",\"ownership_mode\":\"member\",\"project_id\":\"ziac-dev\",\"resource_name\":\"projects/ziac-dev\",\"role\":\"roles/artifactregistry.reader\"}",
        inputs,
    );
}

test "GCP IAM declarations encode member binding and policy ownership explicitly" {
    const condition = ziac.gcp.iam.Condition{
        .title = "expires-after-migration",
        .description = "Temporary migration access",
        .expression = "request.time < timestamp('2026-08-01T00:00:00Z')",
    };
    var member = try ziac.gcp.iam.ProjectMember.build(std.testing.allocator, config, .{
        .name = "temporary-reader",
        .role = "roles/storage.objectViewer",
        .member = "group:platform@example.com",
        .condition = condition,
    });
    defer member.deinit(std.testing.allocator);
    const members = [_][]const u8{
        "serviceAccount:worker@ziac-dev.iam.gserviceaccount.com",
        "group:platform@example.com",
    };
    var binding = try ziac.gcp.iam.ProjectBinding.build(std.testing.allocator, config, .{
        .name = "artifact-readers",
        .role = "roles/artifactregistry.reader",
        .members = &members,
    });
    defer binding.deinit(std.testing.allocator);
    const bindings = [_]ziac.gcp.iam.Binding{
        .{ .role = "roles/storage.objectViewer", .members = &.{"group:readers@example.com"} },
        .{ .role = "roles/logging.viewer", .members = &.{"user:operator@example.com"} },
    };
    var policy = try ziac.gcp.iam.ProjectPolicy.build(std.testing.allocator, config, .{
        .name = "project-access",
        .bindings = &bindings,
    });
    defer policy.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.iam.ProjectMember", member.node.type_name);
    try std.testing.expectEqual(@as(u32, 2), member.node.schema_version);
    try expectInputString(member.node.inputs, "ownership_mode", "member");
    try expectInputString(member.node.inputs, "condition_title", condition.title);
    try std.testing.expectEqualStrings("gcp.iam.ProjectBinding", binding.node.type_name);
    try expectInputString(binding.node.inputs, "ownership_mode", "binding");
    try expectInputString(policy.node.inputs, "ownership_mode", "policy");

    const binding_inputs = try binding.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(binding_inputs);
    try std.testing.expect(std.mem.indexOf(
        u8,
        binding_inputs,
        "[\"group:platform@example.com\",\"serviceAccount:worker@ziac-dev.iam.gserviceaccount.com\"]",
    ) != null);
}

test "GCP IAM supports hierarchy and service account ownership families" {
    var folder = try ziac.gcp.iam.FolderMember.build(std.testing.allocator, config, .{
        .name = "folder-observer",
        .folder_id = "123456789012",
        .role = "roles/browser",
        .member = "group:platform@example.com",
    });
    defer folder.deinit(std.testing.allocator);
    var organization = try ziac.gcp.iam.OrganizationBinding.build(std.testing.allocator, config, .{
        .name = "org-auditors",
        .organization_id = "987654321098",
        .role = "roles/iam.securityReviewer",
        .members = &.{"group:security@example.com"},
    });
    defer organization.deinit(std.testing.allocator);
    var service_account = try ziac.gcp.iam.ServiceAccountIamMember.build(std.testing.allocator, config, .{
        .name = "github-deployer",
        .service_account_email = "deploy@ziac-dev.iam.gserviceaccount.com",
        .role = "roles/iam.workloadIdentityUser",
        .member = "principalSet://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/github/attribute.repository/acme/api",
    });
    defer service_account.deinit(std.testing.allocator);

    try expectInputString(folder.node.inputs, "resource_name", "folders/123456789012");
    try expectInputString(organization.node.inputs, "resource_name", "organizations/987654321098");
    try expectInputString(
        service_account.node.inputs,
        "resource_name",
        "projects/ziac-dev/serviceAccounts/deploy@ziac-dev.iam.gserviceaccount.com",
    );
}

test "GCP IAM rejects unsafe principals conditions and duplicate binding members" {
    try std.testing.expectError(error.InvalidMember, ziac.gcp.iam.ProjectMember.build(std.testing.allocator, config, .{
        .name = "invalid-principal",
        .role = "roles/viewer",
        .member = "not-a-principal",
    }));
    try std.testing.expectError(error.InvalidIamCondition, ziac.gcp.iam.ProjectMember.build(std.testing.allocator, config, .{
        .name = "public-conditional",
        .role = "roles/storage.objectViewer",
        .member = "allUsers",
        .condition = .{ .title = "bad", .expression = "request.time < timestamp('2026-08-01T00:00:00Z')" },
    }));
    try std.testing.expectError(error.InvalidIamCondition, ziac.gcp.iam.ProjectMember.build(std.testing.allocator, config, .{
        .name = "basic-conditional",
        .role = "roles/viewer",
        .member = "group:platform@example.com",
        .condition = .{ .title = "bad", .expression = "request.time < timestamp('2026-08-01T00:00:00Z')" },
    }));
    try std.testing.expectError(error.DuplicateMember, ziac.gcp.iam.ProjectBinding.build(std.testing.allocator, config, .{
        .name = "duplicate",
        .role = "roles/logging.viewer",
        .members = &.{ "user:operator@example.com", "user:operator@example.com" },
    }));
}

test "GCP IAM custom roles and workload identity federation build canonical state" {
    var role = try ziac.gcp.iam.ProjectCustomRole.build(std.testing.allocator, config, .{
        .role_id = "ziacDeployer",
        .title = "Ziac deployer",
        .description = "Least privilege generated by Ziac",
        .included_permissions = &.{ "run.services.update", "run.services.get", "run.services.create" },
        .stage = .ga,
    });
    defer role.deinit(std.testing.allocator);
    var pool = try ziac.gcp.iam.WorkloadIdentityPool.build(std.testing.allocator, config, .{
        .project_number = "123456789012",
        .pool_id = "github-actions",
        .display_name = "GitHub Actions",
        .description = "Keyless CI identities",
    });
    defer pool.deinit(std.testing.allocator);
    var provider = try ziac.gcp.iam.WorkloadIdentityPoolProvider.build(std.testing.allocator, config, .{
        .provider_id = "github-oidc",
        .pool = pool.name,
        .display_name = "GitHub OIDC",
        .issuer_uri = "https://token.actions.githubusercontent.com",
        .allowed_audiences = &.{"https://github.com/acme"},
        .attribute_mapping = &.{
            .{ .key = "attribute.repository", .expression = "assertion.repository" },
            .{ .key = "google.subject", .expression = "assertion.sub" },
        },
        .attribute_condition = "assertion.repository_owner == 'acme'",
    });
    defer provider.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.iam.ProjectCustomRole", role.node.type_name);
    try expectInputString(role.node.inputs, "resource_name", "projects/ziac-dev/roles/ziacDeployer");
    try expectInputString(pool.node.inputs, "resource_name", "projects/123456789012/locations/global/workloadIdentityPools/github-actions");
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.addResource(pool.node);
    try graph.addResource(provider.node);
    try std.testing.expectEqual(@as(usize, 1), graph.dependencies.items.len);
    try std.testing.expectEqualStrings(pool.node.id, graph.dependencies.items[0].to);
    const role_inputs = try role.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(role_inputs);
    try std.testing.expect(std.mem.indexOf(u8, role_inputs, "[\"run.services.create\",\"run.services.get\",\"run.services.update\"]") != null);
    const provider_inputs = try provider.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(provider_inputs);
    try std.testing.expect(std.mem.indexOf(u8, provider_inputs, "attribute.repository") != null);
    try std.testing.expect(std.mem.indexOf(u8, provider_inputs, "google.subject") != null);
}

test "GCP IAM rejects unsafe custom role and federation declarations" {
    try std.testing.expectError(error.DuplicatePermission, ziac.gcp.iam.ProjectCustomRole.build(std.testing.allocator, config, .{
        .role_id = "duplicate",
        .title = "Duplicate",
        .included_permissions = &.{ "run.services.get", "run.services.get" },
    }));
    try std.testing.expectError(error.InvalidPoolId, ziac.gcp.iam.WorkloadIdentityPool.build(std.testing.allocator, config, .{
        .project_number = "123456789012",
        .pool_id = "gcp-reserved",
        .display_name = "Reserved",
    }));
    var pool = try ziac.gcp.iam.WorkloadIdentityPool.build(std.testing.allocator, config, .{
        .project_number = "123456789012",
        .pool_id = "github-actions",
        .display_name = "GitHub Actions",
    });
    defer pool.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidIssuer, ziac.gcp.iam.WorkloadIdentityPoolProvider.build(std.testing.allocator, config, .{
        .provider_id = "github-oidc",
        .pool = pool.name,
        .issuer_uri = "http://token.actions.githubusercontent.com",
        .attribute_mapping = &.{.{ .key = "google.subject", .expression = "assertion.sub" }},
    }));
    try std.testing.expectError(error.MissingSubjectMapping, ziac.gcp.iam.WorkloadIdentityPoolProvider.build(std.testing.allocator, config, .{
        .provider_id = "github-oidc",
        .pool = pool.name,
        .issuer_uri = "https://token.actions.githubusercontent.com",
        .attribute_mapping = &.{.{ .key = "attribute.repository", .expression = "assertion.repository" }},
    }));
}

test "planner rejects overlapping IAM ownership before provider execution" {
    var member = try ziac.gcp.iam.ProjectMember.build(std.testing.allocator, config, .{
        .name = "reader-member",
        .role = "roles/logging.viewer",
        .member = "user:operator@example.com",
    });
    defer member.deinit(std.testing.allocator);
    var binding = try ziac.gcp.iam.ProjectBinding.build(std.testing.allocator, config, .{
        .name = "reader-binding",
        .role = "roles/logging.viewer",
        .members = &.{"group:platform@example.com"},
    });
    defer binding.deinit(std.testing.allocator);
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.addResource(member.node);
    try graph.addResource(binding.node);
    var store = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer store.deinit();

    try std.testing.expectError(
        error.IamOwnershipConflict,
        ziac.plan.buildPlan(std.testing.allocator, &graph, &store),
    );
}

test "GCP project and IAM builders reject invalid identifiers" {
    try std.testing.expectError(
        error.MissingService,
        ziac.gcp.project_service.Service.build(std.testing.allocator, config, .{ .service = "" }),
    );
    try std.testing.expectError(
        error.InvalidAccountId,
        ziac.gcp.iam.ServiceAccount.build(std.testing.allocator, config, .{ .account_id = "Bad" }),
    );
    try std.testing.expectError(
        error.InvalidRole,
        ziac.gcp.iam.ProjectMember.build(std.testing.allocator, config, .{
            .name = "binding",
            .role = "owner",
            .member = "user:dev@example.com",
        }),
    );
}

fn expectInputString(inputs: ziac.value.Value, name: []const u8, expected: []const u8) !void {
    const fields = switch (inputs) {
        .object => |items| items,
        else => return error.TestUnexpectedResult,
    };
    for (fields) |field| {
        if (!std.mem.eql(u8, field.name, name)) continue;
        return switch (field.value) {
            .string => |actual| std.testing.expectEqualStrings(expected, actual),
            else => error.TestUnexpectedResult,
        };
    }
    return error.TestUnexpectedResult;
}
