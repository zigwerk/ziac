const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    DuplicateHeader,
    InvalidAuthorization,
    InvalidHeader,
    InvalidMember,
    InvalidName,
    InvalidRateLimits,
    InvalidResourceName,
    InvalidRetryConfig,
    InvalidRole,
    InvalidServiceAccount,
    InvalidTarget,
    OutputNotKnown,
};

pub const HttpMethod = enum {
    delete,
    get,
    head,
    post,
    put,
    patch,
    options,

    pub fn apiName(self: HttpMethod) []const u8 {
        return switch (self) {
            .delete => "DELETE",
            .get => "GET",
            .head => "HEAD",
            .post => "POST",
            .put => "PUT",
            .patch => "PATCH",
            .options => "OPTIONS",
        };
    }
};

pub const Scheme = enum {
    unspecified,
    http,
    https,

    pub fn apiName(self: Scheme) []const u8 {
        return switch (self) {
            .unspecified => "SCHEME_UNSPECIFIED",
            .http => "HTTP",
            .https => "HTTPS",
        };
    }
};

pub const EnforceMode = enum {
    unspecified,
    if_not_exists,
    always,

    pub fn apiName(self: EnforceMode) []const u8 {
        return switch (self) {
            .unspecified => "URI_OVERRIDE_ENFORCE_MODE_UNSPECIFIED",
            .if_not_exists => "IF_NOT_EXISTS",
            .always => "ALWAYS",
        };
    }
};

pub const Header = struct {
    key: []const u8,
    value: []const u8,
};

pub const UriOverride = struct {
    scheme: Scheme = .unspecified,
    host: []const u8 = "",
    port: u16 = 0,
    path: []const u8 = "",
    query: []const u8 = "",
    enforce_mode: EnforceMode = .unspecified,
};

pub const OidcToken = struct {
    service_account_email: []const u8,
    audience: []const u8,
};

pub const OAuthToken = struct {
    service_account_email: []const u8,
    scope: []const u8,
};

pub const Authorization = union(enum) {
    none,
    oidc: OidcToken,
    oauth: OAuthToken,
};

pub const HttpTarget = struct {
    uri_override: UriOverride = .{},
    method: ?HttpMethod = null,
    headers: []const Header = &.{},
    authorization: Authorization = .none,
};

pub const RateLimits = struct {
    max_dispatches_per_second: f64 = 500,
    max_concurrent_dispatches: u16 = 1_000,
};

pub const RetryConfig = struct {
    max_attempts: i32 = 100,
    max_retry_duration_seconds: u32 = 0,
    min_backoff_seconds: u32 = 1,
    max_backoff_seconds: u32 = 3_600,
    max_doublings: u8 = 16,
};

pub const QueueArgs = struct {
    name: []const u8,
    location: ?[]const u8 = null,
    rate_limits: RateLimits = .{},
    retry_config: RetryConfig = .{},
    http_target: ?HttpTarget = null,
    logging_sample_ratio: f64 = 0,
    retain_on_delete: bool = true,
};

pub const Queue = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
        pub const PurgeTime = output.Descriptor("purge_time", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    state: Outputs.State.OutputType,
    purge_time: Outputs.PurgeTime.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: QueueArgs) BuildError!Queue {
        try provider.validate();
        try validateId(args.name, 1, 100);
        const location = args.location orelse provider.primary_region;
        try validateLocation(location);
        if (!std.math.isFinite(args.rate_limits.max_dispatches_per_second) or
            args.rate_limits.max_dispatches_per_second <= 0 or args.rate_limits.max_dispatches_per_second > 500 or
            args.rate_limits.max_concurrent_dispatches == 0 or args.rate_limits.max_concurrent_dispatches > 5_000)
        {
            return error.InvalidRateLimits;
        }
        if (args.retry_config.max_attempts < -1 or args.retry_config.max_attempts == 0 or
            args.retry_config.min_backoff_seconds > args.retry_config.max_backoff_seconds)
        {
            return error.InvalidRetryConfig;
        }
        if (!std.math.isFinite(args.logging_sample_ratio) or args.logging_sample_ratio < 0 or args.logging_sample_ratio > 1) {
            return error.InvalidRateLimits;
        }

        const rate = try std.fmt.allocPrint(allocator, "{d}", .{args.rate_limits.max_dispatches_per_second});
        defer allocator.free(rate);
        const sample = try std.fmt.allocPrint(allocator, "{d}", .{args.logging_sample_ratio});
        defer allocator.free(sample);
        var target_enabled = false;
        var target_method: []const u8 = "";
        var target_scheme: []const u8 = "";
        var target_host: []const u8 = "";
        var target_path: []const u8 = "";
        var target_query: []const u8 = "";
        var target_port: i64 = 0;
        var enforce_mode: []const u8 = "";
        var auth_kind: []const u8 = "none";
        var auth_service_account: []const u8 = "";
        var auth_audience_or_scope: []const u8 = "";
        const empty_headers = value.Value{ .object = &.{} };
        var headers = empty_headers;
        defer if (target_enabled) allocator.free(headers.object);
        if (args.http_target) |target| {
            target_enabled = true;
            target_method = if (target.method) |method| method.apiName() else "";
            target_scheme = target.uri_override.scheme.apiName();
            target_host = target.uri_override.host;
            target_path = target.uri_override.path;
            target_query = target.uri_override.query;
            target_port = target.uri_override.port;
            enforce_mode = target.uri_override.enforce_mode.apiName();
            try validateTarget(target);
            headers = try headersValueAlloc(allocator, target.headers);
            switch (target.authorization) {
                .none => {},
                .oidc => |token| {
                    auth_kind = "oidc";
                    auth_service_account = token.service_account_email;
                    auth_audience_or_scope = token.audience;
                    if (!validServiceAccount(token.service_account_email, provider.project_id)) return error.InvalidServiceAccount;
                    if (!validHttpsUrl(token.audience)) return error.InvalidAuthorization;
                },
                .oauth => |token| {
                    auth_kind = "oauth";
                    auth_service_account = token.service_account_email;
                    auth_audience_or_scope = token.scope;
                    if (!validServiceAccount(token.service_account_email, provider.project_id)) return error.InvalidServiceAccount;
                    if (token.scope.len == 0 or std.mem.indexOfAny(u8, token.scope, "\x00\r\n ") != null) return error.InvalidAuthorization;
                },
            }
        }
        const fields = [_]value.Field{
            .{ .name = "authorization_audience_or_scope", .value = .{ .string = auth_audience_or_scope } },
            .{ .name = "authorization_kind", .value = .{ .string = auth_kind } },
            .{ .name = "authorization_service_account", .value = .{ .string = auth_service_account } },
            .{ .name = "http_headers", .value = headers },
            .{ .name = "http_method", .value = .{ .string = target_method } },
            .{ .name = "http_target_enabled", .value = .{ .boolean = target_enabled } },
            .{ .name = "location", .value = .{ .string = location } },
            .{ .name = "logging_sample_ratio", .value = .{ .string = sample } },
            .{ .name = "max_attempts", .value = .{ .integer = args.retry_config.max_attempts } },
            .{ .name = "max_backoff_seconds", .value = .{ .integer = args.retry_config.max_backoff_seconds } },
            .{ .name = "max_concurrent_dispatches", .value = .{ .integer = args.rate_limits.max_concurrent_dispatches } },
            .{ .name = "max_dispatches_per_second", .value = .{ .string = rate } },
            .{ .name = "max_doublings", .value = .{ .integer = args.retry_config.max_doublings } },
            .{ .name = "max_retry_duration_seconds", .value = .{ .integer = args.retry_config.max_retry_duration_seconds } },
            .{ .name = "min_backoff_seconds", .value = .{ .integer = args.retry_config.min_backoff_seconds } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "uri_enforce_mode", .value = .{ .string = enforce_mode } },
            .{ .name = "uri_host", .value = .{ .string = target_host } },
            .{ .name = "uri_path", .value = .{ .string = target_path } },
            .{ .name = "uri_port", .value = .{ .integer = target_port } },
            .{ .name = "uri_query", .value = .{ .string = target_query } },
            .{ .name = "uri_scheme", .value = .{ .string = target_scheme } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.tasks.Queue.{s}.{s}", .{ location, args.name });
        defer allocator.free(id);
        const node = resource.ResourceNode.initOwned(allocator, .{
            .id = id,
            .provider = .gcp,
            .type_name = "gcp.tasks.Queue",
            .logical_id = args.name,
            .inputs = .{ .object = &fields },
            .lifecycle = .{ .retain_on_delete = args.retain_on_delete, .operation_timeout_millis = 15 * 60 * 1000 },
        }) catch |err| switch (err) {
            error.DuplicateField => return error.DuplicateField,
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
        };
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .state = Outputs.State.fromResource(node.id),
            .purge_time = Outputs.PurgeTime.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Queue, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const QueueIamMemberArgs = struct {
    name: []const u8,
    queue: output.Output([]const u8, .public),
    role: []const u8,
    member: []const u8,
};

pub const QueueIamMember = struct {
    node: resource.ResourceNode,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: QueueIamMemberArgs) BuildError!QueueIamMember {
        try provider.validate();
        try validateId(args.name, 1, 100);
        if (!std.mem.startsWith(u8, args.role, "roles/cloudtasks.") or std.mem.indexOfAny(u8, args.role, "\x00\r\n ") != null) return error.InvalidRole;
        if (!validMember(args.member)) return error.InvalidMember;
        const queue = try queueValue(args.queue, provider.project_id);
        const fields = [_]value.Field{
            .{ .name = "member", .value = .{ .string = args.member } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "queue", .value = queue },
            .{ .name = "role", .value = .{ .string = args.role } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.tasks.QueueIamMember.{s}", .{args.name});
        defer allocator.free(id);
        const node = resource.ResourceNode.initOwned(allocator, .{
            .id = id,
            .provider = .gcp,
            .type_name = "gcp.tasks.QueueIamMember",
            .logical_id = args.name,
            .inputs = .{ .object = &fields },
        }) catch |err| switch (err) {
            error.DuplicateField => return error.DuplicateField,
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
        };
        return .{ .node = node };
    }

    pub fn deinit(self: *QueueIamMember, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn validateTarget(target: HttpTarget) BuildError!void {
    const override = target.uri_override;
    if (override.host.len > 0 and (!validHost(override.host) or override.scheme == .unspecified)) return error.InvalidTarget;
    if (override.path.len > 0 and (override.path[0] != '/' or std.mem.indexOfAny(u8, override.path, "\x00\r\n?#") != null)) return error.InvalidTarget;
    if (std.mem.indexOfAny(u8, override.query, "\x00\r\n#") != null) return error.InvalidTarget;
    if (target.authorization != .none and override.scheme != .https) return error.InvalidTarget;
}

fn headersValueAlloc(allocator: std.mem.Allocator, headers: []const Header) BuildError!value.Value {
    const fields = try allocator.alloc(value.Field, headers.len);
    errdefer allocator.free(fields);
    for (headers, 0..) |header, index| {
        if (header.key.len == 0 or header.value.len == 0 or std.mem.indexOfAny(u8, header.key, "\x00\r\n:") != null or
            std.mem.indexOfAny(u8, header.value, "\x00\r\n") != null) return error.InvalidHeader;
        for (fields[0..index]) |existing| if (std.ascii.eqlIgnoreCase(existing.name, header.key)) return error.DuplicateHeader;
        fields[index] = .{ .name = header.key, .value = .{ .string = header.value } };
    }
    return .{ .object = fields };
}

fn queueValue(result: output.Output([]const u8, .public), project_id: []const u8) BuildError!value.Value {
    return switch (result) {
        .value => |known| if (validQueueName(known, project_id)) .{ .string = known } else error.InvalidResourceName,
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn validateId(name: []const u8, minimum: usize, maximum: usize) BuildError!void {
    if (name.len < minimum or name.len > maximum or !std.ascii.isAlphanumeric(name[0])) return error.InvalidName;
    for (name) |character| if (!std.ascii.isAlphanumeric(character) and character != '-') return error.InvalidName;
}

fn validateLocation(location: []const u8) BuildError!void {
    if (location.len < 3 or location.len > 63 or !std.ascii.isLower(location[0])) return error.InvalidName;
    for (location) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return error.InvalidName;
}

fn validQueueName(name: []const u8, project_id: []const u8) bool {
    const prefix = "projects/";
    if (!std.mem.startsWith(u8, name, prefix) or std.mem.indexOfAny(u8, name, "\x00\r\n?#") != null) return false;
    var parts = std.mem.splitScalar(u8, name, '/');
    return std.mem.eql(u8, parts.next() orelse return false, "projects") and
        std.mem.eql(u8, parts.next() orelse return false, project_id) and
        std.mem.eql(u8, parts.next() orelse return false, "locations") and
        (parts.next() orelse return false).len > 0 and
        std.mem.eql(u8, parts.next() orelse return false, "queues") and
        (parts.next() orelse return false).len > 0 and parts.next() == null;
}

fn validHost(host: []const u8) bool {
    return host.len > 0 and std.mem.indexOfAny(u8, host, "\x00\r\n /?#") == null;
}

fn validHttpsUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://") and url.len > "https://".len and std.mem.indexOfAny(u8, url, "\x00\r\n ") == null;
}

fn validServiceAccount(email: []const u8, project_id: []const u8) bool {
    return std.mem.endsWith(u8, email, ".iam.gserviceaccount.com") and std.mem.indexOfScalar(u8, email, '@') != null and
        std.mem.indexOf(u8, email, project_id) != null and std.mem.indexOfAny(u8, email, "\x00\r\n /") == null;
}

fn validMember(member: []const u8) bool {
    return (std.mem.eql(u8, member, "allUsers") or std.mem.eql(u8, member, "allAuthenticatedUsers") or std.mem.indexOfScalar(u8, member, ':') != null) and
        std.mem.indexOfAny(u8, member, "\x00\r\n ") == null;
}
