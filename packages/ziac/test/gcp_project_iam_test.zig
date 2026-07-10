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
        "{\"member\":\"serviceAccount:ziac-runtime@ziac-dev.iam.gserviceaccount.com\",\"name\":\"runtime-artifact-reader\",\"project_id\":\"ziac-dev\",\"role\":\"roles/artifactregistry.reader\"}",
        inputs,
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
