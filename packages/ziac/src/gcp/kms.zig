const std = @import("std");
const config_mod = @import("config.zig");
const iam = @import("iam.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    InvalidName,
    InvalidLocation,
    InvalidRole,
    InvalidMember,
    InvalidCondition,
    OutputNotKnown,
    InvalidConfiguration,
};

pub const Purpose = enum {
    encrypt_decrypt,
    asymmetric_sign,
    asymmetric_decrypt,
    raw_encrypt_decrypt,
    mac,

    pub fn apiName(self: Purpose) []const u8 {
        return switch (self) {
            .encrypt_decrypt => "ENCRYPT_DECRYPT",
            .asymmetric_sign => "ASYMMETRIC_SIGN",
            .asymmetric_decrypt => "ASYMMETRIC_DECRYPT",
            .raw_encrypt_decrypt => "RAW_ENCRYPT_DECRYPT",
            .mac => "MAC",
        };
    }
};

pub const ProtectionLevel = enum {
    software,
    hsm,
    external,
    external_vpc,

    pub fn apiName(self: ProtectionLevel) []const u8 {
        return switch (self) {
            .software => "SOFTWARE",
            .hsm => "HSM",
            .external => "EXTERNAL",
            .external_vpc => "EXTERNAL_VPC",
        };
    }
};

pub const Algorithm = enum {
    google_symmetric_encryption,
    rsa_sign_pss_2048_sha256,
    rsa_sign_pkcs1_2048_sha256,
    rsa_decrypt_oaep_2048_sha256,
    ec_sign_p256_sha256,
    ec_sign_p384_sha384,
    hmac_sha256,
    hmac_sha512,
    aes_256_gcm,

    pub fn apiName(self: Algorithm) []const u8 {
        return switch (self) {
            .google_symmetric_encryption => "GOOGLE_SYMMETRIC_ENCRYPTION",
            .rsa_sign_pss_2048_sha256 => "RSA_SIGN_PSS_2048_SHA256",
            .rsa_sign_pkcs1_2048_sha256 => "RSA_SIGN_PKCS1_2048_SHA256",
            .rsa_decrypt_oaep_2048_sha256 => "RSA_DECRYPT_OAEP_2048_SHA256",
            .ec_sign_p256_sha256 => "EC_SIGN_P256_SHA256",
            .ec_sign_p384_sha384 => "EC_SIGN_P384_SHA384",
            .hmac_sha256 => "HMAC_SHA256",
            .hmac_sha512 => "HMAC_SHA512",
            .aes_256_gcm => "AES_256_GCM",
        };
    }
};

pub const VersionTemplate = struct {
    algorithm: Algorithm = .google_symmetric_encryption,
    protection_level: ProtectionLevel = .software,
};

pub const KeyRingArgs = struct { name: []const u8, location: []const u8 };

pub const KeyRing = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: KeyRingArgs) BuildError!KeyRing {
        try provider.validate();
        try validateName(args.name);
        try validateLocation(args.location);
        const fields = [_]value.Field{
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.kms.KeyRing.{s}", .{args.name});
        defer allocator.free(id);
        var node = try nodeAlloc(allocator, id, "gcp.kms.KeyRing", args.name, 2, &fields);
        node.lifecycle.retain_on_delete = true;
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
    }
    pub fn deinit(self: *KeyRing, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const CryptoKeyArgs = struct {
    name: []const u8,
    key_ring: output.Output([]const u8, .public),
    purpose: Purpose = .encrypt_decrypt,
    version_template: VersionTemplate = .{},
    rotation_period_seconds: ?u64 = 7_776_000,
    next_rotation_time: ?[]const u8 = null,
    destroy_scheduled_duration_seconds: u64 = 2_592_000,
    import_only: bool = false,
};

pub const CryptoKey = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: CryptoKeyArgs) BuildError!CryptoKey {
        try provider.validate();
        try validateName(args.name);
        try validateCryptoKeyArgs(args);
        const ring_value = try publicOutputValue(args.key_ring);
        const labels = try labelFieldsAlloc(allocator, provider);
        defer allocator.free(labels);
        var fields: [11]value.Field = undefined;
        var count: usize = 0;
        fields[count] = .{ .name = "algorithm", .value = .{ .string = args.version_template.algorithm.apiName() } };
        count += 1;
        fields[count] = .{ .name = "destroy_scheduled_duration_seconds", .value = .{ .integer = @intCast(args.destroy_scheduled_duration_seconds) } };
        count += 1;
        fields[count] = .{ .name = "import_only", .value = .{ .boolean = args.import_only } };
        count += 1;
        fields[count] = .{ .name = "key_ring", .value = ring_value };
        count += 1;
        fields[count] = .{ .name = "labels", .value = .{ .object = labels } };
        count += 1;
        fields[count] = .{ .name = "name", .value = .{ .string = args.name } };
        count += 1;
        if (args.next_rotation_time) |time| {
            fields[count] = .{ .name = "next_rotation_time", .value = .{ .string = time } };
            count += 1;
        }
        fields[count] = .{ .name = "project_id", .value = .{ .string = provider.project_id } };
        count += 1;
        fields[count] = .{ .name = "protection_level", .value = .{ .string = args.version_template.protection_level.apiName() } };
        count += 1;
        fields[count] = .{ .name = "purpose", .value = .{ .string = args.purpose.apiName() } };
        count += 1;
        if (args.rotation_period_seconds) |seconds| {
            fields[count] = .{ .name = "rotation_period_seconds", .value = .{ .integer = @intCast(seconds) } };
            count += 1;
        }
        const id = try std.fmt.allocPrint(allocator, "gcp.kms.CryptoKey.{s}", .{args.name});
        defer allocator.free(id);
        var node = try nodeAlloc(allocator, id, "gcp.kms.CryptoKey", args.name, 2, fields[0..count]);
        node.lifecycle.retain_on_delete = true;
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
    }
    pub fn deinit(self: *CryptoKey, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const VersionState = enum {
    enabled,
    disabled,
    pub fn apiName(self: VersionState) []const u8 {
        return if (self == .enabled) "ENABLED" else "DISABLED";
    }
};

pub const CryptoKeyVersionArgs = struct {
    name: []const u8,
    crypto_key: output.Output([]const u8, .public),
    state: VersionState = .enabled,
};

pub const CryptoKeyVersion = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    state: Outputs.State.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: CryptoKeyVersionArgs) BuildError!CryptoKeyVersion {
        try provider.validate();
        try validateName(args.name);
        const fields = [_]value.Field{
            .{ .name = "crypto_key", .value = try publicOutputValue(args.crypto_key) },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "state", .value = .{ .string = args.state.apiName() } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.kms.CryptoKeyVersion.{s}", .{args.name});
        defer allocator.free(id);
        var node = try nodeAlloc(allocator, id, "gcp.kms.CryptoKeyVersion", args.name, 1, &fields);
        node.lifecycle.retain_on_delete = true;
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .state = Outputs.State.fromResource(node.id) };
    }
    pub fn deinit(self: *CryptoKeyVersion, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const KeyRingIamMemberArgs = struct {
    name: []const u8,
    key_ring: output.Output([]const u8, .public),
    role: []const u8,
    member: []const u8,
    condition: ?iam.Condition = null,
};
pub const CryptoKeyIamMemberArgs = struct {
    name: []const u8,
    crypto_key: output.Output([]const u8, .public),
    role: []const u8,
    member: []const u8,
    condition: ?iam.Condition = null,
};

pub const KeyRingIamMember = IamMember("gcp.kms.KeyRingIamMember", KeyRingIamMemberArgs, "key_ring");
pub const CryptoKeyIamMember = IamMember("gcp.kms.CryptoKeyIamMember", CryptoKeyIamMemberArgs, "crypto_key");

fn IamMember(comptime type_name: []const u8, comptime Args: type, comptime target_field: []const u8) type {
    return struct {
        pub const Outputs = struct {
            pub const BindingId = output.Descriptor("binding_id", []const u8, .public);
        };
        node: resource.ResourceNode,
        binding_id: Outputs.BindingId.OutputType,

        pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: Args) BuildError!@This() {
            try provider.validate();
            try validateName(args.name);
            try validateIam(args.role, args.member, args.condition);
            const target = @field(args, target_field);
            const condition = args.condition orelse iam.Condition{ .title = "", .expression = "" };
            const fields = [_]value.Field{
                .{ .name = "condition_description", .value = .{ .string = condition.description } },
                .{ .name = "condition_expression", .value = .{ .string = condition.expression } },
                .{ .name = "condition_title", .value = .{ .string = condition.title } },
                .{ .name = "member", .value = .{ .string = args.member } },
                .{ .name = "name", .value = .{ .string = args.name } },
                .{ .name = "ownership_mode", .value = .{ .string = "member" } },
                .{ .name = "project_id", .value = .{ .string = provider.project_id } },
                .{ .name = "resource_name", .value = try publicOutputValue(target) },
                .{ .name = "role", .value = .{ .string = args.role } },
            };
            const id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_name, args.name });
            defer allocator.free(id);
            const node = try nodeAlloc(allocator, id, type_name, args.name, 1, &fields);
            return .{ .node = node, .binding_id = Outputs.BindingId.fromResource(node.id) };
        }
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.node.deinit(allocator);
            self.* = undefined;
        }
    };
}

fn validateCryptoKeyArgs(args: CryptoKeyArgs) BuildError!void {
    const rotation_supported = args.purpose == .encrypt_decrypt;
    if (!rotation_supported and (args.rotation_period_seconds != null or args.next_rotation_time != null)) return error.InvalidConfiguration;
    if (args.rotation_period_seconds) |seconds| if (seconds < 86_400 or seconds > 3_153_600_000) return error.InvalidConfiguration;
    if (args.next_rotation_time) |time| if (time.len < 20 or args.rotation_period_seconds == null) return error.InvalidConfiguration;
    if (args.destroy_scheduled_duration_seconds < 86_400 or args.destroy_scheduled_duration_seconds > 10_368_000) return error.InvalidConfiguration;
    const compatible = switch (args.purpose) {
        .encrypt_decrypt => args.version_template.algorithm == .google_symmetric_encryption,
        .asymmetric_sign => switch (args.version_template.algorithm) {
            .rsa_sign_pss_2048_sha256, .rsa_sign_pkcs1_2048_sha256, .ec_sign_p256_sha256, .ec_sign_p384_sha384 => true,
            else => false,
        },
        .asymmetric_decrypt => args.version_template.algorithm == .rsa_decrypt_oaep_2048_sha256,
        .raw_encrypt_decrypt => args.version_template.algorithm == .aes_256_gcm,
        .mac => args.version_template.algorithm == .hmac_sha256 or args.version_template.algorithm == .hmac_sha512,
    };
    if (!compatible) return error.InvalidConfiguration;
}

fn validateIam(role: []const u8, member: []const u8, condition: ?iam.Condition) BuildError!void {
    if (!std.mem.startsWith(u8, role, "roles/") or role.len <= 6) return error.InvalidRole;
    if (std.mem.indexOfScalar(u8, member, ':') == null or std.mem.eql(u8, member, "allUsers") or std.mem.eql(u8, member, "allAuthenticatedUsers")) return error.InvalidMember;
    if (condition) |entry| if (entry.title.len == 0 or entry.expression.len == 0) return error.InvalidCondition;
}

fn publicOutputValue(source: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (source) {
        .value => |known| .{ .string = known },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn labelFieldsAlloc(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig) BuildError![]value.Field {
    const fields = try allocator.alloc(value.Field, provider.labels.len);
    for (provider.labels, 0..) |label, index| fields[index] = .{ .name = label.key, .value = .{ .string = label.value } };
    return fields;
}

fn nodeAlloc(allocator: std.mem.Allocator, id: []const u8, type_name: []const u8, logical_id: []const u8, schema_version: u32, fields: []const value.Field) BuildError!resource.ResourceNode {
    return resource.ResourceNode.initOwned(allocator, .{ .id = id, .provider = .gcp, .type_name = type_name, .schema_version = schema_version, .logical_id = logical_id, .inputs = .{ .object = fields } }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}
fn validateName(name: []const u8) BuildError!void {
    if (name.len == 0 or name.len > 63 or !std.ascii.isAlphabetic(name[0])) return error.InvalidName;
    for (name) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_')) return error.InvalidName;
}
fn validateLocation(location: []const u8) BuildError!void {
    if (location.len == 0 or location.len > 63) return error.InvalidLocation;
    for (location) |byte| if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '-')) return error.InvalidLocation;
}
