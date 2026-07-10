const std = @import("std");
const zstd = @import("zigeffect_std");
const auth = @import("auth/root.zig");
const provider = @import("../provider.zig");
const provider_error = @import("../provider_error.zig");

pub const ProviderError = provider_error.ProviderError;
pub const version = "0.1.0-alpha";

pub const Api = enum {
    service_usage,
    iam,
    resource_manager,
    artifact_registry,
    run,
    compute,
    dns,
    secret_manager,
};

pub const Endpoints = struct {
    service_usage: []const u8 = "https://serviceusage.googleapis.com",
    iam: []const u8 = "https://iam.googleapis.com",
    resource_manager: []const u8 = "https://cloudresourcemanager.googleapis.com",
    artifact_registry: []const u8 = "https://artifactregistry.googleapis.com",
    run: []const u8 = "https://run.googleapis.com",
    compute: []const u8 = "https://compute.googleapis.com",
    dns: []const u8 = "https://dns.googleapis.com",
    secret_manager: []const u8 = "https://secretmanager.googleapis.com",

    pub fn get(self: Endpoints, api: Api) []const u8 {
        return switch (api) {
            .service_usage => self.service_usage,
            .iam => self.iam,
            .resource_manager => self.resource_manager,
            .artifact_registry => self.artifact_registry,
            .run => self.run,
            .compute => self.compute,
            .dns => self.dns,
            .secret_manager => self.secret_manager,
        };
    }
};

pub const Request = struct {
    api: ?Api = null,
    method: []const u8,
    path: []const u8,
    body: []const u8 = "",
};

pub const Diagnostic = struct {
    allocator: std.mem.Allocator,
    status: ?u16 = null,
    request_id: ?[]const u8 = null,
    google_status: ?[]const u8 = null,
    message: ?[]const u8 = null,
    retry_after_millis: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator) Diagnostic {
        return .{ .allocator = allocator };
    }

    pub fn clear(self: *Diagnostic) void {
        if (self.request_id) |value| self.allocator.free(value);
        if (self.google_status) |value| self.allocator.free(value);
        if (self.message) |value| self.allocator.free(value);
        self.status = null;
        self.request_id = null;
        self.google_status = null;
        self.message = null;
        self.retry_after_millis = null;
    }

    pub fn deinit(self: *Diagnostic) void {
        self.clear();
        self.* = undefined;
    }
};

pub const Client = struct {
    http: zstd.Http.Client,
    token_cache: *auth.TokenCache,
    endpoints: Endpoints,

    pub fn init(http: zstd.Http.Client, token_cache: *auth.TokenCache, endpoints: Endpoints) Client {
        return .{ .http = http, .token_cache = token_cache, .endpoints = endpoints };
    }

    pub fn requestJsonAlloc(
        self: *Client,
        context: *provider.OperationContext,
        request: Request,
        diagnostic: *Diagnostic,
    ) ProviderError!zstd.Http.Response {
        diagnostic.clear();
        try context.checkActive();
        const now_millis = context.nowMillis();
        var token = self.token_cache.getAlloc(context.allocator, now_millis / std.time.ms_per_s) catch |err| {
            return mapAuthError(err);
        };
        defer token.deinit(context.allocator);

        const url = if (request.api) |api|
            joinUrlAlloc(context.allocator, self.endpoints.get(api), request.path)
        else
            context.allocator.dupe(u8, request.path);
        const owned_url = url catch return error.OutOfMemory;
        defer context.allocator.free(owned_url);
        const authorization = std.fmt.allocPrint(
            context.allocator,
            "{s} {s}",
            .{ token.token_type, token.access_token },
        ) catch return error.OutOfMemory;
        defer {
            std.crypto.secureZero(u8, authorization);
            context.allocator.free(authorization);
        }
        const user_agent = std.fmt.allocPrint(context.allocator, "ziac/{s}", .{version}) catch return error.OutOfMemory;
        defer context.allocator.free(user_agent);
        const headers = [_]zstd.Http.Header{
            .{ .name = "authorization", .value = authorization },
            .{ .name = "accept", .value = "application/json" },
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "user-agent", .value = user_agent },
            .{ .name = "x-goog-api-client", .value = user_agent },
        };
        var send_options = zstd.Http.SendOptions{};
        if (context.cancellation) |cancellation| {
            send_options.cancellation = .{
                .ptr = cancellation.ptr,
                .isCancelledFn = cancellation.isCancelledFn,
            };
        }
        if (context.deadline_millis) |deadline| {
            send_options.request_timeout_millis = deadline -| now_millis;
            if (send_options.request_timeout_millis == 0) return error.ProviderTimeout;
        }

        var response = self.http.sendAlloc(context.allocator, .{
            .method = request.method,
            .url = owned_url,
            .headers = &headers,
            .body = request.body,
        }, send_options) catch |err| return mapHttpError(err);

        captureDiagnostic(diagnostic, response, now_millis / std.time.ms_per_s) catch {
            response.deinit(context.allocator);
            return error.OutOfMemory;
        };
        if (response.status < 200 or response.status >= 300) {
            const err = classifyGoogleError(
                response.status,
                diagnostic.google_status,
                diagnostic.retry_after_millis != null,
            );
            response.deinit(context.allocator);
            return err;
        }
        return response;
    }
};

pub fn classifyGoogleError(status: u16, google_status: ?[]const u8, has_retry_after: bool) ProviderError {
    if (status == 401 or statusNameEquals(google_status, "UNAUTHENTICATED")) return error.AuthenticationFailed;
    if (status == 403 or statusNameEquals(google_status, "PERMISSION_DENIED")) return error.AuthorizationFailed;
    if (status == 404 or statusNameEquals(google_status, "NOT_FOUND")) return error.NotFound;
    if (status == 409 or status == 412 or statusNameEquals(google_status, "ALREADY_EXISTS") or statusNameEquals(google_status, "ABORTED")) return error.Conflict;
    if (status == 429) return if (has_retry_after) error.RateLimited else error.QuotaExceeded;
    if (statusNameEquals(google_status, "RESOURCE_EXHAUSTED")) return if (has_retry_after) error.RateLimited else error.QuotaExceeded;
    if (status == 408 or status == 504 or statusNameEquals(google_status, "DEADLINE_EXCEEDED")) return error.ProviderTimeout;
    if (status >= 500 or statusNameEquals(google_status, "UNAVAILABLE") or statusNameEquals(google_status, "INTERNAL")) return error.TransientFailure;
    if (status >= 400 and status < 500) return error.InvalidConfiguration;
    return error.ProviderBug;
}

fn captureDiagnostic(
    diagnostic: *Diagnostic,
    response: zstd.Http.Response,
    now_seconds: u64,
) std.mem.Allocator.Error!void {
    diagnostic.status = response.status;
    const request_id = response.header("x-request-id") orelse
        response.header("x-goog-request-id") orelse
        response.header("x-guploader-uploadid");
    if (request_id) |value| diagnostic.request_id = try diagnostic.allocator.dupe(u8, value);
    diagnostic.retry_after_millis = response.retryAfterMillis(now_seconds);

    var parsed = std.json.parseFromSlice(std.json.Value, diagnostic.allocator, response.body, .{}) catch return;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return,
    };
    const error_value = root.get("error") orelse return;
    const error_object = switch (error_value) {
        .object => |object| object,
        else => return,
    };
    if (jsonString(error_object.get("status"))) |value| {
        diagnostic.google_status = try diagnostic.allocator.dupe(u8, value);
    }
    if (jsonString(error_object.get("message"))) |value| {
        diagnostic.message = try zstd.Secrets.redactAlloc(diagnostic.allocator, value);
    }
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const present = value orelse return null;
    return switch (present) {
        .string => |text| text,
        else => null,
    };
}

fn statusNameEquals(value: ?[]const u8, expected: []const u8) bool {
    return if (value) |name| std.mem.eql(u8, name, expected) else false;
}

fn joinUrlAlloc(allocator: std.mem.Allocator, base: []const u8, path: []const u8) std.mem.Allocator.Error![]const u8 {
    const base_end = std.mem.trimEnd(u8, base, "/");
    const path_start = std.mem.trimStart(u8, path, "/");
    if (path_start.len == 0) return allocator.dupe(u8, base_end);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_end, path_start });
}

fn mapAuthError(err: auth.AuthError) ProviderError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.RequestCancelled => error.ProviderCancelled,
        error.ConnectTimeout, error.RequestTimeout => error.ProviderTimeout,
        error.TransportFailure => error.TransientFailure,
        else => error.AuthenticationFailed,
    };
}

fn mapHttpError(err: zstd.Http.ClientError) ProviderError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.RequestCancelled => error.ProviderCancelled,
        error.ConnectTimeout, error.RequestTimeout => error.ProviderTimeout,
        error.TransportFailure, error.ScriptExhausted => error.TransientFailure,
        error.ResponseBodyTooLarge, error.UnsupportedHttpMethod => error.ProviderBug,
    };
}
