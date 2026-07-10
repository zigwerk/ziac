const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const sql = @import("sql.zig");
const validation = @import("validation.zig");
const value = @import("../value.zig");

pub const Spec = struct {
    id: []const u8,
    sql: []const u8,
};

pub const MigrationArgs = struct {
    cluster_id: []const u8,
    database: []const u8,
    id: []const u8,
    sql_text: []const u8,
    connection_secret: output.Output(value.SecretReference, .secret),
    previous: ?output.Output([]const u8, .public) = null,
    table: []const u8 = "ziac_migrations",
};

pub const BuildError = config_mod.ValidationError || validation.ValidationError || sql.SqlTextError ||
    resource.ResourceGraphError || std.mem.Allocator.Error || error{
    DuplicateField,
    EmptyMigration,
    MigrationsOutOfOrder,
    OutputNotKnown,
    SecretNotKnown,
};

pub const Migration = struct {
    pub const Outputs = struct {
        pub const AppliedId = output.Descriptor("applied_id", []const u8, .public);
    };

    node: resource.ResourceNode,
    applied_id: Outputs.AppliedId.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: MigrationArgs) BuildError!Migration {
        try provider.validate();
        try validation.validateClusterId(args.cluster_id);
        try sql.validateIdentifier(args.database);
        try sql.validateIdentifier(args.table);
        if (args.id.len == 0 or args.sql_text.len == 0 or std.mem.indexOfScalar(u8, args.id, 0) != null or
            !std.unicode.utf8ValidateSlice(args.id)) return error.EmptyMigration;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(args.sql_text, &digest, .{});
        const checksum = std.fmt.bytesToHex(digest, .lower);
        const previous_value: value.Value = if (args.previous) |previous| switch (previous) {
            .value => |known| .{ .string = known },
            .resource_ref => |reference| .{ .output_ref = .{
                .resource_id = reference.resource_id,
                .field = reference.field,
            } },
            .unknown_reason => return error.OutputNotKnown,
        } else .{ .string = "" };
        const fields = [_]value.Field{
            .{ .name = "checksum", .value = .{ .string = &checksum } },
            .{ .name = "cluster_id", .value = .{ .string = args.cluster_id } },
            .{ .name = "connection_secret", .value = try sql.connectionInput(args.connection_secret) },
            .{ .name = "database", .value = .{ .string = args.database } },
            .{ .name = "id", .value = .{ .string = args.id } },
            .{ .name = "previous", .value = previous_value },
            .{ .name = "sql", .value = .{ .string = args.sql_text } },
            .{ .name = "table", .value = .{ .string = args.table } },
        };
        const id = try std.fmt.allocPrint(allocator, "cockroach.Migration.{s}.{s}.{s}", .{ args.cluster_id, args.database, args.id });
        defer allocator.free(id);
        const node = resource.ResourceNode.initOwned(allocator, .{
            .id = id,
            .provider = .cockroach,
            .type_name = "cockroach.Migration",
            .logical_id = args.id,
            .inputs = .{ .object = &fields },
            .lifecycle = .{ .retain_on_delete = true },
        }) catch |err| switch (err) {
            error.DuplicateField => return error.DuplicateField,
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
        };
        return .{ .node = node, .applied_id = Outputs.AppliedId.fromResource(node.id) };
    }

    pub fn deinit(self: *Migration, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const MigrationsArgs = struct {
    cluster_id: []const u8,
    database: []const u8,
    connection_secret: output.Output(value.SecretReference, .secret),
    migrations: []const Spec,
    table: []const u8 = "ziac_migrations",
};

pub const Migrations = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    last_applied: ?output.Output([]const u8, .public),

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: MigrationsArgs) BuildError!Migrations {
        if (args.migrations.len == 0) return error.EmptyMigration;
        for (args.migrations[1..], args.migrations[0 .. args.migrations.len - 1]) |current, previous| {
            if (!std.mem.lessThan(u8, previous.id, current.id)) return error.MigrationsOutOfOrder;
        }
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        var previous_output: ?output.Output([]const u8, .public) = null;
        for (args.migrations) |spec| {
            var migration = try Migration.build(allocator, provider, .{
                .cluster_id = args.cluster_id,
                .database = args.database,
                .id = spec.id,
                .sql_text = spec.sql,
                .connection_secret = args.connection_secret,
                .previous = previous_output,
                .table = args.table,
            });
            defer migration.deinit(allocator);
            try graph.addResource(migration.node);
            const stored_id = graph.resources.items[graph.resources.items.len - 1].id;
            previous_output = Migration.Outputs.AppliedId.fromResource(stored_id);
        }
        try graph.validateAcyclic();
        return .{ .allocator = allocator, .graph = graph, .last_applied = previous_output };
    }

    pub fn deinit(self: *Migrations) void {
        self.graph.deinit();
        self.* = undefined;
    }

    pub fn takeGraph(self: *Migrations) resource.ResourceGraph {
        const graph = self.graph;
        self.graph = resource.ResourceGraph.init(self.allocator);
        return graph;
    }
};
