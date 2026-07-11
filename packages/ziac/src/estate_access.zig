const std = @import("std");
const zstd = @import("zigeffect_std");
const estate = @import("estate.zig");

pub const Status = enum { ready };

pub const EntitlementRecord = struct {
    tier: estate.Entitlement,
    active: bool,
    expires_at_millis: u64,
};

pub const ResolveRequest = struct {
    session_assertion: []const u8,
    connection_id: []const u8,
    now_millis: u64,
};

pub const Resolver = struct {
    ptr: *anyopaque,
    verify_identity: *const fn (*anyopaque, []const u8, u64) anyerror!estate.Identity,
    lookup_entitlement: *const fn (*anyopaque, []const u8, u64) anyerror!EntitlementRecord,
    resolve_connection: *const fn (*anyopaque, []const u8, []const u8, u64) anyerror!estate.Connection,
};

pub const HttpResolver = struct {
    allocator: std.mem.Allocator,
    http: zstd.Http.Client,
    base_url: []u8,
    session_assertion: []u8,
    arena: std.heap.ArenaAllocator,

    pub fn init(
        allocator: std.mem.Allocator,
        http: zstd.Http.Client,
        base_url: []const u8,
        session_assertion: []const u8,
    ) !HttpResolver {
        if (!std.mem.startsWith(u8, base_url, "https://") or base_url.len > 2048 or
            std.mem.indexOfAny(u8, base_url, "\r\n") != null or !validSecretInput(session_assertion))
        {
            return error.InvalidControlPlaneConfiguration;
        }
        const normalized = std.mem.trimEnd(u8, base_url, "/");
        const owned_url = try allocator.dupe(u8, normalized);
        errdefer allocator.free(owned_url);
        const owned_assertion = try allocator.dupe(u8, session_assertion);
        return .{
            .allocator = allocator,
            .http = http,
            .base_url = owned_url,
            .session_assertion = owned_assertion,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *HttpResolver) void {
        self.arena.deinit();
        std.crypto.secureZero(u8, self.session_assertion);
        self.allocator.free(self.session_assertion);
        self.allocator.free(self.base_url);
        self.* = undefined;
    }

    pub fn resolver(self: *HttpResolver) Resolver {
        return .{
            .ptr = self,
            .verify_identity = verifyIdentity,
            .lookup_entitlement = lookupEntitlement,
            .resolve_connection = resolveConnection,
        };
    }

    fn verifyIdentity(raw: *anyopaque, session_assertion: []const u8, now_millis: u64) !estate.Identity {
        const self: *HttpResolver = @ptrCast(@alignCast(raw));
        try self.requireSession(session_assertion);
        const value = try self.requestJson("/v1/estate/identity:verify", "{}");
        const object = jsonObject(value) orelse return error.InvalidControlPlaneResponse;
        const provider = jsonString(object.get("identity_provider")) orelse return error.InvalidControlPlaneResponse;
        const verified = jsonBool(object.get("verified")) orelse return error.InvalidControlPlaneResponse;
        const subject = jsonString(object.get("subject")) orelse return error.InvalidControlPlaneResponse;
        if (!std.mem.eql(u8, provider, "google") or !verified or !validSubject(subject) or now_millis == 0) {
            return error.GoogleIdentityRequired;
        }
        return .{ .provider = .google, .verified = true, .subject = subject };
    }

    fn lookupEntitlement(raw: *anyopaque, subject: []const u8, now_millis: u64) !EntitlementRecord {
        const self: *HttpResolver = @ptrCast(@alignCast(raw));
        if (!validSubject(subject) or now_millis == 0) return error.ProEntitlementRequired;
        const body = try std.json.Stringify.valueAlloc(self.allocator, .{ .subject = subject }, .{});
        defer self.allocator.free(body);
        const value = try self.requestJson("/v1/estate/entitlements:lookup", body);
        const object = jsonObject(value) orelse return error.InvalidControlPlaneResponse;
        const tier_text = jsonString(object.get("tier")) orelse return error.InvalidControlPlaneResponse;
        const tier = std.meta.stringToEnum(estate.Entitlement, tier_text) orelse return error.InvalidControlPlaneResponse;
        return .{
            .tier = tier,
            .active = jsonBool(object.get("active")) orelse return error.InvalidControlPlaneResponse,
            .expires_at_millis = jsonU64(object.get("expires_at_millis")) orelse return error.InvalidControlPlaneResponse,
        };
    }

    fn resolveConnection(raw: *anyopaque, subject: []const u8, connection_id: []const u8, now_millis: u64) !estate.Connection {
        const self: *HttpResolver = @ptrCast(@alignCast(raw));
        if (!validSubject(subject) or !validOpaqueReference(connection_id) or now_millis == 0) return error.GcpConnectionRequired;
        const body = try std.json.Stringify.valueAlloc(self.allocator, .{
            .subject = subject,
            .connection_id = connection_id,
        }, .{});
        defer self.allocator.free(body);
        const value = try self.requestJson("/v1/estate/connections:resolve", body);
        const object = jsonObject(value) orelse return error.InvalidControlPlaneResponse;
        const status_text = jsonString(object.get("status")) orelse return error.InvalidControlPlaneResponse;
        const status = std.meta.stringToEnum(estate.ConnectionStatus, status_text) orelse return error.InvalidControlPlaneResponse;
        const project_id = jsonString(object.get("project_id")) orelse return error.InvalidControlPlaneResponse;
        if (status != .connected or !validProjectId(project_id)) return error.GcpConnectionRequired;
        return .{ .status = status, .project_id = project_id };
    }

    fn requireSession(self: *const HttpResolver, provided: []const u8) !void {
        if (provided.len != self.session_assertion.len or !std.mem.eql(u8, provided, self.session_assertion)) {
            return error.GoogleIdentityRequired;
        }
    }

    fn requestJson(self: *HttpResolver, path: []const u8, body: []const u8) !std.json.Value {
        const url = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, path });
        defer self.allocator.free(url);
        const authorization = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.session_assertion});
        defer {
            std.crypto.secureZero(u8, authorization);
            self.allocator.free(authorization);
        }
        const headers = [_]zstd.Http.Header{
            .{ .name = "authorization", .value = authorization },
            .{ .name = "accept", .value = "application/json" },
            .{ .name = "content-type", .value = "application/json" },
        };
        var response = try self.http.sendAlloc(self.allocator, .{
            .method = "POST",
            .url = url,
            .headers = &headers,
            .body = body,
        }, .{ .response_body_limit = 64 * 1024 });
        defer response.deinit(self.allocator);
        if (response.status == 401) return error.GoogleIdentityRequired;
        if (response.status == 402 or response.status == 403) return error.ProEntitlementRequired;
        if (response.status < 200 or response.status >= 300) return error.ControlPlaneUnavailable;
        var parsed = std.json.parseFromSlice(std.json.Value, self.arena.allocator(), response.body, .{
            .allocate = .alloc_always,
        }) catch return error.InvalidControlPlaneResponse;
        defer parsed.deinit();
        return parsed.value;
    }
};

pub const Access = struct {
    status: Status,
    scan_input: estate.ScanInput,

    pub fn sessionJsonAlloc(self: Access, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, .{
            .identity_provider = @tagName(self.scan_input.identity.provider),
            .authenticated = self.scan_input.identity.verified,
            .entitlement = @tagName(self.scan_input.entitlement),
            .connection = @tagName(self.scan_input.connection.status),
            .project_id = self.scan_input.connection.project_id,
            .last_scan_millis = self.scan_input.observed_at_millis,
            .ready = self.status == .ready,
        }, .{});
    }
};

pub fn resolve(resolver: Resolver, request: ResolveRequest) !Access {
    if (!validOpaqueReference(request.session_assertion) or !validOpaqueReference(request.connection_id) or request.now_millis == 0) {
        return error.InvalidAccessRequest;
    }
    const identity = try resolver.verify_identity(resolver.ptr, request.session_assertion, request.now_millis);
    if (identity.provider != .google or !identity.verified or identity.subject.len == 0) {
        return error.GoogleIdentityRequired;
    }
    const entitlement = try resolver.lookup_entitlement(resolver.ptr, identity.subject, request.now_millis);
    if (!entitlement.active or entitlement.tier != .pro or entitlement.expires_at_millis <= request.now_millis) {
        return error.ProEntitlementRequired;
    }
    const connection = try resolver.resolve_connection(
        resolver.ptr,
        identity.subject,
        request.connection_id,
        request.now_millis,
    );
    if (connection.status != .connected) return error.GcpConnectionRequired;
    if (!validProjectId(connection.project_id)) return error.InvalidProjectId;
    return .{
        .status = .ready,
        .scan_input = .{
            .identity = identity,
            .entitlement = entitlement.tier,
            .connection = connection,
            .observed_at_millis = request.now_millis,
        },
    };
}

pub const AuthorizationRequest = struct {
    client_id: []const u8,
    redirect_uri: []const u8,
    state: []const u8,
    nonce: []const u8,
    code_verifier: []const u8,
};

pub const Callback = struct {
    expected_state: []const u8,
    state: []const u8,
    code: []const u8,
};

pub fn pkceVerifierAlloc(allocator: std.mem.Allocator, entropy: []const u8) ![]u8 {
    if (entropy.len < 32 or entropy.len > 96) return error.InvalidPkceEntropy;
    const size = std.base64.url_safe_no_pad.Encoder.calcSize(entropy.len);
    const output = try allocator.alloc(u8, size);
    _ = std.base64.url_safe_no_pad.Encoder.encode(output, entropy);
    return output;
}

pub fn authorizationUrlAlloc(allocator: std.mem.Allocator, request: AuthorizationRequest) ![]u8 {
    if (!validClientId(request.client_id) or !validLoopbackRedirect(request.redirect_uri) or
        !validOpaqueReference(request.state) or !validOpaqueReference(request.nonce) or
        request.code_verifier.len < 43 or request.code_verifier.len > 128)
    {
        return error.InvalidAuthorizationRequest;
    }
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(request.code_verifier, &digest, .{});
    var challenge_buffer: [43]u8 = undefined;
    const challenge = std.base64.url_safe_no_pad.Encoder.encode(&challenge_buffer, &digest);

    const client_id = try queryEncodeAlloc(allocator, request.client_id);
    defer allocator.free(client_id);
    const redirect_uri = try queryEncodeAlloc(allocator, request.redirect_uri);
    defer allocator.free(redirect_uri);
    const state = try queryEncodeAlloc(allocator, request.state);
    defer allocator.free(state);
    const nonce = try queryEncodeAlloc(allocator, request.nonce);
    defer allocator.free(nonce);
    const scope = try queryEncodeAlloc(allocator, "openid email https://www.googleapis.com/auth/cloud-platform");
    defer allocator.free(scope);
    return std.fmt.allocPrint(
        allocator,
        "https://accounts.google.com/o/oauth2/v2/auth?client_id={s}&redirect_uri={s}&response_type=code&scope={s}&code_challenge={s}&code_challenge_method=S256&state={s}&nonce={s}&access_type=offline&prompt=consent",
        .{ client_id, redirect_uri, scope, challenge, state, nonce },
    );
}

pub fn validateCallback(callback: Callback) ![]const u8 {
    if (!validOpaqueReference(callback.expected_state) or !validOpaqueReference(callback.state) or
        callback.expected_state.len != callback.state.len or
        !std.mem.eql(u8, callback.expected_state, callback.state))
    {
        return error.OAuthStateMismatch;
    }
    if (!validOpaqueReference(callback.code)) return error.InvalidAuthorizationCode;
    return callback.code;
}

fn queryEncodeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (input) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try output.append(allocator, byte);
        } else {
            try output.appendSlice(allocator, &.{ '%', hex[byte >> 4], hex[byte & 0x0f] });
        }
    }
    return output.toOwnedSlice(allocator);
}

fn validOpaqueReference(value: []const u8) bool {
    return value.len >= 8 and value.len <= 4096 and std.mem.indexOfScalar(u8, value, 0) == null;
}

fn validSecretInput(value: []const u8) bool {
    return value.len >= 8 and value.len <= 16 * 1024 and std.mem.indexOfAny(u8, value, "\x00\r\n") == null;
}

fn validSubject(value: []const u8) bool {
    return value.len >= 3 and value.len <= 512 and std.mem.indexOfAny(u8, value, "\x00\r\n") == null;
}

fn jsonObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const present = value orelse return null;
    return switch (present) {
        .string => |text| text,
        else => null,
    };
}

fn jsonBool(value: ?std.json.Value) ?bool {
    const present = value orelse return null;
    return switch (present) {
        .bool => |result| result,
        else => null,
    };
}

fn jsonU64(value: ?std.json.Value) ?u64 {
    const present = value orelse return null;
    return switch (present) {
        .integer => |result| std.math.cast(u64, result),
        else => null,
    };
}

fn validClientId(value: []const u8) bool {
    return value.len >= 16 and value.len <= 512 and std.mem.endsWith(u8, value, ".apps.googleusercontent.com") and
        std.mem.indexOfScalar(u8, value, 0) == null;
}

fn validLoopbackRedirect(value: []const u8) bool {
    return (std.mem.startsWith(u8, value, "http://127.0.0.1:") or std.mem.startsWith(u8, value, "http://[::1]:")) and
        std.mem.endsWith(u8, value, "/oauth/callback") and value.len <= 256;
}

fn validProjectId(value: []const u8) bool {
    if (value.len < 6 or value.len > 63 or !std.ascii.isLower(value[0])) return false;
    if (value[value.len - 1] == '-') return false;
    for (value) |byte| if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '-')) return false;
    return true;
}
