const std = @import("std");
const cloud_run = @import("../cloud_run.zig");
const compute = @import("../compute.zig");
const config_mod = @import("../config.zig");
const dns = @import("../dns.zig");
const output = @import("../../output.zig");
const resource = @import("../../resource.zig");

pub const BuildError = cloud_run.BuildError || compute.BuildError || dns.BuildError || resource.ResourceGraphError || error{
    DuplicateRegion,
    InsufficientRegions,
    ProductionMinInstancesRequired,
    ProductionProbeRequired,
    ConflictingVpcConfiguration,
    DuplicateVpcRegion,
    RegionalVpcMismatch,
};

pub const HealthMode = enum {
    standard,
    production,
};

pub const RegionalDirectVpc = struct {
    region: []const u8,
    config: cloud_run.DirectVpc,
};

pub const ContainerServiceArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    image: []const u8,
    regions: []const []const u8 = &.{},
    domain: []const u8,
    dns_zone: ?[]const u8 = null,
    dns_ttl: u32 = 300,
    http_redirect: bool = true,
    redirect_strip_query: bool = false,
    health_mode: HealthMode = .standard,
    port: u16 = 8080,
    command: []const []const u8 = &.{},
    args: []const []const u8 = &.{},
    cpu: []const u8 = "1",
    memory: []const u8 = "512Mi",
    concurrency: u16 = 80,
    timeout_seconds: u32 = 300,
    min_instances: u32 = 0,
    max_instances: u32 = 100,
    startup_probe: ?cloud_run.HttpProbe = null,
    liveness_probe: ?cloud_run.HttpProbe = null,
    readiness_probe: ?cloud_run.HttpProbe = null,
    service_account: ?[]const u8 = null,
    env: []const cloud_run.EnvVar = &.{},
    secret_volumes: []const cloud_run.SecretVolume = &.{},
    direct_vpc: ?cloud_run.DirectVpc = null,
    regional_direct_vpc: []const RegionalDirectVpc = &.{},
};

pub const ContainerService = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    url: output.Output([]const u8, .public),
    ip_address: compute.GlobalAddress.Outputs.Address.OutputType,
    certificate_status: compute.ManagedSslCertificate.Outputs.Status.OutputType,
    owned_url: []const u8,
    address_resource_id: []const u8,
    certificate_resource_id: []const u8,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: ContainerServiceArgs,
    ) BuildError!ContainerService {
        const regions = if (args.regions.len == 0) provider.service_regions else args.regions;
        try validate(provider, args, regions);

        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base_graph| try graph.appendGraph(base_graph);
        const backend_groups = try allocator.alloc([]const u8, regions.len);
        defer allocator.free(backend_groups);
        var initialized_groups: usize = 0;
        defer for (backend_groups[0..initialized_groups]) |group| allocator.free(group);
        const neg_resource_ids = try allocator.alloc([]const u8, regions.len);
        defer allocator.free(neg_resource_ids);
        var initialized_neg_ids: usize = 0;
        defer for (neg_resource_ids[0..initialized_neg_ids]) |id| allocator.free(id);

        for (regions, 0..) |region, index| {
            var service = try cloud_run.Service.build(allocator, provider, .{
                .name = args.name,
                .image = args.image,
                .region = region,
                .port = args.port,
                .command = args.command,
                .args = args.args,
                .cpu = args.cpu,
                .memory = args.memory,
                .concurrency = args.concurrency,
                .timeout_seconds = args.timeout_seconds,
                .min_instances = args.min_instances,
                .max_instances = args.max_instances,
                .startup_probe = args.startup_probe,
                .liveness_probe = args.liveness_probe,
                .readiness_probe = args.readiness_probe,
                .ingress = .internal_and_cloud_load_balancing,
                .allow_unauthenticated = true,
                .service_account = args.service_account,
                .env = args.env,
                .secret_volumes = args.secret_volumes,
                .direct_vpc = directVpcForRegion(args, region),
            });
            defer service.deinit(allocator);
            try graph.addResource(service.node);

            const neg_name = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ args.name, region });
            defer allocator.free(neg_name);
            var neg = try compute.RegionServerlessNeg.build(allocator, provider, .{
                .name = neg_name,
                .region = region,
                .cloud_run_service = args.name,
            });
            defer neg.deinit(allocator);
            try graph.addResource(neg.node);
            try graph.bindOutput(neg.node.id, service.latest_revision);

            backend_groups[index] = try std.fmt.allocPrint(
                allocator,
                "projects/{s}/regions/{s}/networkEndpointGroups/{s}",
                .{ provider.project_id, region, neg_name },
            );
            initialized_groups += 1;
            neg_resource_ids[index] = try allocator.dupe(u8, neg.node.id);
            initialized_neg_ids += 1;
        }

        const address_name = try resourceNameAlloc(allocator, args.name, "ip");
        defer allocator.free(address_name);
        var address = try compute.GlobalAddress.build(allocator, provider, .{ .name = address_name });
        defer address.deinit(allocator);
        try graph.addResource(address.node);

        const backend_name = try resourceNameAlloc(allocator, args.name, "backend");
        defer allocator.free(backend_name);
        const backends = try allocator.alloc(compute.ServerlessBackend, regions.len);
        defer allocator.free(backends);
        for (regions, backend_groups, 0..) |region, group, index| backends[index] = .{ .region = region, .group = group };
        var backend = try compute.BackendService.build(allocator, provider, .{
            .name = backend_name,
            .backends = backends,
            .outlier_detection = .{},
        });
        defer backend.deinit(allocator);
        try graph.addResource(backend.node);
        for (neg_resource_ids) |neg_id| {
            try graph.bindOutput(backend.node.id, compute.RegionServerlessNeg.Outputs.SelfLink.fromResource(neg_id));
        }

        const map_name = try resourceNameAlloc(allocator, args.name, "map");
        defer allocator.free(map_name);
        const backend_link = try std.fmt.allocPrint(allocator, "projects/{s}/global/backendServices/{s}", .{ provider.project_id, backend_name });
        defer allocator.free(backend_link);
        var url_map = try compute.UrlMap.build(allocator, provider, .{ .name = map_name, .default_service = backend_link });
        defer url_map.deinit(allocator);
        try graph.addResource(url_map.node);
        try graph.bindOutput(url_map.node.id, backend.self_link);

        const certificate_name = try resourceNameAlloc(allocator, args.name, "cert");
        defer allocator.free(certificate_name);
        var certificate = try compute.ManagedSslCertificate.build(allocator, provider, .{
            .name = certificate_name,
            .domains = &.{args.domain},
        });
        defer certificate.deinit(allocator);
        try graph.addResource(certificate.node);

        const https_name = try resourceNameAlloc(allocator, args.name, "https");
        defer allocator.free(https_name);
        const url_map_link = try std.fmt.allocPrint(allocator, "projects/{s}/global/urlMaps/{s}", .{ provider.project_id, map_name });
        defer allocator.free(url_map_link);
        const certificate_link = try std.fmt.allocPrint(allocator, "projects/{s}/global/sslCertificates/{s}", .{ provider.project_id, certificate_name });
        defer allocator.free(certificate_link);
        var https_proxy = try compute.TargetHttpsProxy.build(allocator, provider, .{
            .name = https_name,
            .url_map = url_map_link,
            .ssl_certificates = &.{certificate_link},
        });
        defer https_proxy.deinit(allocator);
        try graph.addResource(https_proxy.node);
        try graph.bindOutput(https_proxy.node.id, url_map.self_link);
        try graph.bindOutput(https_proxy.node.id, certificate.self_link);

        const https_proxy_link = try std.fmt.allocPrint(allocator, "projects/{s}/global/targetHttpsProxies/{s}", .{ provider.project_id, https_name });
        defer allocator.free(https_proxy_link);
        var https_forwarding = try compute.GlobalForwardingRule.build(allocator, provider, .{
            .name = https_name,
            .address_output = address.address,
            .target = https_proxy_link,
        });
        defer https_forwarding.deinit(allocator);
        try graph.addResource(https_forwarding.node);
        try graph.bindOutput(https_forwarding.node.id, address.address);
        try graph.bindOutput(https_forwarding.node.id, https_proxy.self_link);

        if (args.http_redirect) {
            const redirect_map_name = try resourceNameAlloc(allocator, args.name, "http-redirect");
            defer allocator.free(redirect_map_name);
            var redirect_map = try compute.HttpRedirectUrlMap.build(allocator, provider, .{
                .name = redirect_map_name,
                .strip_query = args.redirect_strip_query,
            });
            defer redirect_map.deinit(allocator);
            try graph.addResource(redirect_map.node);

            const http_name = try resourceNameAlloc(allocator, args.name, "http");
            defer allocator.free(http_name);
            const redirect_map_link = try std.fmt.allocPrint(allocator, "projects/{s}/global/urlMaps/{s}", .{ provider.project_id, redirect_map_name });
            defer allocator.free(redirect_map_link);
            var http_proxy = try compute.TargetHttpProxy.build(allocator, provider, .{
                .name = http_name,
                .url_map = redirect_map_link,
            });
            defer http_proxy.deinit(allocator);
            try graph.addResource(http_proxy.node);
            try graph.bindOutput(http_proxy.node.id, redirect_map.self_link);

            const http_proxy_link = try std.fmt.allocPrint(allocator, "projects/{s}/global/targetHttpProxies/{s}", .{ provider.project_id, http_name });
            defer allocator.free(http_proxy_link);
            var http_forwarding = try compute.GlobalForwardingRule.build(allocator, provider, .{
                .name = http_name,
                .address_output = address.address,
                .target = http_proxy_link,
                .port = 80,
            });
            defer http_forwarding.deinit(allocator);
            try graph.addResource(http_forwarding.node);
            try graph.bindOutput(http_forwarding.node.id, address.address);
            try graph.bindOutput(http_forwarding.node.id, http_proxy.self_link);
        }

        if (args.dns_zone) |zone| {
            const fqdn = try std.fmt.allocPrint(allocator, "{s}.", .{args.domain});
            defer allocator.free(fqdn);
            var record = try dns.RecordSet.build(allocator, provider, .{
                .zone = zone,
                .name = fqdn,
                .record_type = .a,
                .ttl = args.dns_ttl,
                .rrdata_outputs = &.{address.address},
            });
            defer record.deinit(allocator);
            try graph.addResource(record.node);
        }

        try graph.validateAcyclic();
        const owned_url = try std.fmt.allocPrint(allocator, "https://{s}", .{args.domain});
        errdefer allocator.free(owned_url);
        const address_resource_id = try allocator.dupe(u8, address.node.id);
        errdefer allocator.free(address_resource_id);
        const certificate_resource_id = try allocator.dupe(u8, certificate.node.id);
        errdefer allocator.free(certificate_resource_id);
        return .{
            .allocator = allocator,
            .graph = graph,
            .url = output.Output([]const u8, .public).known(owned_url),
            .ip_address = compute.GlobalAddress.Outputs.Address.fromResource(address_resource_id),
            .certificate_status = compute.ManagedSslCertificate.Outputs.Status.fromResource(certificate_resource_id),
            .owned_url = owned_url,
            .address_resource_id = address_resource_id,
            .certificate_resource_id = certificate_resource_id,
        };
    }

    pub fn deinit(self: *ContainerService) void {
        self.graph.deinit();
        self.allocator.free(self.owned_url);
        self.allocator.free(self.address_resource_id);
        self.allocator.free(self.certificate_resource_id);
        self.* = undefined;
    }

    pub fn takeGraph(self: *ContainerService) resource.ResourceGraph {
        const graph = self.graph;
        self.graph = resource.ResourceGraph.init(self.allocator);
        return graph;
    }
};

fn validate(
    provider: config_mod.ProviderConfig,
    args: ContainerServiceArgs,
    regions: []const []const u8,
) BuildError!void {
    try provider.validate();
    if (regions.len < 2) return error.InsufficientRegions;
    if (provider.network_tier != .premium) return error.PremiumTierRequired;
    for (regions, 0..) |region, index| {
        if (region.len == 0) return error.MissingRegion;
        for (regions[index + 1 ..]) |other| {
            if (std.mem.eql(u8, region, other)) return error.DuplicateRegion;
        }
    }
    if (args.direct_vpc != null and args.regional_direct_vpc.len > 0) return error.ConflictingVpcConfiguration;
    if (args.regional_direct_vpc.len > 0) {
        if (args.regional_direct_vpc.len != regions.len) return error.RegionalVpcMismatch;
        for (args.regional_direct_vpc, 0..) |binding, index| {
            for (args.regional_direct_vpc[index + 1 ..]) |other| {
                if (std.mem.eql(u8, binding.region, other.region)) return error.DuplicateVpcRegion;
            }
            var found = false;
            for (regions) |region| if (std.mem.eql(u8, binding.region, region)) {
                found = true;
                break;
            };
            if (!found) return error.RegionalVpcMismatch;
        }
    }
    if (args.health_mode == .production) {
        if (args.min_instances == 0) return error.ProductionMinInstancesRequired;
        if (args.startup_probe == null or args.liveness_probe == null) return error.ProductionProbeRequired;
    }
}

fn directVpcForRegion(args: ContainerServiceArgs, region: []const u8) ?cloud_run.DirectVpc {
    if (args.regional_direct_vpc.len == 0) return args.direct_vpc;
    for (args.regional_direct_vpc) |binding| {
        if (std.mem.eql(u8, binding.region, region)) return binding.config;
    }
    unreachable;
}

fn resourceNameAlloc(
    allocator: std.mem.Allocator,
    name: []const u8,
    suffix: []const u8,
) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ name, suffix });
}
