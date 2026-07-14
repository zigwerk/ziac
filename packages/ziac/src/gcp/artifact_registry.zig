const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");
const validation = @import("validation.zig");

pub const BuildError = validation.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    DuplicatePolicy,
    InvalidCleanupPolicy,
    InvalidFormat,
    InvalidKmsKey,
    InvalidValue,
    OutputNotKnown,
};

pub const Format = enum {
    docker,
    maven,
    npm,
    apt,
    yum,
    googet,
    python,
    kfp,
    go,
    generic,
    ruby,

    pub fn apiName(self: Format) []const u8 {
        return switch (self) {
            .docker => "DOCKER",
            .maven => "MAVEN",
            .npm => "NPM",
            .apt => "APT",
            .yum => "YUM",
            .googet => "GOOGET",
            .python => "PYTHON",
            .kfp => "KFP",
            .go => "GO",
            .generic => "GENERIC",
            .ruby => "RUBY",
        };
    }
};

pub const TagState = enum {
    tagged,
    untagged,
    any,

    pub fn apiName(self: TagState) []const u8 {
        return switch (self) {
            .tagged => "TAGGED",
            .untagged => "UNTAGGED",
            .any => "ANY",
        };
    }
};

pub const CleanupCondition = struct {
    tag_state: TagState = .any,
    older_than_seconds: ?u64 = null,
    newer_than_seconds: ?u64 = null,
    package_prefixes: []const []const u8 = &.{},
    version_prefixes: []const []const u8 = &.{},
    tag_prefixes: []const []const u8 = &.{},
};

pub const KeepMostRecent = struct {
    package_prefixes: []const []const u8 = &.{},
    count: u16,
};

pub const CleanupRule = union(enum) {
    delete_condition: CleanupCondition,
    keep_condition: CleanupCondition,
    keep_most_recent: KeepMostRecent,
};

pub const CleanupPolicy = struct {
    name: []const u8,
    rule: CleanupRule,
};

pub const VulnerabilityScanning = enum {
    inherited,
    disabled,

    pub fn apiName(self: VulnerabilityScanning) []const u8 {
        return if (self == .disabled) "DISABLED" else "INHERITED";
    }
};

pub const RepositoryArgs = struct {
    name: []const u8,
    location: ?[]const u8 = null,
    format: Format,
    description: []const u8 = "",
    kms_key_name: ?output.Output([]const u8, .public) = null,
    cleanup_policies: []const CleanupPolicy = &.{},
    cleanup_policy_dry_run: bool = true,
    vulnerability_scanning: VulnerabilityScanning = .inherited,
    protect: bool = true,
    retain_on_delete: bool = false,
};

pub const Repository = struct {
    pub const Outputs = struct {
        pub const RepositoryUrl = output.Descriptor("repository_url", []const u8, .public);
        pub const SizeBytes = output.Descriptor("size_bytes", i64, .public);
    };

    node: resource.ResourceNode,
    repository_url: Outputs.RepositoryUrl.OutputType,
    size_bytes: Outputs.SizeBytes.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: RepositoryArgs) BuildError!Repository {
        try provider.validate();
        if (args.name.len == 0) return error.MissingName;
        if (args.description.len > 1024) return error.InvalidValue;
        const location = args.location orelse provider.primary_region;
        if (location.len == 0) return error.MissingRegion;
        if (args.kms_key_name) |candidate| if (candidate == .value and !validKmsKey(candidate.value)) return error.InvalidKmsKey;

        const label_fields = try allocator.alloc(value.Field, provider.labels.len);
        defer allocator.free(label_fields);
        for (provider.labels, 0..) |label, index| label_fields[index] = .{ .name = label.key, .value = .{ .string = label.value } };
        var cleanup = try cleanupPoliciesValue(allocator, args.cleanup_policies);
        defer cleanup.deinit(allocator);
        const kms = if (args.kms_key_name) |candidate| try publicOutputValue(candidate) else value.Value{ .string = "" };
        const input_fields = [_]value.Field{
            .{ .name = "cleanup_policies", .value = cleanup },
            .{ .name = "cleanup_policy_dry_run", .value = .{ .boolean = args.cleanup_policy_dry_run } },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "format", .value = .{ .string = args.format.apiName() } },
            .{ .name = "kms_key_name", .value = kms },
            .{ .name = "labels", .value = .{ .object = label_fields } },
            .{ .name = "location", .value = .{ .string = location } },
            .{ .name = "mode", .value = .{ .string = "STANDARD_REPOSITORY" } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "vulnerability_scanning", .value = .{ .string = args.vulnerability_scanning.apiName() } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.artifact.Repository.{s}.{s}", .{ location, args.name });
        defer allocator.free(id);
        const node = resource.ResourceNode.initOwned(allocator, .{
            .id = id,
            .provider = .gcp,
            .type_name = "gcp.artifact.Repository",
            .schema_version = 2,
            .logical_id = args.name,
            .inputs = .{ .object = &input_fields },
            .lifecycle = .{ .protect = args.protect, .retain_on_delete = args.retain_on_delete },
        }) catch |err| switch (err) {
            error.DuplicateField => return error.DuplicateField,
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
        };
        return .{
            .node = node,
            .repository_url = Outputs.RepositoryUrl.fromResource(node.id),
            .size_bytes = Outputs.SizeBytes.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Repository, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const DockerRepositoryArgs = struct {
    name: []const u8,
    location: ?[]const u8 = null,
};

pub const DockerRepository = struct {
    pub const Outputs = struct {
        pub const RepositoryUrl = output.Descriptor("repository_url", []const u8, .public);

        pub fn field(comptime name: []const u8) type {
            if (std.mem.eql(u8, name, "repository_url")) return RepositoryUrl;
            @compileError("ZIAC120 unknown gcp.artifact.Repository output field: " ++ name);
        }
    };

    node: resource.ResourceNode,
    repository_url: Outputs.RepositoryUrl.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: DockerRepositoryArgs,
    ) BuildError!DockerRepository {
        try provider.validate();
        if (args.name.len == 0) return error.MissingName;
        const location = args.location orelse provider.primary_region;
        if (location.len == 0) return error.MissingRegion;

        const id = try std.fmt.allocPrint(allocator, "gcp.artifact.Repository.{s}.{s}", .{ location, args.name });
        defer allocator.free(id);
        const label_fields = try allocator.alloc(value.Field, provider.labels.len);
        defer allocator.free(label_fields);
        for (provider.labels, 0..) |label, index| {
            label_fields[index] = .{ .name = label.key, .value = .{ .string = label.value } };
        }
        const input_fields = [_]value.Field{
            .{ .name = "format", .value = .{ .string = "DOCKER" } },
            .{ .name = "labels", .value = .{ .object = label_fields } },
            .{ .name = "location", .value = .{ .string = location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        };
        const node = resource.ResourceNode.initOwned(allocator, .{
            .id = id,
            .provider = .gcp,
            .type_name = "gcp.artifact.Repository",
            .schema_version = 1,
            .logical_id = args.name,
            .inputs = .{ .object = input_fields[0..] },
        }) catch |err| switch (err) {
            error.DuplicateField => return error.DuplicateField,
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
        };
        errdefer {
            var mutable_node = node;
            mutable_node.deinit(allocator);
        }

        return .{
            .node = node,
            .repository_url = Outputs.RepositoryUrl.fromResource(node.id),
        };
    }

    pub fn deinit(self: *DockerRepository, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn cleanupPoliciesValue(allocator: std.mem.Allocator, policies: []const CleanupPolicy) BuildError!value.Value {
    for (policies, 0..) |policy, index| {
        if (policy.name.len == 0 or policy.name.len >= 128) return error.InvalidCleanupPolicy;
        for (policies[0..index]) |previous| if (std.mem.eql(u8, previous.name, policy.name)) return error.DuplicatePolicy;
    }
    const sorted = try allocator.dupe(CleanupPolicy, policies);
    defer allocator.free(sorted);
    std.mem.sort(CleanupPolicy, sorted, {}, cleanupPolicyLessThan);
    const values = try allocator.alloc(value.Value, policies.len);
    defer allocator.free(values);
    var initialized: usize = 0;
    defer for (values[0..initialized]) |*item| item.deinit(allocator);
    for (sorted, 0..) |policy, index| {
        var rule = try cleanupRuleValue(allocator, policy.rule);
        defer rule.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "name", .value = .{ .string = policy.name } },
            .{ .name = "rule", .value = rule },
        };
        values[index] = try value.Value.initOwned(allocator, .{ .object = &fields });
        initialized += 1;
    }
    return value.Value.initOwned(allocator, .{ .list = values });
}

fn cleanupPolicyLessThan(_: void, left: CleanupPolicy, right: CleanupPolicy) bool {
    return std.mem.order(u8, left.name, right.name) == .lt;
}

fn cleanupRuleValue(allocator: std.mem.Allocator, rule: CleanupRule) BuildError!value.Value {
    return switch (rule) {
        .delete_condition => |condition| conditionValue(allocator, "DELETE", condition),
        .keep_condition => |condition| conditionValue(allocator, "KEEP", condition),
        .keep_most_recent => |recent| blk: {
            if (recent.count == 0) return error.InvalidCleanupPolicy;
            var prefixes = try stringListValue(allocator, recent.package_prefixes);
            defer prefixes.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "action", .value = .{ .string = "KEEP" } },
                .{ .name = "count", .value = .{ .integer = recent.count } },
                .{ .name = "kind", .value = .{ .string = "most_recent" } },
                .{ .name = "package_prefixes", .value = prefixes },
            };
            break :blk try value.Value.initOwned(allocator, .{ .object = &fields });
        },
    };
}

fn conditionValue(allocator: std.mem.Allocator, action: []const u8, condition: CleanupCondition) BuildError!value.Value {
    if (condition.older_than_seconds == null and condition.newer_than_seconds == null and condition.package_prefixes.len == 0 and condition.version_prefixes.len == 0 and condition.tag_prefixes.len == 0 and condition.tag_state == .any) return error.InvalidCleanupPolicy;
    if (condition.older_than_seconds == 0 or condition.newer_than_seconds == 0) return error.InvalidCleanupPolicy;
    var packages = try stringListValue(allocator, condition.package_prefixes);
    defer packages.deinit(allocator);
    var versions = try stringListValue(allocator, condition.version_prefixes);
    defer versions.deinit(allocator);
    var tags = try stringListValue(allocator, condition.tag_prefixes);
    defer tags.deinit(allocator);
    const fields = [_]value.Field{
        .{ .name = "action", .value = .{ .string = action } },
        .{ .name = "kind", .value = .{ .string = "condition" } },
        .{ .name = "newer_than_seconds", .value = .{ .integer = @intCast(condition.newer_than_seconds orelse 0) } },
        .{ .name = "older_than_seconds", .value = .{ .integer = @intCast(condition.older_than_seconds orelse 0) } },
        .{ .name = "package_prefixes", .value = packages },
        .{ .name = "tag_prefixes", .value = tags },
        .{ .name = "tag_state", .value = .{ .string = condition.tag_state.apiName() } },
        .{ .name = "version_prefixes", .value = versions },
    };
    return value.Value.initOwned(allocator, .{ .object = &fields });
}

fn stringListValue(allocator: std.mem.Allocator, items: []const []const u8) BuildError!value.Value {
    const values = try allocator.alloc(value.Value, items.len);
    defer allocator.free(values);
    for (items, 0..) |item, index| {
        if (item.len == 0 or std.mem.indexOfAny(u8, item, "\x00\r\n") != null) return error.InvalidCleanupPolicy;
        values[index] = .{ .string = item };
    }
    return value.Value.initOwned(allocator, .{ .list = values });
}

fn publicOutputValue(candidate: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (candidate) {
        .value => |text| .{ .string = text },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn validKmsKey(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "projects/") and std.mem.indexOf(u8, name, "/locations/") != null and std.mem.indexOf(u8, name, "/keyRings/") != null and std.mem.indexOf(u8, name, "/cryptoKeys/") != null and std.mem.indexOfAny(u8, name, "?# \t\r\n") == null;
}
