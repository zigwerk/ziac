const std = @import("std");
const config_mod = @import("config.zig");
const logging = @import("logging.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");

pub const BuildError = logging.BuildError || resource.ResourceGraphError || std.mem.Allocator.Error;

pub const ViewSpec = struct {
    name: []const u8,
    description: []const u8 = "",
    filter: []const u8,
};

pub const ProjectExclusionSpec = struct {
    name: []const u8,
    description: []const u8 = "",
    filter: []const u8,
    disabled: bool = false,
};

pub const MetricSpec = struct {
    name: []const u8,
    description: []const u8 = "",
    filter: []const u8,
    disabled: bool = false,
    mode: logging.MetricMode = .counter,
    labels: []const logging.MetricLabel = &.{},
    label_extractors: []const logging.LabelExtractor = &.{},
};

pub const ApplicationLogPlatformArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    location: []const u8 = "global",
    description: []const u8 = "Application logs",
    retention_days: u16 = 30,
    analytics_enabled: bool = false,
    locked: bool = false,
    kms_key_name: ?output.Output([]const u8, .public) = null,
    restricted_fields: []const []const u8 = &.{},
    indexes: []const logging.IndexConfig = &.{},
    views: []const ViewSpec = &.{},
    route_filter: []const u8 = "logName:*",
    route_exclusions: []const logging.SinkExclusion = &.{},
    project_exclusions: []const ProjectExclusionSpec = &.{},
    metrics: []const MetricSpec = &.{},
    protect: bool = true,
};

pub const ApplicationLogPlatform = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    bucket: output.Output([]const u8, .public),
    sink: output.Output([]const u8, .public),
    writer_identity: output.Output([]const u8, .public),
    views: []output.Output([]const u8, .public),
    metrics: []output.Output([]const u8, .public),

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ApplicationLogPlatformArgs) BuildError!ApplicationLogPlatform {
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);

        const bucket_index = graph.resources.items.len;
        var bucket = try logging.Bucket.build(allocator, provider, .{
            .name = args.name,
            .location = args.location,
            .description = args.description,
            .retention_days = args.retention_days,
            .analytics_enabled = args.analytics_enabled,
            .locked = args.locked,
            .kms_key_name = args.kms_key_name,
            .restricted_fields = args.restricted_fields,
            .indexes = args.indexes,
            .protect = args.protect,
        });
        defer bucket.deinit(allocator);
        try graph.addResource(bucket.node);
        const bucket_output = logging.Bucket.Outputs.Name.fromResource(graph.resources.items[bucket_index].id);

        const view_outputs = try allocator.alloc(output.Output([]const u8, .public), args.views.len);
        errdefer allocator.free(view_outputs);
        for (args.views, 0..) |spec, index| {
            const resource_index = graph.resources.items.len;
            var view = try logging.View.build(allocator, provider, .{
                .name = spec.name,
                .location = args.location,
                .bucket_name = args.name,
                .bucket = bucket_output,
                .description = spec.description,
                .filter = spec.filter,
                .protect = args.protect,
            });
            defer view.deinit(allocator);
            try graph.addResource(view.node);
            view_outputs[index] = logging.View.Outputs.Name.fromResource(graph.resources.items[resource_index].id);
        }

        const sink_name = try std.fmt.allocPrint(allocator, "{s}-route", .{args.name});
        defer allocator.free(sink_name);
        const sink_index = graph.resources.items.len;
        var sink = try logging.Sink.build(allocator, provider, .{
            .name = sink_name,
            .destination = .{ .logging_bucket = bucket_output },
            .filter = args.route_filter,
            .description = "Route application logs into the managed bucket",
            .exclusions = args.route_exclusions,
            .protect = args.protect,
        });
        defer sink.deinit(allocator);
        try graph.addResource(sink.node);
        const sink_id = graph.resources.items[sink_index].id;

        for (args.project_exclusions) |spec| {
            var exclusion = try logging.Exclusion.build(allocator, provider, .{
                .name = spec.name,
                .description = spec.description,
                .filter = spec.filter,
                .disabled = spec.disabled,
                .protect = args.protect,
            });
            defer exclusion.deinit(allocator);
            try graph.addResource(exclusion.node);
        }

        const metric_outputs = try allocator.alloc(output.Output([]const u8, .public), args.metrics.len);
        errdefer allocator.free(metric_outputs);
        for (args.metrics, 0..) |spec, index| {
            const resource_index = graph.resources.items.len;
            var metric = try logging.Metric.build(allocator, provider, .{
                .name = spec.name,
                .description = spec.description,
                .filter = spec.filter,
                .disabled = spec.disabled,
                .mode = spec.mode,
                .labels = spec.labels,
                .label_extractors = spec.label_extractors,
                .bucket_name = bucket_output,
                .protect = args.protect,
            });
            defer metric.deinit(allocator);
            try graph.addResource(metric.node);
            metric_outputs[index] = logging.Metric.Outputs.Name.fromResource(graph.resources.items[resource_index].id);
        }

        try graph.validateAcyclic();
        return .{
            .allocator = allocator,
            .graph = graph,
            .bucket = bucket_output,
            .sink = logging.Sink.Outputs.Name.fromResource(sink_id),
            .writer_identity = logging.Sink.Outputs.WriterIdentity.fromResource(sink_id),
            .views = view_outputs,
            .metrics = metric_outputs,
        };
    }

    pub fn deinit(self: *ApplicationLogPlatform) void {
        self.allocator.free(self.views);
        self.allocator.free(self.metrics);
        self.graph.deinit();
        self.* = undefined;
    }
};
