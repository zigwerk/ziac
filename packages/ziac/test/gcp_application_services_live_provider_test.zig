const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;

test "Workflows lifecycle checkpoints and resumes one Google operation" {
    const workflow_json = "{\"name\":\"projects/ziac-dev/locations/europe-west1/workflows/global-rollout\",\"revisionId\":\"000001-a1b\",\"state\":\"ACTIVE\",\"updateTime\":\"2026-07-14T10:00:00Z\",\"sourceContents\":\"main:\\n  return: ok\\n\",\"serviceAccount\":\"projects/ziac-dev/serviceAccounts/workflows@ziac-dev.iam.gserviceaccount.com\",\"callLogLevel\":\"LOG_ERRORS_ONLY\",\"executionHistoryLevel\":\"EXECUTION_HISTORY_DISABLED\",\"userEnvVars\":{}}";
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/create-workflow\",\"done\":false}"),
        ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/create-workflow\",\"done\":true,\"response\":" ++ workflow_json ++ "}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.application_services_provider.Handler{ .client = &harness.client, .operation_policy = .{ .poll_interval_millis = 0 } };
    var workflow = try buildWorkflow();
    defer workflow.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.create(&context, workflow.node);
    defer pending.deinit();
    try std.testing.expect(pending.operation_handle != null);
    context.operation_handle = pending.operation_handle;
    var created = try handler.read(&context, workflow.node, null);
    defer created.deinit();

    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].url, "/v1/projects/ziac-dev/locations/europe-west1/workflows?workflowId=global-rollout") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "sourceContents") != null);
    try std.testing.expectEqualStrings("000001-a1b", outputValue(created.present, "revision_id").string);
}

test "API Config resolves documents only for mutation and retains reference state" {
    const responses = [_]zstd.Http.Response{ok("{\"name\":\"projects/ziac-dev/locations/global/operations/create-config\",\"done\":false}")};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var secrets = FixedSecretSource{};
    const handler = ziac.gcp.application_services_provider.Handler{ .client = &harness.client, .secret_source = secrets.secretSource() };
    var api = try ziac.gcp.api_gateway.Api.build(std.testing.allocator, config(), .{ .api_id = "global-api" });
    defer api.deinit(std.testing.allocator);
    var api_config = try ziac.gcp.api_gateway.ApiConfig.build(std.testing.allocator, config(), .{
        .api = ziac.PublicOutput([]const u8).known("projects/ziac-dev/locations/global/apis/global-api"),
        .api_id = "global-api",
        .config_id = "v1-4f14",
        .documents = &.{.{
            .path = "openapi.yaml",
            .contents = secretReference(),
            .sha256 = "344e4b2f7f15b76b5606be45d8031fc43f473f8d63f0e02c61dbf89a97f85e69",
        }},
    });
    defer api_config.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.create(&context, api_config.node);
    defer pending.deinit();

    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "b3BlbmFwaTogMy4wLjAK") != null);
    const state_json = try pending.observed_inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(state_json);
    try std.testing.expect(std.mem.indexOf(u8, state_json, "openapi: 3.0.0") == null);
    try std.testing.expect(std.mem.indexOf(u8, state_json, "gcp-secret-manager") != null);
}

test "Application-service mutations reject resolved payloads with a different digest" {
    const responses = [_]zstd.Http.Response{};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var secrets = FixedSecretSource{};
    const handler = ziac.gcp.application_services_provider.Handler{ .client = &harness.client, .secret_source = secrets.secretSource() };
    var api_config = try ziac.gcp.api_gateway.ApiConfig.build(std.testing.allocator, config(), .{
        .api = ziac.PublicOutput([]const u8).known("projects/ziac-dev/locations/global/apis/global-api"),
        .api_id = "global-api",
        .config_id = "v1-tampered",
        .documents = &.{.{
            .path = "openapi.yaml",
            .contents = secretReference(),
            .sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
        }},
    });
    defer api_config.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    try std.testing.expectError(error.InvalidConfiguration, handler.create(&context, api_config.node));
    try std.testing.expectEqual(@as(usize, 0), harness.transport.requests.items.len);
}

test "Identity Platform resolves write-only credentials and forbids singleton deletion" {
    const idp_json = "{\"name\":\"projects/ziac-dev/oauthIdpConfigs/oidc.workforce\",\"displayName\":\"Workforce\",\"enabled\":true,\"issuer\":\"https://identity.example.com\",\"clientId\":\"ziac\"}";
    const responses = [_]zstd.Http.Response{ok(idp_json)};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var secrets = FixedSecretSource{};
    const handler = ziac.gcp.application_services_provider.Handler{ .client = &harness.client, .secret_source = secrets.secretSource() };
    var idp = try ziac.gcp.identity.ProjectOAuthIdpConfig.build(std.testing.allocator, config(), .{
        .provider_id = "oidc.workforce",
        .display_name = "Workforce",
        .issuer = "https://identity.example.com",
        .client_id = "ziac",
        .client_secret = secretReference(),
    });
    defer idp.deinit(std.testing.allocator);
    var project_config = try ziac.gcp.identity.ProjectConfig.build(std.testing.allocator, config(), .{});
    defer project_config.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try handler.create(&context, idp.node);
    defer created.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "openapi: 3.0.0") != null);
    try std.testing.expectError(error.InvalidConfiguration, handler.delete(&context, project_config.node, "projects/ziac-dev/config"));
    try std.testing.expect(outputValue(created, "name") == .string);
}

test "Parameter Manager versions send base64 payload and never retain bytes" {
    const version_json = "{\"name\":\"projects/ziac-dev/locations/global/parameters/application-config/versions/release-1\",\"disabled\":false,\"etag\":\"etag-1\"}";
    const responses = [_]zstd.Http.Response{ok(version_json)};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var secrets = FixedSecretSource{};
    const handler = ziac.gcp.application_services_provider.Handler{ .client = &harness.client, .secret_source = secrets.secretSource() };
    var version = try ziac.gcp.parameter_manager.ParameterVersion.build(std.testing.allocator, config(), .{
        .parameter = ziac.PublicOutput([]const u8).known("projects/ziac-dev/locations/global/parameters/application-config"),
        .parameter_id = "application-config",
        .version_id = "release-1",
        .payload = secretReference(),
        .payload_sha256 = "344e4b2f7f15b76b5606be45d8031fc43f473f8d63f0e02c61dbf89a97f85e69",
    });
    defer version.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try handler.create(&context, version.node);
    defer created.deinit();

    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "b3BlbmFwaTogMy4wLjAK") != null);
    const state_json = try created.observed_inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(state_json);
    try std.testing.expect(std.mem.indexOf(u8, state_json, "openapi: 3.0.0") == null);
    try std.testing.expectEqualStrings("etag-1", outputValue(created, "etag").string);
}

test "API Gateway IAM uses additive etag-safe live-provider dispatch" {
    const empty = "{\"version\":1,\"etag\":\"etag-a\",\"bindings\":[]}";
    const updated = "{\"version\":1,\"etag\":\"etag-b\",\"bindings\":[{\"role\":\"roles/apigateway.viewer\",\"members\":[\"group:platform@example.com\"]}]}";
    const responses = [_]zstd.Http.Response{ ok(empty), ok(updated) };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var live = ziac.gcp.live_provider.LiveProvider.init(&harness.client);
    const provider = live.provider();
    var member = try ziac.gcp.api_gateway.ApiIamMember.build(std.testing.allocator, config(), .{
        .name = "api-viewer",
        .resource_name = ziac.PublicOutput([]const u8).known("projects/ziac-dev/locations/global/apis/global-api"),
        .api_id = "global-api",
        .role = "roles/apigateway.viewer",
        .member = "group:platform@example.com",
    });
    defer member.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var created = try provider.createWithContext(&context, member.node);
    defer created.deinit();

    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[0].url, "/v1/projects/ziac-dev/locations/global/apis/global-api:getIamPolicy"));
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[1].url, "/v1/projects/ziac-dev/locations/global/apis/global-api:setIamPolicy"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"etag\":\"etag-a\"") != null);
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
            .workflows = "https://workflows.example.test",
            .api_gateway = "https://apigateway.example.test",
            .identity_toolkit = "https://identitytoolkit.example.test",
            .parameter_manager = "https://parametermanager.example.test",
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

const FixedSecretSource = struct {
    fn secretSource(self: *FixedSecretSource) ziac.secret.SecretSource {
        return .{ .ptr = self, .resolveFn = resolve };
    }
    fn resolve(_: *anyopaque, _: *ziac.provider.OperationContext, allocator: std.mem.Allocator, _: ziac.value.SecretReference) ziac.provider.ProviderError!ziac.secret.SecretPayload {
        return ziac.secret.SecretPayload.initOwned(allocator, "openapi: 3.0.0\n", null);
    }
};

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
}

fn secretReference() ziac.SecretOutput(ziac.value.SecretReference) {
    return .known(.{ .provider = "gcp-secret-manager", .resource = "projects/ziac-dev/secrets/application-source", .version = "1" });
}

fn buildWorkflow() !ziac.gcp.workflows.Workflow {
    return ziac.gcp.workflows.Workflow.build(std.testing.allocator, config(), .{
        .workflow_id = "global-rollout",
        .source_contents = "main:\n  return: ok\n",
        .service_account = ziac.PublicOutput([]const u8).known("projects/ziac-dev/serviceAccounts/workflows@ziac-dev.iam.gserviceaccount.com"),
        .protect = false,
        .retain_on_delete = false,
    });
}

fn outputValue(result: ziac.provider.ResourceResult, name: []const u8) ziac.value.Value {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name)) return item.value;
    unreachable;
}

fn ok(body: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = @constCast(body) };
}
