const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");
const workloads = @import("compute_workloads.zig");

pub const BuildError = workloads.BuildError || resource.ResourceGraphError || std.mem.Allocator.Error;

pub const VirtualMachineArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    zone: []const u8,
    machine_type: []const u8,
    source_image: output.Output([]const u8, .public),
    disk_name: []const u8 = "",
    disk_size_gb: u64 = 20,
    disk_type: workloads.DiskType = .balanced,
    kms_key: ?output.Output([]const u8, .public) = null,
    network_interfaces: []const workloads.NetworkInterface,
    service_account: output.Output([]const u8, .public),
    oauth_scopes: []const []const u8 = &.{"https://www.googleapis.com/auth/cloud-platform"},
    tags: []const []const u8 = &.{},
    labels: []const config_mod.Label = &.{},
    metadata: []const workloads.Metadata = &.{},
    startup_script: ?output.Output(value.SecretReference, .secret) = null,
    startup_script_sha256: []const u8 = "",
    external_access: bool = false,
    deletion_protection: bool = true,
    shielded_vm: workloads.ShieldedVm = .{},
    confidential_compute: bool = false,
    protect: bool = true,
    retain_disk: bool = true,
};

pub const VirtualMachine = struct {
    graph: resource.ResourceGraph,
    instance: output.Output([]const u8, .public),
    internal_ip: output.Output([]const u8, .public),
    external_ip: output.Output([]const u8, .public),
    disk: output.Output([]const u8, .public),

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: VirtualMachineArgs) BuildError!VirtualMachine {
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);
        const owned_disk_name = if (args.disk_name.len > 0)
            try allocator.dupe(u8, args.disk_name)
        else
            try std.fmt.allocPrint(allocator, "{s}-boot", .{args.name});
        defer allocator.free(owned_disk_name);

        const disk_index = graph.resources.items.len;
        var disk = try workloads.Disk.build(allocator, provider, .{
            .name = owned_disk_name,
            .zone = args.zone,
            .size_gb = args.disk_size_gb,
            .disk_type = args.disk_type,
            .source_image = args.source_image,
            .kms_key = args.kms_key,
            .labels = args.labels,
            .protect = args.protect,
            .retain_on_delete = args.retain_disk,
        });
        defer disk.deinit(allocator);
        try graph.addResource(disk.node);
        const disk_id = graph.resources.items[disk_index].id;

        const interfaces = try allocator.dupe(workloads.NetworkInterface, args.network_interfaces);
        defer allocator.free(interfaces);
        if (args.external_access and interfaces.len > 0) interfaces[0].external_access = true;
        const instance_index = graph.resources.items.len;
        var instance = try workloads.Instance.build(allocator, provider, .{
            .name = args.name,
            .zone = args.zone,
            .machine_type = args.machine_type,
            .boot_disk = workloads.Disk.Outputs.SelfLink.fromResource(disk_id),
            .boot_disk_auto_delete = false,
            .network_interfaces = interfaces,
            .service_account = args.service_account,
            .oauth_scopes = args.oauth_scopes,
            .tags = args.tags,
            .labels = args.labels,
            .metadata = args.metadata,
            .startup_script = args.startup_script,
            .startup_script_sha256 = args.startup_script_sha256,
            .deletion_protection = args.deletion_protection,
            .shielded_vm = args.shielded_vm,
            .confidential_compute = args.confidential_compute,
            .protect = args.protect,
            .retain_on_delete = false,
        });
        defer instance.deinit(allocator);
        try graph.addResource(instance.node);
        const instance_id = graph.resources.items[instance_index].id;
        try graph.validateAcyclic();
        return .{
            .graph = graph,
            .instance = workloads.Instance.Outputs.SelfLink.fromResource(instance_id),
            .internal_ip = workloads.Instance.Outputs.InternalIp.fromResource(instance_id),
            .external_ip = workloads.Instance.Outputs.ExternalIp.fromResource(instance_id),
            .disk = workloads.Disk.Outputs.SelfLink.fromResource(disk_id),
        };
    }

    pub fn deinit(self: *VirtualMachine) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

pub const RegionalFleetScope = struct {
    region: []const u8,
    zones: []const []const u8,
};

pub const FleetScope = union(enum) {
    zonal: []const u8,
    regional: RegionalFleetScope,
};

pub const ManagedInstanceFleetArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    scope: FleetScope,
    machine_type: []const u8,
    source_image: output.Output([]const u8, .public),
    boot_disk_size_gb: u64 = 20,
    boot_disk_type: workloads.DiskType = .balanced,
    network_interfaces: []const workloads.NetworkInterface,
    service_account: output.Output([]const u8, .public),
    oauth_scopes: []const []const u8 = &.{"https://www.googleapis.com/auth/cloud-platform"},
    tags: []const []const u8 = &.{},
    labels: []const config_mod.Label = &.{},
    metadata: []const workloads.Metadata = &.{},
    startup_script: ?output.Output(value.SecretReference, .secret) = null,
    startup_script_sha256: []const u8 = "",
    shielded_vm: workloads.ShieldedVm = .{},
    confidential_compute: bool = false,
    target_size: u32,
    min_replicas: u32,
    max_replicas: u32,
    cpu_utilization_target: f64 = 0.6,
    cooldown_seconds: u32 = 60,
    scale_in_control_seconds: u32 = 600,
    named_ports: []const workloads.NamedPort = &.{},
    update_type: workloads.UpdateType = .proactive,
    replacement_method: workloads.ReplacementMethod = .substitute,
    max_surge: u32 = 1,
    max_unavailable: u32 = 0,
    protect: bool = true,
    retain_on_delete: bool = false,
};

pub const ManagedInstanceFleet = struct {
    graph: resource.ResourceGraph,
    template: output.Output([]const u8, .public),
    group: output.Output([]const u8, .public),
    instance_group: output.Output([]const u8, .public),
    recommended_size: output.Output(i64, .public),

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ManagedInstanceFleetArgs) BuildError!ManagedInstanceFleet {
        if (args.target_size < args.min_replicas or args.target_size > args.max_replicas) return error.InvalidScaling;
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);
        const template_name = try std.fmt.allocPrint(allocator, "{s}-template", .{args.name});
        defer allocator.free(template_name);

        const template_index = graph.resources.items.len;
        var template = try workloads.InstanceTemplate.build(allocator, provider, .{
            .name = template_name,
            .machine_type = args.machine_type,
            .source_image = args.source_image,
            .boot_disk_size_gb = args.boot_disk_size_gb,
            .boot_disk_type = args.boot_disk_type,
            .network_interfaces = args.network_interfaces,
            .service_account = args.service_account,
            .oauth_scopes = args.oauth_scopes,
            .tags = args.tags,
            .labels = args.labels,
            .metadata = args.metadata,
            .startup_script = args.startup_script,
            .startup_script_sha256 = args.startup_script_sha256,
            .shielded_vm = args.shielded_vm,
            .confidential_compute = args.confidential_compute,
            .protect = false,
            .retain_on_delete = args.retain_on_delete,
        });
        defer template.deinit(allocator);
        try graph.addResource(template.node);
        const template_id = graph.resources.items[template_index].id;
        const template_output = workloads.InstanceTemplate.Outputs.SelfLink.fromResource(template_id);

        var group_output: output.Output([]const u8, .public) = undefined;
        var instance_group_output: output.Output([]const u8, .public) = undefined;
        var group_id: []const u8 = undefined;
        switch (args.scope) {
            .zonal => |zone| {
                const group_index = graph.resources.items.len;
                var group = try workloads.InstanceGroupManager.build(allocator, provider, .{
                    .name = args.name,
                    .zone = zone,
                    .instance_template = template_output,
                    .base_instance_name = args.name,
                    .target_size = args.target_size,
                    .named_ports = args.named_ports,
                    .update_type = args.update_type,
                    .replacement_method = args.replacement_method,
                    .max_surge = args.max_surge,
                    .max_unavailable = args.max_unavailable,
                    .protect = args.protect,
                    .retain_on_delete = args.retain_on_delete,
                });
                defer group.deinit(allocator);
                try graph.addResource(group.node);
                group_id = graph.resources.items[group_index].id;
                group_output = workloads.InstanceGroupManager.Outputs.SelfLink.fromResource(group_id);
                instance_group_output = workloads.InstanceGroupManager.Outputs.InstanceGroup.fromResource(group_id);

                const scaler_index = graph.resources.items.len;
                var scaler = try workloads.Autoscaler.build(allocator, provider, .{
                    .name = args.name,
                    .zone = zone,
                    .target = group_output,
                    .min_replicas = args.min_replicas,
                    .max_replicas = args.max_replicas,
                    .cpu_utilization_target = args.cpu_utilization_target,
                    .cooldown_seconds = args.cooldown_seconds,
                    .scale_in_control_seconds = args.scale_in_control_seconds,
                    .protect = args.protect,
                    .retain_on_delete = args.retain_on_delete,
                });
                defer scaler.deinit(allocator);
                try graph.addResource(scaler.node);
                const scaler_id = graph.resources.items[scaler_index].id;
                try graph.validateAcyclic();
                return .{
                    .graph = graph,
                    .template = template_output,
                    .group = group_output,
                    .instance_group = instance_group_output,
                    .recommended_size = workloads.Autoscaler.Outputs.RecommendedSize.fromResource(scaler_id),
                };
            },
            .regional => |scope| {
                const group_index = graph.resources.items.len;
                var group = try workloads.RegionInstanceGroupManager.build(allocator, provider, .{
                    .name = args.name,
                    .region = scope.region,
                    .distribution_zones = scope.zones,
                    .instance_template = template_output,
                    .base_instance_name = args.name,
                    .target_size = args.target_size,
                    .named_ports = args.named_ports,
                    .update_type = args.update_type,
                    .replacement_method = args.replacement_method,
                    .max_surge = args.max_surge,
                    .max_unavailable = args.max_unavailable,
                    .protect = args.protect,
                    .retain_on_delete = args.retain_on_delete,
                });
                defer group.deinit(allocator);
                try graph.addResource(group.node);
                group_id = graph.resources.items[group_index].id;
                group_output = workloads.RegionInstanceGroupManager.Outputs.SelfLink.fromResource(group_id);
                instance_group_output = workloads.RegionInstanceGroupManager.Outputs.InstanceGroup.fromResource(group_id);

                const scaler_index = graph.resources.items.len;
                var scaler = try workloads.RegionAutoscaler.build(allocator, provider, .{
                    .name = args.name,
                    .region = scope.region,
                    .target = group_output,
                    .min_replicas = args.min_replicas,
                    .max_replicas = args.max_replicas,
                    .cpu_utilization_target = args.cpu_utilization_target,
                    .cooldown_seconds = args.cooldown_seconds,
                    .scale_in_control_seconds = args.scale_in_control_seconds,
                    .protect = args.protect,
                    .retain_on_delete = args.retain_on_delete,
                });
                defer scaler.deinit(allocator);
                try graph.addResource(scaler.node);
                const scaler_id = graph.resources.items[scaler_index].id;
                try graph.validateAcyclic();
                return .{
                    .graph = graph,
                    .template = template_output,
                    .group = group_output,
                    .instance_group = instance_group_output,
                    .recommended_size = workloads.RegionAutoscaler.Outputs.RecommendedSize.fromResource(scaler_id),
                };
            },
        }
    }

    pub fn deinit(self: *ManagedInstanceFleet) void {
        self.graph.deinit();
        self.* = undefined;
    }
};
