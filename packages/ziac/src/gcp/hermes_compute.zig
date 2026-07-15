const std = @import("std");
const config_mod = @import("config.zig");
const dns = @import("dns.zig");
const iam = @import("iam.zig");
const network_mod = @import("network.zig");
const delivery = @import("network_delivery.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const secrets = @import("secret_manager.zig");
const value = @import("../value.zig");
const workloads = @import("compute_workloads.zig");
const workload_components = @import("compute_workloads_components.zig");

pub const default_image = "nousresearch/hermes-agent:v0.18.2";
pub const default_proxy_image = "caddy:2.11.4-alpine";
pub const default_source_image = "projects/debian-cloud/global/images/family/debian-12";
pub const iap_source_range = "35.235.240.0/20";
pub const reviewed_startup_script_sha256 = "29fa57ca4fb139f51055b423692a792203688e4578d3626efa80b307740e54e9";

pub const BuildError = network_mod.BuildError || delivery.BuildError || dns.BuildError || iam.BuildError ||
    secrets.BuildError || workload_components.BuildError || resource.ResourceGraphError ||
    std.mem.Allocator.Error || error{
    HermesRegionZoneMismatch,
    InvalidHermesDesktopDomain,
    InvalidHermesDnsZone,
    InvalidHermesOauthClientId,
    InvalidHermesSecretReference,
    UndersizedHermesDisk,
    UndersizedHermesMachine,
    UnpinnedHermesImage,
    UnpinnedHermesProxyImage,
};

pub const HermesComputeArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8 = "hermes",
    region: []const u8,
    zone: []const u8,
    subnet_cidr: []const u8 = "10.84.0.0/24",
    machine_type: []const u8 = "e2-medium",
    disk_size_gb: u64 = 30,
    disk_type: workloads.DiskType = .balanced,
    source_image: output.Output([]const u8, .public) = .{ .value = default_source_image },
    hermes_image: []const u8 = default_image,
    proxy_image: []const u8 = default_proxy_image,
    domain: []const u8,
    dns_zone: ?[]const u8 = null,
    dns_ttl: u32 = 300,
    oauth_client_id: []const u8,
    environment_source: value.SecretReference,
    startup_script: output.Output(value.SecretReference, .secret),
    startup_script_sha256: []const u8,
    labels: []const config_mod.Label = &.{},
    protect: bool = true,
    deletion_protection: bool = true,
    retain_disk: bool = true,
    retain_environment_secret: bool = true,
};

pub const HermesCompute = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    desktop_url: output.Output([]const u8, .public),
    instance: output.Output([]const u8, .public),
    internal_ip: output.Output([]const u8, .public),
    public_ip: output.Output([]const u8, .public),
    disk: output.Output([]const u8, .public),
    network: output.Output([]const u8, .public),
    subnetwork: output.Output([]const u8, .public),
    service_account: output.Output([]const u8, .public),
    environment_secret: output.Output([]const u8, .public),
    environment_version: output.Output(value.SecretReference, .secret),
    owned_desktop_url: []u8,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: HermesComputeArgs,
    ) BuildError!HermesCompute {
        try provider.validate();
        try validateArgs(args);

        const names = try Names.init(allocator, args.name);
        defer names.deinit(allocator);
        const service_account_email = try std.fmt.allocPrint(
            allocator,
            "{s}@{s}.iam.gserviceaccount.com",
            .{ args.name, provider.project_id },
        );
        defer allocator.free(service_account_email);
        const service_account_member = try std.fmt.allocPrint(
            allocator,
            "serviceAccount:{s}",
            .{service_account_email},
        );
        defer allocator.free(service_account_member);
        const environment_secret_path = try std.fmt.allocPrint(
            allocator,
            "projects/{s}/secrets/{s}/versions/latest",
            .{ provider.project_id, names.environment_secret },
        );
        defer allocator.free(environment_secret_path);
        const labels = try componentLabels(allocator, args.labels);
        defer allocator.free(labels);
        const desktop_url = try std.fmt.allocPrint(allocator, "https://{s}", .{args.domain});
        errdefer allocator.free(desktop_url);

        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);

        const network_index = graph.resources.items.len;
        var network = try network_mod.Network.build(allocator, provider, .{ .name = names.network });
        defer network.deinit(allocator);
        network.node.lifecycle.protect = args.protect;
        try graph.addResource(network.node);
        const network_id = graph.resources.items[network_index].id;
        const network_output = network_mod.Network.Outputs.SelfLink.fromResource(network_id);

        const subnet_index = graph.resources.items.len;
        var subnet = try network_mod.Subnetwork.build(allocator, provider, .{
            .name = names.subnetwork,
            .region = args.region,
            .ip_cidr_range = args.subnet_cidr,
            .network = network_output,
        });
        defer subnet.deinit(allocator);
        subnet.node.lifecycle.protect = args.protect;
        try graph.addResource(subnet.node);
        const subnet_id = graph.resources.items[subnet_index].id;
        const subnet_output = network_mod.Subnetwork.Outputs.SelfLink.fromResource(subnet_id);

        const address_index = graph.resources.items.len;
        var address = try network_mod.RegionalAddress.build(allocator, provider, .{
            .name = names.address,
            .region = args.region,
        });
        defer address.deinit(allocator);
        address.node.lifecycle.protect = args.protect;
        try graph.addResource(address.node);
        const address_id = graph.resources.items[address_index].id;
        const address_output = network_mod.RegionalAddress.Outputs.Address.fromResource(address_id);

        var firewall = try delivery.Firewall.build(allocator, provider, .{
            .name = names.iap_firewall,
            .network = network_output,
            .direction = .ingress,
            .action = .{ .allow = &.{.{ .protocol = "tcp", .ports = &.{"22"} }} },
            .source_ranges = &.{iap_source_range},
            .target_tags = &.{"hermes-iap"},
            .logging = true,
            .protect = args.protect,
        });
        defer firewall.deinit(allocator);
        try graph.addResource(firewall.node);

        var desktop_firewall = try delivery.Firewall.build(allocator, provider, .{
            .name = names.desktop_firewall,
            .network = network_output,
            .direction = .ingress,
            .action = .{ .allow = &.{.{ .protocol = "tcp", .ports = &.{ "80", "443" } }} },
            .source_ranges = &.{"0.0.0.0/0"},
            .target_tags = &.{"hermes-desktop"},
            .logging = true,
            .protect = args.protect,
        });
        defer desktop_firewall.deinit(allocator);
        try graph.addResource(desktop_firewall.node);

        const account_index = graph.resources.items.len;
        var account = try iam.ServiceAccount.build(allocator, provider, .{
            .account_id = args.name,
            .display_name = "Hermes Agent runtime",
            .description = "Least-privilege identity for the Ziac Hermes Compute compatibility deployment",
        });
        defer account.deinit(allocator);
        account.node.lifecycle.protect = args.protect;
        try graph.addResource(account.node);
        const account_id = graph.resources.items[account_index].id;
        const account_output = iam.ServiceAccount.Outputs.Email.fromResource(account_id);

        const secret_index = graph.resources.items.len;
        var secret = try secrets.Secret.build(allocator, provider, .{
            .name = names.environment_secret,
            .annotations = &.{.{ .key = "ziac-component", .value = "hermes-compute" }},
            .retain_on_delete = args.retain_environment_secret,
        });
        defer secret.deinit(allocator);
        secret.node.lifecycle.protect = args.protect;
        try graph.addResource(secret.node);
        const secret_id = graph.resources.items[secret_index].id;
        const secret_output = secrets.Secret.Outputs.ResourceName.fromResource(secret_id);

        const version_index = graph.resources.items.len;
        var version = try secrets.SecretVersion.build(allocator, provider, .{
            .name = "config",
            .secret_id = names.environment_secret,
            .source = args.environment_source,
            .source_dependencies = &.{secret_output},
            .removal_policy = if (args.retain_environment_secret) .retain else .disable,
        });
        defer version.deinit(allocator);
        version.node.lifecycle.protect = args.protect;
        try graph.addResource(version.node);
        const version_id = graph.resources.items[version_index].id;

        const access_index = graph.resources.items.len;
        var access = try secrets.SecretIamMember.build(allocator, provider, .{
            .name = "runtime",
            .secret_id = names.environment_secret,
            .role = "roles/secretmanager.secretAccessor",
            .member = service_account_member,
        });
        defer access.deinit(allocator);
        access.node.lifecycle.protect = args.protect;
        try graph.addResource(access.node);
        const access_id = graph.resources.items[access_index].id;
        try graph.addDependency(access_id, secret_id);
        try graph.addDependency(access_id, account_id);

        var machine = try workload_components.VirtualMachine.build(allocator, provider, .{
            .base_graph = &graph,
            .name = args.name,
            .zone = args.zone,
            .machine_type = args.machine_type,
            .source_image = args.source_image,
            .disk_size_gb = args.disk_size_gb,
            .disk_type = args.disk_type,
            .network_interfaces = &.{.{
                .network = network_output,
                .subnetwork = subnet_output,
                .external_access = true,
                .external_ip = address_output,
            }},
            .service_account = account_output,
            .tags = &.{ "hermes-iap", "hermes-desktop" },
            .labels = labels,
            .metadata = &.{
                .{ .key = "block-project-ssh-keys", .value = "TRUE" },
                .{ .key = "enable-oslogin", .value = "TRUE" },
                .{ .key = "hermes-env-secret", .value = environment_secret_path },
                .{ .key = "hermes-image", .value = args.hermes_image },
                .{ .key = "hermes-proxy-image", .value = args.proxy_image },
                .{ .key = "hermes-domain", .value = args.domain },
                .{ .key = "hermes-oauth-client-id", .value = args.oauth_client_id },
            },
            .startup_script = args.startup_script,
            .startup_script_sha256 = args.startup_script_sha256,
            .external_access = true,
            .deletion_protection = args.deletion_protection,
            .protect = args.protect,
            .retain_disk = args.retain_disk,
        });
        errdefer machine.deinit();

        const instance_id = machine.instance.referenceOrNull().?.resource_id;
        try machine.graph.addDependency(instance_id, version_id);
        try machine.graph.addDependency(instance_id, access_id);

        const final_network_id = clonedResourceId(&machine.graph, network_id);
        const final_subnet_id = clonedResourceId(&machine.graph, subnet_id);
        const final_address_id = clonedResourceId(&machine.graph, address_id);
        const final_account_id = clonedResourceId(&machine.graph, account_id);
        const final_secret_id = clonedResourceId(&machine.graph, secret_id);
        const final_version_id = clonedResourceId(&machine.graph, version_id);

        if (args.dns_zone) |zone| {
            const fqdn = try std.fmt.allocPrint(allocator, "{s}.", .{args.domain});
            defer allocator.free(fqdn);
            const record_index = machine.graph.resources.items.len;
            var record = try dns.RecordSet.build(allocator, provider, .{
                .zone = zone,
                .name = fqdn,
                .record_type = .a,
                .ttl = args.dns_ttl,
                .rrdata_outputs = &.{network_mod.RegionalAddress.Outputs.Address.fromResource(final_address_id)},
            });
            defer record.deinit(allocator);
            record.node.lifecycle.protect = args.protect;
            try machine.graph.addResource(record.node);
            const record_id = machine.graph.resources.items[record_index].id;
            try machine.graph.addDependency(instance_id, record_id);
        }
        try machine.graph.validateAcyclic();

        graph.deinit();
        return .{
            .allocator = allocator,
            .graph = machine.graph,
            .desktop_url = .known(desktop_url),
            .instance = machine.instance,
            .internal_ip = machine.internal_ip,
            .public_ip = network_mod.RegionalAddress.Outputs.Address.fromResource(final_address_id),
            .disk = machine.disk,
            .network = network_mod.Network.Outputs.SelfLink.fromResource(final_network_id),
            .subnetwork = network_mod.Subnetwork.Outputs.SelfLink.fromResource(final_subnet_id),
            .service_account = iam.ServiceAccount.Outputs.Email.fromResource(final_account_id),
            .environment_secret = secrets.Secret.Outputs.ResourceName.fromResource(final_secret_id),
            .environment_version = secrets.SecretVersion.Outputs.Version.fromResource(final_version_id),
            .owned_desktop_url = desktop_url,
        };
    }

    pub fn deinit(self: *HermesCompute) void {
        self.graph.deinit();
        self.allocator.free(self.owned_desktop_url);
        self.* = undefined;
    }

    pub fn takeGraph(self: *HermesCompute) resource.ResourceGraph {
        const graph = self.graph;
        self.graph = resource.ResourceGraph.init(graph.allocator);
        return graph;
    }
};

fn clonedResourceId(graph: *const resource.ResourceGraph, id: []const u8) []const u8 {
    for (graph.resources.items) |node| if (std.mem.eql(u8, node.id, id)) return node.id;
    unreachable;
}

fn validateArgs(args: HermesComputeArgs) BuildError!void {
    if (!zoneBelongsToRegion(args.region, args.zone)) return error.HermesRegionZoneMismatch;
    if (!pinnedImage(args.hermes_image)) return error.UnpinnedHermesImage;
    if (!pinnedImage(args.proxy_image)) return error.UnpinnedHermesProxyImage;
    if (!validDomain(args.domain)) return error.InvalidHermesDesktopDomain;
    if (!validOauthClientId(args.oauth_client_id)) return error.InvalidHermesOauthClientId;
    if (args.dns_zone) |zone| if (!validDnsZone(zone)) return error.InvalidHermesDnsZone;
    if (undersizedMachine(args.machine_type)) return error.UndersizedHermesMachine;
    if (args.disk_size_gb < 20) return error.UndersizedHermesDisk;
    const secret_version = args.environment_source.version orelse return error.InvalidHermesSecretReference;
    if (args.environment_source.provider.len == 0 or
        args.environment_source.resource.len == 0 or
        secret_version.len == 0)
    {
        return error.InvalidHermesSecretReference;
    }
}

fn validDomain(domain: []const u8) bool {
    if (domain.len < 3 or domain.len > 253 or domain[domain.len - 1] == '.' or
        std.mem.indexOfAny(u8, domain, "\x00\r\n /:_") != null or
        std.mem.indexOfScalar(u8, domain, '.') == null)
    {
        return false;
    }
    var labels = std.mem.splitScalar(u8, domain, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or label[0] == '-' or label[label.len - 1] == '-') return false;
        for (label) |character| {
            if (!std.ascii.isAlphanumeric(character) and character != '-') return false;
        }
    }
    return true;
}

fn validOauthClientId(client_id: []const u8) bool {
    if (!std.mem.startsWith(u8, client_id, "agent:") or client_id.len <= "agent:".len) return false;
    return std.mem.indexOfAny(u8, client_id, "\x00\r\n ") == null;
}

fn validDnsZone(zone: []const u8) bool {
    if (zone.len == 0 or zone.len > 63 or zone[0] == '-' or zone[zone.len - 1] == '-') return false;
    for (zone) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '-') return false;
    }
    return true;
}

fn zoneBelongsToRegion(region: []const u8, zone: []const u8) bool {
    return region.len > 0 and zone.len > region.len + 1 and
        std.mem.startsWith(u8, zone, region) and zone[region.len] == '-';
}

fn pinnedImage(image: []const u8) bool {
    if (image.len == 0 or std.mem.indexOfAny(u8, image, "\x00\r\n ") != null) return false;
    if (std.mem.indexOf(u8, image, "@sha256:")) |digest_index| {
        const digest = image[digest_index + "@sha256:".len ..];
        if (digest.len != 64) return false;
        for (digest) |character| if (!std.ascii.isHex(character)) return false;
        return digest_index > 0;
    }
    const slash = std.mem.lastIndexOfScalar(u8, image, '/') orelse 0;
    const colon = std.mem.lastIndexOfScalar(u8, image, ':') orelse return false;
    if (colon <= slash or colon + 1 >= image.len) return false;
    return !std.mem.eql(u8, image[colon + 1 ..], "latest");
}

fn undersizedMachine(machine_type: []const u8) bool {
    const name = if (std.mem.lastIndexOfScalar(u8, machine_type, '/')) |slash|
        machine_type[slash + 1 ..]
    else
        machine_type;
    const undersized = [_][]const u8{
        "e2-micro",
        "e2-small",
        "f1-micro",
        "g1-small",
        "n1-standard-1",
        "n2-standard-1",
        "n2d-standard-1",
    };
    for (undersized) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

fn componentLabels(allocator: std.mem.Allocator, caller: []const config_mod.Label) ![]config_mod.Label {
    const fixed = [_]config_mod.Label{
        .{ .key = "application", .value = "hermes-agent" },
        .{ .key = "compatibility", .value = "m84c" },
        .{ .key = "managed-by", .value = "ziac" },
    };
    const result = try allocator.alloc(config_mod.Label, fixed.len + caller.len);
    @memcpy(result[0..fixed.len], &fixed);
    @memcpy(result[fixed.len..], caller);
    return result;
}

const Names = struct {
    network: []u8,
    subnetwork: []u8,
    address: []u8,
    iap_firewall: []u8,
    desktop_firewall: []u8,
    environment_secret: []u8,

    fn init(allocator: std.mem.Allocator, name: []const u8) !Names {
        const network = try allocator.dupe(u8, name);
        errdefer allocator.free(network);
        const subnetwork = try std.fmt.allocPrint(allocator, "{s}-subnet", .{name});
        errdefer allocator.free(subnetwork);
        const address = try std.fmt.allocPrint(allocator, "{s}-ip", .{name});
        errdefer allocator.free(address);
        const iap_firewall = try std.fmt.allocPrint(allocator, "{s}-iap-ssh", .{name});
        errdefer allocator.free(iap_firewall);
        const desktop_firewall = try std.fmt.allocPrint(allocator, "{s}-desktop-edge", .{name});
        errdefer allocator.free(desktop_firewall);
        const environment_secret = try std.fmt.allocPrint(allocator, "{s}-env", .{name});
        return .{
            .network = network,
            .subnetwork = subnetwork,
            .address = address,
            .iap_firewall = iap_firewall,
            .desktop_firewall = desktop_firewall,
            .environment_secret = environment_secret,
        };
    }

    fn deinit(self: Names, allocator: std.mem.Allocator) void {
        allocator.free(self.network);
        allocator.free(self.subnetwork);
        allocator.free(self.address);
        allocator.free(self.iap_firewall);
        allocator.free(self.desktop_firewall);
        allocator.free(self.environment_secret);
    }
};
