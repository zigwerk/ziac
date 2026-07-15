const std = @import("std");
const config_mod = @import("config.zig");
const vertex = @import("vertex_ai.zig");
const actions = @import("vertex_ai_actions.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");

pub const BuildError = vertex.BuildError || resource.ResourceGraphError || std.mem.Allocator.Error || error{InvalidComponent};

pub const OnlinePredictionPlatformArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    model: vertex.ModelArgs,
    endpoint: vertex.EndpointArgs,
    deployment: actions.ModelDeploymentIntent,
};
pub const OnlinePredictionPlatform = struct {
    graph: resource.ResourceGraph,
    model: vertex.Model.Outputs.Name.OutputType,
    endpoint: vertex.Endpoint.Outputs.Name.OutputType,
    deployment: actions.ModelDeploymentIntent,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: OnlinePredictionPlatformArgs) BuildError!OnlinePredictionPlatform {
        if (!std.mem.eql(u8, args.model.location, args.endpoint.location)) return error.InvalidComponent;
        actions.validateModelDeploymentIntent(args.deployment) catch return error.InvalidComponent;
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);
        var model = try vertex.Model.build(allocator, provider, args.model);
        defer model.deinit(allocator);
        try graph.addResource(model.node);
        const model_id = graph.resources.items[graph.resources.items.len - 1].id;
        var endpoint = try vertex.Endpoint.build(allocator, provider, args.endpoint);
        defer endpoint.deinit(allocator);
        try graph.addResource(endpoint.node);
        const endpoint_id = graph.resources.items[graph.resources.items.len - 1].id;
        try graph.addDependency(endpoint_id, model_id);
        try graph.validateAcyclic();
        return .{
            .graph = graph,
            .model = vertex.Model.Outputs.Name.fromResource(model_id),
            .endpoint = vertex.Endpoint.Outputs.Name.fromResource(endpoint_id),
            .deployment = args.deployment,
        };
    }
    pub fn deinit(self: *OnlinePredictionPlatform) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

pub const VectorSearchPlatformArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    index: vertex.IndexArgs,
    endpoint: vertex.IndexEndpointArgs,
    deployment: actions.IndexDeploymentIntent,
};
pub const VectorSearchPlatform = struct {
    graph: resource.ResourceGraph,
    index: vertex.Index.Outputs.Name.OutputType,
    endpoint: vertex.IndexEndpoint.Outputs.Name.OutputType,
    deployment: actions.IndexDeploymentIntent,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: VectorSearchPlatformArgs) BuildError!VectorSearchPlatform {
        if (!std.mem.eql(u8, args.index.location, args.endpoint.location)) return error.InvalidComponent;
        actions.validateIndexDeploymentIntent(args.deployment) catch return error.InvalidComponent;
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);
        var index = try vertex.Index.build(allocator, provider, args.index);
        defer index.deinit(allocator);
        try graph.addResource(index.node);
        const index_id = graph.resources.items[graph.resources.items.len - 1].id;
        var endpoint = try vertex.IndexEndpoint.build(allocator, provider, args.endpoint);
        defer endpoint.deinit(allocator);
        try graph.addResource(endpoint.node);
        const endpoint_id = graph.resources.items[graph.resources.items.len - 1].id;
        try graph.addDependency(endpoint_id, index_id);
        try graph.validateAcyclic();
        return .{
            .graph = graph,
            .index = vertex.Index.Outputs.Name.fromResource(index_id),
            .endpoint = vertex.IndexEndpoint.Outputs.Name.fromResource(endpoint_id),
            .deployment = args.deployment,
        };
    }
    pub fn deinit(self: *VectorSearchPlatform) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

pub const FeatureSpec = struct {
    name: []const u8,
    description: []const u8 = "",
    point_of_contact: []const u8 = "",
    labels: []const vertex.KeyValue = &.{},
};
pub const FeaturePlatformArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    group: vertex.FeatureGroupArgs,
    features: []const FeatureSpec,
    store: vertex.FeatureOnlineStoreArgs,
    view_name: []const u8,
    sync_interval_seconds: u32,
    view_labels: []const vertex.KeyValue = &.{},
};
pub const FeaturePlatform = struct {
    graph: resource.ResourceGraph,
    group: vertex.FeatureGroup.Outputs.Name.OutputType,
    store: vertex.FeatureOnlineStore.Outputs.Name.OutputType,
    view: vertex.FeatureView.Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: FeaturePlatformArgs) BuildError!FeaturePlatform {
        if (args.features.len == 0 or
            !std.mem.eql(u8, args.group.location, args.store.location)) return error.InvalidComponent;
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);

        var group = try vertex.FeatureGroup.build(allocator, provider, args.group);
        defer group.deinit(allocator);
        try graph.addResource(group.node);
        const group_id = graph.resources.items[graph.resources.items.len - 1].id;
        const group_output = vertex.FeatureGroup.Outputs.Name.fromResource(group_id);

        const feature_outputs = try allocator.alloc(output.Output([]const u8, .public), args.features.len);
        defer allocator.free(feature_outputs);
        for (args.features, 0..) |spec, index| {
            var feature = try vertex.Feature.build(allocator, provider, .{
                .name = spec.name,
                .location = args.group.location,
                .feature_group = group_output,
                .description = spec.description,
                .point_of_contact = spec.point_of_contact,
                .labels = spec.labels,
            });
            defer feature.deinit(allocator);
            try graph.addResource(feature.node);
            feature_outputs[index] = vertex.Feature.Outputs.Name.fromResource(graph.resources.items[graph.resources.items.len - 1].id);
        }

        var store = try vertex.FeatureOnlineStore.build(allocator, provider, args.store);
        defer store.deinit(allocator);
        try graph.addResource(store.node);
        const store_id = graph.resources.items[graph.resources.items.len - 1].id;
        const store_output = vertex.FeatureOnlineStore.Outputs.Name.fromResource(store_id);
        var view = try vertex.FeatureView.build(allocator, provider, .{
            .name = args.view_name,
            .location = args.group.location,
            .online_store = store_output,
            .source = .{ .feature_registry = .{ .feature_group = group_output, .features = feature_outputs } },
            .sync_interval_seconds = args.sync_interval_seconds,
            .labels = args.view_labels,
        });
        defer view.deinit(allocator);
        try graph.addResource(view.node);
        const view_id = graph.resources.items[graph.resources.items.len - 1].id;
        try graph.validateAcyclic();
        return .{
            .graph = graph,
            .group = group_output,
            .store = store_output,
            .view = vertex.FeatureView.Outputs.Name.fromResource(view_id),
        };
    }
    pub fn deinit(self: *FeaturePlatform) void {
        self.graph.deinit();
        self.* = undefined;
    }
};
