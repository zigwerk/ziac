const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const validation = @import("validation.zig");
const value = @import("../value.zig");

pub const BuildError = validation.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    DuplicateBackendRegion,
    DuplicateDomain,
    InvalidDomain,
    MissingBackend,
    MissingCertificate,
    MissingDomain,
};

pub const GlobalAddressArgs = struct { name: []const u8 };

pub const GlobalAddress = struct {
    pub const Outputs = struct {
        pub const Address = output.Descriptor("address", []const u8, .public);
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
    };

    node: resource.ResourceNode,
    address: Outputs.Address.OutputType,
    self_link: Outputs.SelfLink.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: GlobalAddressArgs) BuildError!GlobalAddress {
        try validateGlobal(provider, args.name);
        const fields = [_]value.Field{
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "network_tier", .value = .{ .string = "PREMIUM" } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        };
        const node = try buildNode(allocator, "gcp.compute.GlobalAddress", args.name, args.name, &fields);
        return .{
            .node = node,
            .address = Outputs.Address.fromResource(node.id),
            .self_link = Outputs.SelfLink.fromResource(node.id),
        };
    }

    pub fn deinit(self: *GlobalAddress, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const RegionServerlessNegArgs = struct {
    name: []const u8,
    region: []const u8,
    cloud_run_service: []const u8,
};

pub const RegionServerlessNeg = struct {
    pub const Outputs = struct {
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
    };

    node: resource.ResourceNode,
    self_link: Outputs.SelfLink.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: RegionServerlessNegArgs,
    ) BuildError!RegionServerlessNeg {
        try provider.validate();
        if (args.name.len == 0 or args.cloud_run_service.len == 0) return error.MissingName;
        if (args.region.len == 0) return error.MissingRegion;
        const logical_id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ args.region, args.name });
        defer allocator.free(logical_id);
        const fields = [_]value.Field{
            .{ .name = "cloud_run_service", .value = .{ .string = args.cloud_run_service } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "network_endpoint_type", .value = .{ .string = "SERVERLESS" } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "region", .value = .{ .string = args.region } },
        };
        const node = try buildNode(allocator, "gcp.compute.RegionServerlessNeg", logical_id, args.name, &fields);
        return .{ .node = node, .self_link = Outputs.SelfLink.fromResource(node.id) };
    }

    pub fn deinit(self: *RegionServerlessNeg, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const ServerlessBackend = struct {
    region: []const u8,
    group: []const u8,
};

pub const BackendServiceArgs = struct {
    name: []const u8,
    backends: []const ServerlessBackend,
};

pub const BackendService = struct {
    pub const Outputs = struct {
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
    };

    node: resource.ResourceNode,
    self_link: Outputs.SelfLink.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: BackendServiceArgs,
    ) BuildError!BackendService {
        try validateGlobal(provider, args.name);
        if (args.backends.len == 0) return error.MissingBackend;
        for (args.backends, 0..) |backend, index| {
            if (backend.region.len == 0 or backend.group.len == 0) return error.MissingBackend;
            for (args.backends[index + 1 ..]) |other| {
                if (std.mem.eql(u8, backend.region, other.region)) return error.DuplicateBackendRegion;
            }
        }
        const backends = try allocator.alloc(value.Value, args.backends.len);
        errdefer allocator.free(backends);
        var initialized: usize = 0;
        errdefer for (backends[0..initialized]) |*backend| backend.deinit(allocator);
        for (args.backends, 0..) |backend, index| {
            const backend_fields = [_]value.Field{
                .{ .name = "group", .value = .{ .string = backend.group } },
                .{ .name = "region", .value = .{ .string = backend.region } },
            };
            backends[index] = try ownedValue(allocator, .{ .object = &backend_fields });
            initialized += 1;
        }
        defer deinitValues(allocator, backends);
        const fields = [_]value.Field{
            .{ .name = "backends", .value = .{ .list = backends } },
            .{ .name = "load_balancing_scheme", .value = .{ .string = "EXTERNAL_MANAGED" } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "protocol", .value = .{ .string = "HTTP" } },
        };
        const node = try buildNode(allocator, "gcp.compute.BackendService", args.name, args.name, &fields);
        return .{ .node = node, .self_link = Outputs.SelfLink.fromResource(node.id) };
    }

    pub fn deinit(self: *BackendService, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const UrlMapArgs = struct { name: []const u8, default_service: []const u8 };

pub const UrlMap = struct {
    pub const Outputs = struct {
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
    };

    node: resource.ResourceNode,
    self_link: Outputs.SelfLink.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: UrlMapArgs) BuildError!UrlMap {
        try validateGlobal(provider, args.name);
        if (args.default_service.len == 0) return error.MissingBackend;
        const fields = [_]value.Field{
            .{ .name = "default_service", .value = .{ .string = args.default_service } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        };
        const node = try buildNode(allocator, "gcp.compute.UrlMap", args.name, args.name, &fields);
        return .{ .node = node, .self_link = Outputs.SelfLink.fromResource(node.id) };
    }

    pub fn deinit(self: *UrlMap, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const TargetHttpsProxyArgs = struct {
    name: []const u8,
    url_map: []const u8,
    ssl_certificates: []const []const u8,
};

pub const TargetHttpsProxy = struct {
    pub const Outputs = struct {
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
    };

    node: resource.ResourceNode,
    self_link: Outputs.SelfLink.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: TargetHttpsProxyArgs,
    ) BuildError!TargetHttpsProxy {
        try validateGlobal(provider, args.name);
        if (args.url_map.len == 0) return error.MissingBackend;
        if (args.ssl_certificates.len == 0) return error.MissingCertificate;
        const certificates = try stringValuesAlloc(allocator, args.ssl_certificates);
        defer allocator.free(certificates);
        const fields = [_]value.Field{
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "ssl_certificates", .value = .{ .list = certificates } },
            .{ .name = "url_map", .value = .{ .string = args.url_map } },
        };
        const node = try buildNode(allocator, "gcp.compute.TargetHttpsProxy", args.name, args.name, &fields);
        return .{ .node = node, .self_link = Outputs.SelfLink.fromResource(node.id) };
    }

    pub fn deinit(self: *TargetHttpsProxy, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const ManagedSslCertificateArgs = struct {
    name: []const u8,
    domains: []const []const u8,
};

pub const ManagedSslCertificate = struct {
    pub const Outputs = struct {
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
        pub const Status = output.Descriptor("status", []const u8, .public);
        pub const DomainsReady = output.Descriptor("domains_ready", bool, .public);
    };

    node: resource.ResourceNode,
    self_link: Outputs.SelfLink.OutputType,
    status: Outputs.Status.OutputType,
    domains_ready: Outputs.DomainsReady.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: ManagedSslCertificateArgs,
    ) BuildError!ManagedSslCertificate {
        try validateGlobal(provider, args.name);
        if (args.domains.len == 0) return error.MissingDomain;
        for (args.domains, 0..) |domain, index| {
            if (!isValidCertificateDomain(domain)) return error.InvalidDomain;
            for (args.domains[index + 1 ..]) |other| {
                if (std.mem.eql(u8, domain, other)) return error.DuplicateDomain;
            }
        }
        const domains = try stringValuesAlloc(allocator, args.domains);
        defer allocator.free(domains);
        const fields = [_]value.Field{
            .{ .name = "domains", .value = .{ .list = domains } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        };
        const node = try buildNode(allocator, "gcp.compute.ManagedSslCertificate", args.name, args.name, &fields);
        return .{
            .node = node,
            .self_link = Outputs.SelfLink.fromResource(node.id),
            .status = Outputs.Status.fromResource(node.id),
            .domains_ready = Outputs.DomainsReady.fromResource(node.id),
        };
    }

    pub fn deinit(self: *ManagedSslCertificate, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const RedirectResponseCode = enum {
    moved_permanently,
    found,
    see_other,
    temporary_redirect,
    permanent_redirect,

    pub fn apiName(self: RedirectResponseCode) []const u8 {
        return switch (self) {
            .moved_permanently => "MOVED_PERMANENTLY_DEFAULT",
            .found => "FOUND",
            .see_other => "SEE_OTHER",
            .temporary_redirect => "TEMPORARY_REDIRECT",
            .permanent_redirect => "PERMANENT_REDIRECT",
        };
    }
};

pub const HttpRedirectUrlMapArgs = struct {
    name: []const u8,
    strip_query: bool = false,
    response_code: RedirectResponseCode = .moved_permanently,
};

pub const HttpRedirectUrlMap = struct {
    pub const Outputs = struct {
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
    };

    node: resource.ResourceNode,
    self_link: Outputs.SelfLink.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: HttpRedirectUrlMapArgs,
    ) BuildError!HttpRedirectUrlMap {
        try validateGlobal(provider, args.name);
        const fields = [_]value.Field{
            .{ .name = "https_redirect", .value = .{ .boolean = true } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "redirect_response_code", .value = .{ .string = args.response_code.apiName() } },
            .{ .name = "strip_query", .value = .{ .boolean = args.strip_query } },
        };
        const node = try buildNode(allocator, "gcp.compute.HttpRedirectUrlMap", args.name, args.name, &fields);
        return .{ .node = node, .self_link = Outputs.SelfLink.fromResource(node.id) };
    }

    pub fn deinit(self: *HttpRedirectUrlMap, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const TargetHttpProxyArgs = struct {
    name: []const u8,
    url_map: []const u8,
};

pub const TargetHttpProxy = struct {
    pub const Outputs = struct {
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
    };

    node: resource.ResourceNode,
    self_link: Outputs.SelfLink.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: TargetHttpProxyArgs,
    ) BuildError!TargetHttpProxy {
        try validateGlobal(provider, args.name);
        if (args.url_map.len == 0) return error.MissingBackend;
        const fields = [_]value.Field{
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "url_map", .value = .{ .string = args.url_map } },
        };
        const node = try buildNode(allocator, "gcp.compute.TargetHttpProxy", args.name, args.name, &fields);
        return .{ .node = node, .self_link = Outputs.SelfLink.fromResource(node.id) };
    }

    pub fn deinit(self: *TargetHttpProxy, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const GlobalForwardingRuleArgs = struct {
    name: []const u8,
    address: []const u8,
    target: []const u8,
    port: u16 = 443,
};

pub const GlobalForwardingRule = struct {
    pub const Outputs = struct {
        pub const IpAddress = output.Descriptor("ip_address", []const u8, .public);
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
    };

    node: resource.ResourceNode,
    ip_address: Outputs.IpAddress.OutputType,
    self_link: Outputs.SelfLink.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: GlobalForwardingRuleArgs,
    ) BuildError!GlobalForwardingRule {
        try validateGlobal(provider, args.name);
        if (args.address.len == 0 or args.target.len == 0) return error.MissingBackend;
        if (args.port == 0) return error.InvalidPort;
        const fields = [_]value.Field{
            .{ .name = "address", .value = .{ .string = args.address } },
            .{ .name = "load_balancing_scheme", .value = .{ .string = "EXTERNAL_MANAGED" } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "network_tier", .value = .{ .string = "PREMIUM" } },
            .{ .name = "port", .value = .{ .integer = args.port } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "target", .value = .{ .string = args.target } },
        };
        const node = try buildNode(allocator, "gcp.compute.GlobalForwardingRule", args.name, args.name, &fields);
        return .{
            .node = node,
            .ip_address = Outputs.IpAddress.fromResource(node.id),
            .self_link = Outputs.SelfLink.fromResource(node.id),
        };
    }

    pub fn deinit(self: *GlobalForwardingRule, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn validateGlobal(provider: config_mod.ProviderConfig, name: []const u8) BuildError!void {
    try provider.validate();
    if (name.len == 0) return error.MissingName;
    if (provider.network_tier != .premium) return error.PremiumTierRequired;
}

fn isValidCertificateDomain(domain: []const u8) bool {
    if (domain.len == 0 or domain.len > 253 or domain[domain.len - 1] == '.') return false;
    const host = if (std.mem.startsWith(u8, domain, "*.")) domain[2..] else domain;
    if (host.len == 0 or std.mem.indexOfScalar(u8, host, '.') == null) return false;
    var labels = std.mem.splitScalar(u8, host, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63) return false;
        if (!std.ascii.isAlphanumeric(label[0]) or !std.ascii.isAlphanumeric(label[label.len - 1])) return false;
        for (label) |character| {
            if (!(std.ascii.isLower(character) or std.ascii.isDigit(character) or character == '-')) return false;
        }
    }
    return true;
}

fn buildNode(
    allocator: std.mem.Allocator,
    type_name: []const u8,
    id_suffix: []const u8,
    logical_id: []const u8,
    fields: []const value.Field,
) BuildError!resource.ResourceNode {
    const id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_name, id_suffix });
    defer allocator.free(id);
    return resource.ResourceNode.initOwned(allocator, .{
        .id = id,
        .provider = .gcp,
        .type_name = type_name,
        .schema_version = 1,
        .logical_id = logical_id,
        .inputs = .{ .object = fields },
    }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
    };
}

fn stringValuesAlloc(allocator: std.mem.Allocator, strings: []const []const u8) BuildError![]value.Value {
    const values = try allocator.alloc(value.Value, strings.len);
    for (strings, 0..) |string, index| values[index] = .{ .string = string };
    return values;
}

fn ownedValue(allocator: std.mem.Allocator, input: value.Value) BuildError!value.Value {
    return value.Value.initOwned(allocator, input) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn deinitValues(allocator: std.mem.Allocator, values: []value.Value) void {
    for (values) |*item| item.deinit(allocator);
    allocator.free(values);
}
