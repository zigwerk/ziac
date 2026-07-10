const std = @import("std");
const zstd = @import("zigeffect_std");
const provider = @import("../provider.zig");
const provider_error = @import("../provider_error.zig");

pub const api_version = "2024-09-16";
pub const default_base_url = "https://cockroachlabs.cloud/api";
pub const ProviderError = provider_error.ProviderError;

pub const ApiKey = struct {
    value: []const u8,

    pub fn fromEnvAlloc(
        allocator: std.mem.Allocator,
        env: zstd.Env.EnvMap,
        name: []const u8,
    ) (std.mem.Allocator.Error || error{MissingApiKey})!ApiKey {
        const value = env.get(name) orelse return error.MissingApiKey;
        if (value.len == 0) return error.MissingApiKey;
        return .{ .value = try allocator.dupe(u8, value) };
    }

    pub fn deinit(self: *ApiKey, allocator: std.mem.Allocator) void {
        std.crypto.secureZero(u8, @constCast(self.value));
        allocator.free(self.value);
        self.* = undefined;
    }
};

pub const Config = struct {
    base_url: []const u8 = default_base_url,
    version: []const u8 = api_version,
    max_pages: usize = 100,
    max_retries: usize = 3,
    retry_delay_millis: u64 = 250,
};

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    body: []const u8 = "",
};

pub const Diagnostic = struct {
    allocator: std.mem.Allocator,
    status: ?u16 = null,
    request_id: ?[]const u8 = null,
    message: ?[]const u8 = null,
    retry_after_millis: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator) Diagnostic {
        return .{ .allocator = allocator };
    }

    pub fn clear(self: *Diagnostic) void {
        if (self.request_id) |value| self.allocator.free(value);
        if (self.message) |value| self.allocator.free(value);
        self.status = null;
        self.request_id = null;
        self.message = null;
        self.retry_after_millis = null;
    }

    pub fn deinit(self: *Diagnostic) void {
        self.clear();
        self.* = undefined;
    }
};

pub const Cluster = struct {
    id: []const u8,
    name: []const u8,
    cloud_provider: ?[]const u8,
    plan: ?[]const u8,
    state: ?[]const u8,
    sql_dns: ?[]const u8,
    regions: []const Region,

    pub fn deinit(self: *Cluster, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        if (self.cloud_provider) |value| allocator.free(value);
        if (self.plan) |value| allocator.free(value);
        if (self.state) |value| allocator.free(value);
        if (self.sql_dns) |value| allocator.free(value);
        for (self.regions) |*region| @constCast(region).deinit(allocator);
        allocator.free(self.regions);
        self.* = undefined;
    }
};

pub const Region = struct {
    name: []const u8,
    sql_dns: []const u8,
    internal_dns: []const u8,
    private_endpoint_dns: []const u8,
    ui_dns: []const u8,
    node_count: i64,
    primary: ?bool,

    pub fn deinit(self: *Region, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.sql_dns);
        allocator.free(self.internal_dns);
        allocator.free(self.private_endpoint_dns);
        allocator.free(self.ui_dns);
        self.* = undefined;
    }
};

pub const SqlUser = struct {
    name: []const u8,

    pub fn deinit(self: *SqlUser, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.* = undefined;
    }
};

pub fn freeSqlUsers(allocator: std.mem.Allocator, users: []const SqlUser) void {
    for (users) |*user| @constCast(user).deinit(allocator);
    allocator.free(users);
}

pub const Client = struct {
    http: zstd.Http.Client,
    api_key: []const u8,
    config: Config,

    pub fn init(http: zstd.Http.Client, api_key: []const u8, config: Config) Client {
        return .{ .http = http, .api_key = api_key, .config = config };
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
        const url = joinUrlAlloc(context.allocator, self.config.base_url, request.path) catch return error.OutOfMemory;
        defer context.allocator.free(url);
        const authorization = std.fmt.allocPrint(context.allocator, "Bearer {s}", .{self.api_key}) catch return error.OutOfMemory;
        defer {
            std.crypto.secureZero(u8, authorization);
            context.allocator.free(authorization);
        }
        const headers = [_]zstd.Http.Header{
            .{ .name = "authorization", .value = authorization },
            .{ .name = "cc-version", .value = self.config.version },
            .{ .name = "accept", .value = "application/json" },
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "user-agent", .value = "ziac/0.1.0-alpha" },
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
            .url = url,
            .headers = &headers,
            .body = request.body,
        }, send_options) catch |err| return mapHttpError(err);
        captureDiagnostic(diagnostic, response, now_millis / std.time.ms_per_s) catch {
            response.deinit(context.allocator);
            return error.OutOfMemory;
        };
        if (response.status < 200 or response.status >= 300) {
            const err = classifyStatus(response.status);
            response.deinit(context.allocator);
            return err;
        }
        return response;
    }

    pub fn getClusterAlloc(
        self: *Client,
        context: *provider.OperationContext,
        cluster_id: []const u8,
        diagnostic: *Diagnostic,
    ) ProviderError!Cluster {
        const path = std.fmt.allocPrint(context.allocator, "/v1/clusters/{s}", .{cluster_id}) catch return error.OutOfMemory;
        defer context.allocator.free(path);
        var response = try self.requestJsonWithRetryAlloc(context, .{ .method = "GET", .path = path }, diagnostic);
        defer response.deinit(context.allocator);
        return decodeClusterAlloc(context.allocator, response.body);
    }

    pub fn listAllSqlUsersAlloc(
        self: *Client,
        context: *provider.OperationContext,
        cluster_id: []const u8,
        diagnostic: *Diagnostic,
    ) ProviderError![]const SqlUser {
        var users = std.ArrayList(SqlUser).empty;
        errdefer {
            for (users.items) |*user| user.deinit(context.allocator);
            users.deinit(context.allocator);
        }
        var next_page: ?[]const u8 = null;
        defer if (next_page) |value| context.allocator.free(value);
        var page_index: usize = 0;
        while (true) {
            if (page_index >= self.config.max_pages) return error.ProviderBug;
            const path = try sqlUsersPathAlloc(context.allocator, cluster_id, next_page);
            defer context.allocator.free(path);
            var response = try self.requestJsonWithRetryAlloc(context, .{ .method = "GET", .path = path }, diagnostic);
            defer response.deinit(context.allocator);
            var page = try decodeSqlUserPageAlloc(context.allocator, response.body);
            defer page.deinit(context.allocator);
            for (page.users) |user| {
                const name = context.allocator.dupe(u8, user.name) catch return error.OutOfMemory;
                users.append(context.allocator, .{ .name = name }) catch {
                    context.allocator.free(name);
                    return error.OutOfMemory;
                };
            }
            const following = page.next_page orelse break;
            if (following.len == 0) break;
            if (next_page) |current| {
                if (std.mem.eql(u8, current, following)) return error.ProviderBug;
                context.allocator.free(current);
                next_page = null;
            }
            next_page = context.allocator.dupe(u8, following) catch return error.OutOfMemory;
            page_index += 1;
        }
        return users.toOwnedSlice(context.allocator) catch return error.OutOfMemory;
    }

    pub fn createSqlUser(
        self: *Client,
        context: *provider.OperationContext,
        cluster_id: []const u8,
        username: []const u8,
        password: []const u8,
        diagnostic: *Diagnostic,
    ) ProviderError!void {
        const path = try sqlUsersPathAlloc(context.allocator, cluster_id, null);
        defer context.allocator.free(path);
        const body = std.json.Stringify.valueAlloc(context.allocator, .{
            .name = username,
            .password = password,
        }, .{}) catch return error.OutOfMemory;
        defer {
            std.crypto.secureZero(u8, body);
            context.allocator.free(body);
        }
        var response = try self.requestJsonAlloc(context, .{ .method = "POST", .path = path, .body = body }, diagnostic);
        response.deinit(context.allocator);
    }

    pub fn resetSqlUserPassword(
        self: *Client,
        context: *provider.OperationContext,
        cluster_id: []const u8,
        username: []const u8,
        password: []const u8,
        diagnostic: *Diagnostic,
    ) ProviderError!void {
        const path = try sqlUserPathAlloc(context.allocator, cluster_id, username, "/password");
        defer context.allocator.free(path);
        const body = std.json.Stringify.valueAlloc(context.allocator, .{ .password = password }, .{}) catch return error.OutOfMemory;
        defer {
            std.crypto.secureZero(u8, body);
            context.allocator.free(body);
        }
        var response = try self.requestJsonAlloc(context, .{ .method = "PUT", .path = path, .body = body }, diagnostic);
        response.deinit(context.allocator);
    }

    pub fn deleteSqlUser(
        self: *Client,
        context: *provider.OperationContext,
        cluster_id: []const u8,
        username: []const u8,
        diagnostic: *Diagnostic,
    ) ProviderError!void {
        const path = try sqlUserPathAlloc(context.allocator, cluster_id, username, "");
        defer context.allocator.free(path);
        var response = self.requestJsonAlloc(context, .{ .method = "DELETE", .path = path }, diagnostic) catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        response.deinit(context.allocator);
    }

    pub fn requestJsonWithRetryAlloc(
        self: *Client,
        context: *provider.OperationContext,
        request: Request,
        diagnostic: *Diagnostic,
    ) ProviderError!zstd.Http.Response {
        var retries: usize = 0;
        while (true) {
            return self.requestJsonAlloc(context, request, diagnostic) catch |err| {
                if ((err != error.RateLimited and err != error.TransientFailure) or
                    retries >= self.config.max_retries)
                {
                    return err;
                }
                retries += 1;
                context.sleep(diagnostic.retry_after_millis orelse self.config.retry_delay_millis);
                continue;
            };
        }
    }
};

const ClusterDecoded = struct {
    id: []const u8,
    name: []const u8,
    cloud_provider: ?[]const u8,
    plan: ?[]const u8,
    state: ?[]const u8,
    sql_dns: ?[]const u8,
    regions: []const RegionDecoded,
};

const RegionDecoded = struct {
    name: []const u8,
    sql_dns: []const u8,
    internal_dns: []const u8,
    private_endpoint_dns: []const u8,
    ui_dns: []const u8,
    node_count: i64,
    primary: ?bool,
};

fn decodeClusterAlloc(allocator: std.mem.Allocator, json: []const u8) ProviderError!Cluster {
    var decoded = zstd.Schema.decodeDetailedJsonAlloc(
        allocator,
        zstd.Schema.derive(ClusterDecoded, .{
            .regions = zstd.Schema.array(allocator, zstd.Schema.derive(RegionDecoded, .{})),
        }),
        json,
    ) catch return error.ProviderBug;
    defer decoded.deinit();
    if (!decoded.ok()) return error.ProviderBug;
    const value = decoded.value.?;
    const id = allocator.dupe(u8, value.id) catch return error.OutOfMemory;
    errdefer allocator.free(id);
    const name = allocator.dupe(u8, value.name) catch return error.OutOfMemory;
    errdefer allocator.free(name);
    const cloud_provider = if (value.cloud_provider) |text| allocator.dupe(u8, text) catch return error.OutOfMemory else null;
    errdefer if (cloud_provider) |text| allocator.free(text);
    const plan = if (value.plan) |text| allocator.dupe(u8, text) catch return error.OutOfMemory else null;
    errdefer if (plan) |text| allocator.free(text);
    const state = if (value.state) |text| allocator.dupe(u8, text) catch return error.OutOfMemory else null;
    errdefer if (state) |text| allocator.free(text);
    const sql_dns = if (value.sql_dns) |text| allocator.dupe(u8, text) catch return error.OutOfMemory else null;
    errdefer if (sql_dns) |text| allocator.free(text);
    const regions = allocator.alloc(Region, value.regions.len) catch return error.OutOfMemory;
    errdefer allocator.free(regions);
    var initialized: usize = 0;
    errdefer for (regions[0..initialized]) |*region| region.deinit(allocator);
    for (value.regions, 0..) |region, index| {
        const region_name = allocator.dupe(u8, region.name) catch return error.OutOfMemory;
        errdefer allocator.free(region_name);
        const region_sql_dns = allocator.dupe(u8, region.sql_dns) catch return error.OutOfMemory;
        errdefer allocator.free(region_sql_dns);
        const internal_dns = allocator.dupe(u8, region.internal_dns) catch return error.OutOfMemory;
        errdefer allocator.free(internal_dns);
        const private_endpoint_dns = allocator.dupe(u8, region.private_endpoint_dns) catch return error.OutOfMemory;
        errdefer allocator.free(private_endpoint_dns);
        const ui_dns = allocator.dupe(u8, region.ui_dns) catch return error.OutOfMemory;
        regions[index] = .{
            .name = region_name,
            .sql_dns = region_sql_dns,
            .internal_dns = internal_dns,
            .private_endpoint_dns = private_endpoint_dns,
            .ui_dns = ui_dns,
            .node_count = region.node_count,
            .primary = region.primary,
        };
        initialized += 1;
    }
    return .{
        .id = id,
        .name = name,
        .cloud_provider = cloud_provider,
        .plan = plan,
        .state = state,
        .sql_dns = sql_dns,
        .regions = regions,
    };
}

const SqlUserDecoded = struct { name: []const u8 };
const PaginationDecoded = struct { next_page: ?[]const u8 };
const SqlUserPageDecoded = struct {
    users: []const SqlUserDecoded,
    pagination: ?PaginationDecoded,
};

const SqlUserPage = struct {
    users: []const SqlUser,
    next_page: ?[]const u8,

    fn deinit(self: *SqlUserPage, allocator: std.mem.Allocator) void {
        freeSqlUsers(allocator, self.users);
        if (self.next_page) |value| allocator.free(value);
        self.* = undefined;
    }
};

fn decodeSqlUserPageAlloc(allocator: std.mem.Allocator, json: []const u8) ProviderError!SqlUserPage {
    const user_schema = zstd.Schema.derive(SqlUserDecoded, .{});
    const pagination_schema = zstd.Schema.derive(PaginationDecoded, .{});
    var decoded = zstd.Schema.decodeDetailedJsonAlloc(
        allocator,
        zstd.Schema.derive(SqlUserPageDecoded, .{
            .users = zstd.Schema.array(allocator, user_schema),
            .pagination = zstd.Schema.optional(pagination_schema),
        }),
        json,
    ) catch return error.ProviderBug;
    defer decoded.deinit();
    if (!decoded.ok()) return error.ProviderBug;
    const value = decoded.value.?;
    const users = allocator.alloc(SqlUser, value.users.len) catch return error.OutOfMemory;
    errdefer allocator.free(users);
    var initialized: usize = 0;
    errdefer for (users[0..initialized]) |*user| user.deinit(allocator);
    for (value.users, 0..) |user, index| {
        users[index] = .{ .name = allocator.dupe(u8, user.name) catch return error.OutOfMemory };
        initialized += 1;
    }
    const next_page = if (value.pagination) |pagination|
        if (pagination.next_page) |text| allocator.dupe(u8, text) catch return error.OutOfMemory else null
    else
        null;
    return .{ .users = users, .next_page = next_page };
}

fn sqlUsersPathAlloc(
    allocator: std.mem.Allocator,
    cluster_id: []const u8,
    page: ?[]const u8,
) std.mem.Allocator.Error![]const u8 {
    const encoded_cluster = try queryEncodeAlloc(allocator, cluster_id);
    defer allocator.free(encoded_cluster);
    if (page) |token| {
        const encoded = try queryEncodeAlloc(allocator, token);
        defer allocator.free(encoded);
        return std.fmt.allocPrint(allocator, "/v1/clusters/{s}/sql-users?page={s}", .{ encoded_cluster, encoded });
    }
    return std.fmt.allocPrint(allocator, "/v1/clusters/{s}/sql-users", .{encoded_cluster});
}

fn sqlUserPathAlloc(
    allocator: std.mem.Allocator,
    cluster_id: []const u8,
    username: []const u8,
    suffix: []const u8,
) ProviderError![]const u8 {
    const encoded_cluster = queryEncodeAlloc(allocator, cluster_id) catch return error.OutOfMemory;
    defer allocator.free(encoded_cluster);
    const encoded_username = queryEncodeAlloc(allocator, username) catch return error.OutOfMemory;
    defer allocator.free(encoded_username);
    return std.fmt.allocPrint(
        allocator,
        "/v1/clusters/{s}/sql-users/{s}{s}",
        .{ encoded_cluster, encoded_username, suffix },
    ) catch return error.OutOfMemory;
}

fn queryEncodeAlloc(allocator: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try output.append(allocator, byte);
        } else {
            try output.appendSlice(allocator, &.{ '%', hex[byte >> 4], hex[byte & 0x0f] });
        }
    }
    return output.toOwnedSlice(allocator);
}

fn captureDiagnostic(diagnostic: *Diagnostic, response: zstd.Http.Response, now_seconds: u64) std.mem.Allocator.Error!void {
    diagnostic.status = response.status;
    const request_id = response.header("x-request-id") orelse response.header("cf-ray");
    if (request_id) |value| diagnostic.request_id = try diagnostic.allocator.dupe(u8, value);
    diagnostic.retry_after_millis = response.retryAfterMillis(now_seconds);

    var parsed = std.json.parseFromSlice(std.json.Value, diagnostic.allocator, response.body, .{}) catch return;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return,
    };
    const message_value = root.get("message") orelse if (root.get("error")) |error_value| switch (error_value) {
        .object => |object| object.get("message") orelse return,
        else => return,
    } else return;
    const message = switch (message_value) {
        .string => |text| text,
        else => return,
    };
    diagnostic.message = try zstd.Secrets.redactAlloc(diagnostic.allocator, message);
}

fn classifyStatus(status: u16) ProviderError {
    return switch (status) {
        400, 422 => error.InvalidConfiguration,
        401 => error.AuthenticationFailed,
        403 => error.AuthorizationFailed,
        404 => error.NotFound,
        409 => error.Conflict,
        429 => error.RateLimited,
        408, 504 => error.ProviderTimeout,
        500...503, 505...599 => error.TransientFailure,
        else => error.ProviderBug,
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

fn joinUrlAlloc(allocator: std.mem.Allocator, base: []const u8, path: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ std.mem.trimEnd(u8, base, "/"), std.mem.trimStart(u8, path, "/") },
    );
}
