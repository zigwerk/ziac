const std = @import("std");
const build_delivery = @import("build_delivery.zig");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");

pub const BuildError = build_delivery.BuildError || build_delivery.artifact.BuildError || resource.ResourceGraphError || std.mem.Allocator.Error;

pub const PrivatePoolSpec = struct {
    machine_type: []const u8 = "e2-standard-4",
    disk_size_gb: u16 = 100,
    nested_virtualization: bool = false,
    network: ?build_delivery.WorkerNetwork = null,
};

pub const ZigBuildPipelineArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    location: []const u8,
    connection: build_delivery.ConnectionConfig,
    remote_uri: []const u8,
    event: build_delivery.TriggerEvent = .{ .push = .{ .branch = "^main$" } },
    filename: []const u8 = "cloudbuild.yaml",
    service_account: ?[]const u8 = null,
    require_approval: bool = false,
    private_pool: ?PrivatePoolSpec = null,
    artifact_format: build_delivery.artifact.Format = .docker,
    artifact_description: []const u8 = "Zig build artifacts",
    artifact_kms_key: ?output.Output([]const u8, .public) = null,
    cleanup_policies: []const build_delivery.artifact.CleanupPolicy = &.{},
    cleanup_dry_run: bool = true,
    vulnerability_scanning: build_delivery.artifact.VulnerabilityScanning = .inherited,
    protect: bool = true,
};

pub const ZigBuildPipeline = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    connection: output.Output([]const u8, .public),
    source_repository: output.Output([]const u8, .public),
    worker_pool: ?output.Output([]const u8, .public),
    trigger: output.Output([]const u8, .public),
    artifact_repository: output.Output([]const u8, .public),

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ZigBuildPipelineArgs) BuildError!ZigBuildPipeline {
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);

        var connection = try build_delivery.Connection.build(allocator, provider, .{ .name = args.name, .location = args.location, .config = args.connection, .protect = args.protect });
        defer connection.deinit(allocator);
        try graph.addResource(connection.node);
        const connection_id = graph.resources.items[graph.resources.items.len - 1].id;
        const connection_output = build_delivery.Connection.Outputs.Name.fromResource(connection_id);

        var source = try build_delivery.Repository.build(allocator, provider, .{
            .name = args.name,
            .location = args.location,
            .connection_name = args.name,
            .connection = connection_output,
            .remote_uri = args.remote_uri,
            .protect = args.protect,
        });
        defer source.deinit(allocator);
        try graph.addResource(source.node);
        const source_id = graph.resources.items[graph.resources.items.len - 1].id;
        const source_output = build_delivery.Repository.Outputs.Name.fromResource(source_id);

        var pool_output: ?output.Output([]const u8, .public) = null;
        if (args.private_pool) |spec| {
            const pool_name = try std.fmt.allocPrint(allocator, "{s}-pool", .{args.name});
            defer allocator.free(pool_name);
            var pool = try build_delivery.WorkerPool.build(allocator, provider, .{
                .name = pool_name,
                .location = args.location,
                .machine_type = spec.machine_type,
                .disk_size_gb = spec.disk_size_gb,
                .nested_virtualization = spec.nested_virtualization,
                .network = spec.network,
                .protect = args.protect,
            });
            defer pool.deinit(allocator);
            try graph.addResource(pool.node);
            pool_output = build_delivery.WorkerPool.Outputs.Name.fromResource(graph.resources.items[graph.resources.items.len - 1].id);
        }

        const artifact_name = try std.fmt.allocPrint(allocator, "{s}-artifacts", .{args.name});
        defer allocator.free(artifact_name);
        var artifacts = try build_delivery.artifact.Repository.build(allocator, provider, .{
            .name = artifact_name,
            .location = args.location,
            .format = args.artifact_format,
            .description = args.artifact_description,
            .kms_key_name = args.artifact_kms_key,
            .cleanup_policies = args.cleanup_policies,
            .cleanup_policy_dry_run = args.cleanup_dry_run,
            .vulnerability_scanning = args.vulnerability_scanning,
            .protect = args.protect,
        });
        defer artifacts.deinit(allocator);
        try graph.addResource(artifacts.node);
        const artifact_id = graph.resources.items[graph.resources.items.len - 1].id;
        const artifact_output = build_delivery.artifact.Repository.Outputs.RepositoryUrl.fromResource(artifact_id);

        const trigger_name = try std.fmt.allocPrint(allocator, "{s}-trigger", .{args.name});
        defer allocator.free(trigger_name);
        var trigger = try build_delivery.Trigger.build(allocator, provider, .{
            .name = trigger_name,
            .location = args.location,
            .repository = source_output,
            .event = args.event,
            .filename = args.filename,
            .service_account = args.service_account,
            .require_approval = args.require_approval,
            .worker_pool = pool_output,
            .protect = args.protect,
        });
        defer trigger.deinit(allocator);
        try graph.addResource(trigger.node);
        const trigger_id = graph.resources.items[graph.resources.items.len - 1].id;
        try graph.addDependency(trigger_id, artifact_id);

        try graph.validateAcyclic();
        return .{
            .allocator = allocator,
            .graph = graph,
            .connection = connection_output,
            .source_repository = source_output,
            .worker_pool = pool_output,
            .trigger = build_delivery.Trigger.Outputs.Name.fromResource(trigger_id),
            .artifact_repository = artifact_output,
        };
    }

    pub fn deinit(self: *ZigBuildPipeline) void {
        self.graph.deinit();
        self.* = undefined;
    }
};
