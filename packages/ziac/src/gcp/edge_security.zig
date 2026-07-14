const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    DuplicateValue,
    InvalidCachePolicy,
    InvalidCertificate,
    InvalidDomain,
    InvalidMapEntry,
    InvalidName,
    InvalidSecurityPolicy,
    InvalidTlsPolicy,
    InvalidValue,
    OutputNotKnown,
};

pub const CacheMode = enum { use_origin_headers, force_cache_all, cache_all_static };
pub const CompressionMode = enum { disabled, automatic };

pub const BackendBucketArgs = struct {
    name: []const u8,
    bucket: output.Output([]const u8, .public),
    edge_security_policy: ?output.Output([]const u8, .public) = null,
    enable_cdn: bool = true,
    cache_mode: CacheMode = .cache_all_static,
    client_ttl_seconds: u32 = 3600,
    default_ttl_seconds: u32 = 3600,
    max_ttl_seconds: u32 = 86_400,
    negative_caching: bool = true,
    serve_while_stale_seconds: u32 = 86_400,
    request_coalescing: bool = true,
    signed_url_cache_max_age_seconds: u32 = 3600,
    compression: CompressionMode = .automatic,
    include_host: bool = true,
    include_protocol: bool = true,
    include_query_string: bool = true,
    protect: bool = true,
    retain_on_delete: bool = false,
};

pub const BackendBucket = struct {
    pub const Outputs = struct {
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
        pub const Fingerprint = output.Descriptor("fingerprint", []const u8, .public);
    };
    node: resource.ResourceNode,
    self_link: Outputs.SelfLink.OutputType,
    fingerprint: Outputs.Fingerprint.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: BackendBucketArgs) BuildError!BackendBucket {
        try provider.validate();
        try validateName(args.name);
        if (!args.enable_cdn or args.default_ttl_seconds > args.max_ttl_seconds or
            args.client_ttl_seconds > args.max_ttl_seconds or args.max_ttl_seconds > 31_536_000 or
            args.serve_while_stale_seconds > 604_800 or args.signed_url_cache_max_age_seconds > 31_536_000)
            return error.InvalidCachePolicy;
        const fields = [_]value.Field{
            .{ .name = "bucket", .value = try outputValue(args.bucket) },
            .{ .name = "cache_mode", .value = .{ .string = switch (args.cache_mode) {
                .use_origin_headers => "USE_ORIGIN_HEADERS",
                .force_cache_all => "FORCE_CACHE_ALL",
                .cache_all_static => "CACHE_ALL_STATIC",
            } } },
            .{ .name = "client_ttl_seconds", .value = .{ .integer = args.client_ttl_seconds } },
            .{ .name = "compression_mode", .value = .{ .string = if (args.compression == .automatic) "AUTOMATIC" else "DISABLED" } },
            .{ .name = "default_ttl_seconds", .value = .{ .integer = args.default_ttl_seconds } },
            .{ .name = "edge_security_policy", .value = try optionalOutputValue(args.edge_security_policy) },
            .{ .name = "enable_cdn", .value = .{ .boolean = args.enable_cdn } },
            .{ .name = "include_host", .value = .{ .boolean = args.include_host } },
            .{ .name = "include_protocol", .value = .{ .boolean = args.include_protocol } },
            .{ .name = "include_query_string", .value = .{ .boolean = args.include_query_string } },
            .{ .name = "max_ttl_seconds", .value = .{ .integer = args.max_ttl_seconds } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "negative_caching", .value = .{ .boolean = args.negative_caching } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "request_coalescing", .value = .{ .boolean = args.request_coalescing } },
            .{ .name = "serve_while_stale_seconds", .value = .{ .integer = args.serve_while_stale_seconds } },
            .{ .name = "signed_url_cache_max_age_seconds", .value = .{ .integer = args.signed_url_cache_max_age_seconds } },
        };
        const node = try nodeOwned(allocator, "gcp.compute.BackendBucket", args.name, args.name, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
        });
        return .{ .node = node, .self_link = Outputs.SelfLink.fromResource(node.id), .fingerprint = Outputs.Fingerprint.fromResource(node.id) };
    }

    pub fn deinit(self: *BackendBucket, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const SecurityPolicyType = enum { backend, edge };
pub const DenyStatus = enum { forbidden, not_found, bad_gateway };
pub const RateLimit = struct { count: u32, interval_seconds: u32 };
pub const SecurityMatch = union(enum) { src_ip_ranges: []const []const u8, expression: []const u8 };
pub const SecurityAction = union(enum) { allow: void, deny: DenyStatus, throttle: RateLimit };
pub const SecurityRule = struct {
    priority: u32,
    description: []const u8 = "",
    match: SecurityMatch,
    action: SecurityAction,
    preview: bool = false,
};

pub const SecurityPolicyArgs = struct {
    name: []const u8,
    policy_type: SecurityPolicyType,
    rules: []const SecurityRule,
    protect: bool = true,
    retain_on_delete: bool = false,
};

pub const SecurityPolicy = struct {
    pub const Outputs = struct {
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
        pub const Fingerprint = output.Descriptor("fingerprint", []const u8, .public);
    };
    node: resource.ResourceNode,
    self_link: Outputs.SelfLink.OutputType,
    fingerprint: Outputs.Fingerprint.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: SecurityPolicyArgs) BuildError!SecurityPolicy {
        try provider.validate();
        try validateName(args.name);
        if (args.rules.len == 0) return error.InvalidSecurityPolicy;
        var default_count: usize = 0;
        for (args.rules, 0..) |rule, index| {
            for (args.rules[index + 1 ..]) |other| if (rule.priority == other.priority) return error.InvalidSecurityPolicy;
            if (rule.priority == 2_147_483_647) {
                default_count += 1;
                if (!isMatchAll(rule.match)) return error.InvalidSecurityPolicy;
            }
            switch (rule.action) {
                .allow, .deny => {},
                .throttle => |limit| if (limit.count == 0 or limit.interval_seconds == 0 or limit.interval_seconds > 3600) return error.InvalidSecurityPolicy,
            }
            switch (rule.match) {
                .src_ip_ranges => |ranges| if (ranges.len == 0) return error.InvalidSecurityPolicy,
                .expression => |expression| if (expression.len == 0 or expression.len > 2048) return error.InvalidSecurityPolicy,
            }
        }
        if (default_count != 1) return error.InvalidSecurityPolicy;
        var rules = try securityRulesValueOwned(allocator, args.rules);
        defer rules.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "policy_type", .value = .{ .string = if (args.policy_type == .edge) "CLOUD_ARMOR_EDGE" else "CLOUD_ARMOR" } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "rules", .value = rules },
        };
        const node = try nodeOwned(allocator, "gcp.compute.SecurityPolicy", args.name, args.name, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
            .operation_timeout_millis = 30 * 60 * 1000,
        });
        return .{ .node = node, .self_link = Outputs.SelfLink.fromResource(node.id), .fingerprint = Outputs.Fingerprint.fromResource(node.id) };
    }

    pub fn deinit(self: *SecurityPolicy, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const MinimumTls = enum { tls_1_0, tls_1_1, tls_1_2 };
pub const SslProfile = enum { compatible, modern, restricted, custom };
pub const SslPolicyArgs = struct {
    name: []const u8,
    minimum_tls: MinimumTls = .tls_1_2,
    profile: SslProfile = .modern,
    custom_features: []const []const u8 = &.{},
    protect: bool = true,
    retain_on_delete: bool = false,
};

pub const SslPolicy = struct {
    pub const Outputs = struct {
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
        pub const Fingerprint = output.Descriptor("fingerprint", []const u8, .public);
    };
    node: resource.ResourceNode,
    self_link: Outputs.SelfLink.OutputType,
    fingerprint: Outputs.Fingerprint.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: SslPolicyArgs) BuildError!SslPolicy {
        try provider.validate();
        try validateName(args.name);
        if ((args.profile == .custom) != (args.custom_features.len > 0)) return error.InvalidTlsPolicy;
        var features = try stringListValueOwned(allocator, args.custom_features);
        defer features.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "custom_features", .value = features },
            .{ .name = "minimum_tls_version", .value = .{ .string = switch (args.minimum_tls) {
                .tls_1_0 => "TLS_1_0",
                .tls_1_1 => "TLS_1_1",
                .tls_1_2 => "TLS_1_2",
            } } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "profile", .value = .{ .string = switch (args.profile) {
                .compatible => "COMPATIBLE",
                .modern => "MODERN",
                .restricted => "RESTRICTED",
                .custom => "CUSTOM",
            } } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        };
        const node = try nodeOwned(allocator, "gcp.compute.SslPolicy", args.name, args.name, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
        });
        return .{ .node = node, .self_link = Outputs.SelfLink.fromResource(node.id), .fingerprint = Outputs.Fingerprint.fromResource(node.id) };
    }

    pub fn deinit(self: *SslPolicy, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const DnsAuthorizationType = enum { standard, fixed_record };
pub const DnsAuthorizationArgs = struct {
    name: []const u8,
    domain: []const u8,
    location: []const u8 = "global",
    authorization_type: DnsAuthorizationType = .fixed_record,
    protect: bool = true,
    retain_on_delete: bool = false,
};

pub const DnsAuthorization = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const DnsRecordName = output.Descriptor("dns_record_name", []const u8, .public);
        pub const DnsRecordType = output.Descriptor("dns_record_type", []const u8, .public);
        pub const DnsRecordData = output.Descriptor("dns_record_data", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    dns_record_name: Outputs.DnsRecordName.OutputType,
    dns_record_type: Outputs.DnsRecordType.OutputType,
    dns_record_data: Outputs.DnsRecordData.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: DnsAuthorizationArgs) BuildError!DnsAuthorization {
        try provider.validate();
        try validateName(args.name);
        try validateLocation(args.location);
        try validateDomain(args.domain, false);
        const fields = [_]value.Field{
            .{ .name = "authorization_type", .value = .{ .string = if (args.authorization_type == .fixed_record) "FIXED_RECORD" else "PER_PROJECT_RECORD" } },
            .{ .name = "domain", .value = .{ .string = args.domain } },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        };
        const logical_id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ args.location, args.name });
        defer allocator.free(logical_id);
        const node = try nodeOwned(allocator, "gcp.certificatemanager.DnsAuthorization", logical_id, args.name, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
        });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .dns_record_name = Outputs.DnsRecordName.fromResource(node.id),
            .dns_record_type = Outputs.DnsRecordType.fromResource(node.id),
            .dns_record_data = Outputs.DnsRecordData.fromResource(node.id),
        };
    }

    pub fn deinit(self: *DnsAuthorization, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const CertificateScope = enum { default, edge_cache, all_regions };
pub const CertificateArgs = struct {
    name: []const u8,
    domains: []const []const u8,
    dns_authorizations: []const output.Output([]const u8, .public),
    location: []const u8 = "global",
    scope: CertificateScope = .default,
    protect: bool = true,
    retain_on_delete: bool = false,
};

pub const Certificate = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    state: Outputs.State.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: CertificateArgs) BuildError!Certificate {
        try provider.validate();
        try validateName(args.name);
        try validateLocation(args.location);
        if (args.domains.len == 0 or args.dns_authorizations.len == 0) return error.InvalidCertificate;
        for (args.domains, 0..) |domain, index| {
            try validateDomain(domain, true);
            for (args.domains[index + 1 ..]) |other| if (std.mem.eql(u8, domain, other)) return error.DuplicateValue;
        }
        var domains = try stringListValueOwned(allocator, args.domains);
        defer domains.deinit(allocator);
        var authorizations = try outputListValueOwned(allocator, args.dns_authorizations);
        defer authorizations.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "dns_authorizations", .value = authorizations },
            .{ .name = "domains", .value = domains },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "scope", .value = .{ .string = switch (args.scope) {
                .default => "DEFAULT",
                .edge_cache => "EDGE_CACHE",
                .all_regions => "ALL_REGIONS",
            } } },
        };
        const logical_id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ args.location, args.name });
        defer allocator.free(logical_id);
        const node = try nodeOwned(allocator, "gcp.certificatemanager.Certificate", logical_id, args.name, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
            .operation_timeout_millis = 60 * 60 * 1000,
        });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .state = Outputs.State.fromResource(node.id) };
    }

    pub fn deinit(self: *Certificate, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const CertificateMapArgs = struct {
    name: []const u8,
    location: []const u8 = "global",
    protect: bool = true,
    retain_on_delete: bool = false,
};

pub const CertificateMap = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: CertificateMapArgs) BuildError!CertificateMap {
        try provider.validate();
        try validateName(args.name);
        try validateLocation(args.location);
        const fields = [_]value.Field{
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        };
        const logical_id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ args.location, args.name });
        defer allocator.free(logical_id);
        const node = try nodeOwned(allocator, "gcp.certificatemanager.CertificateMap", logical_id, args.name, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
        });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
    }

    pub fn deinit(self: *CertificateMap, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const MapMatcher = union(enum) { hostname: []const u8, primary: void };
pub const CertificateMapEntryArgs = struct {
    name: []const u8,
    map: output.Output([]const u8, .public),
    matcher: MapMatcher,
    certificates: []const output.Output([]const u8, .public),
    location: []const u8 = "global",
    protect: bool = true,
    retain_on_delete: bool = false,
};

pub const CertificateMapEntry = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: CertificateMapEntryArgs) BuildError!CertificateMapEntry {
        try provider.validate();
        try validateName(args.name);
        try validateLocation(args.location);
        if (args.certificates.len == 0) return error.InvalidMapEntry;
        const matcher_kind: []const u8, const matcher_value: []const u8 = switch (args.matcher) {
            .hostname => |hostname| blk: {
                try validateDomain(hostname, true);
                break :blk .{ "HOSTNAME", hostname };
            },
            .primary => .{ "PRIMARY", "PRIMARY" },
        };
        var certificates = try outputListValueOwned(allocator, args.certificates);
        defer certificates.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "certificates", .value = certificates },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "map", .value = try outputValue(args.map) },
            .{ .name = "matcher_kind", .value = .{ .string = matcher_kind } },
            .{ .name = "matcher_value", .value = .{ .string = matcher_value } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        };
        const logical_id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ args.location, args.name });
        defer allocator.free(logical_id);
        const node = try nodeOwned(allocator, "gcp.certificatemanager.CertificateMapEntry", logical_id, args.name, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
        });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
    }

    pub fn deinit(self: *CertificateMapEntry, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const QuicOverride = enum { none, enable, disable };
pub const CertificateMapTargetHttpsProxyArgs = struct {
    name: []const u8,
    url_map: output.Output([]const u8, .public),
    certificate_map: output.Output([]const u8, .public),
    ssl_policy: ?output.Output([]const u8, .public) = null,
    quic: QuicOverride = .enable,
    protect: bool = true,
    retain_on_delete: bool = false,
};

pub const CertificateMapTargetHttpsProxy = struct {
    pub const Outputs = struct {
        pub const SelfLink = output.Descriptor("self_link", []const u8, .public);
        pub const Fingerprint = output.Descriptor("fingerprint", []const u8, .public);
    };
    node: resource.ResourceNode,
    self_link: Outputs.SelfLink.OutputType,
    fingerprint: Outputs.Fingerprint.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: CertificateMapTargetHttpsProxyArgs) BuildError!CertificateMapTargetHttpsProxy {
        try provider.validate();
        try validateName(args.name);
        const fields = [_]value.Field{
            .{ .name = "certificate_map", .value = try outputValue(args.certificate_map) },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "quic_override", .value = .{ .string = switch (args.quic) {
                .none => "NONE",
                .enable => "ENABLE",
                .disable => "DISABLE",
            } } },
            .{ .name = "ssl_policy", .value = try optionalOutputValue(args.ssl_policy) },
            .{ .name = "url_map", .value = try outputValue(args.url_map) },
        };
        const node = try nodeOwned(allocator, "gcp.compute.CertificateMapTargetHttpsProxy", args.name, args.name, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
            .replace_before_delete = true,
        });
        return .{ .node = node, .self_link = Outputs.SelfLink.fromResource(node.id), .fingerprint = Outputs.Fingerprint.fromResource(node.id) };
    }

    pub fn deinit(self: *CertificateMapTargetHttpsProxy, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn nodeOwned(allocator: std.mem.Allocator, type_name: []const u8, logical_scope: []const u8, logical_id: []const u8, fields: []const value.Field, lifecycle: resource.Lifecycle) BuildError!resource.ResourceNode {
    const id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_name, logical_scope });
    defer allocator.free(id);
    return resource.ResourceNode.initOwned(allocator, .{
        .id = id,
        .provider = .gcp,
        .type_name = type_name,
        .schema_version = 1,
        .logical_id = logical_id,
        .inputs = .{ .object = fields },
        .lifecycle = lifecycle,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateField => error.DuplicateField,
        else => unreachable,
    };
}

fn securityRulesValueOwned(allocator: std.mem.Allocator, source: []const SecurityRule) BuildError!value.Value {
    const sorted = try allocator.dupe(SecurityRule, source);
    defer allocator.free(sorted);
    std.mem.sort(SecurityRule, sorted, {}, lessRule);
    const items = try allocator.alloc(value.Value, sorted.len);
    defer allocator.free(items);
    var built: usize = 0;
    defer for (items[0..built]) |*item| item.deinit(allocator);
    for (sorted, 0..) |rule, index| {
        var match_values = switch (rule.match) {
            .src_ip_ranges => |ranges| try stringListValueOwned(allocator, ranges),
            .expression => |expression| try value.Value.initOwned(allocator, .{ .string = expression }),
        };
        defer match_values.deinit(allocator);
        const action_name: []const u8, const rate_count: u32, const rate_interval: u32 = switch (rule.action) {
            .allow => .{ "allow", 0, 0 },
            .deny => |status| .{ switch (status) {
                .forbidden => "deny(403)",
                .not_found => "deny(404)",
                .bad_gateway => "deny(502)",
            }, 0, 0 },
            .throttle => |limit| .{ "throttle", limit.count, limit.interval_seconds },
        };
        const fields = [_]value.Field{
            .{ .name = "action", .value = .{ .string = action_name } },
            .{ .name = "description", .value = .{ .string = rule.description } },
            .{ .name = "match_kind", .value = .{ .string = switch (rule.match) {
                .src_ip_ranges => "SRC_IPS_V1",
                .expression => "EXPR",
            } } },
            .{ .name = "match_values", .value = match_values },
            .{ .name = "preview", .value = .{ .boolean = rule.preview } },
            .{ .name = "priority", .value = .{ .integer = rule.priority } },
            .{ .name = "rate_limit_count", .value = .{ .integer = rate_count } },
            .{ .name = "rate_limit_interval_seconds", .value = .{ .integer = rate_interval } },
        };
        items[index] = try value.Value.initOwned(allocator, .{ .object = &fields });
        built += 1;
    }
    return value.Value.initOwned(allocator, .{ .list = items });
}

fn stringListValueOwned(allocator: std.mem.Allocator, source: []const []const u8) BuildError!value.Value {
    const sorted = try allocator.dupe([]const u8, source);
    defer allocator.free(sorted);
    std.mem.sort([]const u8, sorted, {}, lessString);
    for (sorted, 0..) |item, index| {
        if (item.len == 0 or std.mem.indexOfScalar(u8, item, 0) != null) return error.InvalidValue;
        if (index > 0 and std.mem.eql(u8, sorted[index - 1], item)) return error.DuplicateValue;
    }
    const items = try allocator.alloc(value.Value, sorted.len);
    defer allocator.free(items);
    for (sorted, 0..) |item, index| items[index] = .{ .string = item };
    return value.Value.initOwned(allocator, .{ .list = items });
}

fn outputListValueOwned(allocator: std.mem.Allocator, source: []const output.Output([]const u8, .public)) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, source.len);
    defer allocator.free(items);
    for (source, 0..) |item, index| items[index] = try outputValue(item);
    return value.Value.initOwned(allocator, .{ .list = items });
}

fn outputValue(candidate: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (candidate) {
        .value => |text| if (text.len > 0) .{ .string = text } else error.InvalidValue,
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn optionalOutputValue(candidate: ?output.Output([]const u8, .public)) BuildError!value.Value {
    return if (candidate) |present| outputValue(present) else .{ .string = "" };
}

fn isMatchAll(match: SecurityMatch) bool {
    return switch (match) {
        .src_ip_ranges => |ranges| ranges.len == 1 and std.mem.eql(u8, ranges[0], "*"),
        .expression => false,
    };
}

fn validateName(text: []const u8) BuildError!void {
    if (text.len == 0 or text.len > 63 or !std.ascii.isLower(text[0]) or !std.ascii.isAlphanumeric(text[text.len - 1])) return error.InvalidName;
    for (text) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return error.InvalidName;
}

fn validateLocation(text: []const u8) BuildError!void {
    if (text.len == 0 or text.len > 63 or std.mem.indexOfAny(u8, text, "\x00/ ") != null) return error.InvalidValue;
}

fn validateDomain(text: []const u8, allow_wildcard: bool) BuildError!void {
    const domain = if (std.mem.startsWith(u8, text, "*.")) blk: {
        if (!allow_wildcard) return error.InvalidDomain;
        break :blk text[2..];
    } else text;
    if (domain.len < 3 or domain.len > 253 or domain[0] == '.' or domain[domain.len - 1] == '.' or std.mem.indexOfScalar(u8, domain, '.') == null) return error.InvalidDomain;
    for (domain) |character| if (!std.ascii.isAlphanumeric(character) and character != '-' and character != '.') return error.InvalidDomain;
}

fn lessRule(_: void, left: SecurityRule, right: SecurityRule) bool {
    return left.priority < right.priority;
}

fn lessString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}
