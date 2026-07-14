const std = @import("std");
const config_mod = @import("config.zig");
const edge = @import("edge_security.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");

pub const BuildError = edge.BuildError || resource.ResourceGraphError || std.mem.Allocator.Error;

pub const ProtectedCdnBucketArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    bucket: output.Output([]const u8, .public),
    rules: []const edge.SecurityRule,
    cache_mode: edge.CacheMode = .cache_all_static,
    client_ttl_seconds: u32 = 3600,
    default_ttl_seconds: u32 = 3600,
    max_ttl_seconds: u32 = 86_400,
    negative_caching: bool = true,
    serve_while_stale_seconds: u32 = 86_400,
    request_coalescing: bool = true,
    compression: edge.CompressionMode = .automatic,
    protect: bool = true,
    retain_on_delete: bool = false,
};

pub const ProtectedCdnBucket = struct {
    graph: resource.ResourceGraph,
    backend_bucket: output.Output([]const u8, .public),
    security_policy: output.Output([]const u8, .public),

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ProtectedCdnBucketArgs) BuildError!ProtectedCdnBucket {
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);
        const policy_name = try std.fmt.allocPrint(allocator, "{s}-edge", .{args.name});
        defer allocator.free(policy_name);
        const policy_index = graph.resources.items.len;
        var policy = try edge.SecurityPolicy.build(allocator, provider, .{
            .name = policy_name,
            .policy_type = .edge,
            .rules = args.rules,
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
        });
        defer policy.deinit(allocator);
        try graph.addResource(policy.node);
        const policy_id = graph.resources.items[policy_index].id;

        const backend_index = graph.resources.items.len;
        var backend = try edge.BackendBucket.build(allocator, provider, .{
            .name = args.name,
            .bucket = args.bucket,
            .edge_security_policy = edge.SecurityPolicy.Outputs.SelfLink.fromResource(policy_id),
            .cache_mode = args.cache_mode,
            .client_ttl_seconds = args.client_ttl_seconds,
            .default_ttl_seconds = args.default_ttl_seconds,
            .max_ttl_seconds = args.max_ttl_seconds,
            .negative_caching = args.negative_caching,
            .serve_while_stale_seconds = args.serve_while_stale_seconds,
            .request_coalescing = args.request_coalescing,
            .compression = args.compression,
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
        });
        defer backend.deinit(allocator);
        try graph.addResource(backend.node);
        const backend_id = graph.resources.items[backend_index].id;
        try graph.validateAcyclic();
        return .{
            .graph = graph,
            .backend_bucket = edge.BackendBucket.Outputs.SelfLink.fromResource(backend_id),
            .security_policy = edge.SecurityPolicy.Outputs.SelfLink.fromResource(policy_id),
        };
    }

    pub fn deinit(self: *ProtectedCdnBucket) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

pub const DnsRecordOutputs = struct {
    name: output.Output([]const u8, .public),
    record_name: output.Output([]const u8, .public),
    record_type: output.Output([]const u8, .public),
    record_data: output.Output([]const u8, .public),
};

pub const ManagedCertificateMapArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    domains: []const []const u8,
    location: []const u8 = "global",
    certificate_scope: edge.CertificateScope = .default,
    protect: bool = true,
    retain_on_delete: bool = false,
};

pub const ManagedCertificateMap = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    map: output.Output([]const u8, .public),
    dns_records: []DnsRecordOutputs,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ManagedCertificateMapArgs) BuildError!ManagedCertificateMap {
        if (args.domains.len == 0) return error.InvalidCertificate;
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);
        const records = try allocator.alloc(DnsRecordOutputs, args.domains.len);
        errdefer allocator.free(records);
        const certificate_ids = try allocator.alloc([]const u8, args.domains.len);
        defer allocator.free(certificate_ids);

        for (args.domains, 0..) |domain, index| {
            const child_name = try childNameAlloc(allocator, args.name, index);
            defer allocator.free(child_name);
            const authorization_index = graph.resources.items.len;
            var authorization = try edge.DnsAuthorization.build(allocator, provider, .{
                .name = child_name,
                .domain = domain,
                .location = args.location,
                .protect = args.protect,
                .retain_on_delete = args.retain_on_delete,
            });
            defer authorization.deinit(allocator);
            try graph.addResource(authorization.node);
            const authorization_id = graph.resources.items[authorization_index].id;
            records[index] = .{
                .name = edge.DnsAuthorization.Outputs.Name.fromResource(authorization_id),
                .record_name = edge.DnsAuthorization.Outputs.DnsRecordName.fromResource(authorization_id),
                .record_type = edge.DnsAuthorization.Outputs.DnsRecordType.fromResource(authorization_id),
                .record_data = edge.DnsAuthorization.Outputs.DnsRecordData.fromResource(authorization_id),
            };

            const certificate_index = graph.resources.items.len;
            var certificate = try edge.Certificate.build(allocator, provider, .{
                .name = child_name,
                .domains = &.{domain},
                .dns_authorizations = &.{edge.DnsAuthorization.Outputs.Name.fromResource(authorization_id)},
                .location = args.location,
                .scope = args.certificate_scope,
                .protect = args.protect,
                .retain_on_delete = args.retain_on_delete,
            });
            defer certificate.deinit(allocator);
            try graph.addResource(certificate.node);
            certificate_ids[index] = graph.resources.items[certificate_index].id;
        }

        const map_index = graph.resources.items.len;
        var certificate_map = try edge.CertificateMap.build(allocator, provider, .{
            .name = args.name,
            .location = args.location,
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
        });
        defer certificate_map.deinit(allocator);
        try graph.addResource(certificate_map.node);
        const map_id = graph.resources.items[map_index].id;

        for (args.domains, 0..) |domain, index| {
            const child_name = try childNameAlloc(allocator, args.name, index);
            defer allocator.free(child_name);
            var entry = try edge.CertificateMapEntry.build(allocator, provider, .{
                .name = child_name,
                .map = edge.CertificateMap.Outputs.Name.fromResource(map_id),
                .matcher = .{ .hostname = domain },
                .certificates = &.{edge.Certificate.Outputs.Name.fromResource(certificate_ids[index])},
                .location = args.location,
                .protect = args.protect,
                .retain_on_delete = args.retain_on_delete,
            });
            defer entry.deinit(allocator);
            try graph.addResource(entry.node);
        }
        try graph.validateAcyclic();
        return .{
            .allocator = allocator,
            .graph = graph,
            .map = edge.CertificateMap.Outputs.Name.fromResource(map_id),
            .dns_records = records,
        };
    }

    pub fn deinit(self: *ManagedCertificateMap) void {
        self.allocator.free(self.dns_records);
        self.graph.deinit();
        self.* = undefined;
    }
};

fn childNameAlloc(allocator: std.mem.Allocator, base: []const u8, index: usize) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}-{d}", .{ base, index + 1 });
}
