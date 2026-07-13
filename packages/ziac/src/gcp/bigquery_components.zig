const std = @import("std");
const bigquery = @import("bigquery.zig");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");

pub const BuildError = bigquery.BuildError || resource.ResourceGraphError || error{DuplicateWarehouseObject};

pub const TableSpec = struct {
    table_id: []const u8,
    friendly_name: []const u8 = "",
    description: []const u8 = "",
    schema: []const bigquery.FieldSchema,
    time_partitioning: ?bigquery.TimePartitioning = null,
    clustering_fields: []const []const u8 = &.{},
    require_partition_filter: bool = false,
    expiration_time_ms: u64 = 0,
    kms_key_name: []const u8 = "",
    labels: []const config_mod.Label = &.{},
    retain_on_delete: bool = true,
};

pub const ViewSpec = struct {
    view_id: []const u8,
    query: []const u8,
    description: []const u8 = "",
    materialized: bool = false,
    enable_refresh: bool = true,
    refresh_interval_ms: u64 = 30 * 60 * 1000,
    labels: []const config_mod.Label = &.{},
    retain_on_delete: bool = true,
};

pub const RoutineSpec = struct {
    routine_id: []const u8,
    routine_type: bigquery.RoutineType,
    language: bigquery.RoutineLanguage,
    arguments: []const bigquery.RoutineArgument = &.{},
    return_type_json: []const u8 = "",
    definition_body: []const u8,
    description: []const u8 = "",
    imported_libraries: []const []const u8 = &.{},
    deterministic: ?bool = null,
    retain_on_delete: bool = true,
};

pub const AnalyticsWarehouseArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    dataset_id: []const u8,
    location: []const u8,
    friendly_name: []const u8 = "",
    description: []const u8 = "",
    default_table_expiration_ms: u64 = 0,
    default_partition_expiration_ms: u64 = 0,
    default_kms_key_name: []const u8 = "",
    labels: []const config_mod.Label = &.{},
    tables: []const TableSpec = &.{},
    views: []const ViewSpec = &.{},
    routines: []const RoutineSpec = &.{},
    readers: []const []const u8 = &.{},
    writers: []const []const u8 = &.{},
    retain_on_delete: bool = true,
};

pub const AnalyticsWarehouse = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    dataset_name: bigquery.Dataset.Outputs.Name.OutputType,
    dataset_location: bigquery.Dataset.Outputs.Location.OutputType,
    table_names: []output.Output([]const u8, .public),
    view_names: []output.Output([]const u8, .public),
    routine_names: []output.Output([]const u8, .public),

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: AnalyticsWarehouseArgs,
    ) BuildError!AnalyticsWarehouse {
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        try validateObjectIdentities(args);
        if (args.base_graph) |base| try graph.appendGraph(base);

        const dataset_index = graph.resources.items.len;
        var dataset = try bigquery.Dataset.build(allocator, provider, .{
            .dataset_id = args.dataset_id,
            .location = args.location,
            .friendly_name = if (args.friendly_name.len > 0) args.friendly_name else args.name,
            .description = args.description,
            .default_table_expiration_ms = args.default_table_expiration_ms,
            .default_partition_expiration_ms = args.default_partition_expiration_ms,
            .default_kms_key_name = args.default_kms_key_name,
            .labels = args.labels,
            .retain_on_delete = args.retain_on_delete,
        });
        defer dataset.deinit(allocator);
        try graph.addResource(dataset.node);
        const dataset_resource_id = graph.resources.items[dataset_index].id;
        const dataset_name = bigquery.Dataset.Outputs.Name.fromResource(dataset_resource_id);

        const table_names = try allocator.alloc(output.Output([]const u8, .public), args.tables.len);
        errdefer allocator.free(table_names);
        const view_names = try allocator.alloc(output.Output([]const u8, .public), args.views.len);
        errdefer allocator.free(view_names);
        const routine_names = try allocator.alloc(output.Output([]const u8, .public), args.routines.len);
        errdefer allocator.free(routine_names);
        for (args.tables, 0..) |spec, index| {
            const resource_index = graph.resources.items.len;
            var table = try bigquery.Table.build(allocator, provider, .{
                .dataset = dataset_name,
                .dataset_id = args.dataset_id,
                .table_id = spec.table_id,
                .friendly_name = spec.friendly_name,
                .description = spec.description,
                .schema = spec.schema,
                .time_partitioning = spec.time_partitioning,
                .clustering_fields = spec.clustering_fields,
                .require_partition_filter = spec.require_partition_filter,
                .expiration_time_ms = spec.expiration_time_ms,
                .kms_key_name = spec.kms_key_name,
                .labels = spec.labels,
                .retain_on_delete = spec.retain_on_delete,
            });
            defer table.deinit(allocator);
            try graph.addResource(table.node);
            table_names[index] = bigquery.Table.Outputs.Name.fromResource(graph.resources.items[resource_index].id);
        }
        for (args.views, 0..) |spec, index| {
            const resource_index = graph.resources.items.len;
            var view = try bigquery.View.build(allocator, provider, .{
                .dataset = dataset_name,
                .dataset_id = args.dataset_id,
                .view_id = spec.view_id,
                .query = spec.query,
                .description = spec.description,
                .materialized = spec.materialized,
                .enable_refresh = spec.enable_refresh,
                .refresh_interval_ms = spec.refresh_interval_ms,
                .labels = spec.labels,
                .retain_on_delete = spec.retain_on_delete,
            });
            defer view.deinit(allocator);
            try graph.addResource(view.node);
            view_names[index] = bigquery.View.Outputs.Name.fromResource(graph.resources.items[resource_index].id);
        }
        for (args.routines, 0..) |spec, index| {
            const resource_index = graph.resources.items.len;
            var routine = try bigquery.Routine.build(allocator, provider, .{
                .dataset = dataset_name,
                .dataset_id = args.dataset_id,
                .routine_id = spec.routine_id,
                .routine_type = spec.routine_type,
                .language = spec.language,
                .arguments = spec.arguments,
                .return_type_json = spec.return_type_json,
                .definition_body = spec.definition_body,
                .description = spec.description,
                .imported_libraries = spec.imported_libraries,
                .deterministic = spec.deterministic,
                .retain_on_delete = spec.retain_on_delete,
            });
            defer routine.deinit(allocator);
            try graph.addResource(routine.node);
            routine_names[index] = bigquery.Routine.Outputs.Name.fromResource(graph.resources.items[resource_index].id);
        }
        try addMembers(allocator, &graph, provider, args, dataset_name, args.readers, "reader", "roles/bigquery.dataViewer");
        try addMembers(allocator, &graph, provider, args, dataset_name, args.writers, "writer", "roles/bigquery.dataEditor");
        try graph.validateAcyclic();
        return .{
            .allocator = allocator,
            .graph = graph,
            .dataset_name = bigquery.Dataset.Outputs.Name.fromResource(dataset_resource_id),
            .dataset_location = bigquery.Dataset.Outputs.Location.fromResource(dataset_resource_id),
            .table_names = table_names,
            .view_names = view_names,
            .routine_names = routine_names,
        };
    }

    pub fn deinit(self: *AnalyticsWarehouse) void {
        self.allocator.free(self.table_names);
        self.allocator.free(self.view_names);
        self.allocator.free(self.routine_names);
        self.graph.deinit();
        self.* = undefined;
    }
};

fn validateObjectIdentities(args: AnalyticsWarehouseArgs) BuildError!void {
    for (args.tables) |table| {
        for (args.views) |view| {
            if (std.mem.eql(u8, table.table_id, view.view_id)) return error.DuplicateWarehouseObject;
        }
    }
}

fn addMembers(
    allocator: std.mem.Allocator,
    graph: *resource.ResourceGraph,
    provider: config_mod.ProviderConfig,
    args: AnalyticsWarehouseArgs,
    dataset_name: output.Output([]const u8, .public),
    members: []const []const u8,
    kind: []const u8,
    role: []const u8,
) BuildError!void {
    for (members, 0..) |member, index| {
        const binding_name = try boundedNameAlloc(allocator, args.name, kind, index + 1);
        defer allocator.free(binding_name);
        var binding = try bigquery.DatasetIamMember.build(allocator, provider, .{
            .name = binding_name,
            .dataset = dataset_name,
            .dataset_id = args.dataset_id,
            .role = role,
            .member = member,
        });
        defer binding.deinit(allocator);
        try graph.addResource(binding.node);
    }
}

fn boundedNameAlloc(
    allocator: std.mem.Allocator,
    base: []const u8,
    kind: []const u8,
    index: usize,
) std.mem.Allocator.Error![]const u8 {
    const candidate = try std.fmt.allocPrint(allocator, "{s}-{s}-{d}", .{ base, kind, index });
    if (candidate.len <= 128) return candidate;
    defer allocator.free(candidate);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(candidate, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ base[0..108], hex[0..18] });
}
