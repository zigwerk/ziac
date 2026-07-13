const std = @import("std");
const config_mod = @import("config.zig");
const iam = @import("iam.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const secret_manager = @import("secret_manager.zig");
const sql = @import("sql.zig");
const value = @import("../value.zig");

pub const BuildError = sql.BuildError || iam.BuildError || secret_manager.BuildError || resource.ResourceGraphError || error{
    DuplicateDatabase,
    DuplicateReplica,
    DuplicateUser,
    InvalidIamUser,
    MissingPrivateConnectivityDependency,
};

pub const DatabaseSpec = struct {
    name: []const u8,
    charset: []const u8 = "UTF8",
    collation: []const u8 = "en_US.UTF8",
    retain_on_delete: bool = true,
};

pub const BuiltinUserSpec = struct {
    name: []const u8,
    host: []const u8 = "",
    password: output.Output(value.SecretReference, .secret),
};

pub const IamUserSpec = struct {
    name: []const u8,
    user_type: sql.UserType,
    member: []const u8,
    client: bool = false,
};

pub const ReplicaSpec = struct {
    instance_id: []const u8,
    database_version: ?sql.PostgresVersion = null,
    region: []const u8,
    tier: []const u8,
    edition: sql.Edition = .enterprise,
    disk_type: sql.DiskType = .pd_ssd,
    disk_size_gb: u64 = 20,
    disk_autoresize: bool = true,
    private_network: []const u8 = "",
    ipv4_enabled: bool = false,
    ssl_mode: sql.SslMode = .encrypted_only,
    connector_enforcement: sql.ConnectorEnforcement = .not_required,
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const ClientCertificateSpec = struct {
    common_name: []const u8,
    secret_id: []const u8,
    imported_private_key_version: []const u8 = "",
};

pub const ManagedPostgresArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    primary: sql.InstanceArgs,
    private_connectivity_dependency: ?output.Output([]const u8, .public) = null,
    databases: []const DatabaseSpec = &.{},
    builtin_users: []const BuiltinUserSpec = &.{},
    iam_users: []const IamUserSpec = &.{},
    replicas: []const ReplicaSpec = &.{},
    client_certificate: ?ClientCertificateSpec = null,
};

pub const ManagedPostgres = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    connection_name: sql.Instance.Outputs.ConnectionName.OutputType,
    database_names: []output.Output([]const u8, .public),
    user_names: []output.Output([]const u8, .public),
    replica_connection_names: []output.Output([]const u8, .public),
    client_certificate_private_key: ?output.Output(value.SecretReference, .secret),

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ManagedPostgresArgs) BuildError!ManagedPostgres {
        try validateArgs(args);
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);

        const primary_index = graph.resources.items.len;
        var primary = try sql.Instance.build(allocator, provider, args.primary);
        defer primary.deinit(allocator);
        try graph.addResource(primary.node);
        const primary_id = graph.resources.items[primary_index].id;
        const primary_instance_id = sql.Instance.Outputs.InstanceId.fromResource(primary_id);
        if (args.private_connectivity_dependency) |dependency| try graph.bindOutput(primary_id, dependency);

        const database_names = try allocator.alloc(output.Output([]const u8, .public), args.databases.len);
        errdefer allocator.free(database_names);
        for (args.databases, 0..) |spec, index| {
            const resource_index = graph.resources.items.len;
            var database = try sql.Database.build(allocator, provider, .{
                .instance_id = args.primary.instance_id,
                .name = spec.name,
                .charset = spec.charset,
                .collation = spec.collation,
                .retain_on_delete = spec.retain_on_delete,
            });
            defer database.deinit(allocator);
            try graph.addResource(database.node);
            try graph.addDependency(graph.resources.items[resource_index].id, primary_id);
            database_names[index] = sql.Database.Outputs.Name.fromResource(graph.resources.items[resource_index].id);
        }

        const user_count = args.builtin_users.len + args.iam_users.len;
        const user_names = try allocator.alloc(output.Output([]const u8, .public), user_count);
        errdefer allocator.free(user_names);
        var user_index: usize = 0;
        for (args.builtin_users) |spec| {
            const resource_index = graph.resources.items.len;
            var user = try sql.User.build(allocator, provider, .{
                .instance_id = args.primary.instance_id,
                .name = spec.name,
                .host = spec.host,
                .password = spec.password,
            });
            defer user.deinit(allocator);
            try graph.addResource(user.node);
            try graph.addDependency(graph.resources.items[resource_index].id, primary_id);
            user_names[user_index] = sql.User.Outputs.Name.fromResource(graph.resources.items[resource_index].id);
            user_index += 1;
        }
        for (args.iam_users, 0..) |spec, index| {
            const login_id = try addProjectMember(allocator, &graph, provider, args.name, spec, index, "login", "roles/cloudsql.instanceUser");
            var client_id: ?[]const u8 = null;
            if (spec.client) client_id = try addProjectMember(allocator, &graph, provider, args.name, spec, index, "client", "roles/cloudsql.client");
            const resource_index = graph.resources.items.len;
            var user = try sql.User.build(allocator, provider, .{
                .instance_id = args.primary.instance_id,
                .name = spec.name,
                .user_type = spec.user_type,
            });
            defer user.deinit(allocator);
            try graph.addResource(user.node);
            const user_id = graph.resources.items[resource_index].id;
            try graph.addDependency(user_id, primary_id);
            try graph.addDependency(login_id, user_id);
            if (client_id) |dependent| try graph.addDependency(dependent, user_id);
            user_names[user_index] = sql.User.Outputs.Name.fromResource(user_id);
            user_index += 1;
        }

        const replica_names = try allocator.alloc(output.Output([]const u8, .public), args.replicas.len);
        errdefer allocator.free(replica_names);
        for (args.replicas, 0..) |spec, index| {
            const resource_index = graph.resources.items.len;
            var replica = try sql.ReadReplica.build(allocator, provider, .{
                .instance_id = spec.instance_id,
                .primary_instance_id = primary_instance_id,
                .database_version = spec.database_version orelse args.primary.database_version,
                .region = spec.region,
                .tier = spec.tier,
                .edition = spec.edition,
                .disk_type = spec.disk_type,
                .disk_size_gb = spec.disk_size_gb,
                .disk_autoresize = spec.disk_autoresize,
                .private_network = spec.private_network,
                .ipv4_enabled = spec.ipv4_enabled,
                .ssl_mode = spec.ssl_mode,
                .connector_enforcement = spec.connector_enforcement,
                .protect = spec.protect,
                .retain_on_delete = spec.retain_on_delete,
            });
            defer replica.deinit(allocator);
            try graph.addResource(replica.node);
            const replica_id = graph.resources.items[resource_index].id;
            if (args.private_connectivity_dependency) |dependency| try graph.bindOutput(replica_id, dependency);
            replica_names[index] = sql.Instance.Outputs.ConnectionName.fromResource(replica_id);
        }

        var certificate_private_key: ?output.Output(value.SecretReference, .secret) = null;
        if (args.client_certificate) |spec| {
            const secret_index = graph.resources.items.len;
            var secret = try secret_manager.Secret.build(allocator, provider, .{ .name = spec.secret_id });
            defer secret.deinit(allocator);
            try graph.addResource(secret.node);
            const secret_name = secret_manager.Secret.Outputs.ResourceName.fromResource(graph.resources.items[secret_index].id);
            const certificate_index = graph.resources.items.len;
            var certificate = try sql.ClientCertificate.build(allocator, provider, .{
                .instance_id = args.primary.instance_id,
                .common_name = spec.common_name,
                .private_key_secret = secret_name,
                .imported_private_key_version = spec.imported_private_key_version,
            });
            defer certificate.deinit(allocator);
            try graph.addResource(certificate.node);
            const certificate_id = graph.resources.items[certificate_index].id;
            try graph.addDependency(certificate_id, primary_id);
            certificate_private_key = sql.ClientCertificate.Outputs.PrivateKeyVersion.fromResource(certificate_id);
        }

        try graph.validateAcyclic();
        return .{
            .allocator = allocator,
            .graph = graph,
            .connection_name = sql.Instance.Outputs.ConnectionName.fromResource(primary_id),
            .database_names = database_names,
            .user_names = user_names,
            .replica_connection_names = replica_names,
            .client_certificate_private_key = certificate_private_key,
        };
    }

    pub fn deinit(self: *ManagedPostgres) void {
        self.graph.deinit();
        self.allocator.free(self.database_names);
        self.allocator.free(self.user_names);
        self.allocator.free(self.replica_connection_names);
        self.* = undefined;
    }
};

fn validateArgs(args: ManagedPostgresArgs) BuildError!void {
    if (args.primary.private_network.len > 0 and args.private_connectivity_dependency == null) return error.MissingPrivateConnectivityDependency;
    for (args.databases, 0..) |item, index| for (args.databases[index + 1 ..]) |other| {
        if (std.mem.eql(u8, item.name, other.name)) return error.DuplicateDatabase;
    };
    for (args.replicas, 0..) |item, index| for (args.replicas[index + 1 ..]) |other| {
        if (std.mem.eql(u8, item.instance_id, other.instance_id)) return error.DuplicateReplica;
    };
    for (args.replicas) |item| if (item.private_network.len > 0 and args.private_connectivity_dependency == null) {
        return error.MissingPrivateConnectivityDependency;
    };
    for (args.builtin_users, 0..) |item, index| {
        for (args.builtin_users[index + 1 ..]) |other| if (std.mem.eql(u8, item.name, other.name)) return error.DuplicateUser;
        for (args.iam_users) |other| if (std.mem.eql(u8, item.name, other.name)) return error.DuplicateUser;
    }
    for (args.iam_users, 0..) |item, index| {
        if (item.user_type == .built_in or item.member.len == 0) return error.InvalidIamUser;
        for (args.iam_users[index + 1 ..]) |other| if (std.mem.eql(u8, item.name, other.name)) return error.DuplicateUser;
    }
}

fn addProjectMember(
    allocator: std.mem.Allocator,
    graph: *resource.ResourceGraph,
    provider: config_mod.ProviderConfig,
    component_name: []const u8,
    spec: IamUserSpec,
    index: usize,
    label: []const u8,
    role: []const u8,
) BuildError![]const u8 {
    const name = try std.fmt.allocPrint(allocator, "{s}-{s}-{d}", .{ component_name, label, index });
    defer allocator.free(name);
    var member = try iam.ProjectMember.build(allocator, provider, .{
        .name = name,
        .role = role,
        .member = spec.member,
    });
    defer member.deinit(allocator);
    const resource_index = graph.resources.items.len;
    try graph.addResource(member.node);
    return graph.resources.items[resource_index].id;
}
