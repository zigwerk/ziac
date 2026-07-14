const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const service_networking = @import("service_networking.zig");

pub const BuildError = service_networking.BuildError || resource.ResourceGraphError;

pub const PrivateServiceAccessArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    network: []const u8,
    prefix_length: u8,
    address: []const u8 = "",
    service: []const u8 = "servicenetworking.googleapis.com",
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const PrivateServiceAccess = struct {
    graph: resource.ResourceGraph,
    range_name: output.Output([]const u8, .public),
    address: output.Output([]const u8, .public),
    connection_name: output.Output([]const u8, .public),
    peering: output.Output([]const u8, .public),
    network: output.Output([]const u8, .public),

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: PrivateServiceAccessArgs) BuildError!PrivateServiceAccess {
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);

        const range_index = graph.resources.items.len;
        var range = try service_networking.PrivateServiceRange.build(allocator, provider, .{
            .name = args.name,
            .network = args.network,
            .prefix_length = args.prefix_length,
            .address = args.address,
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
        });
        defer range.deinit(allocator);
        try graph.addResource(range.node);
        const range_id = graph.resources.items[range_index].id;
        const range_name = service_networking.PrivateServiceRange.Outputs.Name.fromResource(range_id);

        const connection_index = graph.resources.items.len;
        var connection = try service_networking.Connection.build(allocator, provider, .{
            .name = args.name,
            .network = args.network,
            .service = args.service,
            .reserved_ranges = &.{.{ .name = args.name, .dependency = range_name }},
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
        });
        defer connection.deinit(allocator);
        try graph.addResource(connection.node);
        const connection_id = graph.resources.items[connection_index].id;

        try graph.validateAcyclic();
        return .{
            .graph = graph,
            .range_name = range_name,
            .address = service_networking.PrivateServiceRange.Outputs.Address.fromResource(range_id),
            .connection_name = service_networking.Connection.Outputs.Name.fromResource(connection_id),
            .peering = service_networking.Connection.Outputs.Peering.fromResource(connection_id),
            .network = service_networking.Connection.Outputs.Network.fromResource(connection_id),
        };
    }

    pub fn deinit(self: *PrivateServiceAccess) void {
        self.graph.deinit();
        self.* = undefined;
    }
};
