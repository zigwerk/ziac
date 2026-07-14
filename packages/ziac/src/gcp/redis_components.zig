const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const redis = @import("redis.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = redis.BuildError || resource.ResourceGraphError || error{
    ConflictingAclPolicy,
    InvalidComponentName,
};

pub const ManagedAclPolicy = struct {
    policy_id: []const u8,
    rules: []const redis.AclRule,
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const ClusterSpec = struct {
    cluster: redis.ClusterArgs,
    acl_policy: ?ManagedAclPolicy = null,
};

pub const CacheSpec = union(enum) {
    classic: redis.InstanceArgs,
    cluster: ClusterSpec,
};

pub const MemorystoreCacheArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    cache: CacheSpec,
};

pub const MemorystoreCache = struct {
    graph: resource.ResourceGraph,
    name: output.Output([]const u8, .public),
    state: output.Output([]const u8, .public),
    host: ?output.Output([]const u8, .public),
    port: ?output.Output(i64, .public),
    read_endpoint: ?output.Output([]const u8, .public),
    auth_secret_version: ?output.Output(value.SecretReference, .secret),
    discovery_endpoint: ?output.Output([]const u8, .public),

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: MemorystoreCacheArgs) BuildError!MemorystoreCache {
        if (args.name.len == 0 or std.mem.indexOfAny(u8, args.name, "\x00\r\n") != null) return error.InvalidComponentName;
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);

        const built: MemorystoreCache = switch (args.cache) {
            .classic => |classic_args| blk: {
                const instance_index = graph.resources.items.len;
                var instance = try redis.Instance.build(allocator, provider, classic_args);
                defer instance.deinit(allocator);
                try graph.addResource(instance.node);
                const instance_id = graph.resources.items[instance_index].id;
                break :blk .{
                    .graph = graph,
                    .name = redis.Instance.Outputs.Name.fromResource(instance_id),
                    .state = redis.Instance.Outputs.State.fromResource(instance_id),
                    .host = redis.Instance.Outputs.Host.fromResource(instance_id),
                    .port = redis.Instance.Outputs.Port.fromResource(instance_id),
                    .read_endpoint = redis.Instance.Outputs.ReadEndpoint.fromResource(instance_id),
                    .auth_secret_version = if (classic_args.auth_enabled) redis.Instance.Outputs.AuthSecretVersion.fromResource(instance_id) else null,
                    .discovery_endpoint = null,
                };
            },
            .cluster => |spec| blk: {
                if (spec.acl_policy != null and spec.cluster.acl_policy != null) return error.ConflictingAclPolicy;
                var cluster_args = spec.cluster;
                if (spec.acl_policy) |acl_spec| {
                    const acl_index = graph.resources.items.len;
                    var acl = try redis.AclPolicy.build(allocator, provider, .{
                        .policy_id = acl_spec.policy_id,
                        .location = spec.cluster.location,
                        .rules = acl_spec.rules,
                        .protect = acl_spec.protect,
                        .retain_on_delete = acl_spec.retain_on_delete,
                    });
                    defer acl.deinit(allocator);
                    try graph.addResource(acl.node);
                    cluster_args.acl_policy = redis.AclPolicy.Outputs.Name.fromResource(graph.resources.items[acl_index].id);
                }
                const cluster_index = graph.resources.items.len;
                var cluster = try redis.Cluster.build(allocator, provider, cluster_args);
                defer cluster.deinit(allocator);
                try graph.addResource(cluster.node);
                const cluster_id = graph.resources.items[cluster_index].id;
                break :blk .{
                    .graph = graph,
                    .name = redis.Cluster.Outputs.Name.fromResource(cluster_id),
                    .state = redis.Cluster.Outputs.State.fromResource(cluster_id),
                    .host = null,
                    .port = null,
                    .read_endpoint = null,
                    .auth_secret_version = null,
                    .discovery_endpoint = redis.Cluster.Outputs.DiscoveryEndpoint.fromResource(cluster_id),
                };
            },
        };
        try built.graph.validateAcyclic();
        return built;
    }

    pub fn deinit(self: *MemorystoreCache) void {
        self.graph.deinit();
        self.* = undefined;
    }
};
