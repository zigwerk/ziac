const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    DuplicateItem,
    InvalidAdmissionRule,
    InvalidAttestor,
    InvalidCondition,
    InvalidKey,
    InvalidMember,
    InvalidName,
    InvalidNote,
    InvalidProject,
    InvalidRole,
    OutputNotKnown,
};

pub const RemovalPolicy = enum { retain, delete };
pub const Evaluation = enum { always_allow, require_attestation, always_deny };
pub const Enforcement = enum { block_and_audit, audit_only };

pub const AdmissionRule = struct {
    evaluation: Evaluation,
    enforcement: Enforcement,
    attestors: []const output.Output([]const u8, .public) = &.{},
};

pub const NamedRule = struct {
    selector: []const u8,
    rule: AdmissionRule,
};

pub const PolicyArgs = struct {
    name: []const u8,
    project: output.Output([]const u8, .public),
    description: []const u8 = "",
    global_policy_evaluation: bool = true,
    allowlist_patterns: []const []const u8 = &.{},
    default_rule: AdmissionRule,
    cluster_rules: []const NamedRule = &.{},
    namespace_rules: []const NamedRule = &.{},
    service_account_rules: []const NamedRule = &.{},
    istio_identity_rules: []const NamedRule = &.{},
};

pub const Policy = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    etag: Outputs.Etag.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: PolicyArgs) BuildError!Policy {
        try provider.validate();
        try validateLogicalName(args.name);
        try validateProject(args.project);
        if (args.description.len > 1024) return error.InvalidName;
        try validateAdmissionRule(args.default_rule);
        try validateNamedRules(args.cluster_rules);
        try validateNamedRules(args.namespace_rules);
        try validateNamedRules(args.service_account_rules);
        try validateNamedRules(args.istio_identity_rules);
        try validateUniqueStrings(args.allowlist_patterns);
        for (args.allowlist_patterns) |pattern| if (!validImagePattern(pattern)) return error.InvalidAdmissionRule;
        var allowlist = try stringsValue(allocator, args.allowlist_patterns);
        defer allowlist.deinit(allocator);
        var default_rule = try admissionRuleValue(allocator, args.default_rule);
        defer default_rule.deinit(allocator);
        var cluster_rules = try namedRulesValue(allocator, args.cluster_rules);
        defer cluster_rules.deinit(allocator);
        var namespace_rules = try namedRulesValue(allocator, args.namespace_rules);
        defer namespace_rules.deinit(allocator);
        var service_account_rules = try namedRulesValue(allocator, args.service_account_rules);
        defer service_account_rules.deinit(allocator);
        var istio_rules = try namedRulesValue(allocator, args.istio_identity_rules);
        defer istio_rules.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "allowlist_patterns", .value = allowlist },
            .{ .name = "cluster_rules", .value = cluster_rules },
            .{ .name = "default_rule", .value = default_rule },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "global_policy_evaluation", .value = .{ .boolean = args.global_policy_evaluation } },
            .{ .name = "istio_identity_rules", .value = istio_rules },
            .{ .name = "namespace_rules", .value = namespace_rules },
            .{ .name = "project", .value = try outputValue(args.project) },
            .{ .name = "service_account_rules", .value = service_account_rules },
        };
        const node = try initNode(allocator, "gcp.binaryauthorization.Policy", args.name, &fields, .{ .protect = true, .retain_on_delete = true });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .etag = Outputs.Etag.fromResource(node.id) };
    }

    pub fn deinit(self: *Policy, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const PkixAlgorithm = enum {
    rsa_pss_2048_sha256,
    rsa_pss_3072_sha256,
    rsa_pss_4096_sha256,
    rsa_pkcs1_2048_sha256,
    rsa_pkcs1_3072_sha256,
    rsa_pkcs1_4096_sha256,
    ecdsa_p256_sha256,
    ecdsa_p384_sha384,
};

pub const PkixPublicKey = struct {
    public_key_pem: []const u8,
    signature_algorithm: PkixAlgorithm,
};

pub const PublicKeyMaterial = union(enum) {
    pgp: []const u8,
    pkix: PkixPublicKey,
};

pub const AttestorPublicKey = struct {
    id: []const u8 = "",
    comment: []const u8 = "",
    key: PublicKeyMaterial,
};

pub const AttestorArgs = struct {
    name: []const u8,
    project: output.Output([]const u8, .public),
    note_reference: output.Output([]const u8, .public),
    public_keys: []const AttestorPublicKey,
    description: []const u8 = "",
    removal_policy: RemovalPolicy = .retain,
};

pub const Attestor = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const DelegationServiceAccount = output.Descriptor("delegation_service_account", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    delegation_service_account: Outputs.DelegationServiceAccount.OutputType,
    etag: Outputs.Etag.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: AttestorArgs) BuildError!Attestor {
        try provider.validate();
        try validateLogicalName(args.name);
        try validateProject(args.project);
        try validateNote(args.note_reference);
        if (args.public_keys.len == 0 or args.description.len > 1024) return error.InvalidAttestor;
        try validatePublicKeys(args.public_keys);
        var keys = try publicKeysValue(allocator, args.public_keys);
        defer keys.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "note_reference", .value = try outputValue(args.note_reference) },
            .{ .name = "project", .value = try outputValue(args.project) },
            .{ .name = "public_keys", .value = keys },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
        };
        const node = try initNode(allocator, "gcp.binaryauthorization.Attestor", args.name, &fields, .{ .retain_on_delete = args.removal_policy == .retain });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .delegation_service_account = Outputs.DelegationServiceAccount.fromResource(node.id),
            .etag = Outputs.Etag.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Attestor, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const IamCondition = struct {
    title: []const u8,
    expression: []const u8,
    description: []const u8 = "",
};

pub const AttestorIamMemberArgs = struct {
    name: []const u8,
    attestor: output.Output([]const u8, .public),
    role: []const u8,
    member: []const u8,
    condition: ?IamCondition = null,
};

pub const AttestorIamMember = struct {
    node: resource.ResourceNode,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: AttestorIamMemberArgs) BuildError!AttestorIamMember {
        try provider.validate();
        try validateLogicalName(args.name);
        try validateOutputContains(args.attestor, "/attestors/", error.InvalidAttestor);
        if (!std.mem.startsWith(u8, args.role, "roles/") or std.mem.indexOfScalar(u8, args.role, ' ') != null) return error.InvalidRole;
        if (!validMember(args.member)) return error.InvalidMember;
        var condition = if (args.condition) |selected| try conditionValue(allocator, selected) else try ownedValue(allocator, .{ .object = &.{} });
        defer condition.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "attestor", .value = try outputValue(args.attestor) },
            .{ .name = "condition", .value = condition },
            .{ .name = "has_condition", .value = .{ .boolean = args.condition != null } },
            .{ .name = "member", .value = .{ .string = args.member } },
            .{ .name = "role", .value = .{ .string = args.role } },
        };
        return .{ .node = try initNode(allocator, "gcp.binaryauthorization.AttestorIamMember", args.name, &fields, .{}) };
    }

    pub fn deinit(self: *AttestorIamMember, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn validateAdmissionRule(rule: AdmissionRule) BuildError!void {
    if (rule.evaluation == .require_attestation) {
        if (rule.attestors.len == 0) return error.InvalidAdmissionRule;
        for (rule.attestors) |attestor| try validateOutputContains(attestor, "/attestors/", error.InvalidAdmissionRule);
    } else if (rule.attestors.len != 0) return error.InvalidAdmissionRule;
}

fn validateNamedRules(rules: []const NamedRule) BuildError!void {
    for (rules, 0..) |item, index| {
        if (item.selector.len == 0 or item.selector.len > 256 or std.mem.indexOfScalar(u8, item.selector, ' ') != null) return error.InvalidAdmissionRule;
        for (rules[index + 1 ..]) |other| if (std.mem.eql(u8, item.selector, other.selector)) return error.DuplicateItem;
        try validateAdmissionRule(item.rule);
    }
}

fn validatePublicKeys(keys: []const AttestorPublicKey) BuildError!void {
    for (keys, 0..) |key, index| {
        if (key.comment.len > 1024) return error.InvalidKey;
        for (keys[index + 1 ..]) |other| if (key.id.len != 0 and std.mem.eql(u8, key.id, other.id)) return error.DuplicateItem;
        switch (key.key) {
            .pgp => |armored| if (!std.mem.startsWith(u8, armored, "-----BEGIN PGP PUBLIC KEY BLOCK-----")) return error.InvalidKey,
            .pkix => |pkix| {
                if (!std.mem.startsWith(u8, pkix.public_key_pem, "-----BEGIN PUBLIC KEY-----") or
                    std.mem.indexOf(u8, pkix.public_key_pem, "PRIVATE KEY") != null) return error.InvalidKey;
                if (key.id.len != 0 and std.Uri.parse(key.id) catch null == null) return error.InvalidKey;
            },
        }
    }
}

fn admissionRuleValue(allocator: std.mem.Allocator, rule: AdmissionRule) BuildError!value.Value {
    const attestors = try allocator.alloc(value.Value, rule.attestors.len);
    defer allocator.free(attestors);
    for (rule.attestors, 0..) |attestor, index| attestors[index] = try outputValue(attestor);
    var owned_attestors = try ownedValue(allocator, .{ .list = attestors });
    defer owned_attestors.deinit(allocator);
    const fields = [_]value.Field{
        .{ .name = "attestors", .value = owned_attestors },
        .{ .name = "enforcement", .value = .{ .string = if (rule.enforcement == .block_and_audit) "ENFORCED_BLOCK_AND_AUDIT_LOG" else "DRYRUN_AUDIT_LOG_ONLY" } },
        .{ .name = "evaluation", .value = .{ .string = switch (rule.evaluation) {
            .always_allow => "ALWAYS_ALLOW",
            .require_attestation => "REQUIRE_ATTESTATION",
            .always_deny => "ALWAYS_DENY",
        } } },
    };
    return ownedValue(allocator, .{ .object = &fields });
}

fn namedRulesValue(allocator: std.mem.Allocator, rules: []const NamedRule) BuildError!value.Value {
    const fields = try allocator.alloc(value.Field, rules.len);
    defer allocator.free(fields);
    for (rules, 0..) |item, index| fields[index] = .{ .name = item.selector, .value = try admissionRuleValue(allocator, item.rule) };
    defer for (fields) |*field| field.value.deinit(allocator);
    return ownedValue(allocator, .{ .object = fields });
}

fn publicKeysValue(allocator: std.mem.Allocator, keys: []const AttestorPublicKey) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, keys.len);
    defer allocator.free(items);
    for (keys, 0..) |key, index| {
        var key_fields: [5]value.Field = undefined;
        var count: usize = 0;
        key_fields[count] = .{ .name = "comment", .value = .{ .string = key.comment } };
        count += 1;
        key_fields[count] = .{ .name = "id", .value = .{ .string = key.id } };
        count += 1;
        switch (key.key) {
            .pgp => |armored| {
                key_fields[count] = .{ .name = "key_type", .value = .{ .string = "pgp" } };
                count += 1;
                key_fields[count] = .{ .name = "public_key", .value = .{ .string = armored } };
                count += 1;
            },
            .pkix => |pkix| {
                key_fields[count] = .{ .name = "key_type", .value = .{ .string = "pkix" } };
                count += 1;
                key_fields[count] = .{ .name = "public_key", .value = .{ .string = pkix.public_key_pem } };
                count += 1;
                key_fields[count] = .{ .name = "signature_algorithm", .value = .{ .string = pkixAlgorithmWire(pkix.signature_algorithm) } };
                count += 1;
            },
        }
        items[index] = try ownedValue(allocator, .{ .object = key_fields[0..count] });
    }
    defer for (items) |*item| item.deinit(allocator);
    return ownedValue(allocator, .{ .list = items });
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
        .value => |known| if (!std.mem.startsWith(u8, known, "projects/") or known.len == "projects/".len or std.mem.indexOfScalarPos(u8, known, "projects/".len, '/') != null) return error.InvalidProject,
        .resource_ref => {},
        .unknown_reason => return error.OutputNotKnown,
    }
}

fn validateNote(selected: output.Output([]const u8, .public)) BuildError!void {
    return validateOutputContains(selected, "/notes/", error.InvalidNote);
}

fn validateOutputContains(selected: output.Output([]const u8, .public), needle: []const u8, failure: error{ InvalidAdmissionRule, InvalidAttestor, InvalidNote }) BuildError!void {
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

fn stringsValue(allocator: std.mem.Allocator, strings: []const []const u8) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, strings.len);
    defer allocator.free(items);
    for (strings, 0..) |item, index| items[index] = .{ .string = item };
    return ownedValue(allocator, .{ .list = items });
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
    for (items, 0..) |item, index| for (items[index + 1 ..]) |other| if (std.mem.eql(u8, item, other)) return error.DuplicateItem;
}

fn validImagePattern(pattern: []const u8) bool {
    return pattern.len > 2 and std.mem.indexOfScalar(u8, pattern, '/') != null and std.mem.indexOfScalar(u8, pattern, ' ') == null;
}

fn validMember(member: []const u8) bool {
    const prefixes = [_][]const u8{ "user:", "group:", "serviceAccount:", "domain:", "principal:", "principalSet:" };
    for (prefixes) |prefix| if (std.mem.startsWith(u8, member, prefix) and member.len > prefix.len) return true;
    return std.mem.eql(u8, member, "allAuthenticatedUsers") or std.mem.eql(u8, member, "allUsers");
}

fn pkixAlgorithmWire(algorithm: PkixAlgorithm) []const u8 {
    return switch (algorithm) {
        .rsa_pss_2048_sha256 => "RSA_PSS_2048_SHA256",
        .rsa_pss_3072_sha256 => "RSA_PSS_3072_SHA256",
        .rsa_pss_4096_sha256 => "RSA_PSS_4096_SHA256",
        .rsa_pkcs1_2048_sha256 => "RSA_SIGN_PKCS1_2048_SHA256",
        .rsa_pkcs1_3072_sha256 => "RSA_SIGN_PKCS1_3072_SHA256",
        .rsa_pkcs1_4096_sha256 => "RSA_SIGN_PKCS1_4096_SHA256",
        .ecdsa_p256_sha256 => "ECDSA_P256_SHA256",
        .ecdsa_p384_sha384 => "ECDSA_P384_SHA384",
    };
}
