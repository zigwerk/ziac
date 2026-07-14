const std = @import("std");
const zstd = @import("zigeffect_std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || resource.ResourceGraphError || error{
    ConflictingSource,
    DuplicateField,
    DuplicateLabel,
    DuplicateMetadata,
    DuplicateNetworkInterface,
    DuplicatePort,
    InvalidAutoscalingMode,
    InvalidCpuTarget,
    InvalidDiskSize,
    InvalidMachineType,
    InvalidName,
    InvalidNetwork,
    InvalidReplicaZones,
    InvalidScaling,
    InvalidServiceAccount,
    InvalidStartupScript,
    InvalidUpdatePolicy,
    InvalidZone,
    MissingNetworkInterface,
    OutputNotKnown,
    SecretMaterialRejected,
};

pub const DiskType = enum {
    standard,
    balanced,
    ssd,
    extreme,

    pub fn apiName(self: DiskType) []const u8 {
        return switch (self) {
            .standard => "pd-standard",
            .balanced => "pd-balanced",
            .ssd => "pd-ssd",
            .extreme => "pd-extreme",
        };
    }
};

pub const DiskArgs = struct {
    name: []const u8,
    zone: []const u8,
    size_gb: u64,
    disk_type: DiskType = .balanced,
    source_image: ?output.Output([]const u8, .public) = null,
    source_snapshot: ?output.Output([]const u8, .public) = null,
    kms_key: ?output.Output([]const u8, .public) = null,
    labels: []const config_mod.Label = &.{},
    physical_block_size_bytes: u32 = 4096,
    provisioned_iops: u64 = 0,
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const Disk = struct {
    pub const Outputs = struct {
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
        pub const Status = output.Descriptor("status", []const u8, .public);
        pub const SizeGb = output.Descriptor("size_gb", i64, .public);
    };

    node: resource.ResourceNode,
    self_link: Outputs.SelfLink.OutputType,
    status: Outputs.Status.OutputType,
    size_gb: Outputs.SizeGb.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: DiskArgs) BuildError!Disk {
        try provider.validate();
        try validateName(args.name);
        try validateZone(args.zone);
        try validateDisk(args.size_gb, args.physical_block_size_bytes, args.disk_type, args.provisioned_iops);
        try validateSources(args.source_image, args.source_snapshot);
        const source_image = try optionalPublicOutputValue(args.source_image);
        const source_snapshot = try optionalPublicOutputValue(args.source_snapshot);
        const kms_key = try optionalPublicOutputValue(args.kms_key);
        var labels = try labelsValueOwned(allocator, provider.labels, args.labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "disk_type", .value = .{ .string = args.disk_type.apiName() } },
            .{ .name = "kms_key", .value = kms_key },
            .{ .name = "labels", .value = labels },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "physical_block_size_bytes", .value = .{ .integer = args.physical_block_size_bytes } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "provisioned_iops", .value = .{ .integer = @intCast(args.provisioned_iops) } },
            .{ .name = "size_gb", .value = .{ .integer = @intCast(args.size_gb) } },
            .{ .name = "source_image", .value = source_image },
            .{ .name = "source_snapshot", .value = source_snapshot },
            .{ .name = "zone", .value = .{ .string = args.zone } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.compute.Disk.{s}.{s}", .{ args.zone, args.name });
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.compute.Disk", args.name, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
            .replace_before_delete = false,
            .operation_timeout_millis = 30 * 60 * 1000,
        });
        return .{
            .node = node,
            .self_link = Outputs.SelfLink.fromResource(node.id),
            .status = Outputs.Status.fromResource(node.id),
            .size_gb = Outputs.SizeGb.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Disk, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const RegionDiskArgs = struct {
    name: []const u8,
    region: []const u8,
    replica_zones: []const []const u8,
    size_gb: u64,
    disk_type: DiskType = .balanced,
    source_snapshot: ?output.Output([]const u8, .public) = null,
    kms_key: ?output.Output([]const u8, .public) = null,
    labels: []const config_mod.Label = &.{},
    physical_block_size_bytes: u32 = 4096,
    provisioned_iops: u64 = 0,
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const RegionDisk = struct {
    pub const Outputs = Disk.Outputs;
    node: resource.ResourceNode,
    self_link: Outputs.SelfLink.OutputType,
    status: Outputs.Status.OutputType,
    size_gb: Outputs.SizeGb.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: RegionDiskArgs) BuildError!RegionDisk {
        try provider.validate();
        try validateName(args.name);
        try validateRegion(args.region);
        try validateReplicaZones(args.region, args.replica_zones);
        try validateDisk(args.size_gb, args.physical_block_size_bytes, args.disk_type, args.provisioned_iops);
        var zones = try stringListValueOwned(allocator, args.replica_zones);
        defer zones.deinit(allocator);
        const source_snapshot = try optionalPublicOutputValue(args.source_snapshot);
        const kms_key = try optionalPublicOutputValue(args.kms_key);
        var labels = try labelsValueOwned(allocator, provider.labels, args.labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "disk_type", .value = .{ .string = args.disk_type.apiName() } },
            .{ .name = "kms_key", .value = kms_key },
            .{ .name = "labels", .value = labels },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "physical_block_size_bytes", .value = .{ .integer = args.physical_block_size_bytes } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "provisioned_iops", .value = .{ .integer = @intCast(args.provisioned_iops) } },
            .{ .name = "region", .value = .{ .string = args.region } },
            .{ .name = "replica_zones", .value = zones },
            .{ .name = "size_gb", .value = .{ .integer = @intCast(args.size_gb) } },
            .{ .name = "source_snapshot", .value = source_snapshot },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.compute.RegionDisk.{s}.{s}", .{ args.region, args.name });
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.compute.RegionDisk", args.name, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
            .operation_timeout_millis = 45 * 60 * 1000,
        });
        return .{ .node = node, .self_link = Outputs.SelfLink.fromResource(node.id), .status = Outputs.Status.fromResource(node.id), .size_gb = Outputs.SizeGb.fromResource(node.id) };
    }

    pub fn deinit(self: *RegionDisk, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const ImageArgs = struct {
    name: []const u8,
    source_disk: output.Output([]const u8, .public),
    family: []const u8 = "",
    description: []const u8 = "",
    storage_locations: []const []const u8 = &.{},
    guest_os_features: []const []const u8 = &.{},
    labels: []const config_mod.Label = &.{},
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const Image = struct {
    pub const Outputs = struct {
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
        pub const Status = output.Descriptor("status", []const u8, .public);
        pub const SourceDiskId = output.Descriptor("source_disk_id", []const u8, .public);
    };
    node: resource.ResourceNode,
    self_link: Outputs.SelfLink.OutputType,
    status: Outputs.Status.OutputType,
    source_disk_id: Outputs.SourceDiskId.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ImageArgs) BuildError!Image {
        try provider.validate();
        try validateName(args.name);
        if (args.family.len > 63 or (args.family.len > 0 and !validName(args.family))) return error.InvalidName;
        if (args.description.len > 2048 or std.mem.indexOfScalar(u8, args.description, 0) != null) return error.InvalidName;
        const source_disk = try publicOutputValue(args.source_disk);
        var storage_locations = try stringListValueOwned(allocator, args.storage_locations);
        defer storage_locations.deinit(allocator);
        var guest_os_features = try stringListValueOwned(allocator, args.guest_os_features);
        defer guest_os_features.deinit(allocator);
        var labels = try labelsValueOwned(allocator, provider.labels, args.labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "family", .value = .{ .string = args.family } },
            .{ .name = "guest_os_features", .value = guest_os_features },
            .{ .name = "labels", .value = labels },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "source_disk", .value = source_disk },
            .{ .name = "storage_locations", .value = storage_locations },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.compute.Image.{s}", .{args.name});
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.compute.Image", args.name, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
            .replace_before_delete = true,
            .operation_timeout_millis = 45 * 60 * 1000,
        });
        return .{ .node = node, .self_link = Outputs.SelfLink.fromResource(node.id), .status = Outputs.Status.fromResource(node.id), .source_disk_id = Outputs.SourceDiskId.fromResource(node.id) };
    }

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const NetworkInterface = struct {
    network: output.Output([]const u8, .public),
    subnetwork: ?output.Output([]const u8, .public) = null,
    private_ip: []const u8 = "",
    external_access: bool = false,
    nic_type: []const u8 = "GVNIC",
    stack_type: []const u8 = "IPV4_ONLY",
};

pub const Metadata = struct {
    key: []const u8,
    value: []const u8,
};

pub const ShieldedVm = struct {
    secure_boot: bool = true,
    vtpm: bool = true,
    integrity_monitoring: bool = true,
};

pub const InstanceArgs = struct {
    name: []const u8,
    zone: []const u8,
    machine_type: []const u8,
    boot_disk: output.Output([]const u8, .public),
    boot_disk_auto_delete: bool = false,
    network_interfaces: []const NetworkInterface,
    service_account: output.Output([]const u8, .public),
    oauth_scopes: []const []const u8 = &.{"https://www.googleapis.com/auth/cloud-platform"},
    tags: []const []const u8 = &.{},
    labels: []const config_mod.Label = &.{},
    metadata: []const Metadata = &.{},
    startup_script: ?output.Output(value.SecretReference, .secret) = null,
    startup_script_sha256: []const u8 = "",
    deletion_protection: bool = true,
    can_ip_forward: bool = false,
    provisioning_model: []const u8 = "STANDARD",
    automatic_restart: bool = true,
    on_host_maintenance: []const u8 = "MIGRATE",
    shielded_vm: ShieldedVm = .{},
    confidential_compute: bool = false,
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const Instance = struct {
    pub const Outputs = struct {
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
        pub const Status = output.Descriptor("status", []const u8, .public);
        pub const InternalIp = output.Descriptor("internal_ip", []const u8, .public);
        pub const ExternalIp = output.Descriptor("external_ip", []const u8, .public);
        pub const Zone = output.Descriptor("zone", []const u8, .public);
    };
    node: resource.ResourceNode,
    self_link: Outputs.SelfLink.OutputType,
    status: Outputs.Status.OutputType,
    internal_ip: Outputs.InternalIp.OutputType,
    external_ip: Outputs.ExternalIp.OutputType,
    zone: Outputs.Zone.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: InstanceArgs) BuildError!Instance {
        try provider.validate();
        try validateName(args.name);
        try validateZone(args.zone);
        try validateMachineType(args.machine_type);
        try validateInstanceControls(args.network_interfaces, args.metadata, args.startup_script, args.startup_script_sha256, args.provisioning_model, args.on_host_maintenance, args.confidential_compute);
        const boot_disk = try publicOutputValue(args.boot_disk);
        var interfaces = try networkInterfacesValueOwned(allocator, args.network_interfaces);
        defer interfaces.deinit(allocator);
        const service_account = try publicOutputValue(args.service_account);
        var scopes = try stringListValueOwned(allocator, args.oauth_scopes);
        defer scopes.deinit(allocator);
        var tags = try stringListValueOwned(allocator, args.tags);
        defer tags.deinit(allocator);
        var labels = try labelsValueOwned(allocator, provider.labels, args.labels);
        defer labels.deinit(allocator);
        var metadata = try metadataValueOwned(allocator, args.metadata);
        defer metadata.deinit(allocator);
        const startup_script = try optionalSecretOutputValue(args.startup_script);
        var shielded = try shieldedValueOwned(allocator, args.shielded_vm);
        defer shielded.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "automatic_restart", .value = .{ .boolean = args.automatic_restart } },
            .{ .name = "boot_disk", .value = boot_disk },
            .{ .name = "boot_disk_auto_delete", .value = .{ .boolean = args.boot_disk_auto_delete } },
            .{ .name = "can_ip_forward", .value = .{ .boolean = args.can_ip_forward } },
            .{ .name = "confidential_compute", .value = .{ .boolean = args.confidential_compute } },
            .{ .name = "deletion_protection", .value = .{ .boolean = args.deletion_protection } },
            .{ .name = "labels", .value = labels },
            .{ .name = "machine_type", .value = .{ .string = args.machine_type } },
            .{ .name = "metadata", .value = metadata },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "network_interfaces", .value = interfaces },
            .{ .name = "oauth_scopes", .value = scopes },
            .{ .name = "on_host_maintenance", .value = .{ .string = args.on_host_maintenance } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "provisioning_model", .value = .{ .string = args.provisioning_model } },
            .{ .name = "service_account", .value = service_account },
            .{ .name = "shielded_vm", .value = shielded },
            .{ .name = "startup_script", .value = startup_script },
            .{ .name = "startup_script_sha256", .value = .{ .string = args.startup_script_sha256 } },
            .{ .name = "tags", .value = tags },
            .{ .name = "zone", .value = .{ .string = args.zone } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.compute.Instance.{s}.{s}", .{ args.zone, args.name });
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.compute.Instance", args.name, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
            .operation_timeout_millis = 30 * 60 * 1000,
        });
        return .{
            .node = node,
            .self_link = Outputs.SelfLink.fromResource(node.id),
            .status = Outputs.Status.fromResource(node.id),
            .internal_ip = Outputs.InternalIp.fromResource(node.id),
            .external_ip = Outputs.ExternalIp.fromResource(node.id),
            .zone = Outputs.Zone.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Instance, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const InstanceTemplateArgs = struct {
    name: []const u8,
    machine_type: []const u8,
    source_image: output.Output([]const u8, .public),
    boot_disk_size_gb: u64 = 20,
    boot_disk_type: DiskType = .balanced,
    boot_disk_auto_delete: bool = true,
    network_interfaces: []const NetworkInterface,
    service_account: output.Output([]const u8, .public),
    oauth_scopes: []const []const u8 = &.{"https://www.googleapis.com/auth/cloud-platform"},
    tags: []const []const u8 = &.{},
    labels: []const config_mod.Label = &.{},
    metadata: []const Metadata = &.{},
    startup_script: ?output.Output(value.SecretReference, .secret) = null,
    startup_script_sha256: []const u8 = "",
    can_ip_forward: bool = false,
    provisioning_model: []const u8 = "STANDARD",
    automatic_restart: bool = true,
    on_host_maintenance: []const u8 = "MIGRATE",
    shielded_vm: ShieldedVm = .{},
    confidential_compute: bool = false,
    protect: bool = false,
    retain_on_delete: bool = true,
};

pub const InstanceTemplate = struct {
    pub const Outputs = struct {
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
    };
    node: resource.ResourceNode,
    self_link: Outputs.SelfLink.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: InstanceTemplateArgs) BuildError!InstanceTemplate {
        try provider.validate();
        try validateName(args.name);
        try validateMachineType(args.machine_type);
        if (args.boot_disk_size_gb == 0) return error.InvalidDiskSize;
        try validateInstanceControls(args.network_interfaces, args.metadata, args.startup_script, args.startup_script_sha256, args.provisioning_model, args.on_host_maintenance, args.confidential_compute);
        const source_image = try publicOutputValue(args.source_image);
        var interfaces = try networkInterfacesValueOwned(allocator, args.network_interfaces);
        defer interfaces.deinit(allocator);
        const service_account = try publicOutputValue(args.service_account);
        var scopes = try stringListValueOwned(allocator, args.oauth_scopes);
        defer scopes.deinit(allocator);
        var tags = try stringListValueOwned(allocator, args.tags);
        defer tags.deinit(allocator);
        var labels = try labelsValueOwned(allocator, provider.labels, args.labels);
        defer labels.deinit(allocator);
        var metadata = try metadataValueOwned(allocator, args.metadata);
        defer metadata.deinit(allocator);
        const startup_script = try optionalSecretOutputValue(args.startup_script);
        var shielded = try shieldedValueOwned(allocator, args.shielded_vm);
        defer shielded.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "automatic_restart", .value = .{ .boolean = args.automatic_restart } },
            .{ .name = "boot_disk_auto_delete", .value = .{ .boolean = args.boot_disk_auto_delete } },
            .{ .name = "boot_disk_size_gb", .value = .{ .integer = @intCast(args.boot_disk_size_gb) } },
            .{ .name = "boot_disk_type", .value = .{ .string = args.boot_disk_type.apiName() } },
            .{ .name = "can_ip_forward", .value = .{ .boolean = args.can_ip_forward } },
            .{ .name = "confidential_compute", .value = .{ .boolean = args.confidential_compute } },
            .{ .name = "labels", .value = labels },
            .{ .name = "machine_type", .value = .{ .string = args.machine_type } },
            .{ .name = "metadata", .value = metadata },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "network_interfaces", .value = interfaces },
            .{ .name = "oauth_scopes", .value = scopes },
            .{ .name = "on_host_maintenance", .value = .{ .string = args.on_host_maintenance } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "provisioning_model", .value = .{ .string = args.provisioning_model } },
            .{ .name = "service_account", .value = service_account },
            .{ .name = "shielded_vm", .value = shielded },
            .{ .name = "source_image", .value = source_image },
            .{ .name = "startup_script", .value = startup_script },
            .{ .name = "startup_script_sha256", .value = .{ .string = args.startup_script_sha256 } },
            .{ .name = "tags", .value = tags },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.compute.InstanceTemplate.{s}", .{args.name});
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.compute.InstanceTemplate", args.name, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
            .replace_before_delete = true,
            .operation_timeout_millis = 30 * 60 * 1000,
        });
        return .{ .node = node, .self_link = Outputs.SelfLink.fromResource(node.id) };
    }

    pub fn deinit(self: *InstanceTemplate, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const NamedPort = struct { name: []const u8, port: u16 };
pub const UpdateType = enum { proactive, opportunistic };
pub const ReplacementMethod = enum { substitute, recreate };

pub const InstanceGroupManagerArgs = struct {
    name: []const u8,
    zone: []const u8,
    instance_template: output.Output([]const u8, .public),
    base_instance_name: []const u8,
    target_size: u32,
    named_ports: []const NamedPort = &.{},
    update_type: UpdateType = .proactive,
    replacement_method: ReplacementMethod = .substitute,
    max_surge: u32 = 1,
    max_unavailable: u32 = 0,
    protect: bool = true,
    retain_on_delete: bool = false,
};

pub const RegionInstanceGroupManagerArgs = struct {
    name: []const u8,
    region: []const u8,
    distribution_zones: []const []const u8,
    instance_template: output.Output([]const u8, .public),
    base_instance_name: []const u8,
    target_size: u32,
    named_ports: []const NamedPort = &.{},
    update_type: UpdateType = .proactive,
    replacement_method: ReplacementMethod = .substitute,
    max_surge: u32 = 1,
    max_unavailable: u32 = 0,
    protect: bool = true,
    retain_on_delete: bool = false,
};

pub const InstanceGroupManager = GroupResource(false);
pub const RegionInstanceGroupManager = GroupResource(true);

fn GroupResource(comptime regional: bool) type {
    return struct {
        pub const Outputs = struct {
            pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
            pub const InstanceGroup = output.Descriptor("instance_group", []const u8, .public);
            pub const Status = output.Descriptor("status", []const u8, .public);
            pub const TargetSize = output.Descriptor("target_size", i64, .public);
            pub const Fingerprint = output.Descriptor("fingerprint", []const u8, .public);
        };
        node: resource.ResourceNode,
        self_link: Outputs.SelfLink.OutputType,
        instance_group: Outputs.InstanceGroup.OutputType,
        status: Outputs.Status.OutputType,
        target_size: Outputs.TargetSize.OutputType,
        fingerprint: Outputs.Fingerprint.OutputType,

        pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: if (regional) RegionInstanceGroupManagerArgs else InstanceGroupManagerArgs) BuildError!@This() {
            try provider.validate();
            try validateName(args.name);
            try validateName(args.base_instance_name);
            if (args.target_size == 0 or args.target_size > 100_000 or args.max_unavailable > args.target_size) return error.InvalidScaling;
            if (args.update_type == .opportunistic and (args.max_surge != 0 or args.max_unavailable != 0)) return error.InvalidUpdatePolicy;
            if (regional) {
                try validateRegion(args.region);
                try validateReplicaZones(args.region, args.distribution_zones);
            } else try validateZone(args.zone);
            const template = try publicOutputValue(args.instance_template);
            var ports = try namedPortsValueOwned(allocator, args.named_ports);
            defer ports.deinit(allocator);
            var zones = if (regional) try stringListValueOwned(allocator, args.distribution_zones) else try stringListValueOwned(allocator, &.{});
            defer zones.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "base_instance_name", .value = .{ .string = args.base_instance_name } },
                .{ .name = "distribution_zones", .value = zones },
                .{ .name = "instance_template", .value = template },
                .{ .name = "max_surge", .value = .{ .integer = args.max_surge } },
                .{ .name = "max_unavailable", .value = .{ .integer = args.max_unavailable } },
                .{ .name = "name", .value = .{ .string = args.name } },
                .{ .name = "named_ports", .value = ports },
                .{ .name = "project_id", .value = .{ .string = provider.project_id } },
                .{ .name = "region", .value = .{ .string = if (regional) args.region else "" } },
                .{ .name = "replacement_method", .value = .{ .string = @tagName(args.replacement_method) } },
                .{ .name = "target_size", .value = .{ .integer = args.target_size } },
                .{ .name = "update_type", .value = .{ .string = @tagName(args.update_type) } },
                .{ .name = "zone", .value = .{ .string = if (regional) "" else args.zone } },
            };
            const scope = if (regional) args.region else args.zone;
            const type_name = if (regional) "gcp.compute.RegionInstanceGroupManager" else "gcp.compute.InstanceGroupManager";
            const id = try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ type_name, scope, args.name });
            defer allocator.free(id);
            const node = try nodeOwned(allocator, id, type_name, args.name, &fields, .{
                .protect = args.protect,
                .retain_on_delete = args.retain_on_delete,
                .operation_timeout_millis = 45 * 60 * 1000,
            });
            return .{
                .node = node,
                .self_link = Outputs.SelfLink.fromResource(node.id),
                .instance_group = Outputs.InstanceGroup.fromResource(node.id),
                .status = Outputs.Status.fromResource(node.id),
                .target_size = Outputs.TargetSize.fromResource(node.id),
                .fingerprint = Outputs.Fingerprint.fromResource(node.id),
            };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.node.deinit(allocator);
            self.* = undefined;
        }
    };
}

pub const AutoscalingMode = enum { on, only_scale_out, off };

pub const AutoscalerArgs = struct {
    name: []const u8,
    zone: []const u8,
    target: output.Output([]const u8, .public),
    min_replicas: u32,
    max_replicas: u32,
    cpu_utilization_target: f64 = 0.6,
    cooldown_seconds: u32 = 60,
    mode: AutoscalingMode = .on,
    scale_in_control_seconds: u32 = 600,
    protect: bool = false,
    retain_on_delete: bool = false,
};

pub const RegionAutoscalerArgs = struct {
    name: []const u8,
    region: []const u8,
    target: output.Output([]const u8, .public),
    min_replicas: u32,
    max_replicas: u32,
    cpu_utilization_target: f64 = 0.6,
    cooldown_seconds: u32 = 60,
    mode: AutoscalingMode = .on,
    scale_in_control_seconds: u32 = 600,
    protect: bool = false,
    retain_on_delete: bool = false,
};

pub const Autoscaler = AutoscalerResource(false);
pub const RegionAutoscaler = AutoscalerResource(true);

fn AutoscalerResource(comptime regional: bool) type {
    return struct {
        pub const Outputs = struct {
            pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
            pub const Status = output.Descriptor("status", []const u8, .public);
            pub const RecommendedSize = output.Descriptor("recommended_size", i64, .public);
        };
        node: resource.ResourceNode,
        self_link: Outputs.SelfLink.OutputType,
        status: Outputs.Status.OutputType,
        recommended_size: Outputs.RecommendedSize.OutputType,

        pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: if (regional) RegionAutoscalerArgs else AutoscalerArgs) BuildError!@This() {
            try provider.validate();
            try validateName(args.name);
            if (regional) try validateRegion(args.region) else try validateZone(args.zone);
            if (args.min_replicas == 0 or args.max_replicas < args.min_replicas or args.max_replicas > 100_000) return error.InvalidScaling;
            if (!std.math.isFinite(args.cpu_utilization_target) or args.cpu_utilization_target <= 0 or args.cpu_utilization_target > 1) return error.InvalidCpuTarget;
            if (args.cooldown_seconds > 3600 or args.scale_in_control_seconds > 86_400) return error.InvalidScaling;
            const target = try publicOutputValue(args.target);
            const fields = [_]value.Field{
                .{ .name = "cooldown_seconds", .value = .{ .integer = args.cooldown_seconds } },
                .{ .name = "cpu_utilization_target_micros", .value = .{ .integer = @intFromFloat(args.cpu_utilization_target * 1_000_000.0) } },
                .{ .name = "max_replicas", .value = .{ .integer = args.max_replicas } },
                .{ .name = "min_replicas", .value = .{ .integer = args.min_replicas } },
                .{ .name = "mode", .value = .{ .string = switch (args.mode) {
                    .on => "ON",
                    .only_scale_out => "ONLY_SCALE_OUT",
                    .off => "OFF",
                } } },
                .{ .name = "name", .value = .{ .string = args.name } },
                .{ .name = "project_id", .value = .{ .string = provider.project_id } },
                .{ .name = "region", .value = .{ .string = if (regional) args.region else "" } },
                .{ .name = "scale_in_control_seconds", .value = .{ .integer = args.scale_in_control_seconds } },
                .{ .name = "target", .value = target },
                .{ .name = "zone", .value = .{ .string = if (regional) "" else args.zone } },
            };
            const scope = if (regional) args.region else args.zone;
            const type_name = if (regional) "gcp.compute.RegionAutoscaler" else "gcp.compute.Autoscaler";
            const id = try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ type_name, scope, args.name });
            defer allocator.free(id);
            const node = try nodeOwned(allocator, id, type_name, args.name, &fields, .{
                .protect = args.protect,
                .retain_on_delete = args.retain_on_delete,
                .operation_timeout_millis = 30 * 60 * 1000,
            });
            return .{ .node = node, .self_link = Outputs.SelfLink.fromResource(node.id), .status = Outputs.Status.fromResource(node.id), .recommended_size = Outputs.RecommendedSize.fromResource(node.id) };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.node.deinit(allocator);
            self.* = undefined;
        }
    };
}

fn validateName(text: []const u8) BuildError!void {
    if (!validName(text)) return error.InvalidName;
}

fn validName(text: []const u8) bool {
    if (text.len == 0 or text.len > 63 or !std.ascii.isLower(text[0]) or !std.ascii.isAlphanumeric(text[text.len - 1])) return false;
    for (text) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return false;
    return true;
}

fn validateRegion(text: []const u8) BuildError!void {
    if (text.len < 3 or text.len > 32 or !std.ascii.isLower(text[0])) return error.InvalidZone;
    for (text) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return error.InvalidZone;
}

fn validateZone(text: []const u8) BuildError!void {
    const separator = std.mem.lastIndexOfScalar(u8, text, '-') orelse return error.InvalidZone;
    if (separator < 2 or separator + 2 != text.len or !std.ascii.isLower(text[text.len - 1])) return error.InvalidZone;
    try validateRegion(text[0..separator]);
}

fn validateReplicaZones(region: []const u8, zones: []const []const u8) BuildError!void {
    if (zones.len < 2) return error.InvalidReplicaZones;
    for (zones, 0..) |zone, index| {
        validateZone(zone) catch return error.InvalidReplicaZones;
        if (!std.mem.startsWith(u8, zone, region) or zone.len != region.len + 2 or zone[region.len] != '-') return error.InvalidReplicaZones;
        for (zones[0..index]) |previous| if (std.mem.eql(u8, previous, zone)) return error.InvalidReplicaZones;
    }
}

fn validateDisk(size_gb: u64, block_size: u32, disk_type: DiskType, provisioned_iops: u64) BuildError!void {
    if (size_gb == 0 or size_gb > 65_536 or (block_size != 4096 and block_size != 16_384)) return error.InvalidDiskSize;
    if (disk_type != .extreme and provisioned_iops != 0) return error.InvalidDiskSize;
}

fn validateSources(image: ?output.Output([]const u8, .public), snapshot: ?output.Output([]const u8, .public)) BuildError!void {
    if (image != null and snapshot != null) return error.ConflictingSource;
}

fn validateMachineType(text: []const u8) BuildError!void {
    if (text.len == 0 or text.len > 255 or std.mem.indexOfAny(u8, text, "\x00\r\n ") != null) return error.InvalidMachineType;
    if (std.mem.indexOfScalar(u8, text, '/') == null and !validName(text)) return error.InvalidMachineType;
}

fn validateInstanceControls(
    interfaces: []const NetworkInterface,
    metadata: []const Metadata,
    startup_script: ?output.Output(value.SecretReference, .secret),
    startup_digest: []const u8,
    provisioning_model: []const u8,
    maintenance: []const u8,
    confidential: bool,
) BuildError!void {
    if (interfaces.len == 0 or interfaces.len > 8) return error.MissingNetworkInterface;
    if ((startup_script == null) != (startup_digest.len == 0)) return error.InvalidStartupScript;
    if (startup_script != null and !validDigest(startup_digest)) return error.InvalidStartupScript;
    if (!std.mem.eql(u8, provisioning_model, "STANDARD") and !std.mem.eql(u8, provisioning_model, "SPOT")) return error.InvalidUpdatePolicy;
    if (!std.mem.eql(u8, maintenance, "MIGRATE") and !std.mem.eql(u8, maintenance, "TERMINATE")) return error.InvalidUpdatePolicy;
    if ((std.mem.eql(u8, provisioning_model, "SPOT") or confidential) and !std.mem.eql(u8, maintenance, "TERMINATE")) return error.InvalidUpdatePolicy;
    for (interfaces, 0..) |interface, index| {
        if (interface.private_ip.len > 64 or std.mem.indexOfAny(u8, interface.private_ip, "\x00\r\n ") != null) return error.InvalidNetwork;
        if (!std.mem.eql(u8, interface.nic_type, "GVNIC") and !std.mem.eql(u8, interface.nic_type, "VIRTIO_NET")) return error.InvalidNetwork;
        if (!std.mem.eql(u8, interface.stack_type, "IPV4_ONLY") and !std.mem.eql(u8, interface.stack_type, "IPV4_IPV6")) return error.InvalidNetwork;
        for (interfaces[0..index]) |previous| if (std.meta.eql(previous.network, interface.network) and std.meta.eql(previous.subnetwork, interface.subnetwork)) return error.DuplicateNetworkInterface;
    }
    for (metadata, 0..) |entry, index| {
        if (entry.key.len == 0 or entry.key.len > 128 or std.mem.indexOfAny(u8, entry.key, "\x00\r\n=") != null or entry.value.len > 262_144) return error.InvalidName;
        if (zstd.Secrets.containsSecret(entry.value)) return error.SecretMaterialRejected;
        for (metadata[0..index]) |previous| if (std.mem.eql(u8, previous.key, entry.key)) return error.DuplicateMetadata;
    }
}

fn validDigest(text: []const u8) bool {
    if (text.len != 64) return false;
    for (text) |character| if (!std.ascii.isHex(character)) return false;
    return true;
}

fn publicOutputValue(candidate: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (candidate) {
        .value => |text| .{ .string = text },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn optionalPublicOutputValue(candidate: ?output.Output([]const u8, .public)) BuildError!value.Value {
    return if (candidate) |present| publicOutputValue(present) else .{ .string = "" };
}

fn optionalSecretOutputValue(candidate: ?output.Output(value.SecretReference, .secret)) BuildError!value.Value {
    const present = candidate orelse return .{ .string = "" };
    return switch (present) {
        .value => |reference| .{ .secret_ref = reference },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn stringListValueOwned(allocator: std.mem.Allocator, strings: []const []const u8) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, strings.len);
    defer allocator.free(items);
    for (strings, 0..) |text, index| {
        if (text.len == 0 or std.mem.indexOfAny(u8, text, "\x00\r\n") != null) return error.InvalidName;
        items[index] = .{ .string = text };
    }
    return value.Value.initOwned(allocator, .{ .list = items });
}

fn networkInterfacesValueOwned(allocator: std.mem.Allocator, interfaces: []const NetworkInterface) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, interfaces.len);
    defer allocator.free(items);
    var built: usize = 0;
    defer for (items[0..built]) |*item| item.deinit(allocator);
    for (interfaces, 0..) |interface, index| {
        const network = try publicOutputValue(interface.network);
        const subnetwork = try optionalPublicOutputValue(interface.subnetwork);
        const fields = [_]value.Field{
            .{ .name = "external_access", .value = .{ .boolean = interface.external_access } },
            .{ .name = "network", .value = network },
            .{ .name = "nic_type", .value = .{ .string = interface.nic_type } },
            .{ .name = "private_ip", .value = .{ .string = interface.private_ip } },
            .{ .name = "stack_type", .value = .{ .string = interface.stack_type } },
            .{ .name = "subnetwork", .value = subnetwork },
        };
        items[index] = try value.Value.initOwned(allocator, .{ .object = &fields });
        built += 1;
    }
    return value.Value.initOwned(allocator, .{ .list = items });
}

fn labelsValueOwned(allocator: std.mem.Allocator, defaults: []const config_mod.Label, explicit: []const config_mod.Label) BuildError!value.Value {
    const combined = try allocator.alloc(config_mod.Label, defaults.len + explicit.len);
    defer allocator.free(combined);
    @memcpy(combined[0..defaults.len], defaults);
    @memcpy(combined[defaults.len..], explicit);
    std.mem.sort(config_mod.Label, combined, {}, struct {
        fn lessThan(_: void, left: config_mod.Label, right: config_mod.Label) bool {
            return std.mem.order(u8, left.key, right.key) == .lt;
        }
    }.lessThan);
    const items = try allocator.alloc(value.Value, combined.len);
    defer allocator.free(items);
    var built: usize = 0;
    defer for (items[0..built]) |*item| item.deinit(allocator);
    for (combined, 0..) |label, index| {
        if (label.key.len == 0 or label.key.len > 63 or label.value.len > 63) return error.InvalidName;
        if (index > 0 and std.mem.eql(u8, combined[index - 1].key, label.key)) return error.DuplicateLabel;
        const fields = [_]value.Field{
            .{ .name = "key", .value = .{ .string = label.key } },
            .{ .name = "value", .value = .{ .string = label.value } },
        };
        items[index] = try value.Value.initOwned(allocator, .{ .object = &fields });
        built += 1;
    }
    return value.Value.initOwned(allocator, .{ .list = items });
}

fn metadataValueOwned(allocator: std.mem.Allocator, metadata: []const Metadata) BuildError!value.Value {
    const sorted = try allocator.dupe(Metadata, metadata);
    defer allocator.free(sorted);
    std.mem.sort(Metadata, sorted, {}, struct {
        fn lessThan(_: void, left: Metadata, right: Metadata) bool {
            return std.mem.order(u8, left.key, right.key) == .lt;
        }
    }.lessThan);
    const items = try allocator.alloc(value.Value, sorted.len);
    defer allocator.free(items);
    var built: usize = 0;
    defer for (items[0..built]) |*item| item.deinit(allocator);
    for (sorted, 0..) |entry, index| {
        const fields = [_]value.Field{
            .{ .name = "key", .value = .{ .string = entry.key } },
            .{ .name = "value", .value = .{ .string = entry.value } },
        };
        items[index] = try value.Value.initOwned(allocator, .{ .object = &fields });
        built += 1;
    }
    return value.Value.initOwned(allocator, .{ .list = items });
}

fn shieldedValueOwned(allocator: std.mem.Allocator, shielded: ShieldedVm) BuildError!value.Value {
    const fields = [_]value.Field{
        .{ .name = "integrity_monitoring", .value = .{ .boolean = shielded.integrity_monitoring } },
        .{ .name = "secure_boot", .value = .{ .boolean = shielded.secure_boot } },
        .{ .name = "vtpm", .value = .{ .boolean = shielded.vtpm } },
    };
    return value.Value.initOwned(allocator, .{ .object = &fields });
}

fn namedPortsValueOwned(allocator: std.mem.Allocator, ports: []const NamedPort) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, ports.len);
    defer allocator.free(items);
    var built: usize = 0;
    defer for (items[0..built]) |*item| item.deinit(allocator);
    for (ports, 0..) |port, index| {
        try validateName(port.name);
        if (port.port == 0) return error.InvalidName;
        for (ports[0..index]) |previous| if (std.mem.eql(u8, previous.name, port.name)) return error.DuplicatePort;
        const fields = [_]value.Field{
            .{ .name = "name", .value = .{ .string = port.name } },
            .{ .name = "port", .value = .{ .integer = port.port } },
        };
        items[index] = try value.Value.initOwned(allocator, .{ .object = &fields });
        built += 1;
    }
    return value.Value.initOwned(allocator, .{ .list = items });
}

fn nodeOwned(allocator: std.mem.Allocator, id: []const u8, type_name: []const u8, logical_id: []const u8, fields: []const value.Field, lifecycle: resource.Lifecycle) BuildError!resource.ResourceNode {
    return resource.ResourceNode.initOwned(allocator, .{
        .id = id,
        .provider = .gcp,
        .type_name = type_name,
        .schema_version = 1,
        .logical_id = logical_id,
        .inputs = .{ .object = fields },
        .lifecycle = lifecycle,
    });
}
