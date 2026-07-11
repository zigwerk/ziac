const std = @import("std");
const ziac = @import("ziac");

test "estate access resolves identity entitlement and project authorization independently" {
    var resolver = ScriptedResolver{
        .identity = .{ .provider = .google, .verified = true, .subject = "google-subject-42" },
        .entitlement = .{ .tier = .pro, .active = true, .expires_at_millis = 1_800_000_000_000 },
        .connection = .{ .status = .connected, .project_id = "acme-prod" },
    };
    const access = try ziac.estate_access.resolve(resolver.resolver(), .{
        .session_assertion = "opaque-session-assertion",
        .connection_id = "gcp-connection-17",
        .now_millis = 1_783_764_000_000,
    });

    try std.testing.expectEqual(ziac.estate_access.Status.ready, access.status);
    try std.testing.expectEqual(ziac.estate.Entitlement.pro, access.scan_input.entitlement);
    try std.testing.expectEqualStrings("acme-prod", access.scan_input.connection.project_id);
    try std.testing.expectEqual(@as(usize, 1), resolver.identity_calls);
    try std.testing.expectEqual(@as(usize, 1), resolver.entitlement_calls);
    try std.testing.expectEqual(@as(usize, 1), resolver.connection_calls);

    const projection = try access.sessionJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(projection);
    try std.testing.expect(std.mem.indexOf(u8, projection, "\"ready\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, projection, "acme-prod") != null);
    try std.testing.expect(std.mem.indexOf(u8, projection, "google-subject-42") == null);
    try std.testing.expect(std.mem.indexOf(u8, projection, "opaque-session-assertion") == null);
    try std.testing.expect(std.mem.indexOf(u8, projection, "gcp-connection-17") == null);
}

test "estate access fails closed before resolving a connection when Pro is expired" {
    var resolver = ScriptedResolver{
        .identity = .{ .provider = .google, .verified = true, .subject = "google-subject-42" },
        .entitlement = .{ .tier = .pro, .active = true, .expires_at_millis = 50 },
        .connection = .{ .status = .connected, .project_id = "acme-prod" },
    };
    try std.testing.expectError(error.ProEntitlementRequired, ziac.estate_access.resolve(resolver.resolver(), .{
        .session_assertion = "opaque-session-assertion",
        .connection_id = "gcp-connection-17",
        .now_millis = 100,
    }));
    try std.testing.expectEqual(@as(usize, 0), resolver.connection_calls);
}

test "Google installed-app authorization uses S256 PKCE and callback state" {
    const verifier = try ziac.estate_access.pkceVerifierAlloc(std.testing.allocator, &[_]u8{0x4a} ** 32);
    defer std.testing.allocator.free(verifier);
    const request = try ziac.estate_access.authorizationUrlAlloc(std.testing.allocator, .{
        .client_id = "client.apps.googleusercontent.com",
        .redirect_uri = "http://127.0.0.1:48321/oauth/callback",
        .state = "state-73",
        .nonce = "nonce-73",
        .code_verifier = verifier,
    });
    defer std.testing.allocator.free(request);

    try std.testing.expect(std.mem.indexOf(u8, request, "code_challenge_method=S256") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "scope=openid%20email%20https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcloud-platform") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "access_type=offline") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, verifier) == null);

    try std.testing.expectEqualStrings("authorization-code", try ziac.estate_access.validateCallback(.{
        .expected_state = "state-73",
        .state = "state-73",
        .code = "authorization-code",
    }));
    try std.testing.expectError(error.OAuthStateMismatch, ziac.estate_access.validateCallback(.{
        .expected_state = "state-73",
        .state = "state-other",
        .code = "authorization-code",
    }));
}

const ScriptedResolver = struct {
    identity: ziac.estate.Identity,
    entitlement: ziac.estate_access.EntitlementRecord,
    connection: ziac.estate.Connection,
    identity_calls: usize = 0,
    entitlement_calls: usize = 0,
    connection_calls: usize = 0,

    fn resolver(self: *ScriptedResolver) ziac.estate_access.Resolver {
        return .{
            .ptr = self,
            .verify_identity = verifyIdentity,
            .lookup_entitlement = lookupEntitlement,
            .resolve_connection = resolveConnection,
        };
    }

    fn verifyIdentity(raw: *anyopaque, _: []const u8, _: u64) anyerror!ziac.estate.Identity {
        const self: *ScriptedResolver = @ptrCast(@alignCast(raw));
        self.identity_calls += 1;
        return self.identity;
    }

    fn lookupEntitlement(raw: *anyopaque, _: []const u8, _: u64) anyerror!ziac.estate_access.EntitlementRecord {
        const self: *ScriptedResolver = @ptrCast(@alignCast(raw));
        self.entitlement_calls += 1;
        return self.entitlement;
    }

    fn resolveConnection(raw: *anyopaque, _: []const u8, _: []const u8, _: u64) anyerror!ziac.estate.Connection {
        const self: *ScriptedResolver = @ptrCast(@alignCast(raw));
        self.connection_calls += 1;
        return self.connection;
    }
};
