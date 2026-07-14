const std = @import("std");
const config_mod = @import("config.zig");
const iam = @import("iam.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const validation = @import("validation.zig");
const value = @import("../value.zig");

pub const BuildError = validation.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    DuplicateValue,
    InvalidAnnotation,
    InvalidReplication,
    InvalidRotation,
    InvalidSecretReference,
    InvalidRole,
    InvalidMember,
    InvalidCondition,
    InvalidTopic,
    InvalidVersionAlias,
};

pub const Replica = struct {
    location: []const u8,
    kms_key_name: ?[]const u8 = null,
};

pub const Replication = union(enum) {
    automatic: ?[]const u8,
    user_managed: []const Replica,
};

pub const Rotation = struct {
    next_rotation_time: []const u8,
    period_seconds: u64,
};

pub const VersionAlias = struct { alias: []const u8, version: u64 };
pub const Annotation = struct { key: []const u8, value: []const u8 };

pub const SecretArgs = struct {
    name: []const u8,
    replication: Replication = .{ .automatic = null },
    topics: []const []const u8 = &.{},
    rotation: ?Rotation = null,
    version_aliases: []const VersionAlias = &.{},
    annotations: []const Annotation = &.{},
    retain_on_delete: bool = true,
};

pub const Secret = struct {
    pub const Outputs = struct {
        pub const ResourceName = output.Descriptor("resource_name", []const u8, .public);
        pub fn field(comptime name: []const u8) type {
            if (std.mem.eql(u8, name, "resource_name")) return ResourceName;
            @compileError("ZIAC120 unknown gcp.secret.Secret output field: " ++ name);
        }
    };
    node: resource.ResourceNode,
    resource_name: Outputs.ResourceName.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: SecretArgs) BuildError!Secret {
        try provider.validate();
        if (args.name.len == 0) return error.MissingName;
        try validateSecretArgs(args);
        const id = try std.fmt.allocPrint(allocator, "gcp.secret.Secret.{s}", .{args.name});
        defer allocator.free(id);
        const labels = try labelFieldsAlloc(allocator, provider);
        defer allocator.free(labels);
        const replicas_json = try replicasJsonAlloc(allocator, args.replication);
        defer if (replicas_json) |text| allocator.free(text);
        const topics = try stringsValueAlloc(allocator, args.topics);
        defer allocator.free(topics.list);
        const aliases = try aliasesFieldsAlloc(allocator, args.version_aliases);
        defer allocator.free(aliases);
        const annotations = try annotationFieldsAlloc(allocator, args.annotations);
        defer allocator.free(annotations);
        var fields: [13]value.Field = undefined;
        var count: usize = 0;
        fields[count] = .{ .name = "annotations", .value = .{ .object = annotations } };
        count += 1;
        switch (args.replication) {
            .automatic => |kms| if (kms) |name| {
                fields[count] = .{ .name = "automatic_kms_key_name", .value = .{ .string = name } };
                count += 1;
            },
            .user_managed => {},
        }
        fields[count] = .{ .name = "labels", .value = .{ .object = labels } };
        count += 1;
        fields[count] = .{ .name = "name", .value = .{ .string = args.name } };
        count += 1;
        fields[count] = .{ .name = "project_id", .value = .{ .string = provider.project_id } };
        count += 1;
        if (replicas_json) |text| {
            fields[count] = .{ .name = "replicas_json", .value = .{ .string = text } };
            count += 1;
        }
        fields[count] = .{ .name = "replication_mode", .value = .{ .string = @tagName(args.replication) } };
        count += 1;
        if (args.rotation) |rotation| {
            fields[count] = .{ .name = "next_rotation_time", .value = .{ .string = rotation.next_rotation_time } };
            count += 1;
            fields[count] = .{ .name = "rotation_period_seconds", .value = .{ .integer = @intCast(rotation.period_seconds) } };
            count += 1;
        }
        fields[count] = .{ .name = "topics", .value = topics };
        count += 1;
        fields[count] = .{ .name = "version_aliases", .value = .{ .object = aliases } };
        count += 1;
        var node = try nodeOwned(allocator, .{ .id = id, .provider = .gcp, .type_name = "gcp.secret.Secret", .schema_version = 2, .logical_id = args.name, .inputs = .{ .object = fields[0..count] } });
        node.lifecycle.retain_on_delete = args.retain_on_delete;
        return .{ .node = node, .resource_name = Outputs.ResourceName.fromResource(node.id) };
    }
    pub fn deinit(self: *Secret, allocator: std.mem.Allocator) void {
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
pub const RemovalPolicy = enum { retain, disable };

pub const SecretVersionArgs = struct {
    name: []const u8,
    secret_id: []const u8,
    source: value.SecretReference,
    source_dependencies: []const output.Output([]const u8, .public) = &.{},
    state: VersionState = .enabled,
    removal_policy: RemovalPolicy = .retain,
};

pub const SecretVersion = struct {
    pub const Outputs = struct {
        pub const Version = output.Descriptor("version", value.SecretReference, .secret);
        pub const State = output.Descriptor("state", []const u8, .public);
        pub fn field(comptime name: []const u8) type {
            if (std.mem.eql(u8, name, "version")) return Version;
            if (std.mem.eql(u8, name, "state")) return State;
            @compileError("ZIAC120 unknown gcp.secret.SecretVersion output field: " ++ name);
        }
    };
    node: resource.ResourceNode,
    version: Outputs.Version.OutputType,
    state: Outputs.State.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: SecretVersionArgs) BuildError!SecretVersion {
        try provider.validate();
        if (args.name.len == 0 or args.secret_id.len == 0) return error.MissingName;
        if (args.source.provider.len == 0 or args.source.resource.len == 0) return error.InvalidSecretReference;
        const id = try std.fmt.allocPrint(allocator, "gcp.secret.SecretVersion.{s}.{s}", .{ args.secret_id, args.name });
        defer allocator.free(id);
        const dependencies = try allocator.alloc(value.Value, args.source_dependencies.len);
        defer allocator.free(dependencies);
        for (args.source_dependencies, 0..) |dependency, index| dependencies[index] = switch (dependency) {
            .value => |known| .{ .string = known },
            .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
            .unknown_reason => return error.InvalidSecretReference,
        };
        var fields: [7]value.Field = undefined;
        var count: usize = 0;
        fields[count] = .{ .name = "name", .value = .{ .string = args.name } };
        count += 1;
        fields[count] = .{ .name = "project_id", .value = .{ .string = provider.project_id } };
        count += 1;
        fields[count] = .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } };
        count += 1;
        fields[count] = .{ .name = "secret_id", .value = .{ .string = args.secret_id } };
        count += 1;
        fields[count] = .{ .name = "source", .value = .{ .secret_ref = args.source } };
        count += 1;
        if (dependencies.len > 0) {
            fields[count] = .{ .name = "source_dependencies", .value = .{ .list = dependencies } };
            count += 1;
        }
        fields[count] = .{ .name = "state", .value = .{ .string = args.state.apiName() } };
        count += 1;
        var node = try nodeOwned(allocator, .{ .id = id, .provider = .gcp, .type_name = "gcp.secret.SecretVersion", .schema_version = 2, .logical_id = args.name, .inputs = .{ .object = fields[0..count] } });
        node.lifecycle.retain_on_delete = args.removal_policy == .retain;
        return .{ .node = node, .version = Outputs.Version.fromResource(node.id), .state = Outputs.State.fromResource(node.id) };
    }
    pub fn deinit(self: *SecretVersion, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const SecretIamMemberArgs = struct {
    name: []const u8,
    secret_id: []const u8,
    role: []const u8,
    member: []const u8,
    condition: ?iam.Condition = null,
};

pub const SecretIamMember = struct {
    pub const Outputs = struct {
        pub const BindingId = output.Descriptor("binding_id", []const u8, .public);
        pub fn field(comptime name: []const u8) type {
            if (std.mem.eql(u8, name, "binding_id")) return BindingId;
            @compileError("ZIAC120 unknown gcp.secret.SecretIamMember output field: " ++ name);
        }
    };
    node: resource.ResourceNode,
    binding_id: Outputs.BindingId.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: SecretIamMemberArgs) BuildError!SecretIamMember {
        try provider.validate();
        if (args.name.len == 0 or args.secret_id.len == 0) return error.MissingName;
        if (!std.mem.startsWith(u8, args.role, "roles/") or args.role.len <= 6) return error.InvalidRole;
        if (std.mem.indexOfScalar(u8, args.member, ':') == null or std.mem.eql(u8, args.member, "allUsers") or std.mem.eql(u8, args.member, "allAuthenticatedUsers")) return error.InvalidMember;
        if (args.condition) |condition| if (condition.title.len == 0 or condition.expression.len == 0) return error.InvalidCondition;
        const id = try std.fmt.allocPrint(allocator, "gcp.secret.SecretIamMember.{s}.{s}", .{ args.secret_id, args.name });
        defer allocator.free(id);
        const resource_name = try std.fmt.allocPrint(allocator, "projects/{s}/secrets/{s}", .{ provider.project_id, args.secret_id });
        defer allocator.free(resource_name);
        const condition = args.condition orelse iam.Condition{ .title = "", .expression = "" };
        const fields = [_]value.Field{
            .{ .name = "condition_description", .value = .{ .string = condition.description } },
            .{ .name = "condition_expression", .value = .{ .string = condition.expression } },
            .{ .name = "condition_title", .value = .{ .string = condition.title } },
            .{ .name = "member", .value = .{ .string = args.member } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "ownership_mode", .value = .{ .string = "member" } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "resource_name", .value = .{ .string = resource_name } },
            .{ .name = "role", .value = .{ .string = args.role } },
            .{ .name = "secret_id", .value = .{ .string = args.secret_id } },
        };
        const node = try nodeOwned(allocator, .{ .id = id, .provider = .gcp, .type_name = "gcp.secret.SecretIamMember", .schema_version = 2, .logical_id = args.name, .inputs = .{ .object = &fields } });
        return .{ .node = node, .binding_id = Outputs.BindingId.fromResource(node.id) };
    }
    pub fn deinit(self: *SecretIamMember, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn validateSecretArgs(args: SecretArgs) BuildError!void {
    switch (args.replication) {
        .automatic => |kms| if (kms) |name| if (!validKmsName(name) or !kmsLocationMatches(name, "global")) return error.InvalidReplication,
        .user_managed => |replicas| {
            if (replicas.len == 0) return error.InvalidReplication;
            for (replicas, 0..) |replica, index| {
                if (!validLocation(replica.location)) return error.InvalidReplication;
                if (replica.kms_key_name) |name| if (!validKmsName(name) or !kmsLocationMatches(name, replica.location)) return error.InvalidReplication;
                for (replicas[0..index]) |prior| if (std.mem.eql(u8, prior.location, replica.location)) return error.InvalidReplication;
            }
        },
    }
    if (args.topics.len > 10) return error.InvalidTopic;
    for (args.topics, 0..) |topic, index| {
        if (!std.mem.startsWith(u8, topic, "projects/") or std.mem.indexOf(u8, topic, "/topics/") == null) return error.InvalidTopic;
        for (args.topics[0..index]) |prior| if (std.mem.eql(u8, prior, topic)) return error.DuplicateValue;
    }
    if (args.rotation) |rotation| {
        if (args.topics.len == 0 or rotation.period_seconds < 3_600 or rotation.next_rotation_time.len < 20) return error.InvalidRotation;
    }
    if (args.version_aliases.len > 50) return error.InvalidVersionAlias;
    for (args.version_aliases, 0..) |alias, index| {
        if (alias.alias.len == 0 or alias.version == 0 or std.mem.eql(u8, alias.alias, "latest")) return error.InvalidVersionAlias;
        for (args.version_aliases[0..index]) |prior| if (std.mem.eql(u8, prior.alias, alias.alias)) return error.InvalidVersionAlias;
    }
    for (args.annotations, 0..) |annotation, index| {
        if (annotation.key.len == 0 or annotation.key.len > 63 or annotation.value.len > 16_384) return error.InvalidAnnotation;
        for (args.annotations[0..index]) |prior| if (std.mem.eql(u8, prior.key, annotation.key)) return error.InvalidAnnotation;
    }
}

fn replicasJsonAlloc(allocator: std.mem.Allocator, replication: Replication) BuildError!?[]u8 {
    const source = switch (replication) {
        .automatic => return null,
        .user_managed => |items| items,
    };
    const sorted = try allocator.dupe(Replica, source);
    defer allocator.free(sorted);
    std.mem.sort(Replica, sorted, {}, struct {
        fn less(_: void, a: Replica, b: Replica) bool {
            return std.mem.lessThan(u8, a.location, b.location);
        }
    }.less);
    var array: std.json.Array = .init(allocator);
    defer {
        for (array.items) |*item| switch (item.*) {
            .object => |*object| object.deinit(allocator),
            else => {},
        };
        array.deinit();
    }
    for (sorted, 0..) |replica, index| {
        _ = index;
        var object: std.json.ObjectMap = .empty;
        try object.put(allocator, "location", .{ .string = replica.location });
        if (replica.kms_key_name) |kms| try object.put(allocator, "kms_key_name", .{ .string = kms });
        try array.append(.{ .object = object });
    }
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .array = array }, .{}) catch error.OutOfMemory;
}

fn stringsValueAlloc(allocator: std.mem.Allocator, strings: []const []const u8) BuildError!value.Value {
    const sorted = try allocator.dupe([]const u8, strings);
    defer allocator.free(sorted);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    const result = try allocator.alloc(value.Value, sorted.len);
    for (sorted, 0..) |text, index| result[index] = .{ .string = text };
    return .{ .list = result };
}

fn aliasesFieldsAlloc(allocator: std.mem.Allocator, aliases: []const VersionAlias) BuildError![]value.Field {
    const sorted = try allocator.dupe(VersionAlias, aliases);
    defer allocator.free(sorted);
    std.mem.sort(VersionAlias, sorted, {}, struct {
        fn less(_: void, a: VersionAlias, b: VersionAlias) bool {
            return std.mem.lessThan(u8, a.alias, b.alias);
        }
    }.less);
    const fields = try allocator.alloc(value.Field, sorted.len);
    for (sorted, 0..) |entry, index| fields[index] = .{ .name = entry.alias, .value = .{ .integer = @intCast(entry.version) } };
    return fields;
}

fn annotationFieldsAlloc(allocator: std.mem.Allocator, annotations: []const Annotation) BuildError![]value.Field {
    const sorted = try allocator.dupe(Annotation, annotations);
    defer allocator.free(sorted);
    std.mem.sort(Annotation, sorted, {}, struct {
        fn less(_: void, a: Annotation, b: Annotation) bool {
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.less);
    const fields = try allocator.alloc(value.Field, sorted.len);
    for (sorted, 0..) |entry, index| fields[index] = .{ .name = entry.key, .value = .{ .string = entry.value } };
    return fields;
}

fn labelFieldsAlloc(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig) BuildError![]value.Field {
    const fields = try allocator.alloc(value.Field, provider.labels.len);
    for (provider.labels, 0..) |label, index| fields[index] = .{ .name = label.key, .value = .{ .string = label.value } };
    return fields;
}
fn validLocation(location: []const u8) bool {
    if (location.len == 0 or location.len > 63) return false;
    for (location) |byte| if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '-') return false;
    return true;
}
fn validKmsName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "projects/") and std.mem.indexOf(u8, name, "/cryptoKeys/") != null;
}
fn kmsLocationMatches(name: []const u8, location: []const u8) bool {
    const marker = "/locations/";
    const start = (std.mem.indexOf(u8, name, marker) orelse return false) + marker.len;
    const end_relative = std.mem.indexOfScalar(u8, name[start..], '/') orelse return false;
    return std.mem.eql(u8, name[start .. start + end_relative], location);
}
fn nodeOwned(allocator: std.mem.Allocator, node: resource.ResourceNode) BuildError!resource.ResourceNode {
    return resource.ResourceNode.initOwned(allocator, node) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}
