const std = @import("std");
const config_mod = @import("config.zig");
const private_endpoint = @import("private_endpoint.zig");
const cloud_run = @import("../gcp/cloud_run.zig");
const dns = @import("../gcp/dns.zig");
const gcp_config = @import("../gcp/config.zig");
const network = @import("../gcp/network.zig");
const project_service = @import("../gcp/project_service.zig");
const psc = @import("../gcp/psc.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");

pub const EligiblePlan = private_endpoint.EligiblePlan;

pub const RegionPolicy = struct {
    region: []const u8,
    subnet_cidr: []const u8,
};

pub const PrivateServiceConnectArgs = struct {
    name: []const u8,
    cluster_resource: ?resource.ResourceNode = null,
    cluster_id: output.Output([]const u8, .public),
    plan: EligiblePlan,
    regions: []const RegionPolicy,
    dns_ttl: u32 = 60,
};

pub const BuildError = private_endpoint.BuildError || network.BuildError || psc.BuildError || dns.BuildError ||
    project_service.BuildError || resource.ResourceGraphError || std.mem.Allocator.Error || error{
    ClusterResourceMismatch,
    DuplicateRegion,
    InsufficientRegions,
    MissingClusterResource,
    RegionPolicyMismatch,
    UnexpectedClusterResource,
};

pub const RegionalBinding = struct {
    region: []const u8,
    direct_vpc: cloud_run.DirectVpc,
    private_dns: private_endpoint.ClusterRegion.Outputs.PrivateEndpointDns.OutputType,
    endpoint_ip: psc.Endpoint.Outputs.IpAddress.OutputType,
    psc_connection_id: psc.Endpoint.Outputs.PscConnectionId.OutputType,
    connection_status: private_endpoint.PrivateEndpointConnection.Outputs.Status.OutputType,
};

pub const PrivateServiceConnect = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    network: network.Network.Outputs.SelfLink.OutputType,
    regions: []RegionalBinding,

    pub fn build(
        allocator: std.mem.Allocator,
        google: gcp_config.ProviderConfig,
        cockroach: config_mod.ProviderConfig,
        args: PrivateServiceConnectArgs,
    ) BuildError!PrivateServiceConnect {
        try google.validate();
        try cockroach.validate();
        if (args.regions.len == 0) return error.InsufficientRegions;
        try validatePolicies(google, args.regions);

        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        try addClusterResource(&graph, args.cluster_resource, args.cluster_id);

        const api_names = [_][]const u8{
            "compute.googleapis.com",
            "dns.googleapis.com",
            "servicedirectory.googleapis.com",
        };
        var api_ids: [api_names.len][]const u8 = undefined;
        for (api_names, 0..) |api_name, index| {
            var api = try project_service.Service.build(allocator, google, .{ .service = api_name });
            defer api.deinit(allocator);
            try graph.addResource(api.node);
            api_ids[index] = graph.resources.items[graph.resources.items.len - 1].id;
        }

        const network_name = try std.fmt.allocPrint(allocator, "{s}-psc", .{args.name});
        defer allocator.free(network_name);
        var vpc = try network.Network.build(allocator, google, .{ .name = network_name });
        defer vpc.deinit(allocator);
        try graph.addResource(vpc.node);
        const network_id = graph.resources.items[graph.resources.items.len - 1].id;
        try graph.addDependency(network_id, api_ids[0]);
        const network_output = network.Network.Outputs.SelfLink.fromResource(network_id);

        const bindings = try allocator.alloc(RegionalBinding, args.regions.len);
        errdefer allocator.free(bindings);
        var initialized: usize = 0;
        errdefer for (bindings[0..initialized]) |binding| allocator.free(binding.region);

        for (args.regions, 0..) |policy, index| {
            const regional_name = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ args.name, policy.region });
            defer allocator.free(regional_name);

            var subnet = try network.Subnetwork.build(allocator, google, .{
                .name = regional_name,
                .region = policy.region,
                .ip_cidr_range = policy.subnet_cidr,
                .network = network_output,
            });
            defer subnet.deinit(allocator);
            try graph.addResource(subnet.node);
            const subnet_id = graph.resources.items[graph.resources.items.len - 1].id;
            try graph.addDependency(subnet_id, api_ids[0]);

            var service = try private_endpoint.PrivateEndpointService.build(allocator, cockroach, .{
                .name = args.name,
                .cluster_id = args.cluster_id,
                .plan = args.plan,
                .region = policy.region,
            });
            defer service.deinit(allocator);
            try graph.addResource(service.node);
            const service_id = graph.resources.items[graph.resources.items.len - 1].id;

            var cluster_region = try private_endpoint.ClusterRegion.build(allocator, cockroach, .{
                .name = args.name,
                .cluster_id = args.cluster_id,
                .region = policy.region,
            });
            defer cluster_region.deinit(allocator);
            try graph.addResource(cluster_region.node);
            const cluster_region_id = graph.resources.items[graph.resources.items.len - 1].id;
            try graph.addDependency(cluster_region_id, service_id);

            var address = try psc.Address.build(allocator, google, .{
                .name = regional_name,
                .region = policy.region,
                .subnetwork = network.Subnetwork.Outputs.SelfLink.fromResource(subnet_id),
            });
            defer address.deinit(allocator);
            try graph.addResource(address.node);
            const address_id = graph.resources.items[graph.resources.items.len - 1].id;
            try graph.addDependency(address_id, api_ids[0]);

            var endpoint = try psc.Endpoint.build(allocator, google, .{
                .name = regional_name,
                .region = policy.region,
                .network = network_output,
                .address = psc.Address.Outputs.Address.fromResource(address_id),
                .address_resource = psc.Address.Outputs.SelfLink.fromResource(address_id),
                .target = private_endpoint.PrivateEndpointService.Outputs.ServiceAttachment.fromResource(service_id),
            });
            defer endpoint.deinit(allocator);
            try graph.addResource(endpoint.node);
            const endpoint_id = graph.resources.items[graph.resources.items.len - 1].id;
            try graph.addDependency(endpoint_id, api_ids[0]);
            try graph.addDependency(endpoint_id, api_ids[2]);

            var connection = try private_endpoint.PrivateEndpointConnection.build(allocator, cockroach, .{
                .name = args.name,
                .cluster_id = args.cluster_id,
                .endpoint_id = psc.Endpoint.Outputs.PscConnectionId.fromResource(endpoint_id),
                .endpoint_service_id = private_endpoint.PrivateEndpointService.Outputs.EndpointServiceId.fromResource(service_id),
                .region = policy.region,
            });
            defer connection.deinit(allocator);
            try graph.addResource(connection.node);
            const connection_id = graph.resources.items[graph.resources.items.len - 1].id;

            var zone = try dns.ManagedZone.build(allocator, google, .{
                .name = regional_name,
                .dns_name = private_endpoint.ClusterRegion.Outputs.PrivateEndpointDns.fromResource(cluster_region_id),
                .network = network_output,
            });
            defer zone.deinit(allocator);
            try graph.addResource(zone.node);
            const zone_id = graph.resources.items[graph.resources.items.len - 1].id;
            try graph.addDependency(zone_id, api_ids[1]);

            var record = try dns.RecordSet.build(allocator, google, .{
                .zone = regional_name,
                .name_output = private_endpoint.ClusterRegion.Outputs.PrivateEndpointDns.fromResource(cluster_region_id),
                .logical_name = policy.region,
                .record_type = .a,
                .ttl = args.dns_ttl,
                .rrdata_outputs = &.{psc.Endpoint.Outputs.IpAddress.fromResource(endpoint_id)},
            });
            defer record.deinit(allocator);
            try graph.addResource(record.node);
            const record_id = graph.resources.items[graph.resources.items.len - 1].id;
            try graph.addDependency(record_id, api_ids[1]);
            try graph.addDependency(record_id, zone_id);
            try graph.addDependency(record_id, connection_id);

            bindings[index] = .{
                .region = try allocator.dupe(u8, policy.region),
                .direct_vpc = .{
                    .network_output = network_output,
                    .subnetwork_output = network.Subnetwork.Outputs.SelfLink.fromResource(subnet_id),
                    .egress = .private_ranges_only,
                },
                .private_dns = private_endpoint.ClusterRegion.Outputs.PrivateEndpointDns.fromResource(cluster_region_id),
                .endpoint_ip = psc.Endpoint.Outputs.IpAddress.fromResource(endpoint_id),
                .psc_connection_id = psc.Endpoint.Outputs.PscConnectionId.fromResource(endpoint_id),
                .connection_status = private_endpoint.PrivateEndpointConnection.Outputs.Status.fromResource(connection_id),
            };
            initialized += 1;
        }
        try graph.validateAcyclic();
        return .{
            .allocator = allocator,
            .graph = graph,
            .network = network_output,
            .regions = bindings,
        };
    }

    pub fn deinit(self: *PrivateServiceConnect) void {
        for (self.regions) |binding| self.allocator.free(binding.region);
        self.allocator.free(self.regions);
        self.graph.deinit();
        self.* = undefined;
    }

    pub fn takeGraph(self: *PrivateServiceConnect) resource.ResourceGraph {
        const graph = self.graph;
        self.graph = resource.ResourceGraph.init(self.allocator);
        return graph;
    }
};

fn addClusterResource(
    graph: *resource.ResourceGraph,
    cluster_resource: ?resource.ResourceNode,
    cluster_id: output.Output([]const u8, .public),
) BuildError!void {
    switch (cluster_id) {
        .resource_ref => |reference| {
            const node = cluster_resource orelse return error.MissingClusterResource;
            if (node.provider != .cockroach or
                !std.mem.eql(u8, node.id, reference.resource_id) or
                !std.mem.eql(u8, reference.field, "cluster_id"))
            {
                return error.ClusterResourceMismatch;
            }
            try graph.addResource(node);
        },
        .value => {
            if (cluster_resource != null) return error.UnexpectedClusterResource;
        },
        .unknown_reason => return error.OutputNotKnown,
    }
}

fn validatePolicies(google: gcp_config.ProviderConfig, policies: []const RegionPolicy) BuildError!void {
    for (policies, 0..) |policy, index| {
        if (policy.region.len == 0) return error.MissingRegion;
        for (policies[index + 1 ..]) |other| {
            if (std.mem.eql(u8, policy.region, other.region)) return error.DuplicateRegion;
        }
    }
    if (google.service_regions.len == 0) {
        if (policies.len != 1 or !std.mem.eql(u8, policies[0].region, google.primary_region)) return error.RegionPolicyMismatch;
        return;
    }
    if (google.service_regions.len != policies.len) return error.RegionPolicyMismatch;
    for (google.service_regions) |expected| {
        var found = false;
        for (policies) |policy| if (std.mem.eql(u8, expected, policy.region)) {
            found = true;
            break;
        };
        if (!found) return error.RegionPolicyMismatch;
    }
}
