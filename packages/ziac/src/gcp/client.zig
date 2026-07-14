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
    storage,
    cloud_build,
    cloud_deploy,
    cloud_asset,
    logging,
    cloud_kms,
    cloud_billing,
    bigquery,
    bigquery_connection,
    bigquery_reservation,
    cloud_scheduler,
    pubsub,
    cloud_tasks,
    eventarc,
    firestore,
    redis,
    service_networking,
    spanner,
    sql_admin,
    workflows,
    api_gateway,
    identity_toolkit,
    parameter_manager,
    certificate_manager,
    network_connectivity,
    container,
    gke_hub,
    cloud_functions,
    batch,
    monitoring,
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
    storage: []const u8 = "https://storage.googleapis.com",
    cloud_build: []const u8 = "https://cloudbuild.googleapis.com",
    cloud_deploy: []const u8 = "https://clouddeploy.googleapis.com",
    cloud_asset: []const u8 = "https://cloudasset.googleapis.com",
    logging: []const u8 = "https://logging.googleapis.com",
    cloud_kms: []const u8 = "https://cloudkms.googleapis.com",
    cloud_billing: []const u8 = "https://cloudbilling.googleapis.com",
    bigquery: []const u8 = "https://bigquery.googleapis.com",
    bigquery_connection: []const u8 = "https://bigqueryconnection.googleapis.com",
    bigquery_reservation: []const u8 = "https://bigqueryreservation.googleapis.com",
    cloud_scheduler: []const u8 = "https://cloudscheduler.googleapis.com",
    pubsub: []const u8 = "https://pubsub.googleapis.com",
    cloud_tasks: []const u8 = "https://cloudtasks.googleapis.com",
    eventarc: []const u8 = "https://eventarc.googleapis.com",
    firestore: []const u8 = "https://firestore.googleapis.com",
    redis: []const u8 = "https://redis.googleapis.com",
    service_networking: []const u8 = "https://servicenetworking.googleapis.com",
    spanner: []const u8 = "https://spanner.googleapis.com",
    sql_admin: []const u8 = "https://sqladmin.googleapis.com",
    workflows: []const u8 = "https://workflows.googleapis.com",
    api_gateway: []const u8 = "https://apigateway.googleapis.com",
    identity_toolkit: []const u8 = "https://identitytoolkit.googleapis.com",
    parameter_manager: []const u8 = "https://parametermanager.googleapis.com",
    certificate_manager: []const u8 = "https://certificatemanager.googleapis.com",
    network_connectivity: []const u8 = "https://networkconnectivity.googleapis.com",
    container: []const u8 = "https://container.googleapis.com",
    gke_hub: []const u8 = "https://gkehub.googleapis.com",
    cloud_functions: []const u8 = "https://cloudfunctions.googleapis.com",
    batch: []const u8 = "https://batch.googleapis.com",
    monitoring: []const u8 = "https://monitoring.googleapis.com",

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
            .storage => self.storage,
            .cloud_build => self.cloud_build,
            .cloud_deploy => self.cloud_deploy,
            .cloud_asset => self.cloud_asset,
            .logging => self.logging,
            .cloud_kms => self.cloud_kms,
            .cloud_billing => self.cloud_billing,
            .bigquery => self.bigquery,
            .bigquery_connection => self.bigquery_connection,
            .bigquery_reservation => self.bigquery_reservation,
            .cloud_scheduler => self.cloud_scheduler,
            .pubsub => self.pubsub,
            .cloud_tasks => self.cloud_tasks,
            .eventarc => self.eventarc,
            .firestore => self.firestore,
            .redis => self.redis,
            .service_networking => self.service_networking,
            .spanner => self.spanner,
            .sql_admin => self.sql_admin,
            .workflows => self.workflows,
            .api_gateway => self.api_gateway,
            .identity_toolkit => self.identity_toolkit,
            .parameter_manager => self.parameter_manager,
            .certificate_manager => self.certificate_manager,
            .network_connectivity => self.network_connectivity,
            .container => self.container,
            .gke_hub => self.gke_hub,
            .cloud_functions => self.cloud_functions,
            .batch => self.batch,
            .monitoring => self.monitoring,
        };
    }
};

pub const Request = struct {
    api: ?Api = null,
    method: []const u8,
    path: []const u8,
    body: []const u8 = "",
    content_type: []const u8 = "application/json",
    accept: []const u8 = "application/json",
    headers: []const zstd.Http.Header = &.{},
    response_body_limit: usize = 1024 * 1024,
};

pub const Diagnostic = struct {
    allocator: std.mem.Allocator,
    status: ?u16 = null,
    request_id: ?[]const u8 = null,
    google_status: ?[]const u8 = null,
    message: ?[]const u8 = null,
    retry_after_millis: ?u64 = null,
    service: ?[]const u8 = null,
    quota_metric: ?[]const u8 = null,
    quota_limit: ?[]const u8 = null,
    quota_subject: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator) Diagnostic {
        return .{ .allocator = allocator };
    }

    pub fn clear(self: *Diagnostic) void {
        if (self.request_id) |value| self.allocator.free(value);
        if (self.google_status) |value| self.allocator.free(value);
        if (self.message) |value| self.allocator.free(value);
        if (self.service) |value| self.allocator.free(value);
        if (self.quota_metric) |value| self.allocator.free(value);
        if (self.quota_limit) |value| self.allocator.free(value);
        if (self.quota_subject) |value| self.allocator.free(value);
        self.status = null;
        self.request_id = null;
        self.google_status = null;
        self.message = null;
        self.retry_after_millis = null;
        self.service = null;
        self.quota_metric = null;
        self.quota_limit = null;
        self.quota_subject = null;
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
        const headers = context.allocator.alloc(zstd.Http.Header, 5 + request.headers.len) catch return error.OutOfMemory;
        defer context.allocator.free(headers);
        headers[0] = .{ .name = "authorization", .value = authorization };
        headers[1] = .{ .name = "accept", .value = request.accept };
        headers[2] = .{ .name = "content-type", .value = request.content_type };
        headers[3] = .{ .name = "user-agent", .value = user_agent };
        headers[4] = .{ .name = "x-goog-api-client", .value = user_agent };
        @memcpy(headers[5..], request.headers);
        var send_options = zstd.Http.SendOptions{};
        send_options.response_body_limit = request.response_body_limit;
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
            .headers = headers,
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
            context.recordDiagnostic(.{
                .category = provider_error.category(err),
                .service = diagnostic.service orelse if (request.api) |api| @tagName(api) else null,
                .status = diagnostic.status,
                .google_status = diagnostic.google_status,
                .request_id = diagnostic.request_id,
                .message = diagnostic.message,
                .retry_after_millis = diagnostic.retry_after_millis,
                .quota_metric = diagnostic.quota_metric,
                .quota_limit = diagnostic.quota_limit,
                .quota_subject = diagnostic.quota_subject,
            });
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
        const bounded = value[0..@min(value.len, max_diagnostic_field_bytes)];
        diagnostic.message = try zstd.Secrets.redactAlloc(diagnostic.allocator, bounded);
    }
    try captureQuotaDetails(diagnostic, error_object.get("details"));
}

fn captureQuotaDetails(diagnostic: *Diagnostic, maybe_details: ?std.json.Value) std.mem.Allocator.Error!void {
    const details = jsonArray(maybe_details) orelse return;
    for (details.items) |detail_value| {
        const detail = jsonObject(detail_value) orelse continue;
        const type_name = jsonString(detail.get("@type")) orelse continue;
        if (std.mem.endsWith(u8, type_name, "google.rpc.QuotaInfo")) {
            if (diagnostic.service == null) diagnostic.service = try cloneDiagnosticText(diagnostic.allocator, jsonString(detail.get("service")));
            if (diagnostic.quota_metric == null) diagnostic.quota_metric = try cloneDiagnosticText(diagnostic.allocator, jsonString(detail.get("quotaMetric")));
            if (diagnostic.quota_limit == null) diagnostic.quota_limit = try cloneDiagnosticText(diagnostic.allocator, jsonString(detail.get("quotaId")));
            continue;
        }
        if (!std.mem.endsWith(u8, type_name, "google.rpc.QuotaFailure")) continue;
        const violations = jsonArray(detail.get("violations")) orelse continue;
        if (violations.items.len == 0) continue;
        const violation = jsonObject(violations.items[0]) orelse continue;
        if (diagnostic.quota_subject == null) {
            diagnostic.quota_subject = try cloneDiagnosticText(diagnostic.allocator, jsonString(violation.get("subject")));
        }
    }
}

const max_diagnostic_field_bytes = 512;

fn cloneDiagnosticText(
    allocator: std.mem.Allocator,
    maybe_text: ?[]const u8,
) std.mem.Allocator.Error!?[]const u8 {
    const text = maybe_text orelse return null;
    const owned: []const u8 = try allocator.dupe(u8, text[0..@min(text.len, max_diagnostic_field_bytes)]);
    return owned;
}

fn jsonObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn jsonArray(maybe_value: ?std.json.Value) ?std.json.Array {
    const value = maybe_value orelse return null;
    return switch (value) {
        .array => |array| array,
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
