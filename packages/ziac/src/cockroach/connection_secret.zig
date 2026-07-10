const std = @import("std");
const config_mod = @import("config.zig");
const existing_cluster = @import("existing_cluster.zig");
const gcp_config = @import("../gcp/config.zig");
const gcp_secret = @import("../gcp/secret_manager.zig");
const output = @import("../output.zig");
const provider = @import("../provider.zig");
const resource = @import("../resource.zig");
const secret = @import("../secret.zig");
const sql_user = @import("sql_user.zig");
const validation = @import("validation.zig");
const value = @import("../value.zig");

pub const PasswordError = std.mem.Allocator.Error || std.Io.RandomSecureError;

pub const Password = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,

    pub fn initOwned(allocator: std.mem.Allocator, bytes: []const u8) std.mem.Allocator.Error!Password {
        return .{ .allocator = allocator, .bytes = try allocator.dupe(u8, bytes) };
    }

    pub fn deinit(self: *Password) void {
        std.crypto.secureZero(u8, self.bytes);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const PasswordSource = struct {
    ptr: *anyopaque,
    generateFn: *const fn (*anyopaque, std.mem.Allocator) PasswordError!Password,

    pub fn generate(self: PasswordSource, allocator: std.mem.Allocator) PasswordError!Password {
        return self.generateFn(self.ptr, allocator);
    }
};

pub const SystemPasswordSource = struct {
    io: std.Io,

    pub fn source(self: *SystemPasswordSource) PasswordSource {
        return .{ .ptr = self, .generateFn = generate };
    }

    fn generate(raw: *anyopaque, allocator: std.mem.Allocator) PasswordError!Password {
        const self: *SystemPasswordSource = @ptrCast(@alignCast(raw));
        var random: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &random);
        try self.io.randomSecure(&random);
        const size = std.base64.url_safe_no_pad.Encoder.calcSize(random.len);
        const encoded = try allocator.alloc(u8, size);
        _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, &random);
        return .{ .allocator = allocator, .bytes = encoded };
    }
};

pub const ConnectionUriArgs = struct {
    host: []const u8,
    port: u16 = 26257,
    database: []const u8,
    username: []const u8,
    password: []const u8,
};

pub fn connectionUriAlloc(allocator: std.mem.Allocator, args: ConnectionUriArgs) ![]u8 {
    if (!isValidHost(args.host) or args.port == 0 or args.database.len == 0 or args.username.len == 0 or args.password.len == 0) {
        return error.InvalidConnection;
    }
    const username = try percentEncodeAlloc(allocator, args.username);
    defer allocator.free(username);
    const password = try percentEncodeAlloc(allocator, args.password);
    defer allocator.free(password);
    const database = try percentEncodeAlloc(allocator, args.database);
    defer allocator.free(database);
    return std.fmt.allocPrint(
        allocator,
        "postgresql://{s}:{s}@{s}:{d}/{s}?sslmode=verify-full",
        .{ username, password, args.host, args.port, database },
    );
}

pub fn passwordFromConnectionUriAlloc(
    allocator: std.mem.Allocator,
    uri: []const u8,
    expected_username: []const u8,
) ![]u8 {
    const prefix = "postgresql://";
    if (!std.mem.startsWith(u8, uri, prefix) or !std.mem.endsWith(u8, uri, "?sslmode=verify-full")) {
        return error.InvalidConnection;
    }
    const authority_start = prefix.len;
    const at = std.mem.indexOfScalarPos(u8, uri, authority_start, '@') orelse return error.InvalidConnection;
    const colon = std.mem.indexOfScalarPos(u8, uri, authority_start, ':') orelse return error.InvalidConnection;
    if (colon >= at) return error.InvalidConnection;
    const username = try percentDecodeAlloc(allocator, uri[authority_start..colon]);
    defer allocator.free(username);
    if (!std.mem.eql(u8, username, expected_username)) return error.InvalidConnection;
    return percentDecodeAlloc(allocator, uri[colon + 1 .. at]);
}

pub const PayloadSpecArgs = struct {
    source_resource: []const u8,
    host: output.Output([]const u8, .public),
    port: u16 = 26257,
    database: []const u8,
    username: []const u8,
};

pub const PayloadSpec = struct {
    allocator: std.mem.Allocator,
    source_resource: []const u8,
    host: output.Output([]const u8, .public),
    port: u16,
    database: []const u8,
    username: []const u8,

    pub fn initOwned(allocator: std.mem.Allocator, args: PayloadSpecArgs) !PayloadSpec {
        const source_resource = try allocator.dupe(u8, args.source_resource);
        errdefer allocator.free(source_resource);
        const host = try cloneHostOutput(allocator, args.host);
        errdefer freeHostOutput(allocator, host);
        const database = try allocator.dupe(u8, args.database);
        errdefer allocator.free(database);
        const username = try allocator.dupe(u8, args.username);
        return .{
            .allocator = allocator,
            .source_resource = source_resource,
            .host = host,
            .port = args.port,
            .database = database,
            .username = username,
        };
    }

    pub fn deinit(self: *PayloadSpec) void {
        self.allocator.free(self.source_resource);
        freeHostOutput(self.allocator, self.host);
        self.allocator.free(self.database);
        self.allocator.free(self.username);
        self.* = undefined;
    }
};

pub const ConnectionPayloadSource = struct {
    spec: *const PayloadSpec,
    password_source: PasswordSource,

    pub fn init(spec: *const PayloadSpec, password_source: PasswordSource) ConnectionPayloadSource {
        return .{ .spec = spec, .password_source = password_source };
    }

    pub fn secretSource(self: *ConnectionPayloadSource) secret.SecretSource {
        return .{ .ptr = self, .resolveFn = resolve };
    }

    fn resolve(
        raw: *anyopaque,
        context: *provider.OperationContext,
        allocator: std.mem.Allocator,
        reference: value.SecretReference,
    ) provider.ProviderError!secret.SecretPayload {
        const self: *ConnectionPayloadSource = @ptrCast(@alignCast(raw));
        if (!std.mem.eql(u8, reference.provider, "ziac-cockroach-connection") or
            !std.mem.eql(u8, reference.resource, self.spec.source_resource) or
            !std.mem.eql(u8, reference.field orelse "", "uri")) return error.NotFound;
        const host = switch (self.spec.host) {
            .value => |known| known,
            .resource_ref => |output_ref| try context.resolveOutputString(.{
                .resource_id = output_ref.resource_id,
                .field = output_ref.field,
            }),
            .unknown_reason => return error.InvalidConfiguration,
        };
        var password = self.password_source.generate(allocator) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Canceled => error.ProviderCancelled,
            error.EntropyUnavailable => error.TransientFailure,
        };
        defer password.deinit();
        const uri = connectionUriAlloc(allocator, .{
            .host = host,
            .port = self.spec.port,
            .database = self.spec.database,
            .username = self.spec.username,
            .password = password.bytes,
        }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidConfiguration,
        };
        return .{ .allocator = allocator, .bytes = uri };
    }
};

pub const ConnectionSecretArgs = struct {
    name: []const u8,
    cluster_id: []const u8,
    plan: existing_cluster.Plan,
    regions: []const []const u8,
    database: []const u8,
    username: []const u8,
    secret_id: []const u8,
    generation: []const u8 = "initial",
    accessor_member: ?[]const u8 = null,
};

pub const BuildError = existing_cluster.BuildError || gcp_secret.BuildError || sql_user.BuildError ||
    resource.ResourceGraphError || std.mem.Allocator.Error || error{InvalidConnection};

pub const ConnectionSecret = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    secret_version: gcp_secret.SecretVersion.Outputs.Version.OutputType,
    payload_spec: PayloadSpec,
    secret_version_resource_id: []const u8,

    pub fn build(
        allocator: std.mem.Allocator,
        google: gcp_config.ProviderConfig,
        cockroach: config_mod.ProviderConfig,
        args: ConnectionSecretArgs,
    ) BuildError!ConnectionSecret {
        if (args.database.len == 0 or args.secret_id.len == 0 or args.generation.len == 0) return error.InvalidConnection;
        try validation.validateUsername(args.username);
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();

        var cluster = try existing_cluster.ExistingCluster.build(allocator, cockroach, .{
            .name = args.name,
            .cluster_id = args.cluster_id,
            .plan = args.plan,
            .regions = args.regions,
        });
        defer cluster.deinit(allocator);
        try graph.addResource(cluster.node);

        var metadata = try gcp_secret.Secret.build(allocator, google, .{ .name = args.secret_id });
        defer metadata.deinit(allocator);
        try graph.addResource(metadata.node);

        const source_resource = try std.fmt.allocPrint(allocator, "cockroach.ConnectionSecret.{s}", .{args.name});
        defer allocator.free(source_resource);
        var version = try gcp_secret.SecretVersion.build(allocator, google, .{
            .name = args.generation,
            .secret_id = args.secret_id,
            .source = .{
                .provider = "ziac-cockroach-connection",
                .resource = source_resource,
                .field = "uri",
            },
            .source_dependencies = &.{cluster.sql_dns},
        });
        defer version.deinit(allocator);
        try graph.addResource(version.node);
        try graph.bindOutput(version.node.id, metadata.resource_name);

        var user = try sql_user.SqlUser.build(allocator, cockroach, .{
            .cluster_id = args.cluster_id,
            .username = args.username,
            .connection_secret = version.version,
        });
        defer user.deinit(allocator);
        try graph.addResource(user.node);
        try graph.bindOutput(user.node.id, cluster.cluster_id);

        if (args.accessor_member) |member| {
            var binding = try gcp_secret.SecretIamMember.build(allocator, google, .{
                .name = args.name,
                .secret_id = args.secret_id,
                .role = "roles/secretmanager.secretAccessor",
                .member = member,
            });
            defer binding.deinit(allocator);
            try graph.addResource(binding.node);
            try graph.bindOutput(binding.node.id, metadata.resource_name);
        }
        try graph.validateAcyclic();

        var payload_spec = try PayloadSpec.initOwned(allocator, .{
            .source_resource = source_resource,
            .host = cluster.sql_dns,
            .database = args.database,
            .username = args.username,
        });
        errdefer payload_spec.deinit();
        const version_resource_id = try allocator.dupe(u8, version.node.id);
        return .{
            .allocator = allocator,
            .graph = graph,
            .secret_version = gcp_secret.SecretVersion.Outputs.Version.fromResource(version_resource_id),
            .payload_spec = payload_spec,
            .secret_version_resource_id = version_resource_id,
        };
    }

    pub fn deinit(self: *ConnectionSecret) void {
        self.graph.deinit();
        self.payload_spec.deinit();
        self.allocator.free(self.secret_version_resource_id);
        self.* = undefined;
    }

    pub fn takeGraph(self: *ConnectionSecret) resource.ResourceGraph {
        const graph = self.graph;
        self.graph = resource.ResourceGraph.init(self.allocator);
        return graph;
    }
};

fn percentEncodeAlloc(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]u8 {
    var output_bytes = std.ArrayList(u8).empty;
    errdefer output_bytes.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (input) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try output_bytes.append(allocator, byte);
        } else {
            try output_bytes.appendSlice(allocator, &.{ '%', hex[byte >> 4], hex[byte & 0x0f] });
        }
    }
    return output_bytes.toOwnedSlice(allocator);
}

fn percentDecodeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output_bytes = std.ArrayList(u8).empty;
    errdefer output_bytes.deinit(allocator);
    var index: usize = 0;
    while (index < input.len) {
        if (input[index] != '%') {
            try output_bytes.append(allocator, input[index]);
            index += 1;
            continue;
        }
        if (index + 2 >= input.len) return error.InvalidConnection;
        const high = std.fmt.charToDigit(input[index + 1], 16) catch return error.InvalidConnection;
        const low = std.fmt.charToDigit(input[index + 2], 16) catch return error.InvalidConnection;
        try output_bytes.append(allocator, @intCast(high * 16 + low));
        index += 3;
    }
    return output_bytes.toOwnedSlice(allocator);
}

fn isValidHost(host: []const u8) bool {
    if (host.len == 0 or host.len > 253 or host[0] == '.' or host[host.len - 1] == '.') return false;
    for (host) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '-' and character != '.') return false;
    }
    return true;
}

fn cloneHostOutput(
    allocator: std.mem.Allocator,
    host: output.Output([]const u8, .public),
) std.mem.Allocator.Error!output.Output([]const u8, .public) {
    return switch (host) {
        .value => |known| .{ .value = try allocator.dupe(u8, known) },
        .resource_ref => |reference| blk: {
            const resource_id = try allocator.dupe(u8, reference.resource_id);
            errdefer allocator.free(resource_id);
            break :blk .{ .resource_ref = .{
                .resource_id = resource_id,
                .field = try allocator.dupe(u8, reference.field),
            } };
        },
        .unknown_reason => |reason| .{ .unknown_reason = try allocator.dupe(u8, reason) },
    };
}

fn freeHostOutput(allocator: std.mem.Allocator, host: output.Output([]const u8, .public)) void {
    switch (host) {
        .value => |known| allocator.free(known),
        .resource_ref => |reference| {
            allocator.free(reference.resource_id);
            allocator.free(reference.field);
        },
        .unknown_reason => |reason| allocator.free(reason),
    }
}
