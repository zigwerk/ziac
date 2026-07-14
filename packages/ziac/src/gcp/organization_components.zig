const std = @import("std");
const config_mod = @import("config.zig");
const organization = @import("organization.zig");
const output = @import("../output.zig");
const project_service = @import("project_service.zig");
const resource = @import("../resource.zig");

pub const BuildError = organization.BuildError || project_service.BuildError || resource.ResourceGraphError || std.mem.Allocator.Error || error{
    DuplicateService,
    DuplicateServiceIdentity,
    InvalidName,
};

pub const FolderSpec = struct {
    display_name: []const u8,
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const ProjectFoundationArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    parent: output.Output([]const u8, .public),
    folder: ?FolderSpec = null,
    project_id: []const u8,
    project_display_name: []const u8 = "",
    project_labels: []const config_mod.Label = &.{},
    billing_account: []const u8,
    services: []const []const u8 = &.{},
    service_identities: []const []const u8 = &.{},
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const ProjectFoundation = struct {
    graph: resource.ResourceGraph,
    folder: ?output.Output([]const u8, .public),
    project: output.Output([]const u8, .public),
    project_id: output.Output([]const u8, .public),
    project_number: output.Output([]const u8, .public),
    billing_enabled: output.Output(bool, .public),

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ProjectFoundationArgs) BuildError!ProjectFoundation {
        if (args.name.len == 0 or args.name.len > 63) return error.InvalidName;
        try ensureUnique(args.services, .service);
        try ensureUnique(args.service_identities, .identity);
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);

        var project_parent = args.parent;
        var folder_output: ?output.Output([]const u8, .public) = null;
        if (args.folder) |spec| {
            var folder = try organization.Folder.build(allocator, provider, .{
                .name = args.name,
                .parent = args.parent,
                .display_name = spec.display_name,
                .protect = spec.protect,
                .retain_on_delete = spec.retain_on_delete,
            });
            defer folder.deinit(allocator);
            try graph.addResource(folder.node);
            folder_output = organization.Folder.Outputs.Name.fromResource(graph.resources.items[graph.resources.items.len - 1].id);
            project_parent = folder_output.?;
        }

        var project = try organization.Project.build(allocator, provider, .{
            .project_id = args.project_id,
            .parent = project_parent,
            .display_name = args.project_display_name,
            .labels = args.project_labels,
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
        });
        defer project.deinit(allocator);
        try graph.addResource(project.node);
        const project_resource_id = graph.resources.items[graph.resources.items.len - 1].id;
        const project_name = organization.Project.Outputs.Name.fromResource(project_resource_id);
        const project_number = organization.Project.Outputs.ProjectNumber.fromResource(project_resource_id);

        var billing = try organization.ProjectBillingAssociation.build(allocator, provider, .{
            .name = args.project_id,
            .project = project_name,
            .billing_account = args.billing_account,
        });
        defer billing.deinit(allocator);
        try graph.addResource(billing.node);
        const billing_id = graph.resources.items[graph.resources.items.len - 1].id;

        var target_provider = provider;
        target_provider.project_id = args.project_id;
        for (args.services) |service_name| {
            const logical_name = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ args.project_id, service_name });
            defer allocator.free(logical_name);
            var service = try project_service.Service.build(allocator, target_provider, .{ .name = logical_name, .service = service_name });
            defer service.deinit(allocator);
            try graph.addResource(service.node);
            try graph.addDependency(graph.resources.items[graph.resources.items.len - 1].id, project_resource_id);
        }
        for (args.service_identities) |service_name| {
            const logical_name = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ args.project_id, service_name });
            defer allocator.free(logical_name);
            var identity = try organization.ServiceIdentity.build(allocator, provider, .{
                .name = logical_name,
                .project_number = project_number,
                .service = service_name,
            });
            defer identity.deinit(allocator);
            try graph.addResource(identity.node);
        }
        try graph.validateAcyclic();
        return .{
            .graph = graph,
            .folder = folder_output,
            .project = project_name,
            .project_id = organization.Project.Outputs.ProjectId.fromResource(project_resource_id),
            .project_number = project_number,
            .billing_enabled = organization.ProjectBillingAssociation.Outputs.BillingEnabled.fromResource(billing_id),
        };
    }

    pub fn deinit(self: *ProjectFoundation) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

const DuplicateKind = enum { service, identity };

fn ensureUnique(items: []const []const u8, kind: DuplicateKind) BuildError!void {
    for (items, 0..) |item, index| {
        for (items[index + 1 ..]) |other| {
            if (!std.mem.eql(u8, item, other)) continue;
            return switch (kind) {
                .service => error.DuplicateService,
                .identity => error.DuplicateServiceIdentity,
            };
        }
    }
}
