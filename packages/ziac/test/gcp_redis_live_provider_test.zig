const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;

test "Memorystore classic lifecycle persists generated auth once and resumes operations" {
    const before = instanceJson(8);
    const after = instanceJson(16);
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/create-cache\",\"done\":false}"),
        ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/create-cache\",\"done\":true}"),
        ok(before),
        ok("{\"authString\":\"generated-redis-auth\"}"),
        ok("{\"name\":\"projects/ziac-dev/secrets/redis-sessions-auth/versions/7\"}"),
        ok(before),
        ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/update-cache\",\"done\":false}"),
        ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/update-cache\",\"done\":true}"),
        ok(after),
        ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/delete-cache\",\"done\":false}"),
        ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/delete-cache\",\"done\":true}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.redis_provider.Handler{ .client = &harness.client, .operation_policy = .{ .poll_interval_millis = 0 } };
    var initial = try buildInstance(8);
    defer initial.deinit(std.testing.allocator);
    var changed = try buildInstance(16);
    defer changed.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.create(&context, initial.node);
    defer pending.deinit();
    try std.testing.expect(std.mem.startsWith(u8, pending.operation_handle.?, "create:"));
    context.operation_handle = pending.operation_handle;
    var created = try handler.read(&context, initial.node, null);
    defer created.deinit();
    context.operation_handle = null;
    try std.testing.expect(outputValue(created.present, "auth_secret_version") == .secret_ref);
    try std.testing.expectEqualStrings("7", outputValue(created.present, "auth_secret_version").secret_ref.version.?);
    var current = try handler.read(&context, initial.node, null);
    defer current.deinit();
    var diff = try ziac.gcp.redis_provider.Handler.diff(&context, changed.node, &current.present);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, diff.kind);
    var update = try handler.update(&context, changed.node, &current.present);
    defer update.deinit();
    try std.testing.expect(std.mem.startsWith(u8, update.operation_handle.?, "update:"));
    context.operation_handle = update.operation_handle;
    var updated = try handler.read(&context, changed.node, null);
    defer updated.deinit();
    context.operation_handle = null;
    try handler.delete(&context, changed.node, updated.present.physical_id);

    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].url, "instanceId=sessions") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[4].url, "/v1/projects/ziac-dev/secrets/redis-sessions-auth:addVersion") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[4].body, "generated-redis-auth") == null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[4].body, "Z2VuZXJhdGVkLXJlZGlzLWF1dGg=") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[6].url, "updateMask=memorySizeGb") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "\"weeklyMaintenanceWindow\":[{\"day\":\"MONDAY\",\"startTime\":{\"hours\":3}}]") != null);
}

test "Memorystore classic version changes use the dedicated upgrade operation" {
    const responses = [_]zstd.Http.Response{
        ok(instanceJsonForVersion("REDIS_7_0")),
        ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/upgrade-cache\",\"done\":false}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.redis_provider.Handler{ .client = &harness.client };
    var initial = try buildVersionedInstance(.redis_7_0);
    defer initial.deinit(std.testing.allocator);
    var upgraded = try buildVersionedInstance(.redis_7_2);
    defer upgraded.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var observed = try handler.read(&context, initial.node, null);
    defer observed.deinit();
    var diff = try ziac.gcp.redis_provider.Handler.diff(&context, upgraded.node, &observed.present);
    defer diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, diff.kind);
    var pending = try handler.update(&context, upgraded.node, &observed.present);
    defer pending.deinit();

    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[1].url, "/v1/projects/ziac-dev/locations/europe-west1/instances/sessions:upgrade"));
    try std.testing.expectEqualStrings("{\"redisVersion\":\"REDIS_7_2\"}", harness.transport.requests.items[1].body);
}

test "Memorystore ACL resolves secret rules and cluster uses PSC network" {
    const acl_json = "{\"name\":\"projects/ziac-dev/locations/us-central1/aclPolicies/application\",\"state\":\"ACTIVE\",\"etag\":\"etag-1\",\"rules\":[{\"username\":\"api\",\"rule\":\"on >resolved-secret ~app:* +@all\"}]}";
    const cluster_json = "{\"name\":\"projects/ziac-dev/locations/us-central1/clusters/global-cache\",\"state\":\"ACTIVE\",\"uid\":\"cluster-uid\",\"shardCount\":3,\"replicaCount\":1,\"nodeType\":\"REDIS_SHARED_CORE_NANO\",\"authorizationMode\":\"AUTH_MODE_IAM_AUTH\",\"transitEncryptionMode\":\"TRANSIT_ENCRYPTION_MODE_SERVER_AUTHENTICATION\",\"pscConfigs\":[{\"network\":\"projects/ziac-dev/global/networks/platform\"}],\"discoveryEndpoints\":[{\"address\":\"10.20.0.5\",\"port\":6379}],\"deletionProtectionEnabled\":true,\"persistenceConfig\":{\"mode\":\"DISABLED\"},\"redisConfigs\":{},\"aclPolicy\":\"projects/ziac-dev/locations/us-central1/aclPolicies/application\"}";
    const responses = [_]zstd.Http.Response{
        ok(acl_json),
        ok(acl_json),
        ok("{\"name\":\"projects/ziac-dev/locations/us-central1/operations/create-cluster\",\"done\":false}"),
        ok("{\"name\":\"projects/ziac-dev/locations/us-central1/operations/create-cluster\",\"done\":true}"),
        ok(cluster_json),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var secrets = FixedSecretSource{};
    const handler = ziac.gcp.redis_provider.Handler{
        .client = &harness.client,
        .operation_policy = .{ .poll_interval_millis = 0 },
        .secret_source = secrets.secretSource(),
    };
    const rule = ziac.SecretOutput(ziac.value.SecretReference).known(.{
        .provider = "gcp-secret-manager",
        .resource = "projects/ziac-dev/secrets/redis-acl-api",
        .version = "1",
    });
    var acl = try ziac.gcp.redis.AclPolicy.build(std.testing.allocator, config(), .{
        .policy_id = "application",
        .location = "us-central1",
        .rules = &.{.{ .username = "api", .rule = rule }},
        .protect = false,
        .retain_on_delete = false,
    });
    defer acl.deinit(std.testing.allocator);
    var cluster = try ziac.gcp.redis.Cluster.build(std.testing.allocator, config(), .{
        .cluster_id = "global-cache",
        .location = "us-central1",
        .shard_count = 3,
        .replica_count = 1,
        .node_type = .shared_core_nano,
        .network = "projects/ziac-dev/global/networks/platform",
        .acl_policy = ziac.PublicOutput([]const u8).known("projects/ziac-dev/locations/us-central1/aclPolicies/application"),
        .protect = false,
        .retain_on_delete = false,
    });
    defer cluster.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var acl_created = try handler.create(&context, acl.node);
    defer acl_created.deinit();
    var acl_read = try handler.read(&context, acl.node, null);
    defer acl_read.deinit();
    var pending = try handler.create(&context, cluster.node);
    defer pending.deinit();
    context.operation_handle = pending.operation_handle;
    var cluster_created = try handler.read(&context, cluster.node, null);
    defer cluster_created.deinit();

    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "resolved-secret") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[2].body, "projects/ziac-dev/global/networks/platform") != null);
    try std.testing.expectEqualStrings("10.20.0.5:6379", outputValue(cluster_created.present, "discovery_endpoint").string);
}

test "Memorystore ACL detects remote rule drift without storing plaintext" {
    const responses = [_]zstd.Http.Response{ok("{\"name\":\"projects/ziac-dev/locations/us-central1/aclPolicies/application\",\"state\":\"ACTIVE\",\"etag\":\"etag-2\",\"rules\":[{\"username\":\"api\",\"rule\":\"on >unexpected-secret ~app:* +@all\"}]}")};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var secrets = FixedSecretSource{};
    const handler = ziac.gcp.redis_provider.Handler{ .client = &harness.client, .secret_source = secrets.secretSource() };
    const rule = ziac.SecretOutput(ziac.value.SecretReference).known(.{
        .provider = "gcp-secret-manager",
        .resource = "projects/ziac-dev/secrets/redis-acl-api",
        .version = "1",
    });
    var acl = try ziac.gcp.redis.AclPolicy.build(std.testing.allocator, config(), .{
        .policy_id = "application",
        .location = "us-central1",
        .rules = &.{.{ .username = "api", .rule = rule }},
        .protect = false,
        .retain_on_delete = false,
    });
    defer acl.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var observed = try handler.read(&context, acl.node, null);
    defer observed.deinit();
    var diff = try ziac.gcp.redis_provider.Handler.diff(&context, acl.node, &observed.present);
    defer diff.deinit();

    try std.testing.expectEqual(ziac.provider.DiffKind.update, diff.kind);
    const encoded = try observed.present.observed_inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "unexpected-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "resolved-secret") == null);
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
            .redis = "https://redis.example.test",
            .secret_manager = "https://secretmanager.example.test",
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
        return ziac.secret.SecretPayload.initOwned(allocator, "on >resolved-secret ~app:* +@all", null);
    }
};

fn buildInstance(memory: u16) !ziac.gcp.redis.Instance {
    return ziac.gcp.redis.Instance.build(std.testing.allocator, config(), .{
        .instance_id = "sessions",
        .location = "europe-west1",
        .tier = .standard_ha,
        .memory_size_gb = memory,
        .network = "projects/ziac-dev/global/networks/platform",
        .connect_mode = .private_service_access,
        .connectivity_dependency = ziac.PublicOutput([]const u8).known("services/servicenetworking.googleapis.com/connections/servicenetworking-googleapis-com"),
        .auth_secret = ziac.PublicOutput([]const u8).known("projects/ziac-dev/secrets/redis-sessions-auth"),
        .read_replicas = 2,
        .persistence = .{ .rdb = .six_hours },
        .maintenance_day = "MONDAY",
        .maintenance_hour_utc = 3,
        .configs = &.{.{ .key = "maxmemory-policy", .value = "allkeys-lru" }},
        .protect = false,
        .retain_on_delete = false,
    });
}

fn buildVersionedInstance(version: ziac.gcp.redis.RedisVersion) !ziac.gcp.redis.Instance {
    return ziac.gcp.redis.Instance.build(std.testing.allocator, config(), .{
        .instance_id = "sessions",
        .location = "europe-west1",
        .tier = .standard_ha,
        .memory_size_gb = 8,
        .redis_version = version,
        .network = "projects/ziac-dev/global/networks/platform",
        .auth_enabled = false,
        .protect = false,
        .retain_on_delete = false,
    });
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
}

fn instanceJson(comptime memory: u16) []const u8 {
    return std.fmt.comptimePrint("{{\"name\":\"projects/ziac-dev/locations/europe-west1/instances/sessions\",\"state\":\"READY\",\"tier\":\"STANDARD_HA\",\"memorySizeGb\":{d},\"redisVersion\":\"REDIS_7_2\",\"authorizedNetwork\":\"projects/ziac-dev/global/networks/platform\",\"connectMode\":\"PRIVATE_SERVICE_ACCESS\",\"authEnabled\":true,\"transitEncryptionMode\":\"SERVER_AUTHENTICATION\",\"replicaCount\":2,\"readEndpoint\":\"10.10.0.4\",\"host\":\"10.10.0.3\",\"port\":6379,\"maintenancePolicy\":{{\"weeklyMaintenanceWindow\":[{{\"day\":\"MONDAY\",\"startTime\":{{\"hours\":3}},\"duration\":\"3600s\"}}]}},\"persistenceConfig\":{{\"persistenceMode\":\"RDB\",\"rdbSnapshotPeriod\":\"SIX_HOURS\"}},\"redisConfigs\":{{\"maxmemory-policy\":\"allkeys-lru\"}}}}", .{memory});
}

fn instanceJsonForVersion(version: []const u8) []const u8 {
    return if (std.mem.eql(u8, version, "REDIS_7_0"))
        "{\"name\":\"projects/ziac-dev/locations/europe-west1/instances/sessions\",\"state\":\"READY\",\"tier\":\"STANDARD_HA\",\"memorySizeGb\":8,\"redisVersion\":\"REDIS_7_0\",\"authorizedNetwork\":\"projects/ziac-dev/global/networks/platform\",\"connectMode\":\"DIRECT_PEERING\",\"authEnabled\":false,\"transitEncryptionMode\":\"SERVER_AUTHENTICATION\",\"replicaCount\":0,\"host\":\"10.10.0.3\",\"port\":6379,\"persistenceConfig\":{\"persistenceMode\":\"DISABLED\"},\"redisConfigs\":{}}"
    else
        unreachable;
}

fn outputValue(result: ziac.provider.ResourceResult, name: []const u8) ziac.value.Value {
    for (result.outputs) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value;
    unreachable;
}

fn ok(body: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = body };
}
