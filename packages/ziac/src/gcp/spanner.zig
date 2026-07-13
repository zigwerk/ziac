const std = @import("std");
const config_mod = @import("config.zig");
const iam = @import("iam.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || resource.ResourceGraphError || std.mem.Allocator.Error || error{
    DuplicateLabel,
    InvalidBackup,
    InvalidBackupSchedule,
    InvalidCapacity,
    InvalidCondition,
    InvalidDatabase,
    InvalidDdl,
    InvalidInstance,
    InvalidKmsKey,
    InvalidMember,
    InvalidRole,
    OutputNotKnown,
};

pub const Label = struct { key: []const u8, value: []const u8 };

pub const Edition = enum {
    standard,
    enterprise,
    enterprise_plus,

    pub fn apiName(self: Edition) []const u8 {
        return switch (self) {
            .standard => "STANDARD",
            .enterprise => "ENTERPRISE",
            .enterprise_plus => "ENTERPRISE_PLUS",
        };
    }
};

pub const DefaultBackupSchedule = enum {
    automatic,
    none,

    pub fn apiName(self: DefaultBackupSchedule) []const u8 {
        return switch (self) {
            .automatic => "AUTOMATIC",
            .none => "NONE",
        };
    }
};

pub const Autoscaling = struct {
    min: u32,
    max: u32,
    high_priority_cpu_percent: u8 = 65,
    storage_percent: u8 = 90,
};

pub const Capacity = union(enum) {
    nodes: u32,
    processing_units: u32,
    autoscaling_nodes: Autoscaling,
    autoscaling_processing_units: Autoscaling,
};

pub const InstanceArgs = struct {
    instance_id: []const u8,
    config: []const u8,
    display_name: []const u8,
    edition: Edition = .standard,
    capacity: Capacity = .{ .processing_units = 100 },
    default_backup_schedule: DefaultBackupSchedule = .automatic,
    labels: []const Label = &.{},
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const Instance = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    state: Outputs.State.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: InstanceArgs) BuildError!Instance {
        try provider.validate();
        try validateId(args.instance_id, 2, 64, error.InvalidInstance);
        if (args.config.len == 0 or args.config.len > 128 or std.mem.indexOfAny(u8, args.config, "\x00\r\n ?") != null) return error.InvalidInstance;
        if (args.display_name.len < 4 or args.display_name.len > 30 or std.mem.indexOfAny(u8, args.display_name, "\x00\r\n") != null) return error.InvalidInstance;
        try validateCapacity(args.capacity, args.edition);
        const labels = try labelsAlloc(allocator, args.labels);
        defer allocator.free(labels);
        const capacity_mode, const capacity_min, const capacity_max, const cpu_target, const storage_target = capacityFields(args.capacity);
        const fields = [_]value.Field{
            .{ .name = "capacity_max", .value = .{ .integer = capacity_max } },
            .{ .name = "capacity_min", .value = .{ .integer = capacity_min } },
            .{ .name = "capacity_mode", .value = .{ .string = capacity_mode } },
            .{ .name = "config", .value = .{ .string = args.config } },
            .{ .name = "cpu_target", .value = .{ .integer = cpu_target } },
            .{ .name = "default_backup_schedule", .value = .{ .string = args.default_backup_schedule.apiName() } },
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "edition", .value = .{ .string = args.edition.apiName() } },
            .{ .name = "instance_id", .value = .{ .string = args.instance_id } },
            .{ .name = "labels", .value = .{ .string = labels } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "storage_target", .value = .{ .integer = storage_target } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.spanner.Instance.{s}", .{args.instance_id});
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.spanner.Instance", args.instance_id, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
            .operation_timeout_millis = 60 * 60 * 1000,
        });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .state = Outputs.State.fromResource(node.id) };
    }

    pub fn deinit(self: *Instance, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const Dialect = enum {
    google_standard_sql,
    postgresql,

    pub fn apiName(self: Dialect) []const u8 {
        return switch (self) {
            .google_standard_sql => "GOOGLE_STANDARD_SQL",
            .postgresql => "POSTGRESQL",
        };
    }
};

pub const DatabaseArgs = struct {
    database_id: []const u8,
    instance: output.Output([]const u8, .public),
    instance_id: []const u8,
    dialect: Dialect = .google_standard_sql,
    ddl: []const []const u8 = &.{},
    kms_key_name: []const u8 = "",
    version_retention_period: []const u8 = "1h",
    default_leader: []const u8 = "",
    drop_protection: bool = true,
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const Database = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    state: Outputs.State.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: DatabaseArgs) BuildError!Database {
        try provider.validate();
        try validateId(args.instance_id, 2, 64, error.InvalidInstance);
        try validateId(args.database_id, 2, 30, error.InvalidDatabase);
        try validateDdl(args.ddl);
        try validateKms(args.kms_key_name);
        if (!validRetention(args.version_retention_period) or std.mem.indexOfAny(u8, args.default_leader, "\x00\r\n ?/") != null) return error.InvalidDatabase;
        const ddl_json = std.json.Stringify.valueAlloc(allocator, args.ddl, .{}) catch return error.OutOfMemory;
        defer allocator.free(ddl_json);
        const fields = [_]value.Field{
            .{ .name = "database_id", .value = .{ .string = args.database_id } },
            .{ .name = "ddl_json", .value = .{ .string = ddl_json } },
            .{ .name = "default_leader", .value = .{ .string = args.default_leader } },
            .{ .name = "dialect", .value = .{ .string = args.dialect.apiName() } },
            .{ .name = "drop_protection", .value = .{ .boolean = args.drop_protection } },
            .{ .name = "instance", .value = try publicOutputValue(args.instance) },
            .{ .name = "instance_id", .value = .{ .string = args.instance_id } },
            .{ .name = "kms_key_name", .value = .{ .string = args.kms_key_name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "version_retention_period", .value = .{ .string = args.version_retention_period } },
        };
        const logical = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ args.instance_id, args.database_id });
        defer allocator.free(logical);
        const id = try std.fmt.allocPrint(allocator, "gcp.spanner.Database.{s}", .{logical});
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.spanner.Database", logical, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
            .operation_timeout_millis = 60 * 60 * 1000,
        });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .state = Outputs.State.fromResource(node.id) };
    }

    pub fn deinit(self: *Database, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const BackupArgs = struct {
    backup_id: []const u8,
    database: output.Output([]const u8, .public),
    instance_id: []const u8,
    database_id: []const u8,
    expire_time: []const u8,
    version_time: []const u8 = "",
    kms_key_name: []const u8 = "",
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const Backup = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
        pub const SizeBytes = output.Descriptor("size_bytes", i64, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    state: Outputs.State.OutputType,
    size_bytes: Outputs.SizeBytes.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: BackupArgs) BuildError!Backup {
        try provider.validate();
        try validateId(args.instance_id, 2, 64, error.InvalidInstance);
        try validateId(args.database_id, 2, 30, error.InvalidDatabase);
        try validateId(args.backup_id, 2, 60, error.InvalidBackup);
        if (!validTimestamp(args.expire_time) or (args.version_time.len > 0 and !validTimestamp(args.version_time))) return error.InvalidBackup;
        try validateKms(args.kms_key_name);
        const fields = [_]value.Field{
            .{ .name = "backup_id", .value = .{ .string = args.backup_id } },
            .{ .name = "database", .value = try publicOutputValue(args.database) },
            .{ .name = "database_id", .value = .{ .string = args.database_id } },
            .{ .name = "expire_time", .value = .{ .string = args.expire_time } },
            .{ .name = "instance_id", .value = .{ .string = args.instance_id } },
            .{ .name = "kms_key_name", .value = .{ .string = args.kms_key_name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "version_time", .value = .{ .string = args.version_time } },
        };
        const logical = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ args.instance_id, args.backup_id });
        defer allocator.free(logical);
        const id = try std.fmt.allocPrint(allocator, "gcp.spanner.Backup.{s}", .{logical});
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.spanner.Backup", logical, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
            .operation_timeout_millis = 60 * 60 * 1000,
        });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .state = Outputs.State.fromResource(node.id),
            .size_bytes = Outputs.SizeBytes.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Backup, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const BackupMode = enum { full, incremental };

pub const BackupScheduleArgs = struct {
    schedule_id: []const u8,
    database: output.Output([]const u8, .public),
    instance_id: []const u8,
    database_id: []const u8,
    cron: []const u8,
    retention_seconds: u32,
    mode: BackupMode = .full,
    kms_key_name: []const u8 = "",
    retain_on_delete: bool = true,
};

pub const BackupSchedule = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const UpdateTime = output.Descriptor("update_time", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    update_time: Outputs.UpdateTime.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: BackupScheduleArgs) BuildError!BackupSchedule {
        try provider.validate();
        try validateId(args.instance_id, 2, 64, error.InvalidInstance);
        try validateId(args.database_id, 2, 30, error.InvalidDatabase);
        try validateId(args.schedule_id, 2, 60, error.InvalidBackupSchedule);
        if (!validCron(args.cron) or args.retention_seconds < 6 * 60 * 60 or args.retention_seconds > 366 * 24 * 60 * 60) return error.InvalidBackupSchedule;
        try validateKms(args.kms_key_name);
        const fields = [_]value.Field{
            .{ .name = "cron", .value = .{ .string = args.cron } },
            .{ .name = "database", .value = try publicOutputValue(args.database) },
            .{ .name = "database_id", .value = .{ .string = args.database_id } },
            .{ .name = "instance_id", .value = .{ .string = args.instance_id } },
            .{ .name = "kms_key_name", .value = .{ .string = args.kms_key_name } },
            .{ .name = "mode", .value = .{ .string = @tagName(args.mode) } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "retention_seconds", .value = .{ .integer = args.retention_seconds } },
            .{ .name = "schedule_id", .value = .{ .string = args.schedule_id } },
        };
        const logical = try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ args.instance_id, args.database_id, args.schedule_id });
        defer allocator.free(logical);
        const id = try std.fmt.allocPrint(allocator, "gcp.spanner.BackupSchedule.{s}", .{logical});
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.spanner.BackupSchedule", logical, &fields, .{ .retain_on_delete = args.retain_on_delete });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .update_time = Outputs.UpdateTime.fromResource(node.id) };
    }

    pub fn deinit(self: *BackupSchedule, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const IamMemberArgs = struct {
    name: []const u8,
    target: output.Output([]const u8, .public),
    instance_id: []const u8,
    database_id: []const u8 = "",
    role: []const u8,
    member: []const u8,
    condition: ?iam.Condition = null,
};

pub const InstanceIamMemberArgs = struct {
    name: []const u8,
    instance: output.Output([]const u8, .public),
    instance_id: []const u8,
    role: []const u8,
    member: []const u8,
    condition: ?iam.Condition = null,
};

pub const DatabaseIamMemberArgs = struct {
    name: []const u8,
    database: output.Output([]const u8, .public),
    instance_id: []const u8,
    database_id: []const u8,
    role: []const u8,
    member: []const u8,
    condition: ?iam.Condition = null,
};

pub const InstanceIamMember = iamMemberType("gcp.spanner.InstanceIamMember", false);
pub const DatabaseIamMember = iamMemberType("gcp.spanner.DatabaseIamMember", true);

fn iamMemberType(comptime type_name: []const u8, comptime database_scope: bool) type {
    return struct {
        pub const Outputs = struct {
            pub const BindingId = output.Descriptor("binding_id", []const u8, .public);
        };
        node: resource.ResourceNode,
        binding_id: Outputs.BindingId.OutputType,

        pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: if (database_scope) DatabaseIamMemberArgs else InstanceIamMemberArgs) BuildError!@This() {
            try provider.validate();
            try validateId(args.instance_id, 2, 64, error.InvalidInstance);
            if (database_scope) try validateId(args.database_id, 2, 30, error.InvalidDatabase);
            try validateId(args.name, 2, 128, error.InvalidMember);
            try validateRole(args.role);
            try validateMember(args.member);
            try validateCondition(args.condition);
            const condition_title = if (args.condition) |condition| condition.title else "";
            const condition_description = if (args.condition) |condition| condition.description else "";
            const condition_expression = if (args.condition) |condition| condition.expression else "";
            const target = if (database_scope) args.database else args.instance;
            const fields = [_]value.Field{
                .{ .name = "condition_description", .value = .{ .string = condition_description } },
                .{ .name = "condition_expression", .value = .{ .string = condition_expression } },
                .{ .name = "condition_title", .value = .{ .string = condition_title } },
                .{ .name = "database_id", .value = .{ .string = if (database_scope) args.database_id else "" } },
                .{ .name = "instance_id", .value = .{ .string = args.instance_id } },
                .{ .name = "member", .value = .{ .string = args.member } },
                .{ .name = "name", .value = .{ .string = args.name } },
                .{ .name = "ownership_mode", .value = .{ .string = "member" } },
                .{ .name = "project_id", .value = .{ .string = provider.project_id } },
                .{ .name = "role", .value = .{ .string = args.role } },
                .{ .name = "resource_name", .value = try publicOutputValue(target) },
            };
            const id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_name, args.name });
            defer allocator.free(id);
            const node = try nodeOwned(allocator, id, type_name, args.name, &fields, .{});
            return .{ .node = node, .binding_id = Outputs.BindingId.fromResource(node.id) };
        }

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.node.deinit(allocator);
            self.* = undefined;
        }
    };
}

fn capacityFields(capacity: Capacity) struct { []const u8, i64, i64, i64, i64 } {
    return switch (capacity) {
        .nodes => |count| .{ "nodes", count, count, 0, 0 },
        .processing_units => |count| .{ "processing_units", count, count, 0, 0 },
        .autoscaling_nodes => |policy| .{ "autoscaling_nodes", policy.min, policy.max, policy.high_priority_cpu_percent, policy.storage_percent },
        .autoscaling_processing_units => |policy| .{ "autoscaling_processing_units", policy.min, policy.max, policy.high_priority_cpu_percent, policy.storage_percent },
    };
}

fn validateCapacity(capacity: Capacity, edition: Edition) BuildError!void {
    switch (capacity) {
        .nodes => |count| if (count == 0) return error.InvalidCapacity,
        .processing_units => |count| if (count == 0 or (count < 1_000 and count % 100 != 0) or (count >= 1_000 and count % 1_000 != 0)) return error.InvalidCapacity,
        .autoscaling_nodes => |policy| {
            if (edition == .standard or policy.min == 0 or policy.max < policy.min) return error.InvalidCapacity;
            try validateTargets(policy);
        },
        .autoscaling_processing_units => |policy| {
            if (edition == .standard or policy.min == 0 or policy.min % 1_000 != 0 or policy.max < policy.min or policy.max % 1_000 != 0) return error.InvalidCapacity;
            try validateTargets(policy);
        },
    }
}

fn validateTargets(policy: Autoscaling) BuildError!void {
    if (policy.high_priority_cpu_percent < 10 or policy.high_priority_cpu_percent > 90 or policy.storage_percent < 10 or policy.storage_percent > 99) return error.InvalidCapacity;
}

fn labelsAlloc(allocator: std.mem.Allocator, labels: []const Label) BuildError![]const u8 {
    const sorted = try allocator.dupe(Label, labels);
    defer allocator.free(sorted);
    std.mem.sort(Label, sorted, {}, struct {
        fn lessThan(_: void, left: Label, right: Label) bool {
            return std.mem.order(u8, left.key, right.key) == .lt;
        }
    }.lessThan);
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    for (sorted, 0..) |label, index| {
        if (!validLabel(label.key) or !validLabelValue(label.value)) return error.InvalidInstance;
        if (index > 0 and std.mem.eql(u8, sorted[index - 1].key, label.key)) return error.DuplicateLabel;
        if (index > 0) try result.append(allocator, '\n');
        try result.appendSlice(allocator, label.key);
        try result.append(allocator, '=');
        try result.appendSlice(allocator, label.value);
    }
    return result.toOwnedSlice(allocator);
}

fn validateDdl(statements: []const []const u8) BuildError!void {
    for (statements) |statement| {
        const trimmed = std.mem.trim(u8, statement, " \t\r\n");
        if (trimmed.len == 0 or trimmed.len > 64 * 1024 or std.mem.indexOfScalar(u8, trimmed, '\x00') != null) return error.InvalidDdl;
        if (std.ascii.startsWithIgnoreCase(trimmed, "DROP DATABASE")) return error.InvalidDdl;
    }
}

fn validateId(id: []const u8, min: usize, max: usize, err: BuildError) BuildError!void {
    if (id.len < min or id.len > max or !std.ascii.isLower(id[0]) or !std.ascii.isAlphanumeric(id[id.len - 1])) return err;
    for (id) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return err;
}

fn validateKms(name: []const u8) BuildError!void {
    if (name.len == 0) return;
    if (!std.mem.startsWith(u8, name, "projects/") or std.mem.indexOf(u8, name, "/locations/") == null or std.mem.indexOf(u8, name, "/keyRings/") == null or std.mem.indexOf(u8, name, "/cryptoKeys/") == null or std.mem.indexOfAny(u8, name, "\x00\r\n ?") != null) return error.InvalidKmsKey;
}

fn validTimestamp(text: []const u8) bool {
    return text.len >= 20 and text.len <= 40 and text[4] == '-' and text[7] == '-' and text[10] == 'T' and text[text.len - 1] == 'Z' and std.mem.indexOfAny(u8, text, "\x00\r\n ") == null;
}

fn validRetention(text: []const u8) bool {
    if (text.len < 2 or text.len > 16) return false;
    for (text[0 .. text.len - 1]) |character| if (!std.ascii.isDigit(character)) return false;
    return switch (text[text.len - 1]) {
        'h', 'd' => true,
        else => false,
    };
}

fn validCron(text: []const u8) bool {
    if (text.len < 9 or text.len > 128 or std.mem.indexOfAny(u8, text, "\x00\r\n") != null) return false;
    var fields: usize = 0;
    var iterator = std.mem.tokenizeScalar(u8, text, ' ');
    while (iterator.next()) |_| fields += 1;
    return fields == 5;
}

fn validLabel(key: []const u8) bool {
    if (key.len == 0 or key.len > 63 or !std.ascii.isLower(key[0])) return false;
    for (key) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '_' and character != '-') return false;
    return true;
}

fn validLabelValue(text: []const u8) bool {
    if (text.len > 63) return false;
    for (text) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '_' and character != '-') return false;
    return true;
}

fn validateRole(role: []const u8) BuildError!void {
    if ((!std.mem.startsWith(u8, role, "roles/") and std.mem.indexOf(u8, role, "/roles/") == null) or std.mem.indexOfAny(u8, role, "\x00\r\n ") != null) return error.InvalidRole;
}

fn validateMember(member: []const u8) BuildError!void {
    if (std.mem.eql(u8, member, "allUsers") or std.mem.eql(u8, member, "allAuthenticatedUsers")) return;
    for ([_][]const u8{ "user:", "serviceAccount:", "group:", "domain:", "principal:", "principalSet:" }) |prefix| if (std.mem.startsWith(u8, member, prefix) and member.len > prefix.len) return;
    return error.InvalidMember;
}

fn validateCondition(condition: ?iam.Condition) BuildError!void {
    const present = condition orelse return;
    if (present.title.len == 0 or present.expression.len == 0 or std.mem.indexOfAny(u8, present.title, "\x00\r\n") != null or std.mem.indexOfAny(u8, present.expression, "\x00\r\n") != null) return error.InvalidCondition;
}

fn publicOutputValue(candidate: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (candidate) {
        .value => |text| .{ .string = text },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
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
