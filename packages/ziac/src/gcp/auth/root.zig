const std = @import("std");
const zstd = @import("zigeffect_std");
const rsa = @import("rsa.zig");

pub const cloud_platform_scope = "https://www.googleapis.com/auth/cloud-platform";
pub const google_token_endpoint = "https://oauth2.googleapis.com/token";
pub const metadata_token_endpoint = "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token";
pub const token_exchange_grant = "urn:ietf:params:oauth:grant-type:token-exchange";
pub const jwt_bearer_grant = "urn:ietf:params:oauth:grant-type:jwt-bearer";
pub const access_token_type = "urn:ietf:params:oauth:token-type:access_token";

pub const AuthError = error{
    CredentialFileNotFound,
    CredentialReadFailed,
    InvalidCredential,
    UnsupportedCredentialType,
    InvalidTokenResponse,
    TokenEndpointRejected,
    MissingSubjectToken,
    InvalidTimestamp,
    InvalidPrivateKey,
    SigningFailed,
    InvalidSignature,
    InvalidSubjectToken,
} || std.mem.Allocator.Error || zstd.Http.TransportError;

pub const CredentialKind = enum {
    authorized_user,
    service_account,
    external_account,
};

pub const AuthorizedUser = struct {
    client_id: []const u8,
    client_secret: []const u8,
    refresh_token: []const u8,
    token_uri: []const u8,
    quota_project_id: ?[]const u8 = null,

    fn deinit(self: *AuthorizedUser, allocator: std.mem.Allocator) void {
        allocator.free(self.client_id);
        allocator.free(self.client_secret);
        allocator.free(self.refresh_token);
        allocator.free(self.token_uri);
        if (self.quota_project_id) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub const ServiceAccount = struct {
    project_id: ?[]const u8,
    private_key_id: ?[]const u8,
    private_key: []const u8,
    client_email: []const u8,
    token_uri: []const u8,

    fn deinit(self: *ServiceAccount, allocator: std.mem.Allocator) void {
        if (self.project_id) |value| allocator.free(value);
        if (self.private_key_id) |value| allocator.free(value);
        allocator.free(self.private_key);
        allocator.free(self.client_email);
        allocator.free(self.token_uri);
        self.* = undefined;
    }
};

pub const CredentialSource = struct {
    file: ?[]const u8,
    url: ?[]const u8,
    headers: []const zstd.Http.Header = &.{},
    format: SubjectTokenFormat = .text,

    fn deinit(self: *CredentialSource, allocator: std.mem.Allocator) void {
        if (self.file) |value| allocator.free(value);
        if (self.url) |value| allocator.free(value);
        for (self.headers) |header| {
            allocator.free(header.name);
            std.crypto.secureZero(u8, @constCast(header.value));
            allocator.free(header.value);
        }
        allocator.free(self.headers);
        self.format.deinit(allocator);
        self.* = undefined;
    }
};

pub const SubjectTokenFormat = union(enum) {
    text,
    json: []const u8,

    fn deinit(self: *SubjectTokenFormat, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text => {},
            .json => |field_name| allocator.free(field_name),
        }
        self.* = undefined;
    }
};

pub const ExternalAccount = struct {
    audience: []const u8,
    subject_token_type: []const u8,
    token_url: []const u8,
    service_account_impersonation_url: ?[]const u8,
    credential_source: CredentialSource,

    fn deinit(self: *ExternalAccount, allocator: std.mem.Allocator) void {
        allocator.free(self.audience);
        allocator.free(self.subject_token_type);
        allocator.free(self.token_url);
        if (self.service_account_impersonation_url) |value| allocator.free(value);
        self.credential_source.deinit(allocator);
        self.* = undefined;
    }
};

pub const Credential = union(CredentialKind) {
    authorized_user: AuthorizedUser,
    service_account: ServiceAccount,
    external_account: ExternalAccount,

    pub fn deinit(self: *Credential, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*value| value.deinit(allocator),
        }
        self.* = undefined;
    }

    pub fn kind(self: Credential) CredentialKind {
        return std.meta.activeTag(self);
    }
};

const TypeProbe = struct {
    type: []const u8,
};

const AuthorizedUserDecoded = struct {
    client_id: []const u8,
    client_secret: []const u8,
    refresh_token: []const u8,
    token_uri: ?[]const u8,
    quota_project_id: ?[]const u8,
};

const ServiceAccountDecoded = struct {
    project_id: ?[]const u8,
    private_key_id: ?[]const u8,
    private_key: []const u8,
    client_email: []const u8,
    token_uri: ?[]const u8,
};

const CredentialSourceDecoded = struct {
    file: ?[]const u8,
    url: ?[]const u8,
};

const ExternalAccountDecoded = struct {
    audience: []const u8,
    subject_token_type: []const u8,
    token_url: []const u8,
    service_account_impersonation_url: ?[]const u8,
    credential_source: CredentialSourceDecoded,
};

pub fn decodeCredentialAlloc(allocator: std.mem.Allocator, json: []const u8) AuthError!Credential {
    var probe = zstd.Schema.decodeDetailedJsonAlloc(
        allocator,
        zstd.Schema.derive(TypeProbe, .{}),
        json,
    ) catch return error.InvalidCredential;
    defer probe.deinit();
    if (!probe.ok()) return error.InvalidCredential;

    if (std.mem.eql(u8, probe.value.?.type, "authorized_user")) {
        var decoded = zstd.Schema.decodeDetailedJsonAlloc(
            allocator,
            zstd.Schema.derive(AuthorizedUserDecoded, .{}),
            json,
        ) catch return error.InvalidCredential;
        defer decoded.deinit();
        if (!decoded.ok()) return error.InvalidCredential;
        const value = decoded.value.?;
        return .{ .authorized_user = try cloneAuthorizedUser(allocator, value) };
    }
    if (std.mem.eql(u8, probe.value.?.type, "service_account")) {
        var decoded = zstd.Schema.decodeDetailedJsonAlloc(
            allocator,
            zstd.Schema.derive(ServiceAccountDecoded, .{}),
            json,
        ) catch return error.InvalidCredential;
        defer decoded.deinit();
        if (!decoded.ok()) return error.InvalidCredential;
        const value = decoded.value.?;
        return .{ .service_account = try cloneServiceAccount(allocator, value) };
    }
    if (std.mem.eql(u8, probe.value.?.type, "external_account")) {
        var decoded = zstd.Schema.decodeDetailedJsonAlloc(
            allocator,
            zstd.Schema.derive(ExternalAccountDecoded, .{
                .credential_source = zstd.Schema.derive(CredentialSourceDecoded, .{}),
            }),
            json,
        ) catch return error.InvalidCredential;
        defer decoded.deinit();
        if (!decoded.ok()) return error.InvalidCredential;
        const value = decoded.value.?;
        if (value.credential_source.file == null and value.credential_source.url == null) {
            return error.InvalidCredential;
        }
        return .{ .external_account = try cloneExternalAccount(allocator, value, json) };
    }
    return error.UnsupportedCredentialType;
}

fn cloneAuthorizedUser(allocator: std.mem.Allocator, value: AuthorizedUserDecoded) std.mem.Allocator.Error!AuthorizedUser {
    const client_id = try allocator.dupe(u8, value.client_id);
    errdefer allocator.free(client_id);
    const client_secret = try allocator.dupe(u8, value.client_secret);
    errdefer allocator.free(client_secret);
    const refresh_token = try allocator.dupe(u8, value.refresh_token);
    errdefer allocator.free(refresh_token);
    const token_uri = try allocator.dupe(u8, value.token_uri orelse google_token_endpoint);
    errdefer allocator.free(token_uri);
    const quota_project_id = if (value.quota_project_id) |input| try allocator.dupe(u8, input) else null;
    return .{
        .client_id = client_id,
        .client_secret = client_secret,
        .refresh_token = refresh_token,
        .token_uri = token_uri,
        .quota_project_id = quota_project_id,
    };
}

fn cloneServiceAccount(allocator: std.mem.Allocator, value: ServiceAccountDecoded) std.mem.Allocator.Error!ServiceAccount {
    const project_id = if (value.project_id) |input| try allocator.dupe(u8, input) else null;
    errdefer if (project_id) |owned| allocator.free(owned);
    const private_key_id = if (value.private_key_id) |input| try allocator.dupe(u8, input) else null;
    errdefer if (private_key_id) |owned| allocator.free(owned);
    const private_key = try allocator.dupe(u8, value.private_key);
    errdefer allocator.free(private_key);
    const client_email = try allocator.dupe(u8, value.client_email);
    errdefer allocator.free(client_email);
    const token_uri = try allocator.dupe(u8, value.token_uri orelse google_token_endpoint);
    return .{
        .project_id = project_id,
        .private_key_id = private_key_id,
        .private_key = private_key,
        .client_email = client_email,
        .token_uri = token_uri,
    };
}

fn cloneExternalAccount(allocator: std.mem.Allocator, value: ExternalAccountDecoded, json: []const u8) AuthError!ExternalAccount {
    const audience = try allocator.dupe(u8, value.audience);
    errdefer allocator.free(audience);
    const subject_token_type = try allocator.dupe(u8, value.subject_token_type);
    errdefer allocator.free(subject_token_type);
    const token_url = try allocator.dupe(u8, value.token_url);
    errdefer allocator.free(token_url);
    const impersonation_url = if (value.service_account_impersonation_url) |input| try allocator.dupe(u8, input) else null;
    errdefer if (impersonation_url) |owned| allocator.free(owned);
    const file = if (value.credential_source.file) |input| try allocator.dupe(u8, input) else null;
    errdefer if (file) |owned| allocator.free(owned);
    const url = if (value.credential_source.url) |input| try allocator.dupe(u8, input) else null;
    errdefer if (url) |owned| allocator.free(owned);
    var source_options = try decodeSourceOptionsAlloc(allocator, json);
    errdefer source_options.deinit(allocator);
    return .{
        .audience = audience,
        .subject_token_type = subject_token_type,
        .token_url = token_url,
        .service_account_impersonation_url = impersonation_url,
        .credential_source = .{
            .file = file,
            .url = url,
            .headers = source_options.headers,
            .format = source_options.format,
        },
    };
}

const SourceOptions = struct {
    headers: []const zstd.Http.Header,
    format: SubjectTokenFormat,

    fn deinit(self: *SourceOptions, allocator: std.mem.Allocator) void {
        var source = CredentialSource{
            .file = null,
            .url = null,
            .headers = self.headers,
            .format = self.format,
        };
        source.deinit(allocator);
        self.* = undefined;
    }
};

fn decodeSourceOptionsAlloc(allocator: std.mem.Allocator, json: []const u8) AuthError!SourceOptions {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return error.InvalidCredential;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidCredential,
    };
    const source_value = root.get("credential_source") orelse return error.InvalidCredential;
    const source = switch (source_value) {
        .object => |object| object,
        else => return error.InvalidCredential,
    };

    var headers = std.ArrayList(zstd.Http.Header).empty;
    errdefer {
        for (headers.items) |header| {
            allocator.free(header.name);
            std.crypto.secureZero(u8, @constCast(header.value));
            allocator.free(header.value);
        }
        headers.deinit(allocator);
    }
    if (source.get("headers")) |headers_value| {
        const header_object = switch (headers_value) {
            .object => |object| object,
            else => return error.InvalidCredential,
        };
        var iterator = header_object.iterator();
        while (iterator.next()) |entry| {
            const value = switch (entry.value_ptr.*) {
                .string => |text| text,
                else => return error.InvalidCredential,
            };
            const name = try allocator.dupe(u8, entry.key_ptr.*);
            errdefer allocator.free(name);
            const owned_value = try allocator.dupe(u8, value);
            errdefer allocator.free(owned_value);
            try headers.append(allocator, .{ .name = name, .value = owned_value });
        }
    }

    var format: SubjectTokenFormat = .text;
    errdefer format.deinit(allocator);
    if (source.get("format")) |format_value| {
        const format_object = switch (format_value) {
            .object => |object| object,
            else => return error.InvalidCredential,
        };
        const type_value = format_object.get("type") orelse return error.InvalidCredential;
        const type_name = switch (type_value) {
            .string => |text| text,
            else => return error.InvalidCredential,
        };
        if (std.mem.eql(u8, type_name, "json")) {
            const field_value = format_object.get("subject_token_field_name") orelse return error.InvalidCredential;
            const field_name = switch (field_value) {
                .string => |text| text,
                else => return error.InvalidCredential,
            };
            format = .{ .json = try allocator.dupe(u8, field_name) };
        } else if (!std.mem.eql(u8, type_name, "text")) {
            return error.InvalidCredential;
        }
    }

    return .{
        .headers = try headers.toOwnedSlice(allocator),
        .format = format,
    };
}

pub const SourceLocation = enum {
    environment,
    well_known_file,
    metadata,
};

pub const FileReader = struct {
    ptr: *anyopaque,
    readFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) AuthError![]const u8,

    pub fn readFileAlloc(self: *FileReader, allocator: std.mem.Allocator, path: []const u8) AuthError![]const u8 {
        return self.readFn(self.ptr, allocator, path);
    }
};

pub fn memoryFileReader(files: *zstd.FileSystem.MemoryFileSystem) FileReader {
    return .{ .ptr = files, .readFn = readMemoryFile };
}

fn readMemoryFile(raw: *anyopaque, allocator: std.mem.Allocator, path: []const u8) AuthError![]const u8 {
    const files: *zstd.FileSystem.MemoryFileSystem = @ptrCast(@alignCast(raw));
    return files.readFileAlloc(allocator, path) catch |err| switch (err) {
        error.FileNotFound => error.CredentialFileNotFound,
        error.OutOfMemory => error.OutOfMemory,
    };
}

pub fn localFileReader(files: *zstd.FileSystem.LocalFileSystem) FileReader {
    return .{ .ptr = files, .readFn = readLocalFile };
}

fn readLocalFile(raw: *anyopaque, allocator: std.mem.Allocator, path: []const u8) AuthError![]const u8 {
    const files: *zstd.FileSystem.LocalFileSystem = @ptrCast(@alignCast(raw));
    return files.readFileAlloc(allocator, path) catch |err| {
        if (err == error.FileNotFound) return error.CredentialFileNotFound;
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.CredentialReadFailed;
    };
}

pub const ResolvedAdc = struct {
    location: SourceLocation,
    credential: ?Credential = null,

    pub fn deinit(self: *ResolvedAdc, allocator: std.mem.Allocator) void {
        if (self.credential) |*credential| credential.deinit(allocator);
        self.* = undefined;
    }

    pub fn credentialKind(self: ResolvedAdc) ?CredentialKind {
        return if (self.credential) |credential| credential.kind() else null;
    }

    pub fn doctorJsonAlloc(self: ResolvedAdc, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        const kind_name = if (self.credentialKind()) |kind| @tagName(kind) else "attached_service_account";
        return std.fmt.allocPrint(
            allocator,
            "{{\"schema\":\"ziac.gcp-auth-doctor.v1\",\"status\":\"ready\",\"source\":\"{s}\",\"credential_type\":\"{s}\"}}",
            .{ @tagName(self.location), kind_name },
        );
    }
};

pub fn resolveAdcAlloc(
    allocator: std.mem.Allocator,
    env: zstd.Env.EnvMap,
    files: anytype,
) AuthError!ResolvedAdc {
    if (env.get("GOOGLE_APPLICATION_CREDENTIALS")) |path| {
        const credential = try readCredentialAlloc(allocator, files, path);
        return .{ .location = .environment, .credential = credential };
    }

    const well_known_path = if (env.get("HOME")) |home|
        try zstd.Path.joinAlloc(allocator, &.{ home, ".config/gcloud/application_default_credentials.json" })
    else if (env.get("APPDATA")) |app_data|
        try zstd.Path.joinAlloc(allocator, &.{ app_data, "gcloud/application_default_credentials.json" })
    else
        null;
    if (well_known_path) |path| {
        defer allocator.free(path);
        if (readCredentialAlloc(allocator, files, path)) |credential| {
            return .{ .location = .well_known_file, .credential = credential };
        } else |err| switch (err) {
            error.CredentialFileNotFound => {},
            else => return err,
        }
    }

    return .{ .location = .metadata };
}

fn readCredentialAlloc(
    allocator: std.mem.Allocator,
    files: anytype,
    path: []const u8,
) AuthError!Credential {
    const content = files.readFileAlloc(allocator, path) catch |err| {
        if (err == error.FileNotFound or err == error.CredentialFileNotFound) return error.CredentialFileNotFound;
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.CredentialReadFailed;
    };
    defer allocator.free(content);
    return decodeCredentialAlloc(allocator, content);
}

pub const OwnedRequest = struct {
    request: zstd.Http.Request,
    owned_url: []const u8,
    owned_body: []const u8,

    pub fn deinit(self: *OwnedRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.owned_url);
        allocator.free(self.owned_body);
        self.* = undefined;
    }
};

const form_headers = [_]zstd.Http.Header{
    .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
};

fn ownedPostRequestAlloc(
    allocator: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
) std.mem.Allocator.Error!OwnedRequest {
    const owned_url = try allocator.dupe(u8, url);
    errdefer allocator.free(owned_url);
    const owned_body = try allocator.dupe(u8, body);
    errdefer allocator.free(owned_body);
    return .{
        .request = .{
            .method = "POST",
            .url = owned_url,
            .headers = &form_headers,
            .body = owned_body,
        },
        .owned_url = owned_url,
        .owned_body = owned_body,
    };
}

pub fn authorizedUserRequestAlloc(
    allocator: std.mem.Allocator,
    credential: AuthorizedUser,
) std.mem.Allocator.Error!OwnedRequest {
    const fields = [_]FormField{
        .{ .name = "client_id", .value = credential.client_id },
        .{ .name = "client_secret", .value = credential.client_secret },
        .{ .name = "refresh_token", .value = credential.refresh_token },
        .{ .name = "grant_type", .value = "refresh_token" },
    };
    const body = try formBodyAlloc(allocator, &fields);
    defer allocator.free(body);
    return ownedPostRequestAlloc(allocator, credential.token_uri, body);
}

pub const Signer = struct {
    ptr: *anyopaque,
    signFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) AuthError![]const u8,

    pub fn signAlloc(self: Signer, allocator: std.mem.Allocator, message: []const u8) AuthError![]const u8 {
        return self.signFn(self.ptr, allocator, message);
    }
};

pub const RsaSigner = struct {
    private_key_pem: []const u8,

    pub fn init(private_key_pem: []const u8) RsaSigner {
        return .{ .private_key_pem = private_key_pem };
    }

    pub fn signer(self: *RsaSigner) Signer {
        return .{ .ptr = self, .signFn = signErased };
    }

    pub fn verify(self: RsaSigner, message: []const u8, signature: []const u8) AuthError!void {
        return rsa.verifyRs256(self.private_key_pem, message, signature);
    }

    fn signErased(raw: *anyopaque, allocator: std.mem.Allocator, message: []const u8) AuthError![]const u8 {
        const self: *RsaSigner = @ptrCast(@alignCast(raw));
        return rsa.signRs256Alloc(allocator, self.private_key_pem, message);
    }
};

pub fn serviceAccountRequestAlloc(
    allocator: std.mem.Allocator,
    credential: ServiceAccount,
    scope: []const u8,
    now_seconds: u64,
    signer: Signer,
) AuthError!OwnedRequest {
    const expires_at = std.math.add(u64, now_seconds, 3600) catch return error.InvalidTimestamp;
    const escaped_email = try zstd.Json.escapeStringAlloc(allocator, credential.client_email);
    defer allocator.free(escaped_email);
    const escaped_scope = try zstd.Json.escapeStringAlloc(allocator, scope);
    defer allocator.free(escaped_scope);
    const escaped_audience = try zstd.Json.escapeStringAlloc(allocator, credential.token_uri);
    defer allocator.free(escaped_audience);

    const header_json = if (credential.private_key_id) |key_id| header: {
        const escaped_key_id = try zstd.Json.escapeStringAlloc(allocator, key_id);
        defer allocator.free(escaped_key_id);
        break :header try std.fmt.allocPrint(
            allocator,
            "{{\"alg\":\"RS256\",\"typ\":\"JWT\",\"kid\":\"{s}\"}}",
            .{escaped_key_id},
        );
    } else try allocator.dupe(u8, "{\"alg\":\"RS256\",\"typ\":\"JWT\"}");
    defer allocator.free(header_json);
    const claims_json = try std.fmt.allocPrint(
        allocator,
        "{{\"iss\":\"{s}\",\"scope\":\"{s}\",\"aud\":\"{s}\",\"iat\":{d},\"exp\":{d}}}",
        .{ escaped_email, escaped_scope, escaped_audience, now_seconds, expires_at },
    );
    defer allocator.free(claims_json);
    const encoded_header = try base64UrlAlloc(allocator, header_json);
    defer allocator.free(encoded_header);
    const encoded_claims = try base64UrlAlloc(allocator, claims_json);
    defer allocator.free(encoded_claims);
    const signing_input = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ encoded_header, encoded_claims });
    defer allocator.free(signing_input);
    const signature = try signer.signAlloc(allocator, signing_input);
    defer allocator.free(signature);
    const encoded_signature = try base64UrlAlloc(allocator, signature);
    defer allocator.free(encoded_signature);
    const assertion = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ signing_input, encoded_signature });
    defer allocator.free(assertion);

    const fields = [_]FormField{
        .{ .name = "grant_type", .value = jwt_bearer_grant },
        .{ .name = "assertion", .value = assertion },
    };
    const body = try formBodyAlloc(allocator, &fields);
    defer allocator.free(body);
    return ownedPostRequestAlloc(allocator, credential.token_uri, body);
}

pub fn externalAccountRequestAlloc(
    allocator: std.mem.Allocator,
    credential: ExternalAccount,
    subject_token: []const u8,
    scope: []const u8,
) AuthError!OwnedRequest {
    if (subject_token.len == 0) return error.MissingSubjectToken;
    const fields = [_]FormField{
        .{ .name = "grant_type", .value = token_exchange_grant },
        .{ .name = "audience", .value = credential.audience },
        .{ .name = "scope", .value = scope },
        .{ .name = "requested_token_type", .value = access_token_type },
        .{ .name = "subject_token", .value = subject_token },
        .{ .name = "subject_token_type", .value = credential.subject_token_type },
    };
    const body = try formBodyAlloc(allocator, &fields);
    defer allocator.free(body);
    return ownedPostRequestAlloc(allocator, credential.token_url, body);
}

const FormField = struct {
    name: []const u8,
    value: []const u8,
};

fn formBodyAlloc(allocator: std.mem.Allocator, fields: []const FormField) std.mem.Allocator.Error![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    for (fields, 0..) |field, index| {
        if (index != 0) try output.append(allocator, '&');
        try appendFormEncoded(&output, allocator, field.name);
        try output.append(allocator, '=');
        try appendFormEncoded(&output, allocator, field.value);
    }
    return output.toOwnedSlice(allocator);
}

fn appendFormEncoded(output: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error!void {
    const hex = "0123456789ABCDEF";
    for (input) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try output.append(allocator, byte);
        } else if (byte == ' ') {
            try output.append(allocator, '+');
        } else {
            try output.appendSlice(allocator, &.{ '%', hex[byte >> 4], hex[byte & 0x0f] });
        }
    }
}

fn base64UrlAlloc(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]const u8 {
    const size = std.base64.url_safe_no_pad.Encoder.calcSize(input.len);
    const encoded = try allocator.alloc(u8, size);
    return std.base64.url_safe_no_pad.Encoder.encode(encoded, input);
}

pub const AccessToken = struct {
    access_token: []const u8,
    token_type: []const u8,
    expires_at_seconds: u64,

    pub fn initOwned(allocator: std.mem.Allocator, value: AccessToken) std.mem.Allocator.Error!AccessToken {
        const access_token = try allocator.dupe(u8, value.access_token);
        errdefer allocator.free(access_token);
        const token_type = try allocator.dupe(u8, value.token_type);
        return .{
            .access_token = access_token,
            .token_type = token_type,
            .expires_at_seconds = value.expires_at_seconds,
        };
    }

    pub fn clone(self: AccessToken, allocator: std.mem.Allocator) std.mem.Allocator.Error!AccessToken {
        return initOwned(allocator, self);
    }

    pub fn deinit(self: *AccessToken, allocator: std.mem.Allocator) void {
        std.crypto.secureZero(u8, @constCast(self.access_token));
        allocator.free(self.access_token);
        allocator.free(self.token_type);
        self.* = undefined;
    }
};

const TokenResponse = struct {
    access_token: []const u8,
    token_type: []const u8,
    expires_in: i64,
};

pub fn parseTokenResponseAlloc(
    allocator: std.mem.Allocator,
    json: []const u8,
    now_seconds: u64,
) AuthError!AccessToken {
    var decoded = zstd.Schema.decodeDetailedJsonAlloc(
        allocator,
        zstd.Schema.derive(TokenResponse, .{}),
        json,
    ) catch return error.InvalidTokenResponse;
    defer decoded.deinit();
    if (!decoded.ok()) return error.InvalidTokenResponse;
    const value = decoded.value.?;
    if (value.access_token.len == 0 or value.token_type.len == 0 or value.expires_in <= 0) {
        return error.InvalidTokenResponse;
    }
    const expires_at = std.math.add(u64, now_seconds, @intCast(value.expires_in)) catch return error.InvalidTokenResponse;
    return AccessToken.initOwned(allocator, .{
        .access_token = value.access_token,
        .token_type = value.token_type,
        .expires_at_seconds = expires_at,
    });
}

pub const TokenSource = struct {
    ptr: *anyopaque,
    fetchFn: *const fn (*anyopaque, std.mem.Allocator, u64) AuthError!AccessToken,

    pub fn fetchAlloc(self: TokenSource, allocator: std.mem.Allocator, now_seconds: u64) AuthError!AccessToken {
        return self.fetchFn(self.ptr, allocator, now_seconds);
    }
};

const metadata_headers = [_]zstd.Http.Header{
    .{ .name = "Metadata-Flavor", .value = "Google" },
};

pub const MetadataTokenSource = struct {
    client: zstd.Http.Client,

    pub fn init(client: zstd.Http.Client) MetadataTokenSource {
        return .{ .client = client };
    }

    pub fn fetchAlloc(self: *MetadataTokenSource, allocator: std.mem.Allocator, now_seconds: u64) AuthError!AccessToken {
        var response = try self.client.sendAlloc(allocator, .{
            .method = "GET",
            .url = metadata_token_endpoint,
            .headers = &metadata_headers,
        }, .{});
        defer response.deinit(allocator);
        if (response.status < 200 or response.status >= 300) return error.TokenEndpointRejected;
        return parseTokenResponseAlloc(allocator, response.body, now_seconds);
    }

    pub fn tokenSource(self: *MetadataTokenSource) TokenSource {
        return .{ .ptr = self, .fetchFn = fetchErased };
    }

    fn fetchErased(raw: *anyopaque, allocator: std.mem.Allocator, now_seconds: u64) AuthError!AccessToken {
        const self: *MetadataTokenSource = @ptrCast(@alignCast(raw));
        return self.fetchAlloc(allocator, now_seconds);
    }
};

pub const AuthorizedUserTokenSource = struct {
    client: zstd.Http.Client,
    credential: *const AuthorizedUser,

    pub fn fetchAlloc(self: *AuthorizedUserTokenSource, allocator: std.mem.Allocator, now_seconds: u64) AuthError!AccessToken {
        var request = try authorizedUserRequestAlloc(allocator, self.credential.*);
        defer request.deinit(allocator);
        return exchangeAlloc(self.client, allocator, request.request, now_seconds);
    }

    pub fn tokenSource(self: *AuthorizedUserTokenSource) TokenSource {
        return .{ .ptr = self, .fetchFn = fetchErased };
    }

    fn fetchErased(raw: *anyopaque, allocator: std.mem.Allocator, now_seconds: u64) AuthError!AccessToken {
        const self: *AuthorizedUserTokenSource = @ptrCast(@alignCast(raw));
        return self.fetchAlloc(allocator, now_seconds);
    }
};

pub const ServiceAccountTokenSource = struct {
    client: zstd.Http.Client,
    credential: *const ServiceAccount,
    signer: Signer,
    scope: []const u8 = cloud_platform_scope,

    pub fn fetchAlloc(self: *ServiceAccountTokenSource, allocator: std.mem.Allocator, now_seconds: u64) AuthError!AccessToken {
        var request = try serviceAccountRequestAlloc(allocator, self.credential.*, self.scope, now_seconds, self.signer);
        defer request.deinit(allocator);
        return exchangeAlloc(self.client, allocator, request.request, now_seconds);
    }

    pub fn tokenSource(self: *ServiceAccountTokenSource) TokenSource {
        return .{ .ptr = self, .fetchFn = fetchErased };
    }

    fn fetchErased(raw: *anyopaque, allocator: std.mem.Allocator, now_seconds: u64) AuthError!AccessToken {
        const self: *ServiceAccountTokenSource = @ptrCast(@alignCast(raw));
        return self.fetchAlloc(allocator, now_seconds);
    }
};

pub const SubjectTokenSource = struct {
    ptr: *anyopaque,
    fetchFn: *const fn (*anyopaque, std.mem.Allocator) AuthError![]const u8,

    pub fn fetchAlloc(self: SubjectTokenSource, allocator: std.mem.Allocator) AuthError![]const u8 {
        return self.fetchFn(self.ptr, allocator);
    }
};

pub const FileSubjectTokenSource = struct {
    reader: FileReader,
    path: []const u8,
    format: SubjectTokenFormat,

    pub fn init(reader: FileReader, path: []const u8, format: SubjectTokenFormat) FileSubjectTokenSource {
        return .{ .reader = reader, .path = path, .format = format };
    }

    pub fn fetchAlloc(self: *FileSubjectTokenSource, allocator: std.mem.Allocator) AuthError![]const u8 {
        const content = try self.reader.readFileAlloc(allocator, self.path);
        defer {
            std.crypto.secureZero(u8, @constCast(content));
            allocator.free(content);
        }
        return parseSubjectTokenAlloc(allocator, content, self.format);
    }

    pub fn subjectTokenSource(self: *FileSubjectTokenSource) SubjectTokenSource {
        return .{ .ptr = self, .fetchFn = fetchErased };
    }

    fn fetchErased(raw: *anyopaque, allocator: std.mem.Allocator) AuthError![]const u8 {
        const self: *FileSubjectTokenSource = @ptrCast(@alignCast(raw));
        return self.fetchAlloc(allocator);
    }
};

pub const UrlSubjectTokenSource = struct {
    client: zstd.Http.Client,
    source: *const CredentialSource,

    pub fn init(client: zstd.Http.Client, source: *const CredentialSource) UrlSubjectTokenSource {
        return .{ .client = client, .source = source };
    }

    pub fn fetchAlloc(self: *UrlSubjectTokenSource, allocator: std.mem.Allocator) AuthError![]const u8 {
        const url = self.source.url orelse return error.InvalidCredential;
        var response = try self.client.sendAlloc(allocator, .{
            .method = "GET",
            .url = url,
            .headers = self.source.headers,
        }, .{});
        defer response.deinit(allocator);
        if (response.status < 200 or response.status >= 300) return error.TokenEndpointRejected;
        return parseSubjectTokenAlloc(allocator, response.body, self.source.format);
    }

    pub fn subjectTokenSource(self: *UrlSubjectTokenSource) SubjectTokenSource {
        return .{ .ptr = self, .fetchFn = fetchErased };
    }

    fn fetchErased(raw: *anyopaque, allocator: std.mem.Allocator) AuthError![]const u8 {
        const self: *UrlSubjectTokenSource = @ptrCast(@alignCast(raw));
        return self.fetchAlloc(allocator);
    }
};

fn parseSubjectTokenAlloc(
    allocator: std.mem.Allocator,
    content: []const u8,
    format: SubjectTokenFormat,
) AuthError![]const u8 {
    const token = switch (format) {
        .text => std.mem.trim(u8, content, " \t\r\n"),
        .json => |field_name| {
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return error.InvalidSubjectToken;
            defer parsed.deinit();
            const object = switch (parsed.value) {
                .object => |value| value,
                else => return error.InvalidSubjectToken,
            };
            const field_value = object.get(field_name) orelse return error.InvalidSubjectToken;
            const value = switch (field_value) {
                .string => |text| text,
                else => return error.InvalidSubjectToken,
            };
            if (value.len == 0) return error.InvalidSubjectToken;
            return allocator.dupe(u8, value);
        },
    };
    if (token.len == 0) return error.InvalidSubjectToken;
    return allocator.dupe(u8, token);
}

pub const ExternalAccountTokenSource = struct {
    client: zstd.Http.Client,
    credential: *const ExternalAccount,
    subject_source: SubjectTokenSource,
    scope: []const u8 = cloud_platform_scope,

    pub fn fetchAlloc(self: *ExternalAccountTokenSource, allocator: std.mem.Allocator, now_seconds: u64) AuthError!AccessToken {
        const subject_token = try self.subject_source.fetchAlloc(allocator);
        defer {
            std.crypto.secureZero(u8, @constCast(subject_token));
            allocator.free(subject_token);
        }
        var request = try externalAccountRequestAlloc(allocator, self.credential.*, subject_token, self.scope);
        defer request.deinit(allocator);
        var federated = try exchangeAlloc(self.client, allocator, request.request, now_seconds);
        const impersonation_url = self.credential.service_account_impersonation_url orelse return federated;
        defer federated.deinit(allocator);
        return impersonateServiceAccountAlloc(
            self.client,
            allocator,
            impersonation_url,
            federated.access_token,
            self.scope,
        );
    }

    pub fn tokenSource(self: *ExternalAccountTokenSource) TokenSource {
        return .{ .ptr = self, .fetchFn = fetchErased };
    }

    fn fetchErased(raw: *anyopaque, allocator: std.mem.Allocator, now_seconds: u64) AuthError!AccessToken {
        const self: *ExternalAccountTokenSource = @ptrCast(@alignCast(raw));
        return self.fetchAlloc(allocator, now_seconds);
    }
};

const ImpersonationResponse = struct {
    accessToken: []const u8,
    expireTime: []const u8,
};

fn impersonateServiceAccountAlloc(
    client: zstd.Http.Client,
    allocator: std.mem.Allocator,
    url: []const u8,
    federated_token: []const u8,
    scope: []const u8,
) AuthError!AccessToken {
    const escaped_scope = try zstd.Json.escapeStringAlloc(allocator, scope);
    defer allocator.free(escaped_scope);
    const body = try std.fmt.allocPrint(
        allocator,
        "{{\"scope\":[\"{s}\"],\"lifetime\":\"3600s\"}}",
        .{escaped_scope},
    );
    defer allocator.free(body);
    const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{federated_token});
    defer {
        std.crypto.secureZero(u8, authorization);
        allocator.free(authorization);
    }
    const headers = [_]zstd.Http.Header{
        .{ .name = "content-type", .value = "application/json" },
        .{ .name = "authorization", .value = authorization },
    };
    var response = try client.sendAlloc(allocator, .{
        .method = "POST",
        .url = url,
        .headers = &headers,
        .body = body,
    }, .{});
    defer response.deinit(allocator);
    if (response.status < 200 or response.status >= 300) return error.TokenEndpointRejected;

    var decoded = zstd.Schema.decodeDetailedJsonAlloc(
        allocator,
        zstd.Schema.derive(ImpersonationResponse, .{}),
        response.body,
    ) catch return error.InvalidTokenResponse;
    defer decoded.deinit();
    if (!decoded.ok()) return error.InvalidTokenResponse;
    const value = decoded.value.?;
    const expires_at_seconds = parseRfc3339Seconds(value.expireTime) orelse return error.InvalidTokenResponse;
    return AccessToken.initOwned(allocator, .{
        .access_token = value.accessToken,
        .token_type = "Bearer",
        .expires_at_seconds = expires_at_seconds,
    });
}

fn parseRfc3339Seconds(value: []const u8) ?u64 {
    if (value.len < 20 or value[4] != '-' or value[7] != '-' or value[10] != 'T' or
        value[13] != ':' or value[16] != ':' or value[value.len - 1] != 'Z') return null;
    if (value.len > 20 and value[19] != '.') return null;

    const year = std.fmt.parseInt(u16, value[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, value[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, value[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u8, value[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u8, value[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u8, value[17..19], 10) catch return null;
    if (year < 1970 or month == 0 or month > 12 or day == 0 or
        day > monthDays(year, month) or hour > 23 or minute > 59 or second > 59) return null;
    if (value.len > 20) {
        const fraction = value[20 .. value.len - 1];
        if (fraction.len == 0) return null;
        for (fraction) |byte| if (!std.ascii.isDigit(byte)) return null;
    }

    var days: u64 = 0;
    var cursor_year: u16 = 1970;
    while (cursor_year < year) : (cursor_year += 1) days += if (isLeapYear(cursor_year)) 366 else 365;
    var cursor_month: u8 = 1;
    while (cursor_month < month) : (cursor_month += 1) days += monthDays(year, cursor_month);
    days += day - 1;
    return days * std.time.s_per_day +
        @as(u64, hour) * std.time.s_per_hour +
        @as(u64, minute) * std.time.s_per_min + second;
}

fn monthDays(year: u16, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn isLeapYear(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
}

fn exchangeAlloc(
    client: zstd.Http.Client,
    allocator: std.mem.Allocator,
    request: zstd.Http.Request,
    now_seconds: u64,
) AuthError!AccessToken {
    var response = try client.sendAlloc(allocator, request, .{});
    defer response.deinit(allocator);
    if (response.status < 200 or response.status >= 300) return error.TokenEndpointRejected;
    return parseTokenResponseAlloc(allocator, response.body, now_seconds);
}

pub const TokenCache = struct {
    source: TokenSource,
    refresh_skew_seconds: u64,
    cached: ?AccessToken = null,

    pub fn init(source: TokenSource, refresh_skew_seconds: u64) TokenCache {
        return .{ .source = source, .refresh_skew_seconds = refresh_skew_seconds };
    }

    pub fn deinit(self: *TokenCache, allocator: std.mem.Allocator) void {
        if (self.cached) |*token| token.deinit(allocator);
        self.* = undefined;
    }

    pub fn getAlloc(self: *TokenCache, allocator: std.mem.Allocator, now_seconds: u64) AuthError!AccessToken {
        if (self.cached) |cached| {
            if (cached.expires_at_seconds > now_seconds and
                cached.expires_at_seconds - now_seconds > self.refresh_skew_seconds)
            {
                return cached.clone(allocator);
            }
        }

        var fresh = try self.source.fetchAlloc(allocator, now_seconds);
        errdefer fresh.deinit(allocator);
        const returned = try fresh.clone(allocator);
        if (self.cached) |*cached| cached.deinit(allocator);
        self.cached = fresh;
        return returned;
    }
};
