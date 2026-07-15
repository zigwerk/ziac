const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    DuplicateKey,
    DuplicateValue,
    InvalidGitRemote,
    InvalidIamMember,
    InvalidName,
    InvalidOutput,
    InvalidRegion,
    InvalidRole,
    InvalidSchedule,
    InvalidSecretVersion,
    InvalidServiceAccount,
};

pub const KeyValue = struct { key: []const u8, value: []const u8 };
pub const RemovalPolicy = enum { retain, delete };
pub const GitAuthentication = union(enum) {
    token_secret_version: []const u8,
    ssh: struct { private_key_secret_version: []const u8, host_public_key: []const u8 },
};
pub const GitRemote = struct {
    url: []const u8,
    default_branch: []const u8 = "main",
    authentication: GitAuthentication,
};

pub const RepositoryArgs = struct {
    name: []const u8,
    location: []const u8,
    display_name: []const u8 = "",
    service_account: ?[]const u8 = null,
    kms_key_name: ?output.Output([]const u8, .public) = null,
    git_remote: ?GitRemote = null,
    default_database: []const u8 = "",
    default_schema: []const u8 = "",
    default_location: []const u8 = "",
    assertion_schema: []const u8 = "",
    database_suffix: []const u8 = "",
    schema_suffix: []const u8 = "",
    table_prefix: []const u8 = "",
    labels: []const KeyValue = &.{},
    protect: bool = true,
    removal_policy: RemovalPolicy = .retain,
};

pub const Repository = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const DataformServiceAccount = output.Descriptor("dataform_service_account", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    dataform_service_account: Outputs.DataformServiceAccount.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: RepositoryArgs) BuildError!Repository {
        try provider.validate();
        try validateCommon(provider, args.name, args.location);
        if (args.service_account) |email| try validateServiceAccount(email);
        var git_remote = if (args.git_remote) |selected| try gitRemoteValue(allocator, selected) else try ownedValue(allocator, .{ .object = &.{} });
        defer git_remote.deinit(allocator);
        var labels = try mapValue(allocator, args.labels);
        defer labels.deinit(allocator);
        var overrides = try compilationConfigValue(allocator, .{
            .default_database = args.default_database,
            .default_schema = args.default_schema,
            .default_location = args.default_location,
            .assertion_schema = args.assertion_schema,
            .database_suffix = args.database_suffix,
            .schema_suffix = args.schema_suffix,
            .table_prefix = args.table_prefix,
        });
        defer overrides.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "git_remote", .value = git_remote },
            .{ .name = "kms_key_name", .value = try optionalOutputValue(args.kms_key_name) },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
            .{ .name = "service_account", .value = .{ .string = args.service_account orelse "" } },
            .{ .name = "workspace_compilation_overrides", .value = overrides },
        };
        const node = try nodeOwned(allocator, "gcp.dataform.Repository", args.location, args.name, null, &fields, .{ .protect = args.protect, .retain_on_delete = args.removal_policy == .retain });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .dataform_service_account = Outputs.DataformServiceAccount.fromResource(node.id) };
    }

    pub fn deinit(self: *Repository, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const WorkspaceArgs = struct { name: []const u8, repository: output.Output([]const u8, .public), protect: bool = false, removal_policy: RemovalPolicy = .delete };
pub const Workspace = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: WorkspaceArgs) BuildError!Workspace {
        try provider.validate();
        try validateName(args.name);
        try validateOutputContains(args.repository, "/repositories/");
        const identity = try repositoryIdentityAlloc(allocator, args.repository);
        defer allocator.free(identity.location);
        defer allocator.free(identity.repository);
        const fields = [_]value.Field{
            .{ .name = "location", .value = .{ .string = identity.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
            .{ .name = "repository", .value = try outputValue(args.repository) },
            .{ .name = "repository_name", .value = .{ .string = identity.repository } },
        };
        const node = try nodeOwned(allocator, "gcp.dataform.Workspace", identity.location, args.name, identity.repository, &fields, .{ .protect = args.protect, .retain_on_delete = args.removal_policy == .retain });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
    }
    pub fn deinit(self: *Workspace, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const CompilationConfig = struct {
    default_database: []const u8 = "",
    default_schema: []const u8 = "",
    default_location: []const u8 = "",
    assertion_schema: []const u8 = "",
    database_suffix: []const u8 = "",
    schema_suffix: []const u8 = "",
    table_prefix: []const u8 = "",
    vars: []const KeyValue = &.{},
};

pub const ReleaseConfigArgs = struct {
    name: []const u8,
    repository: output.Output([]const u8, .public),
    git_commitish: []const u8,
    cron_schedule: []const u8 = "",
    time_zone: []const u8 = "",
    disabled: bool = false,
    default_database: []const u8 = "",
    default_schema: []const u8 = "",
    default_location: []const u8 = "",
    assertion_schema: []const u8 = "",
    database_suffix: []const u8 = "",
    schema_suffix: []const u8 = "",
    table_prefix: []const u8 = "",
    vars: []const KeyValue = &.{},
    protect: bool = true,
    removal_policy: RemovalPolicy = .retain,
};

pub const ReleaseConfig = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const CompilationResult = output.Descriptor("release_compilation_result", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    release_compilation_result: Outputs.CompilationResult.OutputType,
    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ReleaseConfigArgs) BuildError!ReleaseConfig {
        try provider.validate();
        try validateName(args.name);
        try validateOutputContains(args.repository, "/repositories/");
        if (args.git_commitish.len == 0 or args.git_commitish.len > 255) return error.InvalidName;
        try validateSchedulePair(args.cron_schedule, args.time_zone);
        const identity = try repositoryIdentityAlloc(allocator, args.repository);
        defer allocator.free(identity.location);
        defer allocator.free(identity.repository);
        var compilation = try compilationConfigValue(allocator, .{
            .default_database = args.default_database,
            .default_schema = args.default_schema,
            .default_location = args.default_location,
            .assertion_schema = args.assertion_schema,
            .database_suffix = args.database_suffix,
            .schema_suffix = args.schema_suffix,
            .table_prefix = args.table_prefix,
            .vars = args.vars,
        });
        defer compilation.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "code_compilation_config", .value = compilation },
            .{ .name = "cron_schedule", .value = .{ .string = args.cron_schedule } },
            .{ .name = "disabled", .value = .{ .boolean = args.disabled } },
            .{ .name = "git_commitish", .value = .{ .string = args.git_commitish } },
            .{ .name = "location", .value = .{ .string = identity.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
            .{ .name = "repository", .value = try outputValue(args.repository) },
            .{ .name = "repository_name", .value = .{ .string = identity.repository } },
            .{ .name = "time_zone", .value = .{ .string = args.time_zone } },
        };
        const node = try nodeOwned(allocator, "gcp.dataform.ReleaseConfig", identity.location, args.name, identity.repository, &fields, .{ .protect = args.protect, .retain_on_delete = args.removal_policy == .retain });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .release_compilation_result = Outputs.CompilationResult.fromResource(node.id) };
    }
    pub fn deinit(self: *ReleaseConfig, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const WorkflowConfigArgs = struct {
    name: []const u8,
    repository: output.Output([]const u8, .public),
    release_config: output.Output([]const u8, .public),
    cron_schedule: []const u8 = "",
    time_zone: []const u8 = "",
    disabled: bool = false,
    included_tags: []const []const u8 = &.{},
    included_targets: []const []const u8 = &.{},
    transitive_dependencies_included: bool = false,
    transitive_dependents_included: bool = false,
    fully_refresh_incremental_tables_enabled: bool = false,
    service_account: ?[]const u8 = null,
    protect: bool = true,
    removal_policy: RemovalPolicy = .retain,
};

pub const WorkflowConfig = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: WorkflowConfigArgs) BuildError!WorkflowConfig {
        try provider.validate();
        try validateName(args.name);
        try validateOutputContains(args.repository, "/repositories/");
        try validateOutputContains(args.release_config, "/releaseConfigs/");
        try validateSchedulePair(args.cron_schedule, args.time_zone);
        if (args.service_account) |email| try validateServiceAccount(email);
        try validateUnique(args.included_tags);
        try validateUnique(args.included_targets);
        const identity = try repositoryIdentityAlloc(allocator, args.repository);
        defer allocator.free(identity.location);
        defer allocator.free(identity.repository);
        var tags = try stringsValue(allocator, args.included_tags);
        defer tags.deinit(allocator);
        var targets = try stringsValue(allocator, args.included_targets);
        defer targets.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "cron_schedule", .value = .{ .string = args.cron_schedule } },
            .{ .name = "disabled", .value = .{ .boolean = args.disabled } },
            .{ .name = "fully_refresh_incremental_tables_enabled", .value = .{ .boolean = args.fully_refresh_incremental_tables_enabled } },
            .{ .name = "included_tags", .value = tags },
            .{ .name = "included_targets", .value = targets },
            .{ .name = "location", .value = .{ .string = identity.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "release_config", .value = try outputValue(args.release_config) },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
            .{ .name = "repository", .value = try outputValue(args.repository) },
            .{ .name = "repository_name", .value = .{ .string = identity.repository } },
            .{ .name = "service_account", .value = .{ .string = args.service_account orelse "" } },
            .{ .name = "time_zone", .value = .{ .string = args.time_zone } },
            .{ .name = "transitive_dependencies_included", .value = .{ .boolean = args.transitive_dependencies_included } },
            .{ .name = "transitive_dependents_included", .value = .{ .boolean = args.transitive_dependents_included } },
        };
        const node = try nodeOwned(allocator, "gcp.dataform.WorkflowConfig", identity.location, args.name, identity.repository, &fields, .{ .protect = args.protect, .retain_on_delete = args.removal_policy == .retain });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
    }
    pub fn deinit(self: *WorkflowConfig, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const IamCondition = struct { title: []const u8, expression: []const u8, description: []const u8 = "" };
pub const IamMemberArgs = struct { name: []const u8, resource: output.Output([]const u8, .public), role: []const u8, member: []const u8, condition: ?IamCondition = null };
pub const RepositoryIamMember = iamMemberType("gcp.dataform.RepositoryIamMember", "/repositories/");
pub const WorkspaceIamMember = iamMemberType("gcp.dataform.WorkspaceIamMember", "/workspaces/");

fn iamMemberType(comptime type_name: []const u8, comptime segment: []const u8) type {
    return struct {
        node: resource.ResourceNode,
        pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: IamMemberArgs) BuildError!@This() {
            try provider.validate();
            try validateName(args.name);
            try validateOutputContains(args.resource, segment);
            if (!std.mem.startsWith(u8, args.role, "roles/") or std.mem.indexOfScalar(u8, args.role, ' ') != null) return error.InvalidRole;
            if (!validMember(args.member)) return error.InvalidIamMember;
            var condition = if (args.condition) |selected| try conditionValue(allocator, selected) else try ownedValue(allocator, .{ .object = &.{} });
            defer condition.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "condition", .value = condition },
                .{ .name = "has_condition", .value = .{ .boolean = args.condition != null } },
                .{ .name = "member", .value = .{ .string = args.member } },
                .{ .name = "resource", .value = try outputValue(args.resource) },
                .{ .name = "role", .value = .{ .string = args.role } },
            };
            return .{ .node = try nodeOwned(allocator, type_name, "global", args.name, null, &fields, .{}) };
        }
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.node.deinit(allocator);
            self.* = undefined;
        }
    };
}

const RepositoryIdentity = struct { location: []u8, repository: []u8 };
fn repositoryIdentityAlloc(allocator: std.mem.Allocator, selected: output.Output([]const u8, .public)) BuildError!RepositoryIdentity {
    const source = switch (selected) {
        .value => |text| text,
        .resource_ref => |reference| reference.resource_id,
        .unknown_reason => return error.InvalidOutput,
    };
    if (std.mem.startsWith(u8, source, "projects/")) {
        const location_marker = "/locations/";
        const repository_marker = "/repositories/";
        const location_start = (std.mem.indexOf(u8, source, location_marker) orelse return error.InvalidOutput) + location_marker.len;
        const repository_start = (std.mem.indexOfPos(u8, source, location_start, repository_marker) orelse return error.InvalidOutput) + repository_marker.len;
        return .{
            .location = try allocator.dupe(u8, source[location_start .. repository_start - repository_marker.len]),
            .repository = try allocator.dupe(u8, source[repository_start..]),
        };
    }
    const prefix = "gcp.dataform.Repository.";
    if (!std.mem.startsWith(u8, source, prefix)) return error.InvalidOutput;
    const rest = source[prefix.len..];
    const separator = std.mem.indexOfScalar(u8, rest, '.') orelse return error.InvalidOutput;
    return .{ .location = try allocator.dupe(u8, rest[0..separator]), .repository = try allocator.dupe(u8, rest[separator + 1 ..]) };
}

fn gitRemoteValue(allocator: std.mem.Allocator, remote: GitRemote) BuildError!value.Value {
    if (!(std.mem.startsWith(u8, remote.url, "https://") or std.mem.startsWith(u8, remote.url, "ssh://") or std.mem.startsWith(u8, remote.url, "git@")) or remote.default_branch.len == 0) return error.InvalidGitRemote;
    var authentication = switch (remote.authentication) {
        .token_secret_version => |secret| blk: {
            try validateSecretVersion(secret);
            const fields = [_]value.Field{
                .{ .name = "kind", .value = .{ .string = "token" } },
                .{ .name = "token_secret_version", .value = .{ .string = secret } },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
        .ssh => |ssh| blk: {
            try validateSecretVersion(ssh.private_key_secret_version);
            if (ssh.host_public_key.len == 0 or std.mem.indexOf(u8, ssh.host_public_key, "PRIVATE KEY") != null) return error.InvalidGitRemote;
            const fields = [_]value.Field{
                .{ .name = "host_public_key", .value = .{ .string = ssh.host_public_key } },
                .{ .name = "kind", .value = .{ .string = "ssh" } },
                .{ .name = "private_key_secret_version", .value = .{ .string = ssh.private_key_secret_version } },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
    };
    defer authentication.deinit(allocator);
    const fields = [_]value.Field{
        .{ .name = "authentication", .value = authentication },
        .{ .name = "default_branch", .value = .{ .string = remote.default_branch } },
        .{ .name = "url", .value = .{ .string = remote.url } },
    };
    return ownedValue(allocator, .{ .object = &fields });
}

fn compilationConfigValue(allocator: std.mem.Allocator, config: CompilationConfig) BuildError!value.Value {
    var vars = try mapValue(allocator, config.vars);
    defer vars.deinit(allocator);
    const fields = [_]value.Field{
        .{ .name = "assertion_schema", .value = .{ .string = config.assertion_schema } },
        .{ .name = "database_suffix", .value = .{ .string = config.database_suffix } },
        .{ .name = "default_database", .value = .{ .string = config.default_database } },
        .{ .name = "default_location", .value = .{ .string = config.default_location } },
        .{ .name = "default_schema", .value = .{ .string = config.default_schema } },
        .{ .name = "schema_suffix", .value = .{ .string = config.schema_suffix } },
        .{ .name = "table_prefix", .value = .{ .string = config.table_prefix } },
        .{ .name = "vars", .value = vars },
    };
    return ownedValue(allocator, .{ .object = &fields });
}

fn mapValue(allocator: std.mem.Allocator, items: []const KeyValue) BuildError!value.Value {
    const fields = try allocator.alloc(value.Field, items.len);
    defer allocator.free(fields);
    for (items, 0..) |item, index| {
        if (item.key.len == 0 or item.value.len > 4096) return error.InvalidName;
        for (items[0..index]) |prior| if (std.mem.eql(u8, prior.key, item.key)) return error.DuplicateKey;
        fields[index] = .{ .name = item.key, .value = .{ .string = item.value } };
    }
    std.mem.sort(value.Field, fields, {}, lessField);
    return ownedValue(allocator, .{ .object = fields });
}
fn stringsValue(allocator: std.mem.Allocator, items: []const []const u8) BuildError!value.Value {
    const values = try allocator.alloc(value.Value, items.len);
    defer allocator.free(values);
    for (items, 0..) |item, index| values[index] = .{ .string = item };
    return ownedValue(allocator, .{ .list = values });
}
fn conditionValue(allocator: std.mem.Allocator, condition: IamCondition) BuildError!value.Value {
    if (condition.title.len == 0 or condition.expression.len == 0) return error.InvalidIamMember;
    const fields = [_]value.Field{
        .{ .name = "description", .value = .{ .string = condition.description } },
        .{ .name = "expression", .value = .{ .string = condition.expression } },
        .{ .name = "title", .value = .{ .string = condition.title } },
    };
    return ownedValue(allocator, .{ .object = &fields });
}
fn optionalOutputValue(selected: ?output.Output([]const u8, .public)) BuildError!value.Value {
    return if (selected) |known| outputValue(known) else .{ .string = "" };
}
fn outputValue(selected: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (selected) {
        .value => |text| .{ .string = text },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.InvalidOutput,
    };
}
fn validateOutputContains(selected: output.Output([]const u8, .public), segment: []const u8) BuildError!void {
    switch (selected) {
        .value => |text| if (std.mem.indexOf(u8, text, segment) == null) return error.InvalidOutput,
        .resource_ref => {},
        .unknown_reason => return error.InvalidOutput,
    }
}
fn validateSecretVersion(secret: []const u8) BuildError!void {
    const marker = "/secrets/";
    const version = "/versions/";
    const marker_pos = std.mem.indexOf(u8, secret, marker) orelse return error.InvalidSecretVersion;
    const version_pos = std.mem.indexOfPos(u8, secret, marker_pos + marker.len, version) orelse return error.InvalidSecretVersion;
    if (!std.mem.startsWith(u8, secret, "projects/") or version_pos + version.len >= secret.len or std.mem.eql(u8, secret[version_pos + version.len ..], "latest")) return error.InvalidSecretVersion;
}
fn validateSchedulePair(cron: []const u8, time_zone: []const u8) BuildError!void {
    if ((cron.len == 0) != (time_zone.len == 0)) return error.InvalidSchedule;
    if (cron.len != 0 and (std.mem.count(u8, cron, " ") < 4 or std.mem.indexOfAny(u8, cron, "\r\n") != null)) return error.InvalidSchedule;
}
fn validateUnique(items: []const []const u8) BuildError!void {
    for (items, 0..) |item, index| {
        if (item.len == 0) return error.InvalidName;
        for (items[0..index]) |prior| if (std.mem.eql(u8, prior, item)) return error.DuplicateValue;
    }
}
fn validateCommon(provider: config_mod.ProviderConfig, name: []const u8, region: []const u8) BuildError!void {
    try validateName(name);
    if (region.len == 0) return error.InvalidRegion;
    if (provider.service_regions.len == 0) {
        if (!std.mem.eql(u8, provider.primary_region, region)) return error.InvalidRegion;
        return;
    }
    for (provider.service_regions) |allowed| if (std.mem.eql(u8, allowed, region)) return;
    return error.InvalidRegion;
}
fn validateName(name: []const u8) BuildError!void {
    if (name.len == 0 or name.len > 63 or !std.ascii.isLower(name[0]) or !std.ascii.isAlphanumeric(name[name.len - 1])) return error.InvalidName;
    for (name) |char| if (!(std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '-' or char == '_')) return error.InvalidName;
}
fn validateServiceAccount(email: []const u8) BuildError!void {
    if (!std.mem.endsWith(u8, email, ".iam.gserviceaccount.com") or std.mem.indexOfScalar(u8, email, '@') == null) return error.InvalidServiceAccount;
}
fn validMember(member: []const u8) bool {
    inline for (.{ "user:", "group:", "serviceAccount:", "domain:" }) |prefix| if (std.mem.startsWith(u8, member, prefix) and member.len > prefix.len) return true;
    return std.mem.eql(u8, member, "allUsers") or std.mem.eql(u8, member, "allAuthenticatedUsers");
}
fn lessField(_: void, left: value.Field, right: value.Field) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}
fn ownedValue(allocator: std.mem.Allocator, selected: value.Value) BuildError!value.Value {
    return value.Value.initOwned(allocator, selected) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
    };
}
fn nodeOwned(allocator: std.mem.Allocator, type_name: []const u8, scope: []const u8, logical: []const u8, parent: ?[]const u8, fields: []const value.Field, lifecycle: resource.Lifecycle) BuildError!resource.ResourceNode {
    const id = if (parent) |selected|
        try std.fmt.allocPrint(allocator, "{s}.{s}.{s}.{s}", .{ type_name, scope, selected, logical })
    else
        try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ type_name, scope, logical });
    defer allocator.free(id);
    return resource.ResourceNode.initOwned(allocator, .{ .id = id, .provider = .gcp, .type_name = type_name, .schema_version = 1, .logical_id = logical, .inputs = .{ .object = fields }, .lifecycle = lifecycle }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}
