const std = @import("std");
const config_mod = @import("config.zig");
const governance = @import("governance.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");

pub const BuildError = governance.BuildError || resource.ResourceGraphError || std.mem.Allocator.Error || error{
    DuplicatePolicy,
    InvalidName,
};

pub const BoundaryPolicySpec = struct {
    name: []const u8,
    constraint: []const u8,
    spec: governance.PolicySpec,
    dry_run_spec: ?governance.PolicySpec = null,
};

pub const GovernedProjectBoundaryArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    project: output.Output([]const u8, .public),
    project_full_name: output.Output([]const u8, .public),
    policies: []const BoundaryPolicySpec = &.{},
    tag_value: output.Output([]const u8, .public),
    access_policy: output.Output([]const u8, .public),
    access_level: ?output.Output([]const u8, .public) = null,
    restricted_services: []const []const u8,
    dry_run_restricted_services: ?[]const []const u8 = null,
    removal_policy: governance.RemovalPolicy = .retain,
};

pub const GovernedProjectBoundary = struct {
    graph: resource.ResourceGraph,
    tag_binding: output.Output([]const u8, .public),
    perimeter: output.Output([]const u8, .public),

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: GovernedProjectBoundaryArgs) BuildError!GovernedProjectBoundary {
        if (args.name.len == 0 or args.name.len > 63) return error.InvalidName;
        try ensureUniquePolicies(args.policies);
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);

        for (args.policies) |policy_spec| {
            const logical_name = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ args.name, policy_spec.name });
            defer allocator.free(logical_name);
            var policy = try governance.Policy.build(allocator, provider, .{
                .name = logical_name,
                .parent = args.project,
                .constraint = policy_spec.constraint,
                .spec = policy_spec.spec,
                .dry_run_spec = policy_spec.dry_run_spec,
                .removal_policy = args.removal_policy,
            });
            defer policy.deinit(allocator);
            try graph.addResource(policy.node);
        }

        const tag_name = try std.fmt.allocPrint(allocator, "{s}-tag", .{args.name});
        defer allocator.free(tag_name);
        var binding = try governance.TagBinding.build(allocator, provider, .{
            .name = tag_name,
            .parent = args.project_full_name,
            .tag_value = args.tag_value,
            .removal_policy = args.removal_policy,
        });
        defer binding.deinit(allocator);
        try graph.addResource(binding.node);
        const binding_id = graph.resources.items[graph.resources.items.len - 1].id;

        var access_levels: [1]output.Output([]const u8, .public) = undefined;
        const selected_levels: []const output.Output([]const u8, .public) = if (args.access_level) |level| blk: {
            access_levels[0] = level;
            break :blk &access_levels;
        } else &.{};
        const enforced = governance.ServicePerimeterConfig{
            .resources = &.{args.project},
            .restricted_services = args.restricted_services,
            .access_levels = selected_levels,
        };
        const dry_run: ?governance.ServicePerimeterConfig = if (args.dry_run_restricted_services) |services| .{
            .resources = &.{args.project},
            .restricted_services = services,
            .access_levels = selected_levels,
        } else null;
        const perimeter_name = try accessIdentifierAlloc(allocator, args.name);
        defer allocator.free(perimeter_name);
        var perimeter = try governance.ServicePerimeter.build(allocator, provider, .{
            .name = perimeter_name,
            .policy = args.access_policy,
            .title = args.name,
            .status = enforced,
            .dry_run = dry_run,
            .removal_policy = args.removal_policy,
        });
        defer perimeter.deinit(allocator);
        try graph.addResource(perimeter.node);
        const perimeter_id = graph.resources.items[graph.resources.items.len - 1].id;

        try graph.validateAcyclic();
        return .{
            .graph = graph,
            .tag_binding = governance.TagBinding.Outputs.Name.fromResource(binding_id),
            .perimeter = governance.ServicePerimeter.Outputs.Name.fromResource(perimeter_id),
        };
    }

    pub fn deinit(self: *GovernedProjectBoundary) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

fn ensureUniquePolicies(policies: []const BoundaryPolicySpec) BuildError!void {
    for (policies, 0..) |policy, index| {
        for (policies[index + 1 ..]) |other| {
            if (std.mem.eql(u8, policy.name, other.name)) return error.DuplicatePolicy;
        }
    }
}

fn accessIdentifierAlloc(allocator: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]u8 {
    const normalized = try allocator.dupe(u8, name);
    for (normalized) |*char| if (char.* == '-') {
        char.* = '_';
    };
    return normalized;
}
