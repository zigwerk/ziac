const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;
const organization = ziac.gcp.organization;

test "folder create checkpoints a server-assigned identity and resumes from the operation response" {
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"operations/folder-create\",\"done\":false}"),
        ok("{\"name\":\"operations/folder-create\",\"done\":true,\"response\":{\"name\":\"folders/987654321\",\"parent\":\"organizations/123456789\",\"displayName\":\"Platform\",\"state\":\"ACTIVE\",\"etag\":\"etag-folder\"}}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.organization_provider.Handler{ .client = &harness.client, .operation_policy = .{ .poll_interval_millis = 0 } };
    var folder = try buildFolder("Platform");
    defer folder.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.create(&context, folder.node);
    defer pending.deinit();
    try std.testing.expect(!pending.completed);
    try std.testing.expectEqualStrings("operations/folder-create", pending.operation_handle.?);
    try std.testing.expectEqualStrings("POST", harness.transport.requests.items[0].method);
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[0].url, "/v3/folders"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "\"displayName\":\"Platform\"") != null);

    context.operation_handle = pending.operation_handle;
    var resumed = try handler.read(&context, folder.node, null);
    defer resumed.deinit();
    try std.testing.expectEqualStrings("folders/987654321", resumed.present.physical_id);
    try std.testing.expectEqualStrings("987654321", outputString(resumed.present, "folder_id"));
    try std.testing.expectEqualStrings("etag-folder", outputString(resumed.present, "etag"));
}

test "project updates use native parent move then exact etag field masks" {
    const remote = "{\"name\":\"projects/987654321\",\"parent\":\"organizations/123456789\",\"projectId\":\"ziac-platform-prod\",\"displayName\":\"Old name\",\"labels\":{\"owner\":\"platform\"},\"state\":\"ACTIVE\",\"etag\":\"etag-project\"}";
    const responses = [_]zstd.Http.Response{
        ok(remote),
        ok("{\"name\":\"operations/project-move\",\"done\":false}"),
        ok(remote),
        ok("{\"name\":\"operations/project-patch\",\"done\":false}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.organization_provider.Handler{ .client = &harness.client };
    var moved = try buildProject("folders/222222222", "Old name");
    defer moved.deinit(std.testing.allocator);
    var renamed = try buildProject("organizations/123456789", "New name");
    defer renamed.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var observed_move = try handler.read(&context, moved.node, "projects/987654321");
    defer observed_move.deinit();
    var move_pending = try handler.update(&context, moved.node, &observed_move.present);
    defer move_pending.deinit();
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[1].url, "/v3/projects/987654321:move"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"destinationParent\":\"folders/222222222\"") != null);

    var observed_patch = try handler.read(&context, renamed.node, "projects/987654321");
    defer observed_patch.deinit();
    var patch_pending = try handler.update(&context, renamed.node, &observed_patch.present);
    defer patch_pending.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].url, "updateMask=displayName") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].body, "\"etag\":\"etag-project\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].body, "\"labels\"") == null);
}

test "project labels update without clearing an unmanaged display name" {
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"projects/987654321\",\"parent\":\"organizations/123456789\",\"projectId\":\"ziac-platform-prod\",\"displayName\":\"Console managed\",\"labels\":{\"owner\":\"legacy\"},\"state\":\"ACTIVE\",\"etag\":\"etag-project\"}"),
        ok("{\"name\":\"operations/project-patch\",\"done\":false}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.organization_provider.Handler{ .client = &harness.client };
    var project = try buildProject("organizations/123456789", "");
    defer project.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var observed = try handler.read(&context, project.node, "projects/987654321");
    defer observed.deinit();
    var pending = try handler.update(&context, project.node, &observed.present);
    defer pending.deinit();

    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].url, "updateMask=labels") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"displayName\"") == null);
}

test "billing updates and detachment are explicit singleton operations" {
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"projects/ziac-platform-prod/billingInfo\",\"projectId\":\"ziac-platform-prod\",\"billingAccountName\":\"billingAccounts/AAAAAA-BBBBBB-CCCCCC\",\"billingEnabled\":true}"),
        ok("{\"name\":\"projects/ziac-platform-prod/billingInfo\",\"projectId\":\"ziac-platform-prod\",\"billingAccountName\":\"billingAccounts/000000-111111-222222\",\"billingEnabled\":true}"),
        ok("{\"name\":\"projects/ziac-platform-prod/billingInfo\",\"projectId\":\"ziac-platform-prod\",\"billingAccountName\":\"\",\"billingEnabled\":false}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.organization_provider.Handler{ .client = &harness.client };
    var association = try buildBilling(.detach);
    defer association.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var observed = try handler.read(&context, association.node, null);
    defer observed.deinit();
    var updated = try handler.update(&context, association.node, &observed.present);
    defer updated.deinit();
    try std.testing.expectEqualStrings("PUT", harness.transport.requests.items[1].method);
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[1].url, "/v1/projects/ziac-platform-prod/billingInfo"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "billingAccounts/000000-111111-222222") != null);

    try std.testing.expectError(error.DestructiveConfirmationRequired, handler.delete(&context, association.node, observed.present.physical_id));
    context.destructive_confirmation = true;
    try handler.delete(&context, association.node, observed.present.physical_id);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[2].body, "\"billingAccountName\":\"\"") != null);
}

test "service identity generation is resumable and hierarchy deletion is doubly gated" {
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"operations/service-identity\",\"done\":false}"),
        ok("{\"name\":\"operations/service-identity\",\"done\":true,\"response\":{\"email\":\"service-987@gcp-sa-run.iam.gserviceaccount.com\",\"uniqueId\":\"1122334455\"}}"),
        ok("{\"name\":\"operations/project-delete\",\"done\":false}"),
        ok("{\"name\":\"operations/project-delete\",\"done\":true,\"response\":{}}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.organization_provider.Handler{ .client = &harness.client, .operation_policy = .{ .poll_interval_millis = 0 } };
    var identity = try organization.ServiceIdentity.build(std.testing.allocator, config(), .{
        .project_number = ziac.PublicOutput([]const u8).known("987654321"),
        .service = "run.googleapis.com",
    });
    defer identity.deinit(std.testing.allocator);
    var project = try organization.Project.build(std.testing.allocator, config(), .{
        .project_id = "ziac-sandbox-123",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .request_delete = true,
        .protect = false,
        .retain_on_delete = false,
    });
    defer project.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.create(&context, identity.node);
    defer pending.deinit();
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[0].url, "/v1beta1/projects/987654321/services/run.googleapis.com:generateServiceIdentity"));
    context.operation_handle = pending.operation_handle;
    var resumed = try handler.read(&context, identity.node, null);
    defer resumed.deinit();
    try std.testing.expectEqualStrings("service-987@gcp-sa-run.iam.gserviceaccount.com", outputString(resumed.present, "email"));

    context.operation_handle = null;
    try std.testing.expectError(error.DestructiveConfirmationRequired, handler.delete(&context, project.node, "projects/987654321"));
    context.destructive_confirmation = true;
    try handler.delete(&context, project.node, "projects/987654321");
}

test "service identity import reads the generated account through IAM" {
    const responses = [_]zstd.Http.Response{ok(
        "{\"name\":\"projects/ziac-platform-prod/serviceAccounts/service-987@gcp-sa-run.iam.gserviceaccount.com\",\"email\":\"service-987@gcp-sa-run.iam.gserviceaccount.com\",\"uniqueId\":\"1122334455\"}",
    )};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.organization_provider.Handler{ .client = &harness.client };
    var identity = try organization.ServiceIdentity.build(std.testing.allocator, config(), .{
        .project_number = ziac.PublicOutput([]const u8).known("987654321"),
        .service = "run.googleapis.com",
    });
    defer identity.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var imported = try handler.importResource(&context, identity.node, "service-987@gcp-sa-run.iam.gserviceaccount.com");
    defer imported.deinit();

    try std.testing.expect(std.mem.startsWith(u8, harness.transport.requests.items[0].url, "https://iam.example.test/v1/"));
    try std.testing.expectEqualStrings("1122334455", outputString(imported, "unique_id"));
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "host-project", .primary_region = "europe-west1" };
}

fn buildFolder(display_name: []const u8) !organization.Folder {
    return organization.Folder.build(std.testing.allocator, config(), .{
        .name = "platform",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .display_name = display_name,
    });
}

fn buildProject(parent: []const u8, display_name: []const u8) !organization.Project {
    return organization.Project.build(std.testing.allocator, config(), .{
        .project_id = "ziac-platform-prod",
        .parent = ziac.PublicOutput([]const u8).known(parent),
        .display_name = display_name,
        .labels = &.{.{ .key = "owner", .value = "platform" }},
    });
}

fn buildBilling(policy: organization.BillingRemovalPolicy) !organization.ProjectBillingAssociation {
    return organization.ProjectBillingAssociation.build(std.testing.allocator, config(), .{
        .project = ziac.PublicOutput([]const u8).known("projects/ziac-platform-prod"),
        .billing_account = "billingAccounts/000000-111111-222222",
        .removal_policy = policy,
    });
}

const Harness = struct {
    source: FixedTokenSource,
    cache: auth.TokenCache,
    transport: @import("gcp_client_test.zig").RecordingTransport,
    client: gclient.Client,

    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.source = .{};
        self.cache = auth.TokenCache.init(self.source.tokenSource(), 300);
        self.transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{
            .resource_manager = "https://resourcemanager.example.test",
            .cloud_billing = "https://cloudbilling.example.test",
            .service_usage = "https://serviceusage.example.test",
            .iam = "https://iam.example.test",
        });
    }

    fn deinit(self: *Harness) void {
        self.transport.deinit();
        self.cache.deinit(std.testing.allocator);
    }
};

const FixedTokenSource = struct {
    fn tokenSource(self: *FixedTokenSource) auth.TokenSource {
        return .{ .ptr = self, .fetchFn = fetch };
    }
    fn fetch(_: *anyopaque, allocator: std.mem.Allocator, now: u64) auth.AuthError!auth.AccessToken {
        return auth.AccessToken.initOwned(allocator, .{ .access_token = "token", .token_type = "Bearer", .expires_at_seconds = now + 3600 });
    }
};

fn outputString(result: ziac.provider.ResourceResult, name: []const u8) []const u8 {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name)) return item.value.string;
    unreachable;
}

fn ok(body: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = body };
}
