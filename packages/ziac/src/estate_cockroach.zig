const std = @import("std");
const pg = @import("zigeffect_postgres");
const estate = @import("estate.zig");
const service = @import("estate_service.zig");
const kms_vault = @import("gcp/kms_vault.zig");

pub const Database = struct {
    ptr: *anyopaque,
    query_json_fn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror!?[]u8,
    execute_fn: *const fn (*anyopaque, []const u8) anyerror!u64,
};

pub const NativeDatabase = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    pool: pg.Native.Pool,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        connection_uri: []const u8,
        options: pg.Native.Options,
    ) !NativeDatabase {
        const now_millis: u64 = @intCast(std.Io.Clock.real.now(io).toMilliseconds());
        return .{
            .allocator = allocator,
            .io = io,
            .pool = try pg.Native.Pool.init(allocator, io, connection_uri, options, now_millis),
        };
    }

    pub fn deinit(self: *NativeDatabase) void {
        self.pool.deinit();
        self.* = undefined;
    }

    pub fn database(self: *NativeDatabase) Database {
        return .{ .ptr = self, .query_json_fn = queryJson, .execute_fn = execute };
    }

    fn queryJson(raw: *anyopaque, allocator: std.mem.Allocator, statement: []const u8) !?[]u8 {
        const self: *NativeDatabase = @ptrCast(@alignCast(raw));
        var diagnostic = pg.Native.Diagnostic{};
        const now_millis: u64 = @intCast(std.Io.Clock.real.now(self.io).toMilliseconds());
        var result = try self.pool.queryDetailedAlloc(allocator, statement, &diagnostic, now_millis);
        defer result.deinit(allocator);
        if (result.rows.len == 0) return null;
        if (result.rows.len != 1 or result.rows[0].fields.len != 1) return error.InvalidEstateRow;
        const text = switch (result.rows[0].fields[0].value) {
            .text, .timestamp, .decimal => |value| value,
            else => return error.InvalidEstateRow,
        };
        const owned: []u8 = try allocator.dupe(u8, text);
        return owned;
    }

    fn execute(raw: *anyopaque, statement: []const u8) !u64 {
        const self: *NativeDatabase = @ptrCast(@alignCast(raw));
        var diagnostic = pg.Native.Diagnostic{};
        const now_millis: u64 = @intCast(std.Io.Clock.real.now(self.io).toMilliseconds());
        const affected = try self.pool.executeDetailed(statement, &diagnostic, now_millis);
        const count = affected orelse return 0;
        return if (count < 0) 0 else @intCast(count);
    }
};

pub const Repository = struct {
    allocator: std.mem.Allocator,
    database: Database,
    scratch: std.ArrayList([]u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, database: Database) Repository {
        return .{ .allocator = allocator, .database = database };
    }

    pub fn deinit(self: *Repository) void {
        self.clearScratch();
        self.scratch.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn repository(self: *Repository) service.Repository {
        return .{
            .ptr = self,
            .find_session = findSession,
            .find_entitlement = findEntitlement,
            .find_connection = findConnection,
            .revoke_connection = revokeConnection,
            .append_audit = appendAudit,
            .put_session = putSession,
        };
    }

    pub fn challengeVerifier(self: *Repository) service.ChallengeVerifier {
        return .{ .ptr = self, .create_fn = createChallenge, .consume_fn = consumeChallenge };
    }

    pub fn ciphertextStore(self: *Repository) kms_vault.CiphertextStore {
        return .{ .ptr = self, .persist_fn = persistCiphertext };
    }

    fn findSession(raw: *anyopaque, digest: [32]u8) !?service.SessionRecord {
        const self: *Repository = @ptrCast(@alignCast(raw));
        var hex = std.fmt.bytesToHex(digest, .lower);
        const statement = try std.fmt.allocPrint(
            self.allocator,
            "SELECT json_build_object('subject', google_subject, 'expires_at_millis', (extract(epoch FROM expires_at) * 1000)::INT8, 'revoked', revoked_at IS NOT NULL)::STRING FROM ziac_identity_sessions WHERE session_digest = decode('{s}', 'hex') LIMIT 1",
            .{&hex},
        );
        defer self.allocator.free(statement);
        const response = (try self.queryRowAlloc(statement)) orelse return null;
        defer self.allocator.free(response);
        var parsed = std.json.parseFromSlice(SessionRow, self.allocator, response, .{}) catch return error.InvalidEstateRow;
        defer parsed.deinit();
        return .{
            .assertion_digest = digest,
            .subject = try self.keep(parsed.value.subject),
            .expires_at_millis = parsed.value.expires_at_millis,
            .revoked = parsed.value.revoked,
        };
    }

    fn findEntitlement(raw: *anyopaque, subject: []const u8) !?service.EntitlementRecord {
        const self: *Repository = @ptrCast(@alignCast(raw));
        const subject_sql = try literalAlloc(self.allocator, subject);
        defer self.allocator.free(subject_sql);
        const statement = try std.fmt.allocPrint(
            self.allocator,
            "SELECT json_build_object('subject', google_subject, 'tier', tier, 'active', active, 'expires_at_millis', (extract(epoch FROM expires_at) * 1000)::INT8)::STRING FROM ziac_entitlements WHERE google_subject = {s} LIMIT 1",
            .{subject_sql},
        );
        defer self.allocator.free(statement);
        const response = (try self.queryRowAlloc(statement)) orelse return null;
        defer self.allocator.free(response);
        var parsed = std.json.parseFromSlice(EntitlementRow, self.allocator, response, .{}) catch return error.InvalidEstateRow;
        defer parsed.deinit();
        return .{
            .subject = try self.keep(parsed.value.subject),
            .tier = std.meta.stringToEnum(estate.Entitlement, parsed.value.tier) orelse return error.InvalidEstateRow,
            .active = parsed.value.active,
            .expires_at_millis = parsed.value.expires_at_millis,
        };
    }

    fn findConnection(raw: *anyopaque, id: []const u8) !?service.ConnectionRecord {
        const self: *Repository = @ptrCast(@alignCast(raw));
        const id_sql = try literalAlloc(self.allocator, id);
        defer self.allocator.free(id_sql);
        const statement = try std.fmt.allocPrint(
            self.allocator,
            "SELECT json_build_object('id', connection_id::STRING, 'subject', google_subject, 'project_id', project_id, 'status', status, 'credential_key_id', credential_kms_key_version)::STRING FROM ziac_gcp_connections WHERE connection_id::STRING = {s} LIMIT 1",
            .{id_sql},
        );
        defer self.allocator.free(statement);
        const response = (try self.queryRowAlloc(statement)) orelse return null;
        defer self.allocator.free(response);
        var parsed = std.json.parseFromSlice(ConnectionRow, self.allocator, response, .{}) catch return error.InvalidEstateRow;
        defer parsed.deinit();
        return .{
            .id = try self.keep(parsed.value.id),
            .subject = try self.keep(parsed.value.subject),
            .project_id = try self.keep(parsed.value.project_id),
            .status = std.meta.stringToEnum(estate.ConnectionStatus, parsed.value.status) orelse return error.InvalidEstateRow,
            .credential_key_id = try self.keep(parsed.value.credential_key_id),
        };
    }

    fn revokeConnection(raw: *anyopaque, subject: []const u8, id: []const u8) !bool {
        const self: *Repository = @ptrCast(@alignCast(raw));
        const subject_sql = try literalAlloc(self.allocator, subject);
        defer self.allocator.free(subject_sql);
        const id_sql = try literalAlloc(self.allocator, id);
        defer self.allocator.free(id_sql);
        const statement = try std.fmt.allocPrint(
            self.allocator,
            "UPDATE ziac_gcp_connections SET status = 'disconnected', revoked_at = now() WHERE google_subject = {s} AND connection_id::STRING = {s} AND status = 'connected'",
            .{ subject_sql, id_sql },
        );
        defer self.allocator.free(statement);
        return try self.database.execute_fn(self.database.ptr, statement) > 0;
    }

    fn appendAudit(raw: *anyopaque, event: service.AuditEvent) !void {
        const self: *Repository = @ptrCast(@alignCast(raw));
        const subject = try literalAlloc(self.allocator, event.subject);
        defer self.allocator.free(subject);
        const action = try literalAlloc(self.allocator, event.action);
        defer self.allocator.free(action);
        const resource_id = try literalAlloc(self.allocator, event.resource_id);
        defer self.allocator.free(resource_id);
        const outcome = try literalAlloc(self.allocator, event.outcome);
        defer self.allocator.free(outcome);
        const statement = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO ziac_estate_audit (occurred_at, google_subject, action, resource_id, outcome) VALUES (to_timestamp({d} / 1000.0), {s}, {s}, {s}, {s})",
            .{ event.timestamp_millis, subject, action, resource_id, outcome },
        );
        defer self.allocator.free(statement);
        _ = try self.database.execute_fn(self.database.ptr, statement);
    }

    fn putSession(raw: *anyopaque, record: service.SessionRecord) !void {
        const self: *Repository = @ptrCast(@alignCast(raw));
        var hex = std.fmt.bytesToHex(record.assertion_digest, .lower);
        const identity_hex = digestHex(record.subject);
        const subject = try literalAlloc(self.allocator, record.subject);
        defer self.allocator.free(subject);
        const statement = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO ziac_accounts (google_subject, identity_hash) VALUES ({s}, decode('{s}', 'hex')) ON CONFLICT (google_subject) DO NOTHING; INSERT INTO ziac_identity_sessions (session_digest, google_subject, expires_at) VALUES (decode('{s}', 'hex'), {s}, to_timestamp({d} / 1000.0))",
            .{ subject, &identity_hex, &hex, subject, record.expires_at_millis },
        );
        defer self.allocator.free(statement);
        _ = try self.database.execute_fn(self.database.ptr, statement);
    }

    fn consumeChallenge(
        raw: *anyopaque,
        state: []const u8,
        nonce: []const u8,
        verifier: []const u8,
        redirect_uri: []const u8,
        now_millis: u64,
    ) !void {
        const self: *Repository = @ptrCast(@alignCast(raw));
        const state_hex = digestHex(state);
        const nonce_hex = digestHex(nonce);
        const verifier_hex = digestHex(verifier);
        const redirect = try literalAlloc(self.allocator, redirect_uri);
        defer self.allocator.free(redirect);
        const statement = try std.fmt.allocPrint(
            self.allocator,
            "UPDATE ziac_oauth_challenges SET consumed_at = to_timestamp({d} / 1000.0) WHERE state_digest = decode('{s}', 'hex') AND nonce_digest = decode('{s}', 'hex') AND verifier_digest = decode('{s}', 'hex') AND redirect_uri = {s} AND consumed_at IS NULL AND expires_at > to_timestamp({d} / 1000.0)",
            .{ now_millis, &state_hex, &nonce_hex, &verifier_hex, redirect, now_millis },
        );
        defer self.allocator.free(statement);
        if (try self.database.execute_fn(self.database.ptr, statement) != 1) return error.OAuthChallengeRejected;
    }

    fn createChallenge(
        raw: *anyopaque,
        state: []const u8,
        nonce: []const u8,
        verifier: []const u8,
        redirect_uri: []const u8,
        now_millis: u64,
    ) !void {
        const self: *Repository = @ptrCast(@alignCast(raw));
        const state_hex = digestHex(state);
        const nonce_hex = digestHex(nonce);
        const verifier_hex = digestHex(verifier);
        const redirect = try literalAlloc(self.allocator, redirect_uri);
        defer self.allocator.free(redirect);
        const statement = try std.fmt.allocPrint(
            self.allocator,
            "INSERT INTO ziac_oauth_challenges (state_digest, nonce_digest, verifier_digest, redirect_uri, expires_at) VALUES (decode('{s}', 'hex'), decode('{s}', 'hex'), decode('{s}', 'hex'), {s}, to_timestamp({d} / 1000.0))",
            .{ &state_hex, &nonce_hex, &verifier_hex, redirect, now_millis + 10 * std.time.ms_per_min },
        );
        defer self.allocator.free(statement);
        if (try self.database.execute_fn(self.database.ptr, statement) != 1) return error.OAuthChallengeRejected;
    }

    fn persistCiphertext(
        raw: *anyopaque,
        subject: []const u8,
        ciphertext: []const u8,
        key_version: []const u8,
        digest: [32]u8,
    ) !void {
        const self: *Repository = @ptrCast(@alignCast(raw));
        const subject_sql = try literalAlloc(self.allocator, subject);
        defer self.allocator.free(subject_sql);
        const ciphertext_sql = try literalAlloc(self.allocator, ciphertext);
        defer self.allocator.free(ciphertext_sql);
        const key_sql = try literalAlloc(self.allocator, key_version);
        defer self.allocator.free(key_sql);
        var digest_hex = std.fmt.bytesToHex(digest, .lower);
        const statement = try std.fmt.allocPrint(
            self.allocator,
            "UPSERT INTO ziac_google_credentials (google_subject, credential_ciphertext, credential_kms_key_version, credential_sha256, rotated_at) VALUES ({s}, decode({s}, 'base64'), {s}, decode('{s}', 'hex'), now())",
            .{ subject_sql, ciphertext_sql, key_sql, &digest_hex },
        );
        defer self.allocator.free(statement);
        if (try self.database.execute_fn(self.database.ptr, statement) != 1) return error.CredentialPersistenceFailed;
    }

    fn queryRowAlloc(self: *Repository, statement: []const u8) !?[]u8 {
        self.clearScratch();
        return self.database.query_json_fn(self.database.ptr, self.allocator, statement);
    }

    fn keep(self: *Repository, bytes: []const u8) ![]u8 {
        const owned = try self.allocator.dupe(u8, bytes);
        try self.scratch.append(self.allocator, owned);
        return owned;
    }

    fn clearScratch(self: *Repository) void {
        for (self.scratch.items) |item| self.allocator.free(item);
        self.scratch.clearRetainingCapacity();
    }
};

pub const RandomAssertionIssuer = struct {
    io: std.Io,

    pub fn init(io: std.Io) RandomAssertionIssuer {
        return .{ .io = io };
    }

    pub fn issuer(self: *RandomAssertionIssuer) service.AssertionIssuer {
        return .{ .ptr = self, .issue_fn = issue };
    }

    fn issue(raw: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
        const self: *RandomAssertionIssuer = @ptrCast(@alignCast(raw));
        var entropy: [32]u8 = undefined;
        try self.io.randomSecure(&entropy);
        defer std.crypto.secureZero(u8, &entropy);
        const size = std.base64.url_safe_no_pad.Encoder.calcSize(entropy.len);
        const assertion = try allocator.alloc(u8, size);
        _ = std.base64.url_safe_no_pad.Encoder.encode(assertion, &entropy);
        return assertion;
    }
};

const SessionRow = struct { subject: []const u8, expires_at_millis: u64, revoked: bool };
const EntitlementRow = struct { subject: []const u8, tier: []const u8, active: bool, expires_at_millis: u64 };
const ConnectionRow = struct {
    id: []const u8,
    subject: []const u8,
    project_id: []const u8,
    status: []const u8,
    credential_key_id: []const u8,
};

fn literalAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    if (value.len == 0 or value.len > 1024 or std.mem.indexOfAny(u8, value, "\x00\r\n") != null) return error.InvalidEstateValue;
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.append(allocator, '\'');
    for (value) |byte| {
        if (byte == '\'') try output.append(allocator, '\'');
        try output.append(allocator, byte);
    }
    try output.append(allocator, '\'');
    return output.toOwnedSlice(allocator);
}

fn digestHex(value: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &digest, .{});
    defer std.crypto.secureZero(u8, &digest);
    return std.fmt.bytesToHex(digest, .lower);
}
