const std = @import("std");
const config_mod = @import("config.zig");
const firestore = @import("firestore.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");

pub const BuildError = firestore.BuildError || resource.ResourceGraphError || error{
    DuplicateBackupRecurrence,
};

pub const IndexSpec = struct {
    name: []const u8,
    collection_group: []const u8,
    query_scope: firestore.QueryScope = .collection,
    api_scope: firestore.ApiScope = .any_api,
    fields: []const firestore.IndexField,
    density: []const u8 = "",
    multikey: bool = false,
    retain_on_delete: bool = false,
};

pub const FieldSpec = struct {
    collection_group: []const u8,
    field_path: []const u8,
    ttl_enabled: bool = false,
    index_modes: []const firestore.FieldIndexMode = &.{},
    query_scope: firestore.QueryScope = .collection_group,
};

pub const BackupScheduleSpec = struct {
    name: []const u8,
    recurrence: firestore.BackupRecurrence,
    retention_seconds: u64,
    retain_on_delete: bool = false,
};

pub const DocumentStoreArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    database_id: []const u8,
    location: []const u8,
    database_type: firestore.DatabaseType = .firestore_native,
    edition: firestore.DatabaseEdition = .standard,
    concurrency_mode: firestore.ConcurrencyMode = .pessimistic,
    point_in_time_recovery: bool = false,
    delete_protection: bool = true,
    kms_key_name: []const u8 = "",
    realtime_updates_mode: firestore.RealtimeUpdatesMode = .enabled,
    indexes: []const IndexSpec = &.{},
    fields: []const FieldSpec = &.{},
    backup_schedules: []const BackupScheduleSpec = &.{},
    readers: []const []const u8 = &.{},
    writers: []const []const u8 = &.{},
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const DocumentStore = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    database_name: firestore.Database.Outputs.Name.OutputType,
    index_names: []output.Output([]const u8, .public),
    field_names: []output.Output([]const u8, .public),
    backup_schedule_names: []output.Output([]const u8, .public),

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: DocumentStoreArgs) BuildError!DocumentStore {
        try validateSchedules(args.backup_schedules);
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);

        const database_index = graph.resources.items.len;
        var database = try firestore.Database.build(allocator, provider, .{
            .database_id = args.database_id,
            .location = args.location,
            .database_type = args.database_type,
            .edition = args.edition,
            .concurrency_mode = args.concurrency_mode,
            .point_in_time_recovery = args.point_in_time_recovery,
            .delete_protection = args.delete_protection,
            .kms_key_name = args.kms_key_name,
            .realtime_updates_mode = args.realtime_updates_mode,
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
        });
        defer database.deinit(allocator);
        try graph.addResource(database.node);
        const database_resource_id = graph.resources.items[database_index].id;
        const database_name = firestore.Database.Outputs.Name.fromResource(database_resource_id);

        const index_names = try allocator.alloc(output.Output([]const u8, .public), args.indexes.len);
        errdefer allocator.free(index_names);
        for (args.indexes, 0..) |spec, index| {
            const resource_index = graph.resources.items.len;
            var item = try firestore.Index.build(allocator, provider, .{
                .name = spec.name,
                .database = database_name,
                .database_id = args.database_id,
                .collection_group = spec.collection_group,
                .query_scope = spec.query_scope,
                .api_scope = spec.api_scope,
                .fields = spec.fields,
                .density = spec.density,
                .multikey = spec.multikey,
                .retain_on_delete = spec.retain_on_delete,
            });
            defer item.deinit(allocator);
            try graph.addResource(item.node);
            index_names[index] = firestore.Index.Outputs.Name.fromResource(graph.resources.items[resource_index].id);
        }

        const field_names = try allocator.alloc(output.Output([]const u8, .public), args.fields.len);
        errdefer allocator.free(field_names);
        for (args.fields, 0..) |spec, index| {
            const resource_index = graph.resources.items.len;
            var item = try firestore.Field.build(allocator, provider, .{
                .database = database_name,
                .database_id = args.database_id,
                .collection_group = spec.collection_group,
                .field_path = spec.field_path,
                .ttl_enabled = spec.ttl_enabled,
                .index_modes = spec.index_modes,
                .query_scope = spec.query_scope,
            });
            defer item.deinit(allocator);
            try graph.addResource(item.node);
            field_names[index] = firestore.Field.Outputs.Name.fromResource(graph.resources.items[resource_index].id);
        }

        const backup_names = try allocator.alloc(output.Output([]const u8, .public), args.backup_schedules.len);
        errdefer allocator.free(backup_names);
        for (args.backup_schedules, 0..) |spec, index| {
            const resource_index = graph.resources.items.len;
            var item = try firestore.BackupSchedule.build(allocator, provider, .{
                .name = spec.name,
                .database = database_name,
                .database_id = args.database_id,
                .recurrence = spec.recurrence,
                .retention_seconds = spec.retention_seconds,
                .retain_on_delete = spec.retain_on_delete,
            });
            defer item.deinit(allocator);
            try graph.addResource(item.node);
            backup_names[index] = firestore.BackupSchedule.Outputs.Name.fromResource(graph.resources.items[resource_index].id);
        }

        try addMembers(allocator, &graph, provider, args, database_name, args.readers, "reader", "roles/datastore.viewer");
        try addMembers(allocator, &graph, provider, args, database_name, args.writers, "writer", "roles/datastore.user");
        try graph.validateAcyclic();
        return .{
            .allocator = allocator,
            .graph = graph,
            .database_name = firestore.Database.Outputs.Name.fromResource(database_resource_id),
            .index_names = index_names,
            .field_names = field_names,
            .backup_schedule_names = backup_names,
        };
    }

    pub fn deinit(self: *DocumentStore) void {
        self.graph.deinit();
        self.allocator.free(self.index_names);
        self.allocator.free(self.field_names);
        self.allocator.free(self.backup_schedule_names);
        self.* = undefined;
    }
};

fn validateSchedules(schedules: []const BackupScheduleSpec) BuildError!void {
    var daily = false;
    var weekly = false;
    for (schedules) |schedule| switch (schedule.recurrence) {
        .daily => {
            if (daily) return error.DuplicateBackupRecurrence;
            daily = true;
        },
        .weekly => {
            if (weekly) return error.DuplicateBackupRecurrence;
            weekly = true;
        },
    };
}

fn addMembers(
    allocator: std.mem.Allocator,
    graph: *resource.ResourceGraph,
    provider: config_mod.ProviderConfig,
    args: DocumentStoreArgs,
    database_name: output.Output([]const u8, .public),
    members: []const []const u8,
    label: []const u8,
    role: []const u8,
) BuildError!void {
    for (members, 0..) |member, index| {
        const name = try std.fmt.allocPrint(allocator, "{s}-{s}-{d}", .{ args.name, label, index });
        defer allocator.free(name);
        var binding = try firestore.DatabaseIamMember.build(allocator, provider, .{
            .name = name,
            .database = database_name,
            .database_id = args.database_id,
            .role = role,
            .member = member,
        });
        defer binding.deinit(allocator);
        try graph.addResource(binding.node);
    }
}
