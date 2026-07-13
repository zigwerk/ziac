const std = @import("std");
const config_mod = @import("config.zig");
const iam = @import("iam.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || resource.ResourceGraphError || std.mem.Allocator.Error || error{
    DuplicateField,
    InvalidBackupSchedule,
    InvalidDatabase,
    InvalidField,
    InvalidIamCondition,
    InvalidIndex,
    InvalidKmsKey,
    InvalidLocation,
    InvalidMember,
    InvalidRole,
    OutputNotKnown,
};

pub const DatabaseType = enum {
    firestore_native,
    datastore_mode,

    pub fn apiName(self: DatabaseType) []const u8 {
        return switch (self) {
            .firestore_native => "FIRESTORE_NATIVE",
            .datastore_mode => "DATASTORE_MODE",
        };
    }
};

pub const DatabaseEdition = enum {
    standard,
    enterprise,

    pub fn apiName(self: DatabaseEdition) []const u8 {
        return switch (self) {
            .standard => "STANDARD",
            .enterprise => "ENTERPRISE",
        };
    }
};

pub const ConcurrencyMode = enum {
    optimistic,
    pessimistic,
    optimistic_with_entity_groups,

    pub fn apiName(self: ConcurrencyMode) []const u8 {
        return switch (self) {
            .optimistic => "OPTIMISTIC",
            .pessimistic => "PESSIMISTIC",
            .optimistic_with_entity_groups => "OPTIMISTIC_WITH_ENTITY_GROUPS",
        };
    }
};

pub const RealtimeUpdatesMode = enum {
    enabled,
    disabled,

    pub fn apiName(self: RealtimeUpdatesMode) []const u8 {
        return switch (self) {
            .enabled => "REALTIME_UPDATES_MODE_ENABLED",
            .disabled => "REALTIME_UPDATES_MODE_DISABLED",
        };
    }
};

pub const DatabaseArgs = struct {
    database_id: []const u8,
    location: []const u8,
    database_type: DatabaseType = .firestore_native,
    edition: DatabaseEdition = .standard,
    concurrency_mode: ConcurrencyMode = .pessimistic,
    point_in_time_recovery: bool = false,
    delete_protection: bool = true,
    kms_key_name: []const u8 = "",
    realtime_updates_mode: RealtimeUpdatesMode = .enabled,
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const Database = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
        pub const Uid = output.Descriptor("uid", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    etag: Outputs.Etag.OutputType,
    uid: Outputs.Uid.OutputType,
    state: Outputs.State.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: DatabaseArgs) BuildError!Database {
        try provider.validate();
        try validateDatabaseId(args.database_id);
        try validateLocation(args.location);
        if (std.mem.eql(u8, args.database_id, "(default)") and args.edition != .standard) return error.InvalidDatabase;
        if (args.database_type == .datastore_mode and args.edition == .enterprise) return error.InvalidDatabase;
        if (args.database_type == .firestore_native and args.concurrency_mode == .optimistic_with_entity_groups) return error.InvalidDatabase;
        try validateKmsKey(args.kms_key_name);
        const fields = [_]value.Field{
            .{ .name = "concurrency_mode", .value = .{ .string = args.concurrency_mode.apiName() } },
            .{ .name = "database_id", .value = .{ .string = args.database_id } },
            .{ .name = "database_type", .value = .{ .string = args.database_type.apiName() } },
            .{ .name = "delete_protection", .value = .{ .boolean = args.delete_protection } },
            .{ .name = "edition", .value = .{ .string = args.edition.apiName() } },
            .{ .name = "kms_key_name", .value = .{ .string = args.kms_key_name } },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "point_in_time_recovery", .value = .{ .boolean = args.point_in_time_recovery } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "realtime_updates_mode", .value = .{ .string = args.realtime_updates_mode.apiName() } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.firestore.Database.{s}", .{args.database_id});
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.firestore.Database", args.database_id, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
            .operation_timeout_millis = 30 * 60 * 1000,
        });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .etag = Outputs.Etag.fromResource(node.id),
            .uid = Outputs.Uid.fromResource(node.id),
            .state = Outputs.State.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Database, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const QueryScope = enum {
    collection,
    collection_group,
    collection_recursive,

    pub fn apiName(self: QueryScope) []const u8 {
        return switch (self) {
            .collection => "COLLECTION",
            .collection_group => "COLLECTION_GROUP",
            .collection_recursive => "COLLECTION_RECURSIVE",
        };
    }
};

pub const ApiScope = enum {
    any_api,
    datastore_mode_api,
    mongodb_compatible_api,

    pub fn apiName(self: ApiScope) []const u8 {
        return switch (self) {
            .any_api => "ANY_API",
            .datastore_mode_api => "DATASTORE_MODE_API",
            .mongodb_compatible_api => "MONGODB_COMPATIBLE_API",
        };
    }
};

pub const IndexMode = union(enum) {
    ascending,
    descending,
    array_contains,
    vector: u16,
};

pub const IndexField = struct {
    field_path: []const u8,
    mode: IndexMode,
};

pub const IndexArgs = struct {
    name: []const u8 = "",
    database: output.Output([]const u8, .public),
    database_id: []const u8,
    collection_group: []const u8,
    query_scope: QueryScope = .collection,
    api_scope: ApiScope = .any_api,
    fields: []const IndexField,
    density: []const u8 = "",
    multikey: bool = false,
    retain_on_delete: bool = false,
};

pub const Index = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    state: Outputs.State.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: IndexArgs) BuildError!Index {
        try provider.validate();
        try validateDatabaseId(args.database_id);
        try validateSegment(args.collection_group, error.InvalidIndex);
        if (args.fields.len == 0 or args.fields.len > 100) return error.InvalidIndex;
        if (args.density.len > 0 and !std.mem.eql(u8, args.density, "SPARSE_ALL") and !std.mem.eql(u8, args.density, "SPARSE_ANY") and !std.mem.eql(u8, args.density, "DENSE")) return error.InvalidIndex;
        for (args.fields, 0..) |field, index| {
            try validateFieldPath(field.field_path, error.InvalidIndex);
            for (args.fields[index + 1 ..]) |other| if (std.mem.eql(u8, field.field_path, other.field_path)) return error.DuplicateField;
            switch (field.mode) {
                .vector => |dimension| if (dimension == 0 or dimension > 2048) return error.InvalidIndex,
                else => {},
            }
        }
        const logical_name = if (args.name.len > 0) args.name else try std.fmt.allocPrint(allocator, "{s}-index", .{args.collection_group});
        defer if (args.name.len == 0) allocator.free(logical_name);
        try validateLogicalName(logical_name, error.InvalidIndex);
        const fields_json = try indexFieldsJsonAlloc(allocator, args.fields);
        defer allocator.free(fields_json);
        const fields = [_]value.Field{
            .{ .name = "api_scope", .value = .{ .string = args.api_scope.apiName() } },
            .{ .name = "collection_group", .value = .{ .string = args.collection_group } },
            .{ .name = "database", .value = try outputValue(args.database) },
            .{ .name = "database_id", .value = .{ .string = args.database_id } },
            .{ .name = "density", .value = .{ .string = args.density } },
            .{ .name = "fields_json", .value = .{ .string = fields_json } },
            .{ .name = "multikey", .value = .{ .boolean = args.multikey } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "query_scope", .value = .{ .string = args.query_scope.apiName() } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.firestore.Index.{s}.{s}", .{ args.database_id, logical_name });
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.firestore.Index", logical_name, &fields, .{
            .retain_on_delete = args.retain_on_delete,
            .operation_timeout_millis = 30 * 60 * 1000,
        });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .state = Outputs.State.fromResource(node.id) };
    }

    pub fn deinit(self: *Index, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const FieldIndexMode = enum {
    ascending,
    descending,
    array_contains,

    fn apiName(self: FieldIndexMode) []const u8 {
        return switch (self) {
            .ascending => "ASCENDING",
            .descending => "DESCENDING",
            .array_contains => "CONTAINS",
        };
    }
};

pub const FieldArgs = struct {
    database: output.Output([]const u8, .public),
    database_id: []const u8,
    collection_group: []const u8,
    field_path: []const u8,
    ttl_enabled: bool = false,
    index_modes: []const FieldIndexMode = &.{},
    query_scope: QueryScope = .collection_group,
    revert_on_delete: bool = true,
};

pub const Field = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const TtlState = output.Descriptor("ttl_state", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    ttl_state: Outputs.TtlState.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: FieldArgs) BuildError!Field {
        try provider.validate();
        try validateDatabaseId(args.database_id);
        try validateSegment(args.collection_group, error.InvalidField);
        try validateFieldPath(args.field_path, error.InvalidField);
        for (args.index_modes, 0..) |mode, index| for (args.index_modes[index + 1 ..]) |other| if (mode == other) return error.DuplicateField;
        const modes_json = try fieldModesJsonAlloc(allocator, args.index_modes);
        defer allocator.free(modes_json);
        const fields = [_]value.Field{
            .{ .name = "collection_group", .value = .{ .string = args.collection_group } },
            .{ .name = "database", .value = try outputValue(args.database) },
            .{ .name = "database_id", .value = .{ .string = args.database_id } },
            .{ .name = "field_path", .value = .{ .string = args.field_path } },
            .{ .name = "index_modes_json", .value = .{ .string = modes_json } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "query_scope", .value = .{ .string = args.query_scope.apiName() } },
            .{ .name = "revert_on_delete", .value = .{ .boolean = args.revert_on_delete } },
            .{ .name = "ttl_enabled", .value = .{ .boolean = args.ttl_enabled } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.firestore.Field.{s}.{s}.{s}", .{ args.database_id, args.collection_group, args.field_path });
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.firestore.Field", args.field_path, &fields, .{ .operation_timeout_millis = 30 * 60 * 1000 });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .ttl_state = Outputs.TtlState.fromResource(node.id) };
    }

    pub fn deinit(self: *Field, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const DayOfWeek = enum {
    monday,
    tuesday,
    wednesday,
    thursday,
    friday,
    saturday,
    sunday,

    fn apiName(self: DayOfWeek) []const u8 {
        return switch (self) {
            .monday => "MONDAY",
            .tuesday => "TUESDAY",
            .wednesday => "WEDNESDAY",
            .thursday => "THURSDAY",
            .friday => "FRIDAY",
            .saturday => "SATURDAY",
            .sunday => "SUNDAY",
        };
    }
};

pub const BackupRecurrence = union(enum) {
    daily,
    weekly: DayOfWeek,
};

pub const BackupScheduleArgs = struct {
    name: []const u8,
    database: output.Output([]const u8, .public),
    database_id: []const u8,
    recurrence: BackupRecurrence,
    retention_seconds: u64,
    retain_on_delete: bool = false,
};

pub const BackupSchedule = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const CreateTime = output.Descriptor("create_time", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    create_time: Outputs.CreateTime.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: BackupScheduleArgs) BuildError!BackupSchedule {
        try provider.validate();
        try validateLogicalName(args.name, error.InvalidBackupSchedule);
        try validateDatabaseId(args.database_id);
        const maximum_retention = 14 * 7 * 24 * 60 * 60;
        if (args.retention_seconds == 0 or args.retention_seconds > maximum_retention or args.retention_seconds > std.math.maxInt(i64)) return error.InvalidBackupSchedule;
        const recurrence = switch (args.recurrence) {
            .daily => "DAILY",
            .weekly => "WEEKLY",
        };
        const day = switch (args.recurrence) {
            .daily => "",
            .weekly => |selected| selected.apiName(),
        };
        const fields = [_]value.Field{
            .{ .name = "database", .value = try outputValue(args.database) },
            .{ .name = "database_id", .value = .{ .string = args.database_id } },
            .{ .name = "day_of_week", .value = .{ .string = day } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "recurrence", .value = .{ .string = recurrence } },
            .{ .name = "retention_seconds", .value = .{ .integer = @intCast(args.retention_seconds) } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.firestore.BackupSchedule.{s}.{s}", .{ args.database_id, args.name });
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.firestore.BackupSchedule", args.name, &fields, .{ .retain_on_delete = args.retain_on_delete });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .create_time = Outputs.CreateTime.fromResource(node.id) };
    }

    pub fn deinit(self: *BackupSchedule, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const DatabaseIamMemberArgs = struct {
    name: []const u8,
    database: output.Output([]const u8, .public),
    database_id: []const u8,
    role: []const u8,
    member: []const u8,
    condition: ?iam.Condition = null,
};

pub const DatabaseIamMember = struct {
    pub const Outputs = struct {
        pub const BindingId = output.Descriptor("binding_id", []const u8, .public);
    };
    node: resource.ResourceNode,
    binding_id: Outputs.BindingId.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: DatabaseIamMemberArgs) BuildError!DatabaseIamMember {
        try provider.validate();
        try validateLogicalName(args.name, error.InvalidMember);
        try validateDatabaseId(args.database_id);
        try validateRole(args.role);
        try validateMember(args.member);
        try validateCondition(args.condition);
        const resource_name = try std.fmt.allocPrint(allocator, "projects/{s}/databases/{s}", .{ provider.project_id, args.database_id });
        defer allocator.free(resource_name);
        const condition_title = if (args.condition) |condition| condition.title else "";
        const condition_description = if (args.condition) |condition| condition.description else "";
        const condition_expression = if (args.condition) |condition| condition.expression else "";
        const fields = [_]value.Field{
            .{ .name = "condition_description", .value = .{ .string = condition_description } },
            .{ .name = "condition_expression", .value = .{ .string = condition_expression } },
            .{ .name = "condition_title", .value = .{ .string = condition_title } },
            .{ .name = "member", .value = .{ .string = args.member } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "ownership_mode", .value = .{ .string = "member" } },
            .{ .name = "resource_name", .value = .{ .string = resource_name } },
            .{ .name = "role", .value = .{ .string = args.role } },
            .{ .name = "target", .value = try outputValue(args.database) },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.firestore.DatabaseIamMember.{s}", .{args.name});
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.firestore.DatabaseIamMember", args.name, &fields, .{});
        return .{ .node = node, .binding_id = Outputs.BindingId.fromResource(node.id) };
    }

    pub fn deinit(self: *DatabaseIamMember, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn indexFieldsJsonAlloc(allocator: std.mem.Allocator, fields: []const IndexField) BuildError![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var array = std.json.Array.init(arena);
    for (fields) |field| {
        var item: std.json.ObjectMap = .empty;
        try item.put(arena, "fieldPath", .{ .string = field.field_path });
        switch (field.mode) {
            .ascending => try item.put(arena, "order", .{ .string = "ASCENDING" }),
            .descending => try item.put(arena, "order", .{ .string = "DESCENDING" }),
            .array_contains => try item.put(arena, "arrayConfig", .{ .string = "CONTAINS" }),
            .vector => |dimension| {
                var flat: std.json.ObjectMap = .empty;
                try flat.put(arena, "dimension", .{ .integer = dimension });
                var vector_config: std.json.ObjectMap = .empty;
                try vector_config.put(arena, "flat", .{ .object = flat });
                try item.put(arena, "vectorConfig", .{ .object = vector_config });
            },
        }
        try array.append(.{ .object = item });
    }
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .array = array }, .{}) catch error.OutOfMemory;
}

fn fieldModesJsonAlloc(allocator: std.mem.Allocator, modes: []const FieldIndexMode) BuildError![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var array = std.json.Array.init(arena);
    for (modes) |mode| try array.append(.{ .string = mode.apiName() });
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .array = array }, .{}) catch error.OutOfMemory;
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

fn outputValue(selected: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (selected) {
        .value => |known| .{ .string = known },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn validateDatabaseId(database_id: []const u8) BuildError!void {
    if (std.mem.eql(u8, database_id, "(default)")) return;
    if (database_id.len < 4 or database_id.len > 63 or !std.ascii.isLower(database_id[0]) or !std.ascii.isAlphanumeric(database_id[database_id.len - 1])) return error.InvalidDatabase;
    for (database_id) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return error.InvalidDatabase;
}

fn validateLocation(location: []const u8) BuildError!void {
    if (location.len == 0 or location.len > 128 or std.mem.indexOfAny(u8, location, "\x00\r\n /?") != null) return error.InvalidLocation;
}

fn validateKmsKey(key: []const u8) BuildError!void {
    if (key.len == 0) return;
    if (!std.mem.startsWith(u8, key, "projects/") or std.mem.indexOf(u8, key, "/locations/") == null or
        std.mem.indexOf(u8, key, "/keyRings/") == null or std.mem.indexOf(u8, key, "/cryptoKeys/") == null or
        std.mem.indexOfAny(u8, key, "\x00\r\n ?") != null) return error.InvalidKmsKey;
}

fn validateSegment(segment: []const u8, err: BuildError) BuildError!void {
    if (segment.len == 0 or segment.len > 1500 or std.mem.indexOfAny(u8, segment, "\x00\r\n/?") != null) return err;
}

fn validateFieldPath(path: []const u8, err: BuildError) BuildError!void {
    if (path.len == 0 or path.len > 1500 or std.mem.indexOfAny(u8, path, "\x00\r\n/") != null) return err;
    if (path[0] == '.' or path[path.len - 1] == '.' or std.mem.indexOf(u8, path, "..") != null) return err;
}

fn validateLogicalName(name: []const u8, err: BuildError) BuildError!void {
    if (name.len == 0 or name.len > 128 or !std.ascii.isLower(name[0]) or name[name.len - 1] == '-') return err;
    for (name) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return err;
}

fn validateRole(role: []const u8) BuildError!void {
    if ((!std.mem.startsWith(u8, role, "roles/") and !std.mem.startsWith(u8, role, "projects/") and !std.mem.startsWith(u8, role, "organizations/")) or
        (std.mem.indexOf(u8, role, "/roles/") == null and !std.mem.startsWith(u8, role, "roles/")) or
        std.mem.indexOfAny(u8, role, "\x00\r\n ") != null) return error.InvalidRole;
}

fn validateMember(member: []const u8) BuildError!void {
    if (std.mem.eql(u8, member, "allUsers") or std.mem.eql(u8, member, "allAuthenticatedUsers")) return;
    for ([_][]const u8{ "user:", "serviceAccount:", "group:", "domain:", "principal:", "principalSet:" }) |prefix| {
        if (std.mem.startsWith(u8, member, prefix) and member.len > prefix.len) return;
    }
    return error.InvalidMember;
}

fn validateCondition(condition: ?iam.Condition) BuildError!void {
    const present = condition orelse return;
    if (present.title.len == 0 or present.title.len > 100 or present.description.len > 256 or present.expression.len == 0 or present.expression.len > 2048 or
        std.mem.indexOfAny(u8, present.title, "\x00\r\n") != null or std.mem.indexOfAny(u8, present.expression, "\x00\r\n") != null) return error.InvalidIamCondition;
}
