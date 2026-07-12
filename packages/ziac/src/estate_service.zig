const std = @import("std");
const estate = @import("estate.zig");
const google_oauth = @import("gcp/oauth.zig");

pub const SessionRecord = struct {
    assertion_digest: [32]u8,
    subject: []const u8,
    expires_at_millis: u64,
    revoked: bool = false,
};

pub const EntitlementRecord = struct {
    subject: []const u8,
    tier: estate.Entitlement,
    active: bool,
    expires_at_millis: u64,
};

pub const ConnectionRecord = struct {
    id: []const u8,
    subject: []const u8,
    project_id: []const u8,
    status: estate.ConnectionStatus,
    credential_key_id: []const u8,
};

pub const AuditEvent = struct {
    timestamp_millis: u64,
    subject: []const u8,
    action: []const u8,
    resource_id: []const u8,
    outcome: []const u8,
};

pub const Repository = struct {
    ptr: *anyopaque,
    find_session: *const fn (*anyopaque, [32]u8) anyerror!?SessionRecord,
    find_entitlement: *const fn (*anyopaque, []const u8) anyerror!?EntitlementRecord,
    find_connection: *const fn (*anyopaque, []const u8) anyerror!?ConnectionRecord,
    revoke_connection: *const fn (*anyopaque, []const u8, []const u8) anyerror!bool,
    append_audit: *const fn (*anyopaque, AuditEvent) anyerror!void,
    put_session: *const fn (*anyopaque, SessionRecord) anyerror!void,
};

pub const ChallengeVerifier = struct {
    ptr: *anyopaque,
    create_fn: *const fn (*anyopaque, []const u8, []const u8, []const u8, []const u8, u64) anyerror!void,
    consume_fn: *const fn (*anyopaque, []const u8, []const u8, []const u8, []const u8, u64) anyerror!void,
};

pub const AssertionIssuer = struct {
    ptr: *anyopaque,
    issue_fn: *const fn (*anyopaque, std.mem.Allocator) anyerror![]u8,
};

pub const CredentialVault = struct {
    ptr: *anyopaque,
    seal_fn: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,
};

pub const GoogleCallback = struct {
    oauth: google_oauth.Exchange,
    challenges: ChallengeVerifier,
    assertions: AssertionIssuer,
    vault: CredentialVault,
    session_ttl_millis: u64 = 8 * std.time.ms_per_hour,
};

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    authorization: ?[]const u8 = null,
    body: []const u8,
    now_millis: u64,
};

pub const Response = struct {
    allocator: std.mem.Allocator,
    status: u16,
    body: []u8,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
        self.* = undefined;
    }
};

pub const Service = struct {
    repository: Repository,
    google_callback: ?GoogleCallback = null,

    pub fn init(repository: Repository) Service {
        return .{ .repository = repository };
    }

    pub fn initWithGoogle(repository: Repository, callback: GoogleCallback) Service {
        return .{ .repository = repository, .google_callback = callback };
    }

    pub fn handleAlloc(self: *Service, allocator: std.mem.Allocator, request: Request) !Response {
        if (request.body.len > 64 * 1024 or request.now_millis == 0) return responseAlloc(allocator, 400, .{ .error_code = "invalid_request" });
        if (!std.mem.eql(u8, request.method, "POST")) return responseAlloc(allocator, 405, .{ .error_code = "method_not_allowed" });
        if (std.mem.eql(u8, request.path, "/v1/oauth/google/challenges")) return self.createGoogleChallengeAlloc(allocator, request);
        if (std.mem.eql(u8, request.path, "/v1/oauth/google/callback")) return self.completeGoogleCallbackAlloc(allocator, request);

        var session = self.authenticate(request.authorization, request.now_millis) catch {
            return responseAlloc(allocator, 401, .{ .error_code = "google_identity_required" });
        };
        const owned_subject = try allocator.dupe(u8, session.subject);
        defer allocator.free(owned_subject);
        session.subject = owned_subject;
        if (std.mem.eql(u8, request.path, "/v1/estate/identity:verify")) {
            try self.audit(request.now_millis, session.subject, "identity.verify", "identity", "allowed");
            return responseAlloc(allocator, 200, .{
                .identity_provider = "google",
                .verified = true,
                .subject = session.subject,
            });
        }
        if (std.mem.eql(u8, request.path, "/v1/estate/entitlements:lookup")) {
            const subject = parseStringField(allocator, request.body, "subject") catch {
                try self.audit(request.now_millis, session.subject, "entitlement.lookup", "subscription", "denied");
                return responseAlloc(allocator, 400, .{ .error_code = "invalid_request" });
            };
            defer allocator.free(subject);
            if (!std.mem.eql(u8, subject, session.subject)) {
                try self.audit(request.now_millis, session.subject, "entitlement.lookup", "subscription", "denied");
                return responseAlloc(allocator, 403, .{ .error_code = "subject_mismatch" });
            }
            const entitlement = (try self.repository.find_entitlement(self.repository.ptr, session.subject)) orelse {
                try self.audit(request.now_millis, session.subject, "entitlement.lookup", "subscription", "denied");
                return responseAlloc(allocator, 403, .{ .error_code = "pro_entitlement_required" });
            };
            const active = entitlement.active and entitlement.tier == .pro and entitlement.expires_at_millis > request.now_millis;
            try self.audit(request.now_millis, session.subject, "entitlement.lookup", "subscription", if (active) "allowed" else "denied");
            return responseAlloc(allocator, if (active) 200 else 403, .{
                .tier = @tagName(entitlement.tier),
                .active = active,
                .expires_at_millis = entitlement.expires_at_millis,
            });
        }
        if (std.mem.eql(u8, request.path, "/v1/estate/connections:resolve")) {
            return self.resolveConnectionAlloc(allocator, request, session);
        }
        if (std.mem.eql(u8, request.path, "/v1/estate/connections:revoke")) {
            return self.revokeConnectionAlloc(allocator, request, session);
        }
        try self.audit(request.now_millis, session.subject, "route.unknown", "unknown", "denied");
        return responseAlloc(allocator, 404, .{ .error_code = "not_found" });
    }

    fn createGoogleChallengeAlloc(self: *Service, allocator: std.mem.Allocator, request: Request) !Response {
        const callback = self.google_callback orelse return responseAlloc(allocator, 503, .{ .error_code = "google_oauth_unavailable" });
        const state = parseStringField(allocator, request.body, "state") catch return responseAlloc(allocator, 400, .{ .error_code = "invalid_oauth_challenge" });
        defer allocator.free(state);
        const nonce = parseStringField(allocator, request.body, "nonce") catch return responseAlloc(allocator, 400, .{ .error_code = "invalid_oauth_challenge" });
        defer allocator.free(nonce);
        const verifier = parseStringField(allocator, request.body, "code_verifier") catch return responseAlloc(allocator, 400, .{ .error_code = "invalid_oauth_challenge" });
        defer allocator.free(verifier);
        const redirect = parseStringField(allocator, request.body, "redirect_uri") catch return responseAlloc(allocator, 400, .{ .error_code = "invalid_oauth_challenge" });
        defer allocator.free(redirect);
        callback.challenges.create_fn(callback.challenges.ptr, state, nonce, verifier, redirect, request.now_millis) catch {
            return responseAlloc(allocator, 400, .{ .error_code = "oauth_challenge_rejected" });
        };
        return responseAlloc(allocator, 201, .{ .status = "ready", .expires_at_millis = request.now_millis + 10 * std.time.ms_per_min });
    }

    fn completeGoogleCallbackAlloc(self: *Service, allocator: std.mem.Allocator, request: Request) !Response {
        const callback = self.google_callback orelse return responseAlloc(allocator, 503, .{ .error_code = "google_oauth_unavailable" });
        var fields = parseCallbackRequest(allocator, request.body) catch {
            return responseAlloc(allocator, 400, .{ .error_code = "invalid_oauth_callback" });
        };
        defer fields.deinit(allocator);
        callback.challenges.consume_fn(
            callback.challenges.ptr,
            fields.state,
            fields.nonce,
            fields.code_verifier,
            fields.redirect_uri,
            request.now_millis,
        ) catch return responseAlloc(allocator, 400, .{ .error_code = "oauth_challenge_rejected" });
        var grant = callback.oauth.exchangeAlloc(allocator, .{
            .code = fields.code,
            .code_verifier = fields.code_verifier,
            .redirect_uri = fields.redirect_uri,
            .expected_nonce = fields.nonce,
            .now_seconds = request.now_millis / std.time.ms_per_s,
        }) catch return responseAlloc(allocator, 401, .{ .error_code = "google_identity_required" });
        defer grant.deinit();
        callback.vault.seal_fn(callback.vault.ptr, grant.subject, grant.refresh_token) catch {
            return responseAlloc(allocator, 503, .{ .error_code = "credential_vault_unavailable" });
        };
        const assertion = callback.assertions.issue_fn(callback.assertions.ptr, allocator) catch {
            return responseAlloc(allocator, 503, .{ .error_code = "session_issuer_unavailable" });
        };
        defer {
            std.crypto.secureZero(u8, assertion);
            allocator.free(assertion);
        }
        if (assertion.len < 32 or assertion.len > 512 or std.mem.indexOfAny(u8, assertion, "\x00\r\n") != null) {
            return responseAlloc(allocator, 503, .{ .error_code = "session_issuer_unavailable" });
        }
        const expires_at_millis = request.now_millis +| callback.session_ttl_millis;
        self.repository.put_session(self.repository.ptr, .{
            .assertion_digest = sessionDigest(assertion),
            .subject = grant.subject,
            .expires_at_millis = expires_at_millis,
        }) catch return responseAlloc(allocator, 503, .{ .error_code = "session_store_unavailable" });
        try self.audit(request.now_millis, grant.subject, "oauth.google.callback", "identity", "allowed");
        return responseAlloc(allocator, 200, .{
            .session_assertion = assertion,
            .expires_at_millis = expires_at_millis,
            .identity_provider = "google",
        });
    }

    fn authenticate(self: *Service, authorization: ?[]const u8, now_millis: u64) !SessionRecord {
        const header = authorization orelse return error.MissingSession;
        const prefix = "Bearer ";
        if (!std.mem.startsWith(u8, header, prefix)) return error.MissingSession;
        const assertion = header[prefix.len..];
        if (assertion.len < 8 or assertion.len > 16 * 1024 or std.mem.indexOfAny(u8, assertion, "\x00\r\n") != null) return error.InvalidSession;
        const session = (try self.repository.find_session(self.repository.ptr, sessionDigest(assertion))) orelse return error.InvalidSession;
        if (session.revoked or session.expires_at_millis <= now_millis) return error.ExpiredSession;
        return session;
    }

    fn resolveConnectionAlloc(self: *Service, allocator: std.mem.Allocator, request: Request, session: SessionRecord) !Response {
        const parsed = parseConnectionRequest(allocator, request.body, true) catch {
            try self.audit(request.now_millis, session.subject, "connection.resolve", "invalid", "denied");
            return responseAlloc(allocator, 400, .{ .error_code = "invalid_request" });
        };
        defer parsed.deinit(allocator);
        if (!std.mem.eql(u8, parsed.subject.?, session.subject)) {
            try self.audit(request.now_millis, session.subject, "connection.resolve", parsed.connection_id, "denied");
            return responseAlloc(allocator, 403, .{ .error_code = "subject_mismatch" });
        }
        const connection = (try self.repository.find_connection(self.repository.ptr, parsed.connection_id)) orelse {
            try self.audit(request.now_millis, session.subject, "connection.resolve", parsed.connection_id, "denied");
            return responseAlloc(allocator, 404, .{ .error_code = "connection_not_found" });
        };
        if (!std.mem.eql(u8, connection.subject, session.subject) or connection.status != .connected) {
            try self.audit(request.now_millis, session.subject, "connection.resolve", parsed.connection_id, "denied");
            return responseAlloc(allocator, 403, .{ .error_code = "gcp_connection_required" });
        }
        try self.audit(request.now_millis, session.subject, "connection.resolve", parsed.connection_id, "allowed");
        return responseAlloc(allocator, 200, .{
            .status = @tagName(connection.status),
            .project_id = connection.project_id,
        });
    }

    fn revokeConnectionAlloc(self: *Service, allocator: std.mem.Allocator, request: Request, session: SessionRecord) !Response {
        const parsed = parseConnectionRequest(allocator, request.body, false) catch {
            try self.audit(request.now_millis, session.subject, "connection.revoke", "invalid", "denied");
            return responseAlloc(allocator, 400, .{ .error_code = "invalid_request" });
        };
        defer parsed.deinit(allocator);
        const revoked = try self.repository.revoke_connection(self.repository.ptr, session.subject, parsed.connection_id);
        try self.audit(request.now_millis, session.subject, "connection.revoke", parsed.connection_id, if (revoked) "allowed" else "denied");
        return responseAlloc(allocator, if (revoked) 200 else 404, .{
            .status = if (revoked) "revoked" else "not_found",
        });
    }

    fn audit(self: *Service, now_millis: u64, subject: []const u8, action: []const u8, resource_id: []const u8, outcome: []const u8) !void {
        try self.repository.append_audit(self.repository.ptr, .{
            .timestamp_millis = now_millis,
            .subject = subject,
            .action = action,
            .resource_id = resource_id,
            .outcome = outcome,
        });
    }
};

pub const MemoryStore = struct {
    allocator: std.mem.Allocator,
    sessions: std.ArrayList(SessionRecord) = .empty,
    entitlements: std.ArrayList(EntitlementRecord) = .empty,
    connections: std.ArrayList(ConnectionRecord) = .empty,
    audit: std.ArrayList(AuditEvent) = .empty,

    pub fn init(allocator: std.mem.Allocator) MemoryStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MemoryStore) void {
        for (self.sessions.items) |record| self.allocator.free(record.subject);
        for (self.entitlements.items) |record| self.allocator.free(record.subject);
        for (self.connections.items) |record| {
            self.allocator.free(record.id);
            self.allocator.free(record.subject);
            self.allocator.free(record.project_id);
            self.allocator.free(record.credential_key_id);
        }
        for (self.audit.items) |record| {
            self.allocator.free(record.subject);
            self.allocator.free(record.action);
            self.allocator.free(record.resource_id);
            self.allocator.free(record.outcome);
        }
        self.sessions.deinit(self.allocator);
        self.entitlements.deinit(self.allocator);
        self.connections.deinit(self.allocator);
        self.audit.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn putSession(self: *MemoryStore, record: SessionRecord) !void {
        try self.sessions.append(self.allocator, .{
            .assertion_digest = record.assertion_digest,
            .subject = try self.allocator.dupe(u8, record.subject),
            .expires_at_millis = record.expires_at_millis,
            .revoked = record.revoked,
        });
    }

    pub fn putEntitlement(self: *MemoryStore, record: EntitlementRecord) !void {
        try self.entitlements.append(self.allocator, .{
            .subject = try self.allocator.dupe(u8, record.subject),
            .tier = record.tier,
            .active = record.active,
            .expires_at_millis = record.expires_at_millis,
        });
    }

    pub fn putConnection(self: *MemoryStore, record: ConnectionRecord) !void {
        const id = try self.allocator.dupe(u8, record.id);
        errdefer self.allocator.free(id);
        const subject = try self.allocator.dupe(u8, record.subject);
        errdefer self.allocator.free(subject);
        const project_id = try self.allocator.dupe(u8, record.project_id);
        errdefer self.allocator.free(project_id);
        const key = try self.allocator.dupe(u8, record.credential_key_id);
        errdefer self.allocator.free(key);
        try self.connections.append(self.allocator, .{
            .id = id,
            .subject = subject,
            .project_id = project_id,
            .status = record.status,
            .credential_key_id = key,
        });
    }

    pub fn repository(self: *MemoryStore) Repository {
        return .{
            .ptr = self,
            .find_session = findSession,
            .find_entitlement = findEntitlement,
            .find_connection = findConnection,
            .revoke_connection = revokeConnection,
            .append_audit = appendAudit,
            .put_session = putSessionErased,
        };
    }

    fn putSessionErased(raw: *anyopaque, record: SessionRecord) !void {
        const self: *MemoryStore = @ptrCast(@alignCast(raw));
        return self.putSession(record);
    }

    fn findSession(raw: *anyopaque, digest: [32]u8) !?SessionRecord {
        const self: *MemoryStore = @ptrCast(@alignCast(raw));
        for (self.sessions.items) |record| if (std.crypto.timing_safe.eql([32]u8, record.assertion_digest, digest)) return record;
        return null;
    }

    fn findEntitlement(raw: *anyopaque, subject: []const u8) !?EntitlementRecord {
        const self: *MemoryStore = @ptrCast(@alignCast(raw));
        for (self.entitlements.items) |record| if (std.mem.eql(u8, record.subject, subject)) return record;
        return null;
    }

    fn findConnection(raw: *anyopaque, id: []const u8) !?ConnectionRecord {
        const self: *MemoryStore = @ptrCast(@alignCast(raw));
        for (self.connections.items) |record| if (std.mem.eql(u8, record.id, id)) return record;
        return null;
    }

    fn revokeConnection(raw: *anyopaque, subject: []const u8, id: []const u8) !bool {
        const self: *MemoryStore = @ptrCast(@alignCast(raw));
        for (self.connections.items) |*record| {
            if (!std.mem.eql(u8, record.id, id) or !std.mem.eql(u8, record.subject, subject)) continue;
            record.status = .disconnected;
            return true;
        }
        return false;
    }

    fn appendAudit(raw: *anyopaque, event: AuditEvent) !void {
        const self: *MemoryStore = @ptrCast(@alignCast(raw));
        const subject = try self.allocator.dupe(u8, event.subject);
        errdefer self.allocator.free(subject);
        const action = try self.allocator.dupe(u8, event.action);
        errdefer self.allocator.free(action);
        const resource_id = try self.allocator.dupe(u8, event.resource_id);
        errdefer self.allocator.free(resource_id);
        const outcome = try self.allocator.dupe(u8, event.outcome);
        errdefer self.allocator.free(outcome);
        try self.audit.append(self.allocator, .{
            .timestamp_millis = event.timestamp_millis,
            .subject = subject,
            .action = action,
            .resource_id = resource_id,
            .outcome = outcome,
        });
    }
};

pub fn sessionDigest(assertion: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(assertion, &digest, .{});
    return digest;
}

const ConnectionRequest = struct {
    subject: ?[]u8,
    connection_id: []u8,

    fn deinit(self: ConnectionRequest, allocator: std.mem.Allocator) void {
        if (self.subject) |subject| allocator.free(subject);
        allocator.free(self.connection_id);
    }
};

fn parseConnectionRequest(allocator: std.mem.Allocator, body: []const u8, require_subject: bool) !ConnectionRequest {
    const subject = parseStringField(allocator, body, "subject") catch |err| if (require_subject) return err else null;
    errdefer if (subject) |value| allocator.free(value);
    return .{
        .subject = subject,
        .connection_id = try parseStringField(allocator, body, "connection_id"),
    };
}

fn parseStringField(allocator: std.mem.Allocator, body: []const u8, name: []const u8) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidJson,
    };
    const text = switch (object.get(name) orelse return error.InvalidJson) {
        .string => |value| value,
        else => return error.InvalidJson,
    };
    if (text.len < 3 or text.len > 512 or std.mem.indexOfAny(u8, text, "\x00\r\n") != null) return error.InvalidJson;
    return allocator.dupe(u8, text);
}

const CallbackRequest = struct {
    state: []u8,
    nonce: []u8,
    code: []u8,
    code_verifier: []u8,
    redirect_uri: []u8,

    fn deinit(self: *CallbackRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.state);
        allocator.free(self.nonce);
        std.crypto.secureZero(u8, self.code);
        allocator.free(self.code);
        std.crypto.secureZero(u8, self.code_verifier);
        allocator.free(self.code_verifier);
        allocator.free(self.redirect_uri);
    }
};

fn parseCallbackRequest(allocator: std.mem.Allocator, body: []const u8) !CallbackRequest {
    const state = try parseStringField(allocator, body, "state");
    errdefer allocator.free(state);
    const nonce = try parseStringField(allocator, body, "nonce");
    errdefer allocator.free(nonce);
    const code = try parseStringField(allocator, body, "code");
    errdefer allocator.free(code);
    const verifier = try parseStringField(allocator, body, "code_verifier");
    errdefer allocator.free(verifier);
    const redirect = try parseStringField(allocator, body, "redirect_uri");
    return .{ .state = state, .nonce = nonce, .code = code, .code_verifier = verifier, .redirect_uri = redirect };
}

fn responseAlloc(allocator: std.mem.Allocator, status: u16, value: anytype) !Response {
    return .{
        .allocator = allocator,
        .status = status,
        .body = try std.json.Stringify.valueAlloc(allocator, value, .{}),
    };
}
