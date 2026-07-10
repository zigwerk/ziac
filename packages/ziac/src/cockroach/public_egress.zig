const std = @import("std");
const authorized_network = @import("authorized_network.zig");
const config_mod = @import("config.zig");
const cloud_run = @import("../gcp/cloud_run.zig");
const gcp_config = @import("../gcp/config.zig");
const network = @import("../gcp/network.zig");
const resource = @import("../resource.zig");

pub const RegionPolicy = struct {
    region: []const u8,
    subnet_cidr: []const u8,
};

pub const PublicStaticEgressArgs = struct {
    name: []const u8,
    cluster_id: []const u8,
    regions: []const RegionPolicy,
};

pub const RegionalVpc = struct {
    region: []const u8,
    config: cloud_run.DirectVpc,
};

pub const BuildError = network.BuildError || authorized_network.BuildError || resource.ResourceGraphError ||
    std.mem.Allocator.Error || error{ DuplicateRegion, InsufficientRegions, PremiumTierRequired, RegionPolicyMismatch };

pub const PublicStaticEgress = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    regional_vpc: []RegionalVpc,

    pub fn build(
        allocator: std.mem.Allocator,
        google: gcp_config.ProviderConfig,
        cockroach: config_mod.ProviderConfig,
        args: PublicStaticEgressArgs,
    ) BuildError!PublicStaticEgress {
        try google.validate();
        try cockroach.validate();
        if (google.network_tier != .premium) return error.PremiumTierRequired;
        if (args.regions.len == 0) return error.InsufficientRegions;
        try validatePolicies(google, args.regions);

        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        const network_name = try std.fmt.allocPrint(allocator, "{s}-egress", .{args.name});
        defer allocator.free(network_name);
        var vpc = try network.Network.build(allocator, google, .{ .name = network_name });
        defer vpc.deinit(allocator);
        try graph.addResource(vpc.node);
        const network_id = graph.resources.items[graph.resources.items.len - 1].id;

        const regional_vpc = try allocator.alloc(RegionalVpc, args.regions.len);
        errdefer allocator.free(regional_vpc);
        var initialized: usize = 0;
        errdefer for (regional_vpc[0..initialized]) |regional| allocator.free(regional.region);

        for (args.regions, 0..) |policy, index| {
            const resource_name = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ args.name, policy.region });
            defer allocator.free(resource_name);
            const network_output = network.Network.Outputs.SelfLink.fromResource(network_id);
            var subnet = try network.Subnetwork.build(allocator, google, .{
                .name = resource_name,
                .region = policy.region,
                .ip_cidr_range = policy.subnet_cidr,
                .network = network_output,
            });
            defer subnet.deinit(allocator);
            try graph.addResource(subnet.node);
            const subnet_id = graph.resources.items[graph.resources.items.len - 1].id;

            var router = try network.Router.build(allocator, google, .{
                .name = resource_name,
                .region = policy.region,
                .network = network_output,
            });
            defer router.deinit(allocator);
            try graph.addResource(router.node);
            const router_id = graph.resources.items[graph.resources.items.len - 1].id;

            var address = try network.RegionalAddress.build(allocator, google, .{
                .name = resource_name,
                .region = policy.region,
            });
            defer address.deinit(allocator);
            try graph.addResource(address.node);
            const address_id = graph.resources.items[graph.resources.items.len - 1].id;

            var nat = try network.RouterNat.build(allocator, google, .{
                .name = resource_name,
                .region = policy.region,
                .router_name = resource_name,
                .router = network.Router.Outputs.SelfLink.fromResource(router_id),
                .subnetwork = network.Subnetwork.Outputs.SelfLink.fromResource(subnet_id),
                .nat_ip = network.RegionalAddress.Outputs.SelfLink.fromResource(address_id),
            });
            defer nat.deinit(allocator);
            try graph.addResource(nat.node);

            var allowlist = try authorized_network.AuthorizedNetwork.build(allocator, cockroach, .{
                .name = resource_name,
                .cluster_id = args.cluster_id,
                .ip_address = network.RegionalAddress.Outputs.Address.fromResource(address_id),
                .cidr_mask = 32,
                .sql = true,
                .ui = false,
                .production = true,
            });
            defer allowlist.deinit(allocator);
            try graph.addResource(allowlist.node);

            regional_vpc[index] = .{
                .region = try allocator.dupe(u8, policy.region),
                .config = .{
                    .network_output = network.Network.Outputs.SelfLink.fromResource(network_id),
                    .subnetwork_output = network.Subnetwork.Outputs.SelfLink.fromResource(subnet_id),
                    .egress = .all_traffic,
                },
            };
            initialized += 1;
        }
        try graph.validateAcyclic();
        return .{ .allocator = allocator, .graph = graph, .regional_vpc = regional_vpc };
    }

    pub fn deinit(self: *PublicStaticEgress) void {
        for (self.regional_vpc) |regional| self.allocator.free(regional.region);
        self.allocator.free(self.regional_vpc);
        self.graph.deinit();
        self.* = undefined;
    }

    pub fn takeGraph(self: *PublicStaticEgress) resource.ResourceGraph {
        const graph = self.graph;
        self.graph = resource.ResourceGraph.init(self.allocator);
        return graph;
    }
};

fn validatePolicies(google: gcp_config.ProviderConfig, policies: []const RegionPolicy) BuildError!void {
    for (policies, 0..) |policy, index| {
        if (policy.region.len == 0) return error.MissingRegion;
        for (policies[index + 1 ..]) |other| {
            if (std.mem.eql(u8, policy.region, other.region)) return error.DuplicateRegion;
        }
    }
    if (google.service_regions.len == 0) return;
    if (google.service_regions.len != policies.len) return error.RegionPolicyMismatch;
    for (google.service_regions) |region| {
        var found = false;
        for (policies) |policy| if (std.mem.eql(u8, region, policy.region)) {
            found = true;
            break;
        };
        if (!found) return error.RegionPolicyMismatch;
    }
}
