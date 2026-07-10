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
    delete_protection: ?[]const u8,
    cockroach_version: ?[]const u8,
    cidr_range: ?[]const u8,
    private_network_visibility: ?bool,
    provisioned_virtual_cpus: ?i64,
    request_unit_limit: ?i64,
    storage_mib_limit: ?i64,
    num_virtual_cpus: ?i64,
    storage_gib: ?i64,
    sql_dns: ?[]const u8,
    regions: []const Region,

    pub fn deinit(self: *Cluster, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        if (self.cloud_provider) |value| allocator.free(value);
        if (self.plan) |value| allocator.free(value);
        if (self.state) |value| allocator.free(value);
        if (self.delete_protection) |value| allocator.free(value);
        if (self.cockroach_version) |value| allocator.free(value);
        if (self.cidr_range) |value| allocator.free(value);
        if (self.sql_dns) |value| allocator.free(value);
        for (self.regions) |*region| @constCast(region).deinit(allocator);
        allocator.free(self.regions);
        self.* = undefined;
    }
};

pub const ClusterPlan = enum {
    basic,
    standard,
    advanced,

    pub fn apiName(self: ClusterPlan) []const u8 {
        return switch (self) {
            .basic => "BASIC",
            .standard => "STANDARD",
            .advanced => "ADVANCED",
        };
    }
};

pub const ClusterRegionSpec = struct {
    name: []const u8,
    node_count: i64 = 0,
    primary: bool = false,
};

pub const ManagedClusterSpec = struct {
    name: []const u8,
    plan: ClusterPlan,
    protect: bool,
    regions: []const ClusterRegionSpec,
    provisioned_virtual_cpus: ?i64 = null,
    request_unit_limit: ?i64 = null,
    storage_mib_limit: ?i64 = null,
    num_virtual_cpus: ?i64 = null,
    storage_gib: ?i64 = null,
    cockroach_version: ?[]const u8 = null,
    private_network_visibility: bool = false,
    cidr_range: ?[]const u8 = null,
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

pub const AllowlistEntry = struct {
    cidr_ip: []const u8,
    cidr_mask: u8,
    name: ?[]const u8 = null,
    sql: bool,
    ui: bool,

    pub fn deinit(self: *AllowlistEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.cidr_ip);
        if (self.name) |name| allocator.free(name);
        self.* = undefined;
    }
};

pub fn freeAllowlistEntries(allocator: std.mem.Allocator, entries: []const AllowlistEntry) void {
    for (entries) |*entry| @constCast(entry).deinit(allocator);
    allocator.free(entries);
}

pub const PrivateEndpointServiceStatus = enum {
    creating,
    available,
    create_failed,
    deleting,
    delete_failed,

    pub fn apiName(self: PrivateEndpointServiceStatus) []const u8 {
        return switch (self) {
            .creating => "CREATING",
            .available => "AVAILABLE",
            .create_failed => "CREATE_FAILED",
            .deleting => "DELETING",
            .delete_failed => "DELETE_FAILED",
        };
    }

    fn parse(text: []const u8) ProviderError!PrivateEndpointServiceStatus {
        inline for (std.meta.fields(PrivateEndpointServiceStatus)) |field| {
            const candidate: PrivateEndpointServiceStatus = @enumFromInt(field.value);
            if (std.mem.eql(u8, text, candidate.apiName())) return candidate;
        }
        return error.ProviderBug;
    }
};

pub const PrivateEndpointService = struct {
    availability_zone_ids: []const []const u8,
    cloud_provider: []const u8,
    endpoint_service_id: []const u8,
    name: []const u8,
    region_name: []const u8,
    status: PrivateEndpointServiceStatus,

    pub fn deinit(self: *PrivateEndpointService, allocator: std.mem.Allocator) void {
        for (self.availability_zone_ids) |zone| allocator.free(zone);
        allocator.free(self.availability_zone_ids);
        allocator.free(self.cloud_provider);
        allocator.free(self.endpoint_service_id);
        allocator.free(self.name);
        allocator.free(self.region_name);
        self.* = undefined;
    }
};

pub fn freePrivateEndpointServices(allocator: std.mem.Allocator, services: []const PrivateEndpointService) void {
    for (services) |*service| @constCast(service).deinit(allocator);
    allocator.free(services);
}

pub const PrivateEndpointConnectionStatus = enum {
    pending,
    pending_acceptance,
    available,
    deleting,
    deleted,
    rejected,
    failed,
    expired,
    stale,

    pub fn apiName(self: PrivateEndpointConnectionStatus) []const u8 {
        return switch (self) {
            .pending => "STATUS_PENDING",
            .pending_acceptance => "STATUS_PENDING_ACCEPTANCE",
            .available => "STATUS_AVAILABLE",
            .deleting => "STATUS_DELETING",
            .deleted => "STATUS_DELETED",
            .rejected => "STATUS_REJECTED",
            .failed => "STATUS_FAILED",
            .expired => "STATUS_EXPIRED",
            .stale => "STATUS_STALE",
        };
    }

    fn parse(text: []const u8) ProviderError!PrivateEndpointConnectionStatus {
        inline for (std.meta.fields(PrivateEndpointConnectionStatus)) |field| {
            const candidate: PrivateEndpointConnectionStatus = @enumFromInt(field.value);
            if (std.mem.eql(u8, text, candidate.apiName())) return candidate;
        }
        return error.ProviderBug;
    }
};

pub const PrivateEndpointConnection = struct {
    cloud_provider: []const u8,
    endpoint_id: []const u8,
    endpoint_service_id: []const u8,
    region_name: ?[]const u8,
    service_name: []const u8,
    status: PrivateEndpointConnectionStatus,

    pub fn deinit(self: *PrivateEndpointConnection, allocator: std.mem.Allocator) void {
        allocator.free(self.cloud_provider);
        allocator.free(self.endpoint_id);
        allocator.free(self.endpoint_service_id);
        if (self.region_name) |region| allocator.free(region);
        allocator.free(self.service_name);
        self.* = undefined;
    }
};

pub fn freePrivateEndpointConnections(allocator: std.mem.Allocator, connections: []const PrivateEndpointConnection) void {
    for (connections) |*connection| @constCast(connection).deinit(allocator);
    allocator.free(connections);
}

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

    pub fn createClusterAlloc(
        self: *Client,
        context: *provider.OperationContext,
        spec: ManagedClusterSpec,
        diagnostic: *Diagnostic,
    ) ProviderError!Cluster {
        const body = try clusterMutationBodyAlloc(context.allocator, spec, true);
        defer context.allocator.free(body);
        var response = try self.requestJsonWithRetryAlloc(context, .{
            .method = "POST",
            .path = "/v1/clusters",
            .body = body,
        }, diagnostic);
        defer response.deinit(context.allocator);
        return decodeClusterAlloc(context.allocator, response.body);
    }

    pub fn updateClusterAlloc(
        self: *Client,
        context: *provider.OperationContext,
        cluster_id: []const u8,
        spec: ManagedClusterSpec,
        diagnostic: *Diagnostic,
    ) ProviderError!Cluster {
        const path = try clusterPathAlloc(context.allocator, cluster_id);
        defer context.allocator.free(path);
        const body = try clusterMutationBodyAlloc(context.allocator, spec, false);
        defer context.allocator.free(body);
        var response = try self.requestJsonWithRetryAlloc(context, .{
            .method = "PATCH",
            .path = path,
            .body = body,
        }, diagnostic);
        defer response.deinit(context.allocator);
        return decodeClusterAlloc(context.allocator, response.body);
    }

    pub fn deleteCluster(
        self: *Client,
        context: *provider.OperationContext,
        cluster_id: []const u8,
        diagnostic: *Diagnostic,
    ) ProviderError!void {
        const path = try clusterPathAlloc(context.allocator, cluster_id);
        defer context.allocator.free(path);
        var response = self.requestJsonWithRetryAlloc(context, .{
            .method = "DELETE",
            .path = path,
        }, diagnostic) catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        response.deinit(context.allocator);
    }

    pub fn enablePrivateEndpointServicesAlloc(
        self: *Client,
        context: *provider.OperationContext,
        cluster_id: []const u8,
        diagnostic: *Diagnostic,
    ) ProviderError![]const PrivateEndpointService {
        const path = try privateEndpointCollectionPathAlloc(context.allocator, cluster_id, "services");
        defer context.allocator.free(path);
        var response = try self.requestJsonWithRetryAlloc(context, .{ .method = "POST", .path = path }, diagnostic);
        defer response.deinit(context.allocator);
        return decodePrivateEndpointServicesAlloc(context.allocator, response.body);
    }

    pub fn listPrivateEndpointServicesAlloc(
        self: *Client,
        context: *provider.OperationContext,
        cluster_id: []const u8,
        diagnostic: *Diagnostic,
    ) ProviderError![]const PrivateEndpointService {
        const path = try privateEndpointCollectionPathAlloc(context.allocator, cluster_id, "services");
        defer context.allocator.free(path);
        var response = try self.requestJsonWithRetryAlloc(context, .{ .method = "GET", .path = path }, diagnostic);
        defer response.deinit(context.allocator);
        return decodePrivateEndpointServicesAlloc(context.allocator, response.body);
    }

    pub fn listPrivateEndpointConnectionsAlloc(
        self: *Client,
        context: *provider.OperationContext,
        cluster_id: []const u8,
        diagnostic: *Diagnostic,
    ) ProviderError![]const PrivateEndpointConnection {
        const path = try privateEndpointCollectionPathAlloc(context.allocator, cluster_id, "connections");
        defer context.allocator.free(path);
        var response = try self.requestJsonWithRetryAlloc(context, .{ .method = "GET", .path = path }, diagnostic);
        defer response.deinit(context.allocator);
        return decodePrivateEndpointConnectionsAlloc(context.allocator, response.body);
    }

    pub fn addPrivateEndpointConnection(
        self: *Client,
        context: *provider.OperationContext,
        cluster_id: []const u8,
        endpoint_id: []const u8,
        diagnostic: *Diagnostic,
    ) ProviderError!void {
        if (endpoint_id.len == 0) return error.InvalidConfiguration;
        const path = try privateEndpointCollectionPathAlloc(context.allocator, cluster_id, "connections");
        defer context.allocator.free(path);
        const body = std.json.Stringify.valueAlloc(context.allocator, .{ .endpoint_id = endpoint_id }, .{}) catch return error.OutOfMemory;
        defer context.allocator.free(body);
        var response = try self.requestJsonWithRetryAlloc(context, .{ .method = "POST", .path = path, .body = body }, diagnostic);
        response.deinit(context.allocator);
    }

    pub fn deletePrivateEndpointConnection(
        self: *Client,
        context: *provider.OperationContext,
        cluster_id: []const u8,
        endpoint_id: []const u8,
        diagnostic: *Diagnostic,
    ) ProviderError!void {
        if (endpoint_id.len == 0) return error.InvalidConfiguration;
        const collection = try privateEndpointCollectionPathAlloc(context.allocator, cluster_id, "connections");
        defer context.allocator.free(collection);
        const encoded_endpoint = queryEncodeAlloc(context.allocator, endpoint_id) catch return error.OutOfMemory;
        defer context.allocator.free(encoded_endpoint);
        const path = std.fmt.allocPrint(context.allocator, "{s}/{s}", .{ collection, encoded_endpoint }) catch return error.OutOfMemory;
        defer context.allocator.free(path);
        var response = self.requestJsonWithRetryAlloc(context, .{ .method = "DELETE", .path = path }, diagnostic) catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        response.deinit(context.allocator);
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

    pub fn listAllowlistEntriesAlloc(
        self: *Client,
        context: *provider.OperationContext,
        cluster_id: []const u8,
        diagnostic: *Diagnostic,
    ) ProviderError![]const AllowlistEntry {
        const path = try allowlistCollectionPathAlloc(context.allocator, cluster_id);
        defer context.allocator.free(path);
        var response = try self.requestJsonWithRetryAlloc(context, .{ .method = "GET", .path = path }, diagnostic);
        defer response.deinit(context.allocator);
        return decodeAllowlistAlloc(context.allocator, response.body);
    }

    pub fn putAllowlistEntry(
        self: *Client,
        context: *provider.OperationContext,
        cluster_id: []const u8,
        entry: AllowlistEntry,
        diagnostic: *Diagnostic,
    ) ProviderError!void {
        return self.writeAllowlistEntry(context, cluster_id, entry, "PUT", diagnostic);
    }

    pub fn updateAllowlistEntry(
        self: *Client,
        context: *provider.OperationContext,
        cluster_id: []const u8,
        entry: AllowlistEntry,
        diagnostic: *Diagnostic,
    ) ProviderError!void {
        return self.writeAllowlistEntry(context, cluster_id, entry, "PATCH", diagnostic);
    }

    pub fn deleteAllowlistEntry(
        self: *Client,
        context: *provider.OperationContext,
        cluster_id: []const u8,
        cidr_ip: []const u8,
        cidr_mask: u8,
        diagnostic: *Diagnostic,
    ) ProviderError!void {
        const path = try allowlistEntryPathAlloc(context.allocator, cluster_id, cidr_ip, cidr_mask);
        defer context.allocator.free(path);
        var response = self.requestJsonAlloc(context, .{ .method = "DELETE", .path = path }, diagnostic) catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        response.deinit(context.allocator);
    }

    fn writeAllowlistEntry(
        self: *Client,
        context: *provider.OperationContext,
        cluster_id: []const u8,
        entry: AllowlistEntry,
        method: []const u8,
        diagnostic: *Diagnostic,
    ) ProviderError!void {
        const path = try allowlistEntryPathAlloc(context.allocator, cluster_id, entry.cidr_ip, entry.cidr_mask);
        defer context.allocator.free(path);
        const body = std.json.Stringify.valueAlloc(context.allocator, .{
            .name = entry.name,
            .sql = entry.sql,
            .ui = entry.ui,
        }, .{}) catch return error.OutOfMemory;
        defer context.allocator.free(body);
        var response = try self.requestJsonAlloc(context, .{ .method = method, .path = path, .body = body }, diagnostic);
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

fn clusterMutationBodyAlloc(
    allocator: std.mem.Allocator,
    spec: ManagedClusterSpec,
    create: bool,
) ProviderError![]const u8 {
    if (spec.name.len == 0 or spec.regions.len == 0) return error.InvalidConfiguration;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temp = arena.allocator();

    var spec_object: std.json.ObjectMap = .{};
    try putJson(temp, &spec_object, "plan", .{ .string = spec.plan.apiName() });
    try putJson(temp, &spec_object, "delete_protection", .{ .string = if (spec.protect) "ENABLED" else "DISABLED" });
    switch (spec.plan) {
        .basic, .standard => try putJson(temp, &spec_object, "serverless", try serverlessWireValue(temp, spec, create)),
        .advanced => try putJson(temp, &spec_object, "dedicated", try dedicatedWireValue(temp, spec, create)),
    }
    if (!create) {
        return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = spec_object }, .{}) catch return error.OutOfMemory;
    }

    var root: std.json.ObjectMap = .{};
    try putJson(temp, &root, "name", .{ .string = spec.name });
    try putJson(temp, &root, "provider", .{ .string = "GCP" });
    try putJson(temp, &root, "spec", .{ .object = spec_object });
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = root }, .{}) catch return error.OutOfMemory;
}

fn serverlessWireValue(
    allocator: std.mem.Allocator,
    spec: ManagedClusterSpec,
    create: bool,
) ProviderError!std.json.Value {
    const regions = try sortedClusterRegionsAlloc(allocator, spec.regions);
    var primary_region: ?[]const u8 = null;
    var primary_count: usize = 0;
    var region_values = std.json.Array.init(allocator);
    for (regions) |region| {
        if (region.primary) {
            primary_count += 1;
            primary_region = region.name;
        }
        region_values.append(.{ .string = region.name }) catch return error.OutOfMemory;
    }
    if (primary_count > 1 or (regions.len > 1 and primary_count != 1)) return error.InvalidConfiguration;

    var serverless: std.json.ObjectMap = .{};
    if (regions.len > 1) try putJson(allocator, &serverless, "primary_region", .{ .string = primary_region.? });
    try putJson(allocator, &serverless, "regions", .{ .array = region_values });

    var usage: std.json.ObjectMap = .{};
    switch (spec.plan) {
        .basic => {
            if (spec.request_unit_limit) |limit| try putJson(allocator, &usage, "request_unit_limit", .{ .string = try positiveIntegerStringAlloc(allocator, limit) });
            if (spec.storage_mib_limit) |limit| try putJson(allocator, &usage, "storage_mib_limit", .{ .string = try positiveIntegerStringAlloc(allocator, limit) });
        },
        .standard => {
            const cpus = spec.provisioned_virtual_cpus orelse return error.InvalidConfiguration;
            try putJson(allocator, &usage, "provisioned_virtual_cpus", .{ .string = try positiveIntegerStringAlloc(allocator, cpus) });
        },
        .advanced => unreachable,
    }
    if (usage.count() > 0 or (!create and spec.plan == .basic)) {
        try putJson(allocator, &serverless, "usage_limits", .{ .object = usage });
    }
    if (create) try putJson(allocator, &serverless, "with_empty_ip_allowlist", .{ .bool = true });
    return .{ .object = serverless };
}

fn dedicatedWireValue(
    allocator: std.mem.Allocator,
    spec: ManagedClusterSpec,
    create: bool,
) ProviderError!std.json.Value {
    const cpus = spec.num_virtual_cpus orelse return error.InvalidConfiguration;
    if (cpus <= 0 or cpus > std.math.maxInt(i32)) return error.InvalidConfiguration;
    const regions = try sortedClusterRegionsAlloc(allocator, spec.regions);

    var dedicated: std.json.ObjectMap = .{};
    if (create) {
        if (spec.cidr_range) |cidr| try putJson(allocator, &dedicated, "cidr_range", .{ .string = cidr });
        if (spec.cockroach_version) |version| try putJson(allocator, &dedicated, "cockroach_version", .{ .string = version });
    }
    var hardware: std.json.ObjectMap = .{};
    var machine_spec: std.json.ObjectMap = .{};
    try putJson(allocator, &machine_spec, "num_virtual_cpus", .{ .integer = cpus });
    try putJson(allocator, &hardware, "machine_spec", .{ .object = machine_spec });
    if (spec.storage_gib) |storage| {
        if (storage <= 0 or storage > std.math.maxInt(i32)) return error.InvalidConfiguration;
        try putJson(allocator, &hardware, "storage_gib", .{ .integer = storage });
    } else if (create) {
        try putJson(allocator, &hardware, "storage_gib", .{ .integer = 0 });
    }
    try putJson(allocator, &dedicated, "hardware", .{ .object = hardware });
    if (create and spec.private_network_visibility) try putJson(allocator, &dedicated, "network_visibility", .{ .string = "PRIVATE" });
    var region_nodes: std.json.ObjectMap = .{};
    for (regions) |region| {
        if (region.node_count <= 0 or region.node_count > std.math.maxInt(i32)) return error.InvalidConfiguration;
        try putJson(allocator, &region_nodes, region.name, .{ .integer = region.node_count });
    }
    try putJson(allocator, &dedicated, "region_nodes", .{ .object = region_nodes });
    return .{ .object = dedicated };
}

fn sortedClusterRegionsAlloc(
    allocator: std.mem.Allocator,
    regions: []const ClusterRegionSpec,
) ProviderError![]ClusterRegionSpec {
    const sorted = allocator.dupe(ClusterRegionSpec, regions) catch return error.OutOfMemory;
    std.mem.sort(ClusterRegionSpec, sorted, {}, lessThanClusterRegion);
    for (sorted, 0..) |region, index| {
        if (region.name.len == 0) return error.InvalidConfiguration;
        if (index > 0 and std.mem.eql(u8, sorted[index - 1].name, region.name)) return error.InvalidConfiguration;
    }
    return sorted;
}

fn positiveIntegerStringAlloc(allocator: std.mem.Allocator, number: i64) ProviderError![]const u8 {
    if (number <= 0) return error.InvalidConfiguration;
    return std.fmt.allocPrint(allocator, "{d}", .{number}) catch return error.OutOfMemory;
}

fn putJson(allocator: std.mem.Allocator, map: *std.json.ObjectMap, key: []const u8, item: std.json.Value) ProviderError!void {
    map.put(allocator, key, item) catch return error.OutOfMemory;
}

fn lessThanClusterRegion(_: void, left: ClusterRegionSpec, right: ClusterRegionSpec) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}

const ClusterDecoded = struct {
    id: []const u8,
    name: []const u8,
    cloud_provider: ?[]const u8,
    plan: ?[]const u8,
    state: ?[]const u8,
    delete_protection: ?[]const u8,
    cockroach_version: ?[]const u8,
    cidr_range: ?[]const u8,
    network_visibility: ?[]const u8,
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
    const delete_protection = if (value.delete_protection) |text| allocator.dupe(u8, text) catch return error.OutOfMemory else null;
    errdefer if (delete_protection) |text| allocator.free(text);
    const cockroach_version = if (value.cockroach_version) |text| allocator.dupe(u8, text) catch return error.OutOfMemory else null;
    errdefer if (cockroach_version) |text| allocator.free(text);
    const cidr_range = if (value.cidr_range) |text| allocator.dupe(u8, text) catch return error.OutOfMemory else null;
    errdefer if (cidr_range) |text| allocator.free(text);
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
    const sizing = try decodeClusterSizing(allocator, json);
    return .{
        .id = id,
        .name = name,
        .cloud_provider = cloud_provider,
        .plan = plan,
        .state = state,
        .delete_protection = delete_protection,
        .cockroach_version = cockroach_version,
        .cidr_range = cidr_range,
        .private_network_visibility = if (value.network_visibility) |visibility| std.mem.eql(u8, visibility, "PRIVATE") else null,
        .provisioned_virtual_cpus = sizing.provisioned_virtual_cpus,
        .request_unit_limit = sizing.request_unit_limit,
        .storage_mib_limit = sizing.storage_mib_limit,
        .num_virtual_cpus = sizing.num_virtual_cpus,
        .storage_gib = sizing.storage_gib,
        .sql_dns = sql_dns,
        .regions = regions,
    };
}

const ClusterSizing = struct {
    provisioned_virtual_cpus: ?i64 = null,
    request_unit_limit: ?i64 = null,
    storage_mib_limit: ?i64 = null,
    num_virtual_cpus: ?i64 = null,
    storage_gib: ?i64 = null,
};

fn decodeClusterSizing(allocator: std.mem.Allocator, json: []const u8) ProviderError!ClusterSizing {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const config = jsonObject(root.get("config") orelse return .{}) orelse return error.ProviderBug;
    if (jsonObject(config.get("serverless") orelse .null)) |serverless| {
        if (jsonObject(serverless.get("usage_limits") orelse .null)) |limits| {
            return .{
                .provisioned_virtual_cpus = try jsonOptionalInteger(limits.get("provisioned_virtual_cpus")),
                .request_unit_limit = try jsonOptionalInteger(limits.get("request_unit_limit")),
                .storage_mib_limit = try jsonOptionalInteger(limits.get("storage_mib_limit")),
            };
        }
        return .{};
    }
    if (jsonObject(config.get("dedicated") orelse .null)) |dedicated| {
        return .{
            .num_virtual_cpus = try jsonOptionalInteger(dedicated.get("num_virtual_cpus")),
            .storage_gib = try jsonOptionalInteger(dedicated.get("storage_gib")),
        };
    }
    return .{};
}

fn jsonObject(item: std.json.Value) ?std.json.ObjectMap {
    return switch (item) {
        .object => |object| object,
        else => null,
    };
}

fn jsonOptionalInteger(item: ?std.json.Value) ProviderError!?i64 {
    const value = item orelse return null;
    return switch (value) {
        .integer => |number| number,
        .number_string, .string => |text| std.fmt.parseInt(i64, text, 10) catch return error.ProviderBug,
        .null => null,
        else => error.ProviderBug,
    };
}

const SqlUserDecoded = struct { name: []const u8 };
const PaginationDecoded = struct { next_page: ?[]const u8 };
const SqlUserPageDecoded = struct {
    users: []const SqlUserDecoded,
    pagination: ?PaginationDecoded,
};

const AllowlistEntryDecoded = struct {
    cidr_ip: []const u8,
    cidr_mask: i64,
    name: ?[]const u8,
    sql: bool,
    ui: bool,
};

const AllowlistResponseDecoded = struct {
    allowlist: []const AllowlistEntryDecoded,
    propagating: bool,
};

const PrivateEndpointServiceDecoded = struct {
    availability_zone_ids: []const []const u8,
    cloud_provider: []const u8,
    endpoint_service_id: []const u8,
    name: []const u8,
    region_name: []const u8,
    status: []const u8,
};

const PrivateEndpointServicesDecoded = struct {
    services: []const PrivateEndpointServiceDecoded,
};

const PrivateEndpointConnectionDecoded = struct {
    cloud_provider: []const u8,
    endpoint_id: []const u8,
    endpoint_service_id: []const u8,
    region_name: ?[]const u8,
    service_name: []const u8,
    status: []const u8,
};

const PrivateEndpointConnectionsDecoded = struct {
    connections: []const PrivateEndpointConnectionDecoded,
};

fn decodePrivateEndpointServicesAlloc(allocator: std.mem.Allocator, json: []const u8) ProviderError![]const PrivateEndpointService {
    const service_schema = zstd.Schema.derive(PrivateEndpointServiceDecoded, .{
        .availability_zone_ids = zstd.Schema.array(allocator, zstd.Schema.string()),
    });
    var decoded = zstd.Schema.decodeDetailedJsonAlloc(
        allocator,
        zstd.Schema.derive(PrivateEndpointServicesDecoded, .{
            .services = zstd.Schema.array(allocator, service_schema),
        }),
        json,
    ) catch return error.ProviderBug;
    defer decoded.deinit();
    if (!decoded.ok()) return error.ProviderBug;
    const source = decoded.value.?.services;
    const services = allocator.alloc(PrivateEndpointService, source.len) catch return error.OutOfMemory;
    errdefer allocator.free(services);
    var initialized: usize = 0;
    errdefer for (services[0..initialized]) |*service| service.deinit(allocator);
    for (source, 0..) |service, index| {
        const status = try PrivateEndpointServiceStatus.parse(service.status);
        const zones = allocator.alloc([]const u8, service.availability_zone_ids.len) catch return error.OutOfMemory;
        errdefer allocator.free(zones);
        var initialized_zones: usize = 0;
        errdefer for (zones[0..initialized_zones]) |zone| allocator.free(zone);
        for (service.availability_zone_ids, 0..) |zone, zone_index| {
            zones[zone_index] = allocator.dupe(u8, zone) catch return error.OutOfMemory;
            initialized_zones += 1;
        }
        const cloud_provider = allocator.dupe(u8, service.cloud_provider) catch return error.OutOfMemory;
        errdefer allocator.free(cloud_provider);
        const endpoint_service_id = allocator.dupe(u8, service.endpoint_service_id) catch return error.OutOfMemory;
        errdefer allocator.free(endpoint_service_id);
        const name = allocator.dupe(u8, service.name) catch return error.OutOfMemory;
        errdefer allocator.free(name);
        const region_name = allocator.dupe(u8, service.region_name) catch return error.OutOfMemory;
        services[index] = .{
            .availability_zone_ids = zones,
            .cloud_provider = cloud_provider,
            .endpoint_service_id = endpoint_service_id,
            .name = name,
            .region_name = region_name,
            .status = status,
        };
        initialized += 1;
    }
    return services;
}

fn decodePrivateEndpointConnectionsAlloc(allocator: std.mem.Allocator, json: []const u8) ProviderError![]const PrivateEndpointConnection {
    const connection_schema = zstd.Schema.derive(PrivateEndpointConnectionDecoded, .{
        .region_name = zstd.Schema.optional(zstd.Schema.string()),
    });
    var decoded = zstd.Schema.decodeDetailedJsonAlloc(
        allocator,
        zstd.Schema.derive(PrivateEndpointConnectionsDecoded, .{
            .connections = zstd.Schema.array(allocator, connection_schema),
        }),
        json,
    ) catch return error.ProviderBug;
    defer decoded.deinit();
    if (!decoded.ok()) return error.ProviderBug;
    const source = decoded.value.?.connections;
    const connections = allocator.alloc(PrivateEndpointConnection, source.len) catch return error.OutOfMemory;
    errdefer allocator.free(connections);
    var initialized: usize = 0;
    errdefer for (connections[0..initialized]) |*connection| connection.deinit(allocator);
    for (source, 0..) |connection, index| {
        const status = try PrivateEndpointConnectionStatus.parse(connection.status);
        const cloud_provider = allocator.dupe(u8, connection.cloud_provider) catch return error.OutOfMemory;
        errdefer allocator.free(cloud_provider);
        const endpoint_id = allocator.dupe(u8, connection.endpoint_id) catch return error.OutOfMemory;
        errdefer allocator.free(endpoint_id);
        const endpoint_service_id = allocator.dupe(u8, connection.endpoint_service_id) catch return error.OutOfMemory;
        errdefer allocator.free(endpoint_service_id);
        const region_name = if (connection.region_name) |region| allocator.dupe(u8, region) catch return error.OutOfMemory else null;
        errdefer if (region_name) |region| allocator.free(region);
        const service_name = allocator.dupe(u8, connection.service_name) catch return error.OutOfMemory;
        connections[index] = .{
            .cloud_provider = cloud_provider,
            .endpoint_id = endpoint_id,
            .endpoint_service_id = endpoint_service_id,
            .region_name = region_name,
            .service_name = service_name,
            .status = status,
        };
        initialized += 1;
    }
    return connections;
}

fn decodeAllowlistAlloc(allocator: std.mem.Allocator, json: []const u8) ProviderError![]const AllowlistEntry {
    var decoded = zstd.Schema.decodeDetailedJsonAlloc(
        allocator,
        zstd.Schema.derive(AllowlistResponseDecoded, .{
            .allowlist = zstd.Schema.array(allocator, zstd.Schema.derive(AllowlistEntryDecoded, .{})),
        }),
        json,
    ) catch return error.ProviderBug;
    defer decoded.deinit();
    if (!decoded.ok()) return error.ProviderBug;
    const entries = allocator.alloc(AllowlistEntry, decoded.value.?.allowlist.len) catch return error.OutOfMemory;
    errdefer allocator.free(entries);
    var initialized: usize = 0;
    errdefer for (entries[0..initialized]) |*entry| entry.deinit(allocator);
    for (decoded.value.?.allowlist, 0..) |entry, index| {
        if (entry.cidr_mask < 0 or entry.cidr_mask > 32) return error.ProviderBug;
        const cidr_ip = allocator.dupe(u8, entry.cidr_ip) catch return error.OutOfMemory;
        errdefer allocator.free(cidr_ip);
        const name = if (entry.name) |name| allocator.dupe(u8, name) catch return error.OutOfMemory else null;
        entries[index] = .{
            .cidr_ip = cidr_ip,
            .cidr_mask = @intCast(entry.cidr_mask),
            .name = name,
            .sql = entry.sql,
            .ui = entry.ui,
        };
        initialized += 1;
    }
    return entries;
}

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

fn clusterPathAlloc(allocator: std.mem.Allocator, cluster_id: []const u8) ProviderError![]const u8 {
    const encoded_cluster = queryEncodeAlloc(allocator, cluster_id) catch return error.OutOfMemory;
    defer allocator.free(encoded_cluster);
    return std.fmt.allocPrint(allocator, "/v1/clusters/{s}", .{encoded_cluster}) catch return error.OutOfMemory;
}

fn allowlistCollectionPathAlloc(
    allocator: std.mem.Allocator,
    cluster_id: []const u8,
) ProviderError![]const u8 {
    const encoded_cluster = queryEncodeAlloc(allocator, cluster_id) catch return error.OutOfMemory;
    defer allocator.free(encoded_cluster);
    return std.fmt.allocPrint(
        allocator,
        "/v1/clusters/{s}/networking/allowlist",
        .{encoded_cluster},
    ) catch return error.OutOfMemory;
}

fn privateEndpointCollectionPathAlloc(
    allocator: std.mem.Allocator,
    cluster_id: []const u8,
    kind: []const u8,
) ProviderError![]const u8 {
    if (cluster_id.len == 0) return error.InvalidConfiguration;
    const suffix = if (std.mem.eql(u8, kind, "services"))
        "private-endpoint-services"
    else if (std.mem.eql(u8, kind, "connections"))
        "private-endpoint-connections"
    else
        return error.InvalidConfiguration;
    const encoded_cluster = queryEncodeAlloc(allocator, cluster_id) catch return error.OutOfMemory;
    defer allocator.free(encoded_cluster);
    return std.fmt.allocPrint(
        allocator,
        "/v1/clusters/{s}/networking/{s}",
        .{ encoded_cluster, suffix },
    ) catch return error.OutOfMemory;
}

fn allowlistEntryPathAlloc(
    allocator: std.mem.Allocator,
    cluster_id: []const u8,
    cidr_ip: []const u8,
    cidr_mask: u8,
) ProviderError![]const u8 {
    const collection = try allowlistCollectionPathAlloc(allocator, cluster_id);
    defer allocator.free(collection);
    const encoded_ip = queryEncodeAlloc(allocator, cidr_ip) catch return error.OutOfMemory;
    defer allocator.free(encoded_ip);
    return std.fmt.allocPrint(allocator, "{s}/{s}/{d}", .{ collection, encoded_ip, cidr_mask }) catch return error.OutOfMemory;
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
