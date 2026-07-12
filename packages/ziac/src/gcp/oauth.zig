const std = @import("std");
const zstd = @import("zigeffect_std");

pub const Config = struct {
    client_id: []const u8,
    client_secret: []const u8,
    token_endpoint: []const u8 = "https://oauth2.googleapis.com/token",
    tokeninfo_endpoint: []const u8 = "https://oauth2.googleapis.com/tokeninfo",
};

pub const ExchangeRequest = struct {
    code: []const u8,
    code_verifier: []const u8,
    redirect_uri: []const u8,
    expected_nonce: []const u8,
    now_seconds: u64,
};

pub const Grant = struct {
    allocator: std.mem.Allocator,
    subject: []u8,
    email: []u8,
    access_token: []u8,
    refresh_token: []u8,
    expires_at_seconds: u64,

    pub fn deinit(self: *Grant) void {
        self.allocator.free(self.subject);
        self.allocator.free(self.email);
        std.crypto.secureZero(u8, self.access_token);
        self.allocator.free(self.access_token);
        std.crypto.secureZero(u8, self.refresh_token);
        self.allocator.free(self.refresh_token);
        self.* = undefined;
    }
};

pub const Exchange = struct {
    ptr: *anyopaque,
    exchange_fn: *const fn (*anyopaque, std.mem.Allocator, ExchangeRequest) anyerror!Grant,

    pub fn exchangeAlloc(self: Exchange, allocator: std.mem.Allocator, request: ExchangeRequest) !Grant {
        return self.exchange_fn(self.ptr, allocator, request);
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    http: zstd.Http.Client,
    client_id: []u8,
    client_secret: []u8,
    token_endpoint: []u8,
    tokeninfo_endpoint: []u8,

    pub fn init(allocator: std.mem.Allocator, http: zstd.Http.Client, config: Config) !Client {
        if (!validClientId(config.client_id) or !validSecret(config.client_secret) or
            !validHttpsUrl(config.token_endpoint) or !validHttpsUrl(config.tokeninfo_endpoint)) return error.InvalidOAuthConfiguration;
        const client_id = try allocator.dupe(u8, config.client_id);
        errdefer allocator.free(client_id);
        const client_secret = try allocator.dupe(u8, config.client_secret);
        errdefer allocator.free(client_secret);
        const token_endpoint = try allocator.dupe(u8, config.token_endpoint);
        errdefer allocator.free(token_endpoint);
        return .{
            .allocator = allocator,
            .http = http,
            .client_id = client_id,
            .client_secret = client_secret,
            .token_endpoint = token_endpoint,
            .tokeninfo_endpoint = try allocator.dupe(u8, config.tokeninfo_endpoint),
        };
    }

    pub fn deinit(self: *Client) void {
        self.allocator.free(self.client_id);
        std.crypto.secureZero(u8, self.client_secret);
        self.allocator.free(self.client_secret);
        self.allocator.free(self.token_endpoint);
        self.allocator.free(self.tokeninfo_endpoint);
        self.* = undefined;
    }

    pub fn exchanger(self: *Client) Exchange {
        return .{ .ptr = self, .exchange_fn = exchangeErased };
    }

    fn exchangeErased(raw: *anyopaque, allocator: std.mem.Allocator, request: ExchangeRequest) !Grant {
        const self: *Client = @ptrCast(@alignCast(raw));
        return self.exchangeAlloc(allocator, request);
    }

    pub fn exchangeAlloc(self: *Client, allocator: std.mem.Allocator, request: ExchangeRequest) !Grant {
        try validateExchange(request);
        const token_body = try formAlloc(allocator, &.{
            .{ .name = "code", .value = request.code },
            .{ .name = "client_id", .value = self.client_id },
            .{ .name = "client_secret", .value = self.client_secret },
            .{ .name = "redirect_uri", .value = request.redirect_uri },
            .{ .name = "grant_type", .value = "authorization_code" },
            .{ .name = "code_verifier", .value = request.code_verifier },
        });
        defer {
            std.crypto.secureZero(u8, token_body);
            allocator.free(token_body);
        }
        var token_response = try self.sendFormAlloc(allocator, self.token_endpoint, token_body);
        defer token_response.deinit(allocator);
        var token_json = std.json.parseFromSlice(std.json.Value, allocator, token_response.body, .{}) catch return error.InvalidOAuthResponse;
        defer token_json.deinit();
        const token_object = jsonObject(token_json.value) orelse return error.InvalidOAuthResponse;
        const access_token_text = jsonString(token_object.get("access_token")) orelse return error.InvalidOAuthResponse;
        const refresh_token_text = jsonString(token_object.get("refresh_token")) orelse return error.InvalidOAuthResponse;
        const id_token_text = jsonString(token_object.get("id_token")) orelse return error.InvalidOAuthResponse;
        const token_type = jsonString(token_object.get("token_type")) orelse return error.InvalidOAuthResponse;
        const expires_in = jsonU64(token_object.get("expires_in")) orelse return error.InvalidOAuthResponse;
        if (!std.mem.eql(u8, token_type, "Bearer") or expires_in == 0 or expires_in > 86_400 or
            !validSecret(access_token_text) or !validSecret(refresh_token_text) or !validSecret(id_token_text)) return error.InvalidOAuthResponse;

        const verify_body = try formAlloc(allocator, &.{.{ .name = "id_token", .value = id_token_text }});
        defer {
            std.crypto.secureZero(u8, verify_body);
            allocator.free(verify_body);
        }
        var verified_response = try self.sendFormAlloc(allocator, self.tokeninfo_endpoint, verify_body);
        defer verified_response.deinit(allocator);
        var verified_json = std.json.parseFromSlice(std.json.Value, allocator, verified_response.body, .{}) catch return error.InvalidOidcIdentity;
        defer verified_json.deinit();
        const identity = jsonObject(verified_json.value) orelse return error.InvalidOidcIdentity;
        const audience = jsonString(identity.get("aud")) orelse return error.InvalidOidcIdentity;
        const issuer = jsonString(identity.get("iss")) orelse return error.InvalidOidcIdentity;
        const subject = jsonString(identity.get("sub")) orelse return error.InvalidOidcIdentity;
        const email = jsonString(identity.get("email")) orelse return error.InvalidOidcIdentity;
        const nonce = jsonString(identity.get("nonce")) orelse return error.InvalidOidcIdentity;
        const expires_at = jsonU64(identity.get("exp")) orelse return error.InvalidOidcIdentity;
        const email_verified = jsonBool(identity.get("email_verified")) orelse return error.InvalidOidcIdentity;
        if (!std.mem.eql(u8, audience, self.client_id) or
            !(std.mem.eql(u8, issuer, "accounts.google.com") or std.mem.eql(u8, issuer, "https://accounts.google.com")) or
            !std.mem.eql(u8, nonce, request.expected_nonce) or !email_verified or expires_at <= request.now_seconds or
            !validSubject(subject) or !validEmail(email)) return error.InvalidOidcIdentity;

        const owned_subject = try allocator.dupe(u8, subject);
        errdefer allocator.free(owned_subject);
        const owned_email = try allocator.dupe(u8, email);
        errdefer allocator.free(owned_email);
        const access_token = try allocator.dupe(u8, access_token_text);
        errdefer {
            std.crypto.secureZero(u8, access_token);
            allocator.free(access_token);
        }
        const refresh_token = try allocator.dupe(u8, refresh_token_text);
        return .{
            .allocator = allocator,
            .subject = owned_subject,
            .email = owned_email,
            .access_token = access_token,
            .refresh_token = refresh_token,
            .expires_at_seconds = request.now_seconds + expires_in,
        };
    }

    fn sendFormAlloc(self: *Client, allocator: std.mem.Allocator, url: []const u8, body: []const u8) !zstd.Http.Response {
        const headers = [_]zstd.Http.Header{
            .{ .name = "accept", .value = "application/json" },
            .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
        };
        var response = try self.http.sendAlloc(allocator, .{
            .method = "POST",
            .url = url,
            .headers = &headers,
            .body = body,
        }, .{ .response_body_limit = 64 * 1024 });
        if (response.status < 200 or response.status >= 300) {
            response.deinit(allocator);
            return error.OAuthExchangeFailed;
        }
        return response;
    }
};

fn validateExchange(request: ExchangeRequest) !void {
    if (!validSecret(request.code) or request.code_verifier.len < 43 or request.code_verifier.len > 128 or
        !validLoopbackRedirect(request.redirect_uri) or !validOpaque(request.expected_nonce) or request.now_seconds == 0)
    {
        return error.InvalidOAuthExchange;
    }
}

const FormField = struct { name: []const u8, value: []const u8 };

fn formAlloc(allocator: std.mem.Allocator, fields: []const FormField) ![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    for (fields, 0..) |field, index| {
        if (index != 0) try output.append(allocator, '&');
        try appendEncoded(&output, allocator, field.name);
        try output.append(allocator, '=');
        try appendEncoded(&output, allocator, field.value);
    }
    return output.toOwnedSlice(allocator);
}

fn appendEncoded(output: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (input) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try output.append(allocator, byte);
        } else {
            try output.appendSlice(allocator, &.{ '%', hex[byte >> 4], hex[byte & 0x0f] });
        }
    }
}

fn validClientId(value: []const u8) bool {
    return value.len >= 16 and value.len <= 512 and std.mem.endsWith(u8, value, ".apps.googleusercontent.com") and std.mem.indexOfScalar(u8, value, 0) == null;
}

fn validHttpsUrl(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "https://") and value.len <= 2048 and std.mem.indexOfAny(u8, value, "\x00\r\n") == null;
}

fn validSecret(value: []const u8) bool {
    return value.len >= 8 and value.len <= 16 * 1024 and std.mem.indexOfAny(u8, value, "\x00\r\n") == null;
}

fn validOpaque(value: []const u8) bool {
    return value.len >= 8 and value.len <= 512 and std.mem.indexOfAny(u8, value, "\x00\r\n") == null;
}

fn validLoopbackRedirect(value: []const u8) bool {
    return (std.mem.startsWith(u8, value, "http://127.0.0.1:") or std.mem.startsWith(u8, value, "http://[::1]:")) and
        std.mem.endsWith(u8, value, "/oauth/callback") and value.len <= 256;
}

fn validSubject(value: []const u8) bool {
    return value.len >= 3 and value.len <= 512 and std.mem.indexOfAny(u8, value, "\x00\r\n") == null;
}

fn validEmail(value: []const u8) bool {
    return value.len >= 3 and value.len <= 320 and std.mem.indexOfScalar(u8, value, '@') != null and std.mem.indexOfAny(u8, value, "\x00\r\n") == null;
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

fn jsonU64(value: ?std.json.Value) ?u64 {
    const present = value orelse return null;
    return switch (present) {
        .integer => |number| std.math.cast(u64, number),
        else => null,
    };
}

fn jsonBool(value: ?std.json.Value) ?bool {
    const present = value orelse return null;
    return switch (present) {
        .bool => |boolean| boolean,
        else => null,
    };
}
