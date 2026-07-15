const std = @import("std");
const config_mod = @import("config.zig");
const eventarc = @import("eventarc_advanced.zig");
const connectors = @import("connectors.zig");
const resource = @import("../resource.zig");

pub const BuildError = config_mod.ValidationError || eventarc.BuildError || connectors.BuildError || resource.ResourceGraphError || std.mem.Allocator.Error || error{InvalidComponent};

pub const AdvancedEventRouteArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    bus: eventarc.MessageBusArgs,
    pipeline: eventarc.PipelineArgs,
    enrollment_name: []const u8,
    cel_match: []const u8,
    publishers: []const []const u8 = &.{},
};
pub const AdvancedEventRoute = struct {
    graph: resource.ResourceGraph,
    bus: eventarc.MessageBus.Outputs.Name.OutputType,
    pipeline: eventarc.Pipeline.Outputs.Name.OutputType,
    enrollment: eventarc.Enrollment.Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: AdvancedEventRouteArgs) BuildError!AdvancedEventRoute {
        if (!std.mem.eql(u8, args.bus.location, args.pipeline.location)) return error.InvalidComponent;
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);
        var bus = try eventarc.MessageBus.build(allocator, provider, args.bus);
        defer bus.deinit(allocator);
        try graph.addResource(bus.node);
        const bus_output = eventarc.MessageBus.Outputs.Name.fromResource(graph.resources.items[graph.resources.items.len - 1].id);
        var pipeline = try eventarc.Pipeline.build(allocator, provider, args.pipeline);
        defer pipeline.deinit(allocator);
        try graph.addResource(pipeline.node);
        const pipeline_output = eventarc.Pipeline.Outputs.Name.fromResource(graph.resources.items[graph.resources.items.len - 1].id);
        var enrollment = try eventarc.Enrollment.build(allocator, provider, .{
            .name = args.enrollment_name,
            .location = args.bus.location,
            .message_bus = bus_output,
            .destination_pipeline = pipeline_output,
            .cel_match = args.cel_match,
        });
        defer enrollment.deinit(allocator);
        try graph.addResource(enrollment.node);
        const enrollment_output = eventarc.Enrollment.Outputs.Name.fromResource(graph.resources.items[graph.resources.items.len - 1].id);
        for (args.publishers) |publisher| {
            var member = try eventarc.MessageBusIamMember.build(allocator, provider, .{ .location = args.bus.location, .message_bus = bus_output, .role = "roles/eventarc.publisher", .member = publisher });
            defer member.deinit(allocator);
            try graph.addResource(member.node);
        }
        try graph.validateAcyclic();
        return .{ .graph = graph, .bus = bus_output, .pipeline = pipeline_output, .enrollment = enrollment_output };
    }
    pub fn deinit(self: *AdvancedEventRoute) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

pub const PrivateConnectorArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    settings: connectors.RegionalSettingsArgs,
    connection: connectors.ConnectionArgs,
    endpoint: ?connectors.EndpointAttachmentArgs = null,
    operators: []const []const u8 = &.{},
};
pub const PrivateConnector = struct {
    graph: resource.ResourceGraph,
    connection: connectors.Connection.Outputs.Name.OutputType,
    endpoint: ?connectors.EndpointAttachment.Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: PrivateConnectorArgs) BuildError!PrivateConnector {
        if (!std.mem.eql(u8, args.settings.location, args.connection.location) or args.settings.egress_mode != .private_ip) return error.InvalidComponent;
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);
        var settings = try connectors.RegionalSettings.build(allocator, provider, args.settings);
        defer settings.deinit(allocator);
        try graph.addResource(settings.node);
        var connection = try connectors.Connection.build(allocator, provider, args.connection);
        defer connection.deinit(allocator);
        try graph.addResource(connection.node);
        const connection_output = connectors.Connection.Outputs.Name.fromResource(graph.resources.items[graph.resources.items.len - 1].id);
        var endpoint_output: ?connectors.EndpointAttachment.Outputs.Name.OutputType = null;
        if (args.endpoint) |endpoint_args| {
            if (!std.mem.eql(u8, endpoint_args.location, args.connection.location)) return error.InvalidComponent;
            var endpoint = try connectors.EndpointAttachment.build(allocator, provider, endpoint_args);
            defer endpoint.deinit(allocator);
            try graph.addResource(endpoint.node);
            endpoint_output = connectors.EndpointAttachment.Outputs.Name.fromResource(graph.resources.items[graph.resources.items.len - 1].id);
        }
        for (args.operators) |operator| {
            var member = try connectors.ConnectionIamMember.build(allocator, provider, .{ .location = args.connection.location, .connection = connection_output, .role = "roles/connectors.admin", .member = operator });
            defer member.deinit(allocator);
            try graph.addResource(member.node);
        }
        try graph.validateAcyclic();
        return .{ .graph = graph, .connection = connection_output, .endpoint = endpoint_output };
    }
    pub fn deinit(self: *PrivateConnector) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

pub const ConnectorEventBridgeArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    connection: connectors.ConnectionArgs,
    subscription: connectors.EventSubscriptionArgs,
};
pub const ConnectorEventBridge = struct {
    graph: resource.ResourceGraph,
    connection: connectors.Connection.Outputs.Name.OutputType,
    subscription: connectors.EventSubscription.Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ConnectorEventBridgeArgs) BuildError!ConnectorEventBridge {
        if (!std.mem.eql(u8, args.connection.location, args.subscription.location)) return error.InvalidComponent;
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);
        var connection = try connectors.Connection.build(allocator, provider, args.connection);
        defer connection.deinit(allocator);
        try graph.addResource(connection.node);
        const connection_output = connectors.Connection.Outputs.Name.fromResource(graph.resources.items[graph.resources.items.len - 1].id);
        var subscription_args = args.subscription;
        subscription_args.connection = connection_output;
        var subscription = try connectors.EventSubscription.build(allocator, provider, subscription_args);
        defer subscription.deinit(allocator);
        try graph.addResource(subscription.node);
        const subscription_output = connectors.EventSubscription.Outputs.Name.fromResource(graph.resources.items[graph.resources.items.len - 1].id);
        try graph.validateAcyclic();
        return .{ .graph = graph, .connection = connection_output, .subscription = subscription_output };
    }
    pub fn deinit(self: *ConnectorEventBridge) void {
        self.graph.deinit();
        self.* = undefined;
    }
};
