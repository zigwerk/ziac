const std = @import("std");
const ziac = @import("ziac");

test "Estate control plane exposes bounded health probes without a session" {
    var store = ziac.estate_service.MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    var service = ziac.estate_service.Service.init(store.repository());

    inline for (.{ "/health/startup", "/health/live" }) |path| {
        var response = try service.handleAlloc(std.testing.allocator, .{
            .method = "GET",
            .path = path,
            .body = "",
            .now_millis = 1,
        });
        defer response.deinit();
        try std.testing.expectEqual(@as(u16, 200), response.status);
        try std.testing.expect(std.mem.indexOf(u8, response.body, "ready") != null);
    }
}

test "Estate Pro service authenticates ownership, resolves access, audits, and revokes" {
    var store = ziac.estate_service.MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    try store.putSession(.{
        .assertion_digest = ziac.estate_service.sessionDigest("session-secret-42"),
        .subject = "google-subject-42",
        .expires_at_millis = 2_000,
    });
    try store.putEntitlement(.{
        .subject = "google-subject-42",
        .tier = .pro,
        .active = true,
        .expires_at_millis = 2_000,
    });
    try store.putConnection(.{
        .id = "gcp-connection-17",
        .subject = "google-subject-42",
        .project_id = "acme-prod",
        .status = .connected,
        .credential_key_id = "kms-key-version-7",
    });
    var service = ziac.estate_service.Service.init(store.repository());

    var identity = try service.handleAlloc(std.testing.allocator, .{
        .method = "POST",
        .path = "/v1/estate/identity:verify",
        .authorization = "Bearer session-secret-42",
        .body = "{}",
        .now_millis = 1_000,
    });
    defer identity.deinit();
    try std.testing.expectEqual(@as(u16, 200), identity.status);
    try std.testing.expect(std.mem.indexOf(u8, identity.body, "google-subject-42") != null);
    try std.testing.expect(std.mem.indexOf(u8, identity.body, "session-secret-42") == null);

    var entitlement = try service.handleAlloc(std.testing.allocator, .{
        .method = "POST",
        .path = "/v1/estate/entitlements:lookup",
        .authorization = "Bearer session-secret-42",
        .body = "{\"subject\":\"google-subject-42\"}",
        .now_millis = 1_000,
    });
    defer entitlement.deinit();
    try std.testing.expectEqual(@as(u16, 200), entitlement.status);
    try std.testing.expect(std.mem.indexOf(u8, entitlement.body, "\"tier\":\"pro\"") != null);

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
    try std.testing.expect(std.mem.indexOf(u8, connection.body, "kms-key-version-7") == null);

    var forbidden = try service.handleAlloc(std.testing.allocator, .{
        .method = "POST",
        .path = "/v1/estate/connections:resolve",
        .authorization = "Bearer session-secret-42",
        .body = "{\"subject\":\"other-subject\",\"connection_id\":\"gcp-connection-17\"}",
        .now_millis = 1_000,
    });
    defer forbidden.deinit();
    try std.testing.expectEqual(@as(u16, 403), forbidden.status);

    var revoked = try service.handleAlloc(std.testing.allocator, .{
        .method = "POST",
        .path = "/v1/estate/connections:revoke",
        .authorization = "Bearer session-secret-42",
        .body = "{\"connection_id\":\"gcp-connection-17\"}",
        .now_millis = 1_001,
    });
    defer revoked.deinit();
    try std.testing.expectEqual(@as(u16, 200), revoked.status);

    var after_revoke = try service.handleAlloc(std.testing.allocator, .{
        .method = "POST",
        .path = "/v1/estate/connections:resolve",
        .authorization = "Bearer session-secret-42",
        .body = "{\"subject\":\"google-subject-42\",\"connection_id\":\"gcp-connection-17\"}",
        .now_millis = 1_002,
    });
    defer after_revoke.deinit();
    try std.testing.expectEqual(@as(u16, 403), after_revoke.status);
    try std.testing.expect(store.audit.items.len >= 6);
    for (store.audit.items) |event| {
        try std.testing.expect(std.mem.indexOf(u8, event.action, "session-secret-42") == null);
        try std.testing.expect(std.mem.indexOf(u8, event.resource_id, "kms-key-version-7") == null);
    }
}

test "Estate Pro service fails closed for expired sessions and inactive subscriptions" {
    var store = ziac.estate_service.MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    try store.putSession(.{
        .assertion_digest = ziac.estate_service.sessionDigest("expired-session"),
        .subject = "google-subject-42",
        .expires_at_millis = 50,
    });
    try store.putEntitlement(.{
        .subject = "google-subject-42",
        .tier = .pro,
        .active = false,
        .expires_at_millis = 2_000,
    });
    var service = ziac.estate_service.Service.init(store.repository());

    var expired = try service.handleAlloc(std.testing.allocator, .{
        .method = "POST",
        .path = "/v1/estate/identity:verify",
        .authorization = "Bearer expired-session",
        .body = "{}",
        .now_millis = 100,
    });
    defer expired.deinit();
    try std.testing.expectEqual(@as(u16, 401), expired.status);
}

test "Estate Pro Google callback consumes PKCE, vaults refresh credentials, and returns one session" {
    var store = ziac.estate_service.MemoryStore.init(std.testing.allocator);
    defer store.deinit();
    var exchange = ScriptedExchange{};
    var challenge = ScriptedChallenge{};
    var issuer = FixedIssuer{};
    var vault = RecordingVault{};
    var service = ziac.estate_service.Service.initWithGoogle(store.repository(), .{
        .oauth = exchange.exchanger(),
        .challenges = challenge.verifier(),
        .assertions = issuer.issuer(),
        .vault = vault.vault(),
        .session_ttl_millis = 60_000,
    });

    var created = try service.handleAlloc(std.testing.allocator, .{
        .method = "POST",
        .path = "/v1/oauth/google/challenges",
        .body = "{\"state\":\"state-73\",\"nonce\":\"nonce-73\",\"code_verifier\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"redirect_uri\":\"http://127.0.0.1:48321/oauth/callback\"}",
        .now_millis = 999,
    });
    defer created.deinit();
    try std.testing.expectEqual(@as(u16, 201), created.status);

    var callback = try service.handleAlloc(std.testing.allocator, .{
        .method = "POST",
        .path = "/v1/oauth/google/callback",
        .body = "{\"state\":\"state-73\",\"nonce\":\"nonce-73\",\"code\":\"authorization-code\",\"code_verifier\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"redirect_uri\":\"http://127.0.0.1:48321/oauth/callback\"}",
        .now_millis = 1_000,
    });
    defer callback.deinit();

    try std.testing.expectEqual(@as(u16, 200), callback.status);
    try std.testing.expect(std.mem.indexOf(u8, callback.body, FixedIssuer.assertion) != null);
    try std.testing.expect(std.mem.indexOf(u8, callback.body, "refresh-secret") == null);
    try std.testing.expectEqual(@as(usize, 1), challenge.create_calls);
    try std.testing.expectEqual(@as(usize, 1), challenge.consume_calls);
    try std.testing.expectEqual(@as(usize, 1), exchange.calls);
    try std.testing.expectEqual(@as(usize, 1), vault.calls);
    try std.testing.expectEqual(@as(usize, 1), store.sessions.items.len);

    var identity = try service.handleAlloc(std.testing.allocator, .{
        .method = "POST",
        .path = "/v1/estate/identity:verify",
        .authorization = "Bearer " ++ FixedIssuer.assertion,
        .body = "{}",
        .now_millis = 1_001,
    });
    defer identity.deinit();
    try std.testing.expectEqual(@as(u16, 200), identity.status);
}

const ScriptedExchange = struct {
    calls: usize = 0,

    fn exchanger(self: *ScriptedExchange) ziac.gcp.oauth.Exchange {
        return .{ .ptr = self, .exchange_fn = exchange };
    }

    fn exchange(raw: *anyopaque, allocator: std.mem.Allocator, _: ziac.gcp.oauth.ExchangeRequest) !ziac.gcp.oauth.Grant {
        const self: *ScriptedExchange = @ptrCast(@alignCast(raw));
        self.calls += 1;
        return .{
            .allocator = allocator,
            .subject = try allocator.dupe(u8, "google-subject-42"),
            .email = try allocator.dupe(u8, "owner@example.com"),
            .access_token = try allocator.dupe(u8, "access-secret"),
            .refresh_token = try allocator.dupe(u8, "refresh-secret"),
            .expires_at_seconds = 4_600,
        };
    }
};

const ScriptedChallenge = struct {
    create_calls: usize = 0,
    consume_calls: usize = 0,

    fn verifier(self: *ScriptedChallenge) ziac.estate_service.ChallengeVerifier {
        return .{ .ptr = self, .create_fn = create, .consume_fn = consume };
    }

    fn create(raw: *anyopaque, _: []const u8, _: []const u8, _: []const u8, _: []const u8, _: u64) !void {
        const self: *ScriptedChallenge = @ptrCast(@alignCast(raw));
        self.create_calls += 1;
    }

    fn consume(raw: *anyopaque, state: []const u8, nonce: []const u8, verifier_text: []const u8, redirect: []const u8, _: u64) !void {
        const self: *ScriptedChallenge = @ptrCast(@alignCast(raw));
        self.consume_calls += 1;
        if (!std.mem.eql(u8, state, "state-73") or !std.mem.eql(u8, nonce, "nonce-73") or verifier_text.len < 43 or
            !std.mem.endsWith(u8, redirect, "/oauth/callback")) return error.ChallengeMismatch;
    }
};

const FixedIssuer = struct {
    const assertion = "issued-session-assertion-00000000000000000001";

    fn issuer(self: *FixedIssuer) ziac.estate_service.AssertionIssuer {
        return .{ .ptr = self, .issue_fn = issue };
    }

    fn issue(_: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
        return allocator.dupe(u8, assertion);
    }
};

const RecordingVault = struct {
    calls: usize = 0,

    fn vault(self: *RecordingVault) ziac.estate_service.CredentialVault {
        return .{ .ptr = self, .seal_fn = seal };
    }

    fn seal(raw: *anyopaque, subject: []const u8, refresh: []const u8) !void {
        const self: *RecordingVault = @ptrCast(@alignCast(raw));
        self.calls += 1;
        if (!std.mem.eql(u8, subject, "google-subject-42") or !std.mem.eql(u8, refresh, "refresh-secret")) return error.InvalidCredential;
    }
};
