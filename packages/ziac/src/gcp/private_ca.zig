const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    DuplicateItem,
    InvalidAlgorithm,
    InvalidCertificateRequest,
    InvalidCondition,
    InvalidKmsKey,
    InvalidLifetime,
    InvalidLocation,
    InvalidMember,
    InvalidName,
    InvalidParent,
    InvalidRole,
    InvalidSubject,
    InvalidTemplate,
    OutputNotKnown,
};

pub const RemovalPolicy = enum { retain, delete };
pub const Tier = enum { enterprise, devops };

pub const CaPoolArgs = struct {
    name: []const u8,
    project: output.Output([]const u8, .public),
    location: []const u8,
    tier: Tier,
    maximum_lifetime_seconds: u64,
    publish_ca_cert: bool = true,
    publish_crl: bool = true,
    kms_key: ?output.Output([]const u8, .public) = null,
    labels: []const config_mod.Label = &.{},
    removal_policy: RemovalPolicy = .retain,
};

pub const CaPool = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: CaPoolArgs) BuildError!CaPool {
        try provider.validate();
        try validateLogicalName(args.name);
        try validateProject(args.project);
        try validateLocation(args.location);
        try validateLifetime(args.maximum_lifetime_seconds, 600, 315_576_000);
        var kms: value.Value = .{ .string = "" };
        if (args.kms_key) |selected| {
            try validateOutputContains(selected, "/cryptoKeys/", error.InvalidKmsKey);
            kms = try outputValue(selected);
        }
        var labels = try labelsValue(allocator, args.labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "kms_key", .value = kms },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "maximum_lifetime_seconds", .value = .{ .integer = @intCast(args.maximum_lifetime_seconds) } },
            .{ .name = "project", .value = try outputValue(args.project) },
            .{ .name = "publish_ca_cert", .value = .{ .boolean = args.publish_ca_cert } },
            .{ .name = "publish_crl", .value = .{ .boolean = args.publish_crl } },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
            .{ .name = "tier", .value = .{ .string = if (args.tier == .enterprise) "ENTERPRISE" else "DEVOPS" } },
        };
        const node = try initNode(allocator, "gcp.privateca.CaPool", args.name, &fields, .{ .protect = true, .retain_on_delete = args.removal_policy == .retain, .operation_timeout_millis = 30 * 60 * 1000 });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
    }

    pub fn deinit(self: *CaPool, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const AuthorityType = enum { self_signed, subordinate };
pub const KeyAlgorithm = enum { rsa_2048_sha256, rsa_3072_sha256, rsa_4096_sha256, ec_p256_sha256, ec_p384_sha384 };

pub const Subject = struct {
    common_name: []const u8,
    organization: []const u8 = "",
    organizational_unit: []const u8 = "",
    country_code: []const u8 = "",
    locality: []const u8 = "",
    province: []const u8 = "",
};

pub const CertificateAuthorityArgs = struct {
    name: []const u8,
    pool: output.Output([]const u8, .public),
    authority_type: AuthorityType,
    lifetime_seconds: u64,
    key_algorithm: KeyAlgorithm,
    subject: Subject,
    subordinate_issuer: ?output.Output([]const u8, .public) = null,
    gcs_bucket: []const u8 = "",
    labels: []const config_mod.Label = &.{},
    removal_policy: RemovalPolicy = .retain,
};

pub const CertificateAuthority = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
        pub const PemCaCertificates = output.Descriptor("pem_ca_certificates", []const []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    state: Outputs.State.OutputType,
    pem_ca_certificates: Outputs.PemCaCertificates.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: CertificateAuthorityArgs) BuildError!CertificateAuthority {
        try provider.validate();
        try validateLogicalName(args.name);
        try validateOutputContains(args.pool, "/caPools/", error.InvalidParent);
        try validateLifetime(args.lifetime_seconds, 86_400, 315_576_000);
        try validateSubject(args.subject);
        if ((args.authority_type == .self_signed) != (args.subordinate_issuer == null)) return error.InvalidParent;
        var issuer: value.Value = .{ .string = "" };
        if (args.subordinate_issuer) |selected| {
            try validateOutputContains(selected, "/certificateAuthorities/", error.InvalidParent);
            issuer = try outputValue(selected);
        }
        if (args.gcs_bucket.len != 0 and !validBucket(args.gcs_bucket)) return error.InvalidName;
        var subject = try subjectValue(allocator, args.subject);
        defer subject.deinit(allocator);
        var labels = try labelsValue(allocator, args.labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "authority_type", .value = .{ .string = if (args.authority_type == .self_signed) "SELF_SIGNED" else "SUBORDINATE" } },
            .{ .name = "gcs_bucket", .value = .{ .string = args.gcs_bucket } },
            .{ .name = "key_algorithm", .value = .{ .string = keyAlgorithmWire(args.key_algorithm) } },
            .{ .name = "labels", .value = labels },
            .{ .name = "lifetime_seconds", .value = .{ .integer = @intCast(args.lifetime_seconds) } },
            .{ .name = "pool", .value = try outputValue(args.pool) },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
            .{ .name = "subordinate_issuer", .value = issuer },
            .{ .name = "subject", .value = subject },
        };
        const node = try initNode(allocator, "gcp.privateca.CertificateAuthority", args.name, &fields, .{ .protect = true, .retain_on_delete = args.removal_policy == .retain, .operation_timeout_millis = 30 * 60 * 1000 });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .state = Outputs.State.fromResource(node.id),
            .pem_ca_certificates = Outputs.PemCaCertificates.fromResource(node.id),
        };
    }

    pub fn deinit(self: *CertificateAuthority, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const KeyUsage = struct {
    digital_signature: bool = false,
    content_commitment: bool = false,
    key_encipherment: bool = false,
    data_encipherment: bool = false,
    key_agreement: bool = false,
    cert_sign: bool = false,
    crl_sign: bool = false,
    server_auth: bool = false,
    client_auth: bool = false,
    code_signing: bool = false,
    email_protection: bool = false,
};

pub const CertificateTemplateArgs = struct {
    name: []const u8,
    project: output.Output([]const u8, .public),
    location: []const u8,
    description: []const u8 = "",
    maximum_lifetime_seconds: u64,
    is_ca: bool = false,
    max_issuer_path_length: ?u8 = null,
    allow_subject_passthrough: bool = false,
    allow_sans_passthrough: bool = false,
    key_usage: KeyUsage,
    labels: []const config_mod.Label = &.{},
    removal_policy: RemovalPolicy = .retain,
};

pub const CertificateTemplate = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: CertificateTemplateArgs) BuildError!CertificateTemplate {
        try provider.validate();
        try validateLogicalName(args.name);
        try validateProject(args.project);
        try validateLocation(args.location);
        try validateLifetime(args.maximum_lifetime_seconds, 600, 315_576_000);
        if (args.description.len > 1024 or (args.max_issuer_path_length != null and !args.is_ca) or !hasKeyUsage(args.key_usage)) return error.InvalidTemplate;
        var usage = try keyUsageValue(allocator, args.key_usage);
        defer usage.deinit(allocator);
        var labels = try labelsValue(allocator, args.labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "allow_sans_passthrough", .value = .{ .boolean = args.allow_sans_passthrough } },
            .{ .name = "allow_subject_passthrough", .value = .{ .boolean = args.allow_subject_passthrough } },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "is_ca", .value = .{ .boolean = args.is_ca } },
            .{ .name = "key_usage", .value = usage },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "max_issuer_path_length", .value = .{ .integer = if (args.max_issuer_path_length) |length| length else -1 } },
            .{ .name = "maximum_lifetime_seconds", .value = .{ .integer = @intCast(args.maximum_lifetime_seconds) } },
            .{ .name = "project", .value = try outputValue(args.project) },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
        };
        const node = try initNode(allocator, "gcp.privateca.CertificateTemplate", args.name, &fields, .{ .retain_on_delete = args.removal_policy == .retain, .operation_timeout_millis = 30 * 60 * 1000 });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
    }

    pub fn deinit(self: *CertificateTemplate, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const CertificateConfig = struct {
    subject: Subject,
    dns_names: []const []const u8 = &.{},
    email_addresses: []const []const u8 = &.{},
    ip_addresses: []const []const u8 = &.{},
    uris: []const []const u8 = &.{},
};

pub const CertificateRequest = union(enum) {
    config: CertificateConfig,
    pem_csr: []const u8,
};

pub const CertificateArgs = struct {
    name: []const u8,
    pool: output.Output([]const u8, .public),
    lifetime_seconds: u64,
    template: ?output.Output([]const u8, .public) = null,
    request: CertificateRequest,
    labels: []const config_mod.Label = &.{},
};

pub const Certificate = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const PemCertificate = output.Descriptor("pem_certificate", []const u8, .public);
        pub const PemCertificateChain = output.Descriptor("pem_certificate_chain", []const []const u8, .public);
        pub const Issuer = output.Descriptor("issuer", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    pem_certificate: Outputs.PemCertificate.OutputType,
    pem_certificate_chain: Outputs.PemCertificateChain.OutputType,
    issuer: Outputs.Issuer.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: CertificateArgs) BuildError!Certificate {
        try provider.validate();
        try validateLogicalName(args.name);
        try validateOutputContains(args.pool, "/caPools/", error.InvalidParent);
        try validateLifetime(args.lifetime_seconds, 60, 315_576_000);
        var template: value.Value = .{ .string = "" };
        if (args.template) |selected| {
            try validateOutputContains(selected, "/certificateTemplates/", error.InvalidTemplate);
            template = try outputValue(selected);
        }
        var request = try certificateRequestValue(allocator, args.request);
        defer request.deinit(allocator);
        var labels = try labelsValue(allocator, args.labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "labels", .value = labels },
            .{ .name = "lifetime_seconds", .value = .{ .integer = @intCast(args.lifetime_seconds) } },
            .{ .name = "pool", .value = try outputValue(args.pool) },
            .{ .name = "request", .value = request },
            .{ .name = "template", .value = template },
        };
        const node = try initNode(allocator, "gcp.privateca.Certificate", args.name, &fields, .{ .protect = true, .retain_on_delete = true, .operation_timeout_millis = 30 * 60 * 1000 });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .pem_certificate = Outputs.PemCertificate.fromResource(node.id),
            .pem_certificate_chain = Outputs.PemCertificateChain.fromResource(node.id),
            .issuer = Outputs.Issuer.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Certificate, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const IamCondition = struct {
    title: []const u8,
    expression: []const u8,
    description: []const u8 = "",
};

pub const IamMemberArgs = struct {
    name: []const u8,
    resource: output.Output([]const u8, .public),
    role: []const u8,
    member: []const u8,
    condition: ?IamCondition = null,
};

pub const CaPoolIamMember = iamMemberType("gcp.privateca.CaPoolIamMember", "/caPools/");
pub const CertificateTemplateIamMember = iamMemberType("gcp.privateca.CertificateTemplateIamMember", "/certificateTemplates/");

fn iamMemberType(comptime type_name: []const u8, comptime resource_segment: []const u8) type {
    return struct {
        node: resource.ResourceNode,

        pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: IamMemberArgs) BuildError!@This() {
            try provider.validate();
            try validateLogicalName(args.name);
            try validateOutputContains(args.resource, resource_segment, error.InvalidParent);
            if (!std.mem.startsWith(u8, args.role, "roles/") or std.mem.indexOfScalar(u8, args.role, ' ') != null) return error.InvalidRole;
            if (!validMember(args.member)) return error.InvalidMember;
            var condition = if (args.condition) |selected| try conditionValue(allocator, selected) else try ownedValue(allocator, .{ .object = &.{} });
            defer condition.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "condition", .value = condition },
                .{ .name = "has_condition", .value = .{ .boolean = args.condition != null } },
                .{ .name = "member", .value = .{ .string = args.member } },
                .{ .name = "resource", .value = try outputValue(args.resource) },
                .{ .name = "role", .value = .{ .string = args.role } },
            };
            return .{ .node = try initNode(allocator, type_name, args.name, &fields, .{}) };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.node.deinit(allocator);
            self.* = undefined;
        }
    };
}

fn certificateRequestValue(allocator: std.mem.Allocator, request: CertificateRequest) BuildError!value.Value {
    return switch (request) {
        .pem_csr => |csr| blk: {
            if (!std.mem.startsWith(u8, csr, "-----BEGIN CERTIFICATE REQUEST-----") or std.mem.indexOf(u8, csr, "PRIVATE KEY") != null) return error.InvalidCertificateRequest;
            const fields = [_]value.Field{
                .{ .name = "kind", .value = .{ .string = "pem_csr" } },
                .{ .name = "pem_csr", .value = .{ .string = csr } },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
        .config => |config| blk: {
            try validateSubject(config.subject);
            if (config.dns_names.len + config.email_addresses.len + config.ip_addresses.len + config.uris.len == 0) return error.InvalidCertificateRequest;
            try validateUniqueStrings(config.dns_names);
            try validateUniqueStrings(config.email_addresses);
            try validateUniqueStrings(config.ip_addresses);
            try validateUniqueStrings(config.uris);
            var subject = try subjectValue(allocator, config.subject);
            defer subject.deinit(allocator);
            var dns = try stringsValue(allocator, config.dns_names);
            defer dns.deinit(allocator);
            var emails = try stringsValue(allocator, config.email_addresses);
            defer emails.deinit(allocator);
            var ips = try stringsValue(allocator, config.ip_addresses);
            defer ips.deinit(allocator);
            var uris = try stringsValue(allocator, config.uris);
            defer uris.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "dns_names", .value = dns },
                .{ .name = "email_addresses", .value = emails },
                .{ .name = "ip_addresses", .value = ips },
                .{ .name = "kind", .value = .{ .string = "config" } },
                .{ .name = "subject", .value = subject },
                .{ .name = "uris", .value = uris },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
    };
}

fn subjectValue(allocator: std.mem.Allocator, subject: Subject) BuildError!value.Value {
    const fields = [_]value.Field{
        .{ .name = "common_name", .value = .{ .string = subject.common_name } },
        .{ .name = "country_code", .value = .{ .string = subject.country_code } },
        .{ .name = "locality", .value = .{ .string = subject.locality } },
        .{ .name = "organization", .value = .{ .string = subject.organization } },
        .{ .name = "organizational_unit", .value = .{ .string = subject.organizational_unit } },
        .{ .name = "province", .value = .{ .string = subject.province } },
    };
    return ownedValue(allocator, .{ .object = &fields });
}

fn keyUsageValue(allocator: std.mem.Allocator, usage: KeyUsage) BuildError!value.Value {
    const fields = [_]value.Field{
        .{ .name = "cert_sign", .value = .{ .boolean = usage.cert_sign } },
        .{ .name = "client_auth", .value = .{ .boolean = usage.client_auth } },
        .{ .name = "code_signing", .value = .{ .boolean = usage.code_signing } },
        .{ .name = "content_commitment", .value = .{ .boolean = usage.content_commitment } },
        .{ .name = "crl_sign", .value = .{ .boolean = usage.crl_sign } },
        .{ .name = "data_encipherment", .value = .{ .boolean = usage.data_encipherment } },
        .{ .name = "digital_signature", .value = .{ .boolean = usage.digital_signature } },
        .{ .name = "email_protection", .value = .{ .boolean = usage.email_protection } },
        .{ .name = "key_agreement", .value = .{ .boolean = usage.key_agreement } },
        .{ .name = "key_encipherment", .value = .{ .boolean = usage.key_encipherment } },
        .{ .name = "server_auth", .value = .{ .boolean = usage.server_auth } },
    };
    return ownedValue(allocator, .{ .object = &fields });
}

fn conditionValue(allocator: std.mem.Allocator, condition: IamCondition) BuildError!value.Value {
    if (condition.title.len == 0 or condition.expression.len == 0 or condition.title.len > 100 or condition.description.len > 256) return error.InvalidCondition;
    const fields = [_]value.Field{
        .{ .name = "description", .value = .{ .string = condition.description } },
        .{ .name = "expression", .value = .{ .string = condition.expression } },
        .{ .name = "title", .value = .{ .string = condition.title } },
    };
    return ownedValue(allocator, .{ .object = &fields });
}

fn labelsValue(allocator: std.mem.Allocator, labels: []const config_mod.Label) BuildError!value.Value {
    const fields = try allocator.alloc(value.Field, labels.len);
    defer allocator.free(fields);
    for (labels, 0..) |label, index| {
        for (labels[index + 1 ..]) |other| if (std.mem.eql(u8, label.key, other.key)) return error.DuplicateItem;
        fields[index] = .{ .name = label.key, .value = .{ .string = label.value } };
    }
    return ownedValue(allocator, .{ .object = fields });
}

fn stringsValue(allocator: std.mem.Allocator, strings: []const []const u8) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, strings.len);
    defer allocator.free(items);
    for (strings, 0..) |item, index| items[index] = .{ .string = item };
    return ownedValue(allocator, .{ .list = items });
}

fn initNode(allocator: std.mem.Allocator, type_name: []const u8, logical_name: []const u8, fields: []const value.Field, lifecycle: resource.Lifecycle) BuildError!resource.ResourceNode {
    const id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_name, logical_name });
    defer allocator.free(id);
    return resource.ResourceNode.initOwned(allocator, .{ .id = id, .provider = .gcp, .type_name = type_name, .schema_version = 1, .logical_id = logical_name, .inputs = .{ .object = fields }, .lifecycle = lifecycle }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}

fn validateLogicalName(name: []const u8) BuildError!void {
    if (name.len == 0 or name.len > 63 or !std.ascii.isLower(name[0]) or !std.ascii.isAlphanumeric(name[name.len - 1])) return error.InvalidName;
    for (name) |char| if (!(std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '-')) return error.InvalidName;
}

fn validateProject(selected: output.Output([]const u8, .public)) BuildError!void {
    switch (selected) {
        .value => |known| if (!std.mem.startsWith(u8, known, "projects/") or known.len == "projects/".len or std.mem.indexOfScalarPos(u8, known, "projects/".len, '/') != null) return error.InvalidParent,
        .resource_ref => {},
        .unknown_reason => return error.OutputNotKnown,
    }
}

fn validateLocation(location: []const u8) BuildError!void {
    if (location.len == 0 or location.len > 63) return error.InvalidLocation;
    for (location) |char| if (!(std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '-')) return error.InvalidLocation;
}

fn validateLifetime(seconds: u64, minimum: u64, maximum: u64) BuildError!void {
    if (seconds < minimum or seconds > maximum) return error.InvalidLifetime;
}

fn validateSubject(subject: Subject) BuildError!void {
    if (subject.common_name.len == 0 or subject.common_name.len > 64 or subject.organization.len > 64 or subject.organizational_unit.len > 64 or subject.locality.len > 128 or subject.province.len > 128 or
        (subject.country_code.len != 0 and (subject.country_code.len != 2 or !std.ascii.isUpper(subject.country_code[0]) or !std.ascii.isUpper(subject.country_code[1])))) return error.InvalidSubject;
}

fn validateOutputContains(selected: output.Output([]const u8, .public), needle: []const u8, failure: error{ InvalidKmsKey, InvalidParent, InvalidTemplate }) BuildError!void {
    switch (selected) {
        .value => |known| if (!std.mem.startsWith(u8, known, "projects/") or std.mem.indexOf(u8, known, needle) == null) return failure,
        .resource_ref => {},
        .unknown_reason => return error.OutputNotKnown,
    }
}

fn outputValue(selected: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (selected) {
        .value => |known| .{ .string = known },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn ownedValue(allocator: std.mem.Allocator, source: value.Value) BuildError!value.Value {
    var holder = resource.ResourceNode.initOwned(allocator, .{ .id = "temporary", .provider = .local, .type_name = "local.Value", .schema_version = 1, .logical_id = "temporary", .inputs = source }) catch |err| switch (err) {
        error.DuplicateField => return error.DuplicateField,
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    const result = holder.inputs;
    holder.inputs = .{ .object = &.{} };
    holder.deinit(allocator);
    return result;
}

fn validateUniqueStrings(items: []const []const u8) BuildError!void {
    for (items, 0..) |item, index| {
        if (item.len == 0) return error.InvalidCertificateRequest;
        for (items[index + 1 ..]) |other| if (std.mem.eql(u8, item, other)) return error.DuplicateItem;
    }
}

fn validMember(member: []const u8) bool {
    const prefixes = [_][]const u8{ "user:", "group:", "serviceAccount:", "domain:", "principal:", "principalSet:" };
    for (prefixes) |prefix| if (std.mem.startsWith(u8, member, prefix) and member.len > prefix.len) return true;
    return false;
}

fn hasKeyUsage(usage: KeyUsage) bool {
    return usage.digital_signature or usage.content_commitment or usage.key_encipherment or usage.data_encipherment or usage.key_agreement or usage.cert_sign or usage.crl_sign or usage.server_auth or usage.client_auth or usage.code_signing or usage.email_protection;
}

fn validBucket(name: []const u8) bool {
    if (name.len < 3 or name.len > 63 or !std.ascii.isAlphanumeric(name[0]) or !std.ascii.isAlphanumeric(name[name.len - 1])) return false;
    for (name) |char| if (!(std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '-' or char == '_' or char == '.')) return false;
    return true;
}

fn keyAlgorithmWire(algorithm: KeyAlgorithm) []const u8 {
    return switch (algorithm) {
        .rsa_2048_sha256 => "RSA_PKCS1_2048_SHA256",
        .rsa_3072_sha256 => "RSA_PKCS1_3072_SHA256",
        .rsa_4096_sha256 => "RSA_PKCS1_4096_SHA256",
        .ec_p256_sha256 => "EC_P256_SHA256",
        .ec_p384_sha384 => "EC_P384_SHA384",
    };
}
