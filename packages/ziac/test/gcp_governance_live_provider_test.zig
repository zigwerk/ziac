const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;
const governance = ziac.gcp.governance;

test "organization policy uses spec etag and exact full-overwrite mask" {
    const old_policy = "{\"name\":\"organizations/123456789/policies/gcp.resourceLocations\",\"spec\":{\"etag\":\"spec-old\",\"inheritFromParent\":false,\"reset\":false,\"rules\":[{\"values\":{\"allowedValues\":[\"in:us-locations\"]}}]},\"etag\":\"policy-old\"}";
    const new_policy = "{\"name\":\"organizations/123456789/policies/gcp.resourceLocations\",\"spec\":{\"etag\":\"spec-new\",\"inheritFromParent\":false,\"reset\":false,\"rules\":[{\"values\":{\"allowedValues\":[\"in:eu-locations\"]}}]},\"etag\":\"policy-new\"}";
    const responses = [_]zstd.Http.Response{ ok(new_policy), ok(old_policy), ok(new_policy), ok("{}") };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.governance_provider.Handler{ .client = &harness.client };
    var policy = try buildPolicy(.delete);
    defer policy.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try handler.create(&context, policy.node);
    defer created.deinit();
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[0].url, "/v2/organizations/123456789/policies"));

    var observed = try handler.read(&context, policy.node, created.physical_id);
    defer observed.deinit();
    var updated = try handler.update(&context, policy.node, &observed.present);
    defer updated.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[2].url, "updateMask=spec%2CdryRunSpec") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[2].body, "\"etag\":\"spec-old\"") != null);

    try std.testing.expectError(error.DestructiveConfirmationRequired, handler.delete(&context, policy.node, updated.physical_id));
    context.destructive_confirmation = true;
    try handler.delete(&context, policy.node, updated.physical_id);
}

test "tag key checkpoints server identity and tag binding reads through parent listing" {
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"operations/tag-key-create\",\"done\":false}"),
        ok("{\"name\":\"operations/tag-key-create\",\"done\":true,\"response\":{\"name\":\"tagKeys/111\",\"parent\":\"organizations/123456789\",\"shortName\":\"environment\",\"description\":\"Deployment environment\",\"purpose\":\"PURPOSE_UNSPECIFIED\",\"purposeData\":{},\"allowedValuesRegex\":\"\",\"namespacedName\":\"123456789/environment\",\"etag\":\"etag-key\"}}"),
        ok("{\"tagBindings\":[{\"name\":\"tagBindings/%2F%2Fcloudresourcemanager.googleapis.com%2Fprojects%2F987654321/tagValues/222\",\"parent\":\"//cloudresourcemanager.googleapis.com/projects/987654321\",\"tagValue\":\"tagValues/222\"}]}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.governance_provider.Handler{ .client = &harness.client, .operation_policy = .{ .poll_interval_millis = 0 } };
    var key = try buildTagKey();
    defer key.deinit(std.testing.allocator);
    var binding = try governance.TagBinding.build(std.testing.allocator, config(), .{
        .name = "platform-production",
        .parent = ziac.PublicOutput([]const u8).known("//cloudresourcemanager.googleapis.com/projects/987654321"),
        .tag_value = ziac.PublicOutput([]const u8).known("tagValues/222"),
    });
    defer binding.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.create(&context, key.node);
    defer pending.deinit();
    try std.testing.expect(!pending.completed);
    try std.testing.expectEqualStrings("operations/tag-key-create", pending.operation_handle.?);
    context.operation_handle = pending.operation_handle;
    var resumed = try handler.read(&context, key.node, null);
    defer resumed.deinit();
    try std.testing.expectEqualStrings("tagKeys/111", resumed.present.physical_id);

    context.operation_handle = null;
    var discovered = try handler.read(&context, binding.node, null);
    defer discovered.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[2].url, "/v3/tagBindings?parent=%2F%2Fcloudresourcemanager.googleapis.com%2Fprojects%2F987654321") != null);
    try std.testing.expectEqualStrings("tagValues/222", outputString(discovered.present, "tag_value"));
}

test "access policy level and perimeter mutations are resumable" {
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"operations/access-policy\",\"done\":false}"),
        ok("{\"name\":\"operations/access-policy\",\"done\":true,\"response\":{\"name\":\"accessPolicies/123\",\"parent\":\"organizations/123456789\",\"title\":\"Platform access\",\"scopes\":[\"folders/222222222\"],\"etag\":\"etag-policy\"}}"),
        ok("{\"name\":\"operations/access-level\",\"done\":false}"),
        ok("{\"name\":\"operations/access-level\",\"done\":true,\"response\":{\"name\":\"accessPolicies/123/accessLevels/trusted_engineers\",\"title\":\"Trusted engineers\",\"description\":\"\",\"custom\":{\"expr\":\"request.auth != null\"}}}"),
        ok("{\"name\":\"operations/perimeter\",\"done\":false}"),
        ok("{\"name\":\"operations/perimeter\",\"done\":true,\"response\":{\"name\":\"accessPolicies/123/servicePerimeters/production_data\",\"title\":\"Production data\",\"description\":\"\",\"perimeterType\":\"PERIMETER_TYPE_REGULAR\",\"status\":{\"resources\":[\"projects/987654321\"],\"restrictedServices\":[\"storage.googleapis.com\"]},\"useExplicitDryRunSpec\":false,\"etag\":\"etag-perimeter\"}}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.governance_provider.Handler{ .client = &harness.client, .operation_policy = .{ .poll_interval_millis = 0 } };
    var access_policy = try governance.AccessPolicy.build(std.testing.allocator, config(), .{
        .name = "platform",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .title = "Platform access",
        .scope = ziac.PublicOutput([]const u8).known("folders/222222222"),
    });
    defer access_policy.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var policy_pending = try handler.create(&context, access_policy.node);
    defer policy_pending.deinit();
    context.operation_handle = policy_pending.operation_handle;
    var policy_result = try handler.read(&context, access_policy.node, null);
    defer policy_result.deinit();
    try std.testing.expectEqualStrings("accessPolicies/123", policy_result.present.physical_id);

    var level = try governance.AccessLevel.build(std.testing.allocator, config(), .{
        .name = "trusted_engineers",
        .policy = ziac.PublicOutput([]const u8).known("accessPolicies/123"),
        .title = "Trusted engineers",
        .level = .{ .custom = "request.auth != null" },
    });
    defer level.deinit(std.testing.allocator);
    context.operation_handle = null;
    var level_pending = try handler.create(&context, level.node);
    defer level_pending.deinit();
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[2].url, "/v1/accessPolicies/123/accessLevels"));
    context.operation_handle = level_pending.operation_handle;
    var level_result = try handler.read(&context, level.node, null);
    defer level_result.deinit();

    var perimeter = try governance.ServicePerimeter.build(std.testing.allocator, config(), .{
        .name = "production_data",
        .policy = ziac.PublicOutput([]const u8).known("accessPolicies/123"),
        .title = "Production data",
        .status = .{
            .resources = &.{ziac.PublicOutput([]const u8).known("projects/987654321")},
            .restricted_services = &.{"storage.googleapis.com"},
        },
    });
    defer perimeter.deinit(std.testing.allocator);
    context.operation_handle = null;
    var perimeter_pending = try handler.create(&context, perimeter.node);
    defer perimeter_pending.deinit();
    context.operation_handle = perimeter_pending.operation_handle;
    var perimeter_result = try handler.read(&context, perimeter.node, null);
    defer perimeter_result.deinit();
    try std.testing.expectEqualStrings("accessPolicies/123/servicePerimeters/production_data", perimeter_result.present.physical_id);
}

test "access policy deletion requires declaration intent and operation authority" {
    var access_policy = try governance.AccessPolicy.build(std.testing.allocator, config(), .{
        .name = "platform",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .title = "Platform access",
        .protect = false,
        .retain_on_delete = false,
    });
    defer access_policy.deinit(std.testing.allocator);
    var harness: Harness = undefined;
    harness.init(&.{});
    defer harness.deinit();
    const handler = ziac.gcp.governance_provider.Handler{ .client = &harness.client };
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    context.destructive_confirmation = true;

    try std.testing.expectError(error.DestructiveConfirmationRequired, handler.delete(&context, access_policy.node, "accessPolicies/123"));
}

test "custom constraints tag values holds and user bindings preserve Google identities" {
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"organizations/123456789/customConstraints/custom.requireCmek\",\"resourceTypes\":[\"storage.googleapis.com/Bucket\"],\"methodTypes\":[\"CREATE\",\"UPDATE\"],\"condition\":\"!has(resource.encryption.defaultKmsKeyName)\",\"actionType\":\"DENY\",\"displayName\":\"Require customer-managed encryption\",\"description\":\"Reject buckets without a default KMS key.\",\"updateTime\":\"2026-07-14T12:00:00Z\"}"),
        ok("{\"name\":\"operations/tag-value-create\",\"done\":false}"),
        ok("{\"name\":\"operations/tag-value-create\",\"done\":true,\"response\":{\"name\":\"tagValues/222\",\"parent\":\"tagKeys/111\",\"shortName\":\"production\",\"namespacedName\":\"123456789/environment/production\",\"etag\":\"etag-value\"}}"),
        ok("{\"tagHolds\":[{\"name\":\"tagValues/222/tagHolds/333\",\"holder\":\"//run.googleapis.com/projects/ziac-platform-prod/locations/europe-west1/services/api\",\"origin\":\"ziac\",\"helpLink\":\"https://example.com/runbook/tag-hold\",\"createTime\":\"2026-07-14T12:01:00Z\"}]}"),
        ok("{\"gcpUserAccessBindings\":[{\"name\":\"organizations/123456789/gcpUserAccessBindings/444\",\"groupKey\":\"01d520gv4vjcrht\",\"accessLevels\":[\"accessPolicies/123/accessLevels/trusted_engineers\"]}]}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.governance_provider.Handler{ .client = &harness.client, .operation_policy = .{ .poll_interval_millis = 0 } };
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

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
    var created_constraint = try handler.create(&context, constraint.node);
    defer created_constraint.deinit();
    try std.testing.expectEqualStrings("organizations/123456789/customConstraints/custom.requireCmek", created_constraint.physical_id);

    var tag_value = try governance.TagValue.build(std.testing.allocator, config(), .{
        .name = "production",
        .parent = ziac.PublicOutput([]const u8).known("tagKeys/111"),
        .short_name = "production",
    });
    defer tag_value.deinit(std.testing.allocator);
    var pending_value = try handler.create(&context, tag_value.node);
    defer pending_value.deinit();
    context.operation_handle = pending_value.operation_handle;
    var created_value = try handler.read(&context, tag_value.node, null);
    defer created_value.deinit();
    try std.testing.expectEqualStrings("tagValues/222", created_value.present.physical_id);

    var hold = try governance.TagHold.build(std.testing.allocator, config(), .{
        .name = "platform-database",
        .parent = ziac.PublicOutput([]const u8).known("tagValues/222"),
        .holder = "//run.googleapis.com/projects/ziac-platform-prod/locations/europe-west1/services/api",
        .origin = "ziac",
        .help_link = "https://example.com/runbook/tag-hold",
    });
    defer hold.deinit(std.testing.allocator);
    context.operation_handle = null;
    var discovered_hold = try handler.read(&context, hold.node, null);
    defer discovered_hold.deinit();
    try std.testing.expectEqualStrings("tagValues/222/tagHolds/333", discovered_hold.present.physical_id);

    var binding = try governance.GcpUserAccessBinding.build(std.testing.allocator, config(), .{
        .name = "platform-engineers",
        .organization = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .group_key = "01d520gv4vjcrht",
        .access_level = ziac.PublicOutput([]const u8).known("accessPolicies/123/accessLevels/trusted_engineers"),
    });
    defer binding.deinit(std.testing.allocator);
    var discovered_binding = try handler.read(&context, binding.node, null);
    defer discovered_binding.deinit();
    try std.testing.expectEqualStrings("organizations/123456789/gcpUserAccessBindings/444", discovered_binding.present.physical_id);
}

fn buildPolicy(removal_policy: governance.RemovalPolicy) !governance.Policy {
    return governance.Policy.build(std.testing.allocator, config(), .{
        .name = "allowed-regions",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .constraint = "gcp.resourceLocations",
        .spec = .{ .rules = &.{.{ .effect = .{ .values = .{ .allowed = &.{"in:eu-locations"} } } }} },
        .removal_policy = removal_policy,
    });
}

fn buildTagKey() !governance.TagKey {
    return governance.TagKey.build(std.testing.allocator, config(), .{
        .name = "environment",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .short_name = "environment",
        .description = "Deployment environment",
    });
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "host-project", .primary_region = "europe-west1" };
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
            .organization_policy = "https://orgpolicy.example.test",
            .access_context_manager = "https://accesscontextmanager.example.test",
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
