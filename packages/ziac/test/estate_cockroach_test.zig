const std = @import("std");
const ziac = @import("ziac");

test "Cockroach Estate repository serves the control-plane contract with bounded statements" {
    var database = ScriptedDatabase.init(std.testing.allocator, &.{
        "{\"subject\":\"google-subject-42\",\"expires_at_millis\":2000,\"revoked\":false}",
        "{\"subject\":\"google-subject-42\",\"expires_at_millis\":2000,\"revoked\":false}",
        "{\"subject\":\"google-subject-42\",\"tier\":\"pro\",\"active\":true,\"expires_at_millis\":2000}",
        "{\"subject\":\"google-subject-42\",\"expires_at_millis\":2000,\"revoked\":false}",
        "{\"id\":\"gcp-connection-17\",\"subject\":\"google-subject-42\",\"project_id\":\"acme-prod\",\"status\":\"connected\",\"credential_key_id\":\"kms-key-version-7\"}",
    });
    defer database.deinit();
    var repository = ziac.estate_cockroach.Repository.init(std.testing.allocator, database.database());
    defer repository.deinit();
    var service = ziac.estate_service.Service.init(repository.repository());

    const digest = ziac.estate_service.sessionDigest("session-secret-42");
    try database.expectSessionDigest(digest);
    var identity = try service.handleAlloc(std.testing.allocator, .{
        .method = "POST",
        .path = "/v1/estate/identity:verify",
        .authorization = "Bearer session-secret-42",
        .body = "{}",
        .now_millis = 1_000,
    });
    defer identity.deinit();
    try std.testing.expectEqual(@as(u16, 200), identity.status);

    var entitlement = try service.handleAlloc(std.testing.allocator, .{
        .method = "POST",
        .path = "/v1/estate/entitlements:lookup",
        .authorization = "Bearer session-secret-42",
        .body = "{\"subject\":\"google-subject-42\"}",
        .now_millis = 1_000,
    });
    defer entitlement.deinit();
    try std.testing.expectEqual(@as(u16, 200), entitlement.status);

    var connection = try service.handleAlloc(std.testing.allocator, .{
        .method = "POST",
        .path = "/v1/estate/connections:resolve",
        .authorization = "Bearer session-secret-42",
        .body = "{\"subject\":\"google-subject-42\",\"connection_id\":\"gcp-connection-17\"}",
        .now_millis = 1_000,
    });
    defer connection.deinit();
    try std.testing.expectEqual(@as(u16, 200), connection.status);
    try std.testing.expect(std.mem.indexOf(u8, connection.body, "acme-prod") != null);

    try std.testing.expectEqual(@as(usize, 5), database.query_cursor);
    try std.testing.expect(database.executed.items.len >= 3);
    for (database.queries.items) |query| {
        try std.testing.expect(std.mem.indexOf(u8, query, "session-secret-42") == null);
        try std.testing.expect(query.len < 4096);
    }

    const challenge = repository.challengeVerifier();
    try challenge.create_fn(challenge.ptr, "state-73", "nonce-73", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "http://127.0.0.1:48321/oauth/callback", 999);
    try challenge.consume_fn(challenge.ptr, "state-73", "nonce-73", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "http://127.0.0.1:48321/oauth/callback", 1_000);
    const ciphertext_store = repository.ciphertextStore();
    try ciphertext_store.persist_fn(
        ciphertext_store.ptr,
        "google-subject-42",
        "ZW5jcnlwdGVkLWJ5dGVz",
        "projects/ziac-control/locations/global/keyRings/estate/cryptoKeys/oauth/cryptoKeyVersions/7",
        [_]u8{0x42} ** 32,
    );
    const create_challenge_sql = database.executed.items[database.executed.items.len - 3];
    const challenge_sql = database.executed.items[database.executed.items.len - 2];
    const credential_sql = database.executed.items[database.executed.items.len - 1];
    try std.testing.expect(std.mem.indexOf(u8, create_challenge_sql, "ziac_oauth_challenges") != null);
    try std.testing.expect(std.mem.indexOf(u8, challenge_sql, "consumed_at IS NULL") != null);
    try std.testing.expect(std.mem.indexOf(u8, credential_sql, "ziac_google_credentials") != null);
    try std.testing.expect(std.mem.indexOf(u8, credential_sql, "refresh-secret") == null);
}

const ScriptedDatabase = struct {
    allocator: std.mem.Allocator,
    responses: []const []const u8,
    query_cursor: usize = 0,
    queries: std.ArrayList([]u8) = .empty,
    executed: std.ArrayList([]u8) = .empty,
    expected_digest: ?[32]u8 = null,

    fn init(allocator: std.mem.Allocator, responses: []const []const u8) ScriptedDatabase {
        return .{ .allocator = allocator, .responses = responses };
    }
    fn deinit(self: *ScriptedDatabase) void {
        for (self.queries.items) |item| self.allocator.free(item);
        for (self.executed.items) |item| self.allocator.free(item);
        self.queries.deinit(self.allocator);
        self.executed.deinit(self.allocator);
    }
    fn database(self: *ScriptedDatabase) ziac.estate_cockroach.Database {
        return .{ .ptr = self, .query_json_fn = query, .execute_fn = execute };
    }
    fn expectSessionDigest(self: *ScriptedDatabase, digest: [32]u8) !void {
        self.expected_digest = digest;
    }
    fn query(raw: *anyopaque, allocator: std.mem.Allocator, statement: []const u8) !?[]u8 {
        const self: *ScriptedDatabase = @ptrCast(@alignCast(raw));
        try self.queries.append(self.allocator, try self.allocator.dupe(u8, statement));
        if (self.query_cursor >= self.responses.len) return null;
        const response = self.responses[self.query_cursor];
        self.query_cursor += 1;
        const owned: []u8 = try allocator.dupe(u8, response);
        return owned;
    }
    fn execute(raw: *anyopaque, statement: []const u8) !u64 {
        const self: *ScriptedDatabase = @ptrCast(@alignCast(raw));
        try self.executed.append(self.allocator, try self.allocator.dupe(u8, statement));
        return 1;
    }
};
