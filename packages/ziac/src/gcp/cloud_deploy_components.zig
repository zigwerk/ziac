const std = @import("std");
const cloud_deploy = @import("cloud_deploy.zig");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");

pub const BuildError = cloud_deploy.BuildError || resource.ResourceGraphError || std.mem.Allocator.Error;

pub const Region = struct {
    region: []const u8,
    profile: []const u8,
    require_approval: bool = false,
};

pub const AutomationSpec = struct {
    enabled: bool = false,
    wait_seconds: u32 = 0,
    repair_attempts: u8 = 0,
};

pub const ProductionFreeze = struct {
    target_region: []const u8,
    time_zone: []const u8,
    days: []const cloud_deploy.Day,
};

pub const GlobalCloudRunDeliveryArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    location: []const u8,
    regions: []const Region,
    service_account: []const u8,
    canary_percentages: []const u8 = &.{},
    automation: ?AutomationSpec = null,
    production_freeze: ?ProductionFreeze = null,
    protect: bool = true,
};

pub const GlobalCloudRunDelivery = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    pipeline: output.Output([]const u8, .public),
    automation: ?output.Output([]const u8, .public),
    policy: ?output.Output([]const u8, .public),

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: GlobalCloudRunDeliveryArgs) BuildError!GlobalCloudRunDelivery {
        try provider.validate();
        if (args.regions.len == 0) return error.InvalidTarget;
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);

        const stages = try allocator.alloc(cloud_deploy.Stage, args.regions.len);
        defer allocator.free(stages);
        const target_ids = try allocator.alloc([]const u8, args.regions.len);
        var target_ids_initialized: usize = 0;
        defer {
            for (target_ids[0..target_ids_initialized]) |id| allocator.free(id);
            allocator.free(target_ids);
        }

        for (args.regions, 0..) |region, index| {
            if (region.region.len == 0 or region.profile.len == 0) return error.InvalidTarget;
            for (args.regions[0..index]) |previous| if (std.mem.eql(u8, previous.region, region.region)) return error.InvalidTarget;
            const target_name = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ args.name, region.region });
            target_ids[index] = target_name;
            target_ids_initialized += 1;
            var target = try cloud_deploy.Target.build(allocator, provider, .{
                .name = target_name,
                .location = args.location,
                .runtime = .{ .cloud_run = .{ .location = region.region } },
                .require_approval = region.require_approval,
                .execution = &.{.{
                    .usages = &.{ .render, .deploy, .verify },
                    .service_account = args.service_account,
                }},
                .protect = args.protect,
            });
            defer target.deinit(allocator);
            try graph.addResource(target.node);
            const target_id = graph.resources.items[graph.resources.items.len - 1].id;
            stages[index] = .{
                .target = cloud_deploy.Target.Outputs.Name.fromResource(target_id),
                .profiles = &.{region.profile},
                .strategy = if (index + 1 == args.regions.len and args.canary_percentages.len != 0)
                    .{ .canary = .{ .percentages = args.canary_percentages, .verify = true } }
                else
                    .{ .standard = .{ .verify = true } },
            };
        }

        var pipeline = try cloud_deploy.DeliveryPipeline.build(allocator, provider, .{
            .name = args.name,
            .location = args.location,
            .description = "Global Cloud Run delivery progression",
            .stages = stages,
            .protect = args.protect,
        });
        defer pipeline.deinit(allocator);
        try graph.addResource(pipeline.node);
        const pipeline_id = graph.resources.items[graph.resources.items.len - 1].id;
        const pipeline_output = cloud_deploy.DeliveryPipeline.Outputs.Name.fromResource(pipeline_id);

        var automation_output: ?output.Output([]const u8, .public) = null;
        if (args.automation) |spec| {
            const automation_name = try std.fmt.allocPrint(allocator, "{s}-progress", .{args.name});
            defer allocator.free(automation_name);
            const rules = [_]cloud_deploy.AutomationRule{
                .{ .promote = .{ .id = "promote-next", .wait_seconds = spec.wait_seconds } },
                .{ .advance = .{ .id = "advance-canary", .wait_seconds = spec.wait_seconds } },
                .{ .repair = .{
                    .id = "repair-rollout",
                    .retry = if (spec.repair_attempts == 0) null else .{ .attempts = spec.repair_attempts, .wait_seconds = spec.wait_seconds },
                    .rollback = .{},
                } },
            };
            var automation = try cloud_deploy.Automation.build(allocator, provider, .{
                .name = automation_name,
                .location = args.location,
                .pipeline_name = args.name,
                .pipeline = pipeline_output,
                .service_account = args.service_account,
                .target_ids = &.{target_ids[0]},
                .rules = &rules,
                .suspended = !spec.enabled,
                .protect = args.protect,
            });
            defer automation.deinit(allocator);
            try graph.addResource(automation.node);
            automation_output = cloud_deploy.Automation.Outputs.Name.fromResource(graph.resources.items[graph.resources.items.len - 1].id);
        }

        var policy_output: ?output.Output([]const u8, .public) = null;
        if (args.production_freeze) |freeze| {
            var target_name: ?[]const u8 = null;
            for (args.regions, 0..) |region, index| if (std.mem.eql(u8, region.region, freeze.target_region)) {
                target_name = target_ids[index];
                break;
            };
            const selected = target_name orelse return error.InvalidTarget;
            const policy_name = try std.fmt.allocPrint(allocator, "{s}-production-guard", .{args.name});
            defer allocator.free(policy_name);
            const restrictions = [_]cloud_deploy.RolloutRestriction{.{
                .id = "production-freeze",
                .invokers = &.{ .user, .automation },
                .actions = &.{ .create, .advance, .approve, .rollback },
                .time_zone = freeze.time_zone,
                .weekly_windows = &.{.{ .days = freeze.days }},
            }};
            var policy = try cloud_deploy.DeployPolicy.build(allocator, provider, .{
                .name = policy_name,
                .location = args.location,
                .selectors = &.{.{ .pipeline_id = args.name, .target_id = selected }},
                .rules = &restrictions,
                .protect = args.protect,
                .retain_on_delete = args.protect,
            });
            defer policy.deinit(allocator);
            try graph.addResource(policy.node);
            policy_output = cloud_deploy.DeployPolicy.Outputs.Name.fromResource(graph.resources.items[graph.resources.items.len - 1].id);
        }

        try graph.validateAcyclic();
        return .{
            .allocator = allocator,
            .graph = graph,
            .pipeline = pipeline_output,
            .automation = automation_output,
            .policy = policy_output,
        };
    }

    pub fn deinit(self: *GlobalCloudRunDelivery) void {
        self.graph.deinit();
        self.* = undefined;
    }
};
