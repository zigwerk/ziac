const std = @import("std");
const config_mod = @import("config.zig");
const connection_secret = @import("connection_secret.zig");
const database_mod = @import("database.zig");
const existing_cluster = @import("existing_cluster.zig");
const gcp_config = @import("../gcp/config.zig");
const grants_mod = @import("grants.zig");
const migration_mod = @import("migration.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const ApplicationDatabaseArgs = struct {
    name: []const u8,
    cluster_id: []const u8,
    plan: existing_cluster.Plan,
    regions: []const []const u8,
    database: []const u8,
    username: []const u8,
    secret_id: []const u8,
    generation: []const u8 = "initial",
    accessor_member: ?[]const u8 = null,
    admin_connection: value.SecretReference,
    privileges: []const grants_mod.Privilege = &.{.all},
    migrations: []const migration_mod.Spec = &.{},
    migration_table: []const u8 = "ziac_migrations",
    protect_database: bool = true,
};

pub const BuildError = connection_secret.BuildError || database_mod.BuildError || grants_mod.BuildError ||
    migration_mod.BuildError || resource.ResourceGraphError || error{InvalidAdminConnection};

pub fn validateAdminConnection(reference: value.SecretReference) error{InvalidAdminConnection}!void {
    if (!std.mem.eql(u8, reference.provider, "gcp-secret-manager") or reference.field != null) {
        return error.InvalidAdminConnection;
    }
    var parts = std.mem.splitScalar(u8, reference.resource, '/');
    if (!std.mem.eql(u8, parts.next() orelse return error.InvalidAdminConnection, "projects") or
        !validSecretNamePart(parts.next() orelse return error.InvalidAdminConnection) or
        !std.mem.eql(u8, parts.next() orelse return error.InvalidAdminConnection, "secrets") or
        !validSecretNamePart(parts.next() orelse return error.InvalidAdminConnection) or
        parts.next() != null)
    {
        return error.InvalidAdminConnection;
    }
    const version = reference.version orelse return error.InvalidAdminConnection;
    if (version.len == 0) return error.InvalidAdminConnection;
    for (version) |character| if (!std.ascii.isDigit(character)) return error.InvalidAdminConnection;
}

pub const ApplicationDatabase = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    connection: connection_secret.ConnectionSecret,
    connection_secret: output.Output(value.SecretReference, .secret),
    database_name: output.Output([]const u8, .public),
    last_migration: ?output.Output([]const u8, .public),

    pub fn build(
        allocator: std.mem.Allocator,
        google: gcp_config.ProviderConfig,
        cockroach: config_mod.ProviderConfig,
        args: ApplicationDatabaseArgs,
    ) BuildError!ApplicationDatabase {
        try validateAdminConnection(args.admin_connection);
        var connection = try connection_secret.ConnectionSecret.build(allocator, google, cockroach, .{
            .name = args.name,
            .cluster_id = args.cluster_id,
            .plan = args.plan,
            .regions = args.regions,
            .database = args.database,
            .username = args.username,
            .secret_id = args.secret_id,
            .generation = args.generation,
            .accessor_member = args.accessor_member,
        });
        errdefer connection.deinit();

        var graph = connection.takeGraph();
        errdefer graph.deinit();
        const admin_connection = output.Output(value.SecretReference, .secret).known(args.admin_connection);

        var database = try database_mod.Database.build(allocator, cockroach, .{
            .cluster_id = args.cluster_id,
            .name = args.database,
            .connection_secret = admin_connection,
            .protect = args.protect_database,
        });
        defer database.deinit(allocator);
        try graph.addResource(database.node);
        try graph.bindOutput(database.node.id, connection.cluster_id);
        const database_name = database_mod.Database.Outputs.Name.fromResource(
            graph.resources.items[graph.resources.items.len - 1].id,
        );

        var grants = try grants_mod.Grants.build(allocator, cockroach, .{
            .cluster_id = args.cluster_id,
            .database = args.database,
            .grantee = args.username,
            .privileges = args.privileges,
            .connection_secret = admin_connection,
        });
        defer grants.deinit(allocator);
        try graph.addResource(grants.node);
        try graph.bindOutput(grants.node.id, database_name);
        try graph.bindOutput(grants.node.id, connection.sql_user);

        var previous: ?output.Output([]const u8, .public) = null;
        for (args.migrations, 0..) |spec, index| {
            if (index > 0 and !std.mem.lessThan(u8, args.migrations[index - 1].id, spec.id)) {
                return error.MigrationsOutOfOrder;
            }
            var migration = try migration_mod.Migration.build(allocator, cockroach, .{
                .cluster_id = args.cluster_id,
                .database = args.database,
                .id = spec.id,
                .sql_text = spec.sql,
                .connection_secret = connection.secret_version,
                .previous = previous,
                .table = args.migration_table,
            });
            defer migration.deinit(allocator);
            try graph.addResource(migration.node);
            if (index == 0) {
                try graph.bindOutput(migration.node.id, database_name);
                try graph.bindOutput(migration.node.id, grants.grantee);
            }
            const stored_id = graph.resources.items[graph.resources.items.len - 1].id;
            previous = migration_mod.Migration.Outputs.AppliedId.fromResource(stored_id);
        }

        try graph.validateAcyclic();
        return .{
            .allocator = allocator,
            .graph = graph,
            .connection = connection,
            .connection_secret = connection.secret_version,
            .database_name = database_name,
            .last_migration = previous,
        };
    }

    pub fn deinit(self: *ApplicationDatabase) void {
        self.graph.deinit();
        self.connection.deinit();
        self.* = undefined;
    }

    pub fn payloadSpec(self: *const ApplicationDatabase) *const connection_secret.PayloadSpec {
        return &self.connection.payload_spec;
    }

    pub fn takeGraph(self: *ApplicationDatabase) resource.ResourceGraph {
        const graph = self.graph;
        self.graph = resource.ResourceGraph.init(self.allocator);
        return graph;
    }
};

fn validSecretNamePart(part: []const u8) bool {
    if (part.len == 0) return false;
    for (part) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '-' and character != '_') return false;
    }
    return true;
}
