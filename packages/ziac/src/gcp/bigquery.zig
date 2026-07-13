const std = @import("std");
const config_mod = @import("config.zig");
const iam = @import("iam.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || resource.ResourceGraphError || std.mem.Allocator.Error || error{
    ConflictingOutput,
    CredentialMaterialRejected,
    DuplicateField,
    DuplicateLabel,
    InvalidAssignment,
    InvalidCommitment,
    InvalidConnection,
    InvalidDataset,
    InvalidIamCondition,
    InvalidKmsKey,
    InvalidLocation,
    InvalidMember,
    InvalidReservation,
    InvalidRole,
    InvalidRoutine,
    InvalidSchema,
    InvalidTable,
    InvalidView,
    OutputNotKnown,
};

pub const DatasetArgs = struct {
    dataset_id: []const u8,
    location: []const u8,
    friendly_name: []const u8 = "",
    description: []const u8 = "",
    default_table_expiration_ms: u64 = 0,
    default_partition_expiration_ms: u64 = 0,
    default_kms_key_name: []const u8 = "",
    labels: []const config_mod.Label = &.{},
    delete_contents_on_destroy: bool = false,
    retain_on_delete: bool = true,
};

pub const Dataset = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
        pub const Location = output.Descriptor("location", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    etag: Outputs.Etag.OutputType,
    location: Outputs.Location.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: DatasetArgs) BuildError!Dataset {
        try provider.validate();
        try validateIdentifier(args.dataset_id, .dataset);
        try validateLocation(args.location);
        try validateText(args.friendly_name, 1024, error.InvalidDataset);
        try validateText(args.description, 16_384, error.InvalidDataset);
        try validateExpiration(args.default_table_expiration_ms);
        try validateExpiration(args.default_partition_expiration_ms);
        try validateKmsKey(provider.project_id, args.default_kms_key_name);
        const labels_json = try labelsJsonAlloc(allocator, args.labels);
        defer allocator.free(labels_json);
        const fields = [_]value.Field{
            .{ .name = "dataset_id", .value = .{ .string = args.dataset_id } },
            .{ .name = "default_kms_key_name", .value = .{ .string = args.default_kms_key_name } },
            .{ .name = "default_partition_expiration_ms", .value = .{ .integer = @intCast(args.default_partition_expiration_ms) } },
            .{ .name = "default_table_expiration_ms", .value = .{ .integer = @intCast(args.default_table_expiration_ms) } },
            .{ .name = "delete_contents_on_destroy", .value = .{ .boolean = args.delete_contents_on_destroy } },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "friendly_name", .value = .{ .string = args.friendly_name } },
            .{ .name = "labels_json", .value = .{ .string = labels_json } },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.bigquery.Dataset.{s}", .{args.dataset_id});
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.bigquery.Dataset", args.dataset_id, &fields, .{
            .retain_on_delete = args.retain_on_delete,
            .operation_timeout_millis = 10 * 60 * 1000,
        });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .etag = Outputs.Etag.fromResource(node.id),
            .location = Outputs.Location.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Dataset, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const FieldType = enum {
    string,
    bytes,
    integer,
    float,
    numeric,
    bignumeric,
    boolean,
    timestamp,
    date,
    time,
    datetime,
    geography,
    json,
    interval,
    record,

    pub fn apiName(self: FieldType) []const u8 {
        return switch (self) {
            .string => "STRING",
            .bytes => "BYTES",
            .integer => "INTEGER",
            .float => "FLOAT",
            .numeric => "NUMERIC",
            .bignumeric => "BIGNUMERIC",
            .boolean => "BOOLEAN",
            .timestamp => "TIMESTAMP",
            .date => "DATE",
            .time => "TIME",
            .datetime => "DATETIME",
            .geography => "GEOGRAPHY",
            .json => "JSON",
            .interval => "INTERVAL",
            .record => "RECORD",
        };
    }
};

pub const FieldMode = enum {
    nullable,
    required,
    repeated,

    pub fn apiName(self: FieldMode) []const u8 {
        return switch (self) {
            .nullable => "NULLABLE",
            .required => "REQUIRED",
            .repeated => "REPEATED",
        };
    }
};

pub const FieldSchema = struct {
    name: []const u8,
    field_type: FieldType,
    mode: FieldMode = .nullable,
    description: []const u8 = "",
    fields: []const FieldSchema = &.{},
};

pub const PartitionGranularity = enum {
    hour,
    day,
    month,
    year,

    pub fn apiName(self: PartitionGranularity) []const u8 {
        return switch (self) {
            .hour => "HOUR",
            .day => "DAY",
            .month => "MONTH",
            .year => "YEAR",
        };
    }
};

pub const TimePartitioning = struct {
    field: []const u8 = "",
    granularity: PartitionGranularity = .day,
    expiration_ms: u64 = 0,
};

pub const TableArgs = struct {
    dataset: output.Output([]const u8, .public),
    dataset_id: []const u8,
    table_id: []const u8,
    friendly_name: []const u8 = "",
    description: []const u8 = "",
    schema: []const FieldSchema,
    time_partitioning: ?TimePartitioning = null,
    clustering_fields: []const []const u8 = &.{},
    require_partition_filter: bool = false,
    expiration_time_ms: u64 = 0,
    kms_key_name: []const u8 = "",
    labels: []const config_mod.Label = &.{},
    retain_on_delete: bool = true,
};

pub const Table = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
        pub const NumRows = output.Descriptor("num_rows", u64, .public);
        pub const NumBytes = output.Descriptor("num_bytes", u64, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    etag: Outputs.Etag.OutputType,
    num_rows: Outputs.NumRows.OutputType,
    num_bytes: Outputs.NumBytes.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: TableArgs) BuildError!Table {
        try provider.validate();
        try validateIdentifier(args.dataset_id, .dataset);
        try validateIdentifier(args.table_id, .table);
        if (args.schema.len == 0) return error.InvalidSchema;
        try validateSchema(args.schema, 0);
        if (args.time_partitioning) |partitioning| {
            if (partitioning.field.len > 0 and !schemaPathExists(args.schema, partitioning.field)) return error.InvalidTable;
            try validateExpiration(partitioning.expiration_ms);
        } else if (args.require_partition_filter) return error.InvalidTable;
        if (args.clustering_fields.len > 4) return error.InvalidTable;
        for (args.clustering_fields, 0..) |field, index| {
            if (!schemaPathExists(args.schema, field)) return error.InvalidTable;
            for (args.clustering_fields[index + 1 ..]) |other| if (std.mem.eql(u8, field, other)) return error.InvalidTable;
        }
        try validateText(args.friendly_name, 1024, error.InvalidTable);
        try validateText(args.description, 16_384, error.InvalidTable);
        try validateKmsKey(provider.project_id, args.kms_key_name);
        const schema_json = try schemaJsonAlloc(allocator, args.schema);
        defer allocator.free(schema_json);
        const labels_json = try labelsJsonAlloc(allocator, args.labels);
        defer allocator.free(labels_json);
        const clustering = try stringValuesAlloc(allocator, args.clustering_fields);
        defer allocator.free(clustering);
        const partition_field = if (args.time_partitioning) |partition| partition.field else "";
        const partition_type = if (args.time_partitioning) |partition| partition.granularity.apiName() else "";
        const partition_expiration: u64 = if (args.time_partitioning) |partition| partition.expiration_ms else 0;
        const fields = [_]value.Field{
            .{ .name = "clustering_fields", .value = .{ .list = clustering } },
            .{ .name = "dataset", .value = try outputValue(args.dataset) },
            .{ .name = "dataset_id", .value = .{ .string = args.dataset_id } },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "expiration_time_ms", .value = .{ .integer = @intCast(args.expiration_time_ms) } },
            .{ .name = "friendly_name", .value = .{ .string = args.friendly_name } },
            .{ .name = "kms_key_name", .value = .{ .string = args.kms_key_name } },
            .{ .name = "labels_json", .value = .{ .string = labels_json } },
            .{ .name = "partition_expiration_ms", .value = .{ .integer = @intCast(partition_expiration) } },
            .{ .name = "partition_field", .value = .{ .string = partition_field } },
            .{ .name = "partition_type", .value = .{ .string = partition_type } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "require_partition_filter", .value = .{ .boolean = args.require_partition_filter } },
            .{ .name = "schema_json", .value = .{ .string = schema_json } },
            .{ .name = "table_id", .value = .{ .string = args.table_id } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.bigquery.Table.{s}.{s}", .{ args.dataset_id, args.table_id });
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.bigquery.Table", args.table_id, &fields, .{
            .retain_on_delete = args.retain_on_delete,
            .operation_timeout_millis = 10 * 60 * 1000,
        });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .etag = Outputs.Etag.fromResource(node.id),
            .num_rows = Outputs.NumRows.fromResource(node.id),
            .num_bytes = Outputs.NumBytes.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const ViewArgs = struct {
    dataset: output.Output([]const u8, .public),
    dataset_id: []const u8,
    view_id: []const u8,
    query: []const u8,
    description: []const u8 = "",
    use_legacy_sql: bool = false,
    materialized: bool = false,
    enable_refresh: bool = true,
    refresh_interval_ms: u64 = 30 * 60 * 1000,
    labels: []const config_mod.Label = &.{},
    retain_on_delete: bool = true,
};

pub const View = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    etag: Outputs.Etag.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ViewArgs) BuildError!View {
        try provider.validate();
        try validateIdentifier(args.dataset_id, .dataset);
        try validateIdentifier(args.view_id, .table);
        if (args.use_legacy_sql or args.query.len == 0 or std.mem.indexOfScalar(u8, args.query, 0) != null) return error.InvalidView;
        if (args.materialized and (args.refresh_interval_ms < 30 * 60 * 1000 or args.refresh_interval_ms > 7 * 24 * 60 * 60 * 1000)) return error.InvalidView;
        try validateText(args.description, 16_384, error.InvalidView);
        const labels_json = try labelsJsonAlloc(allocator, args.labels);
        defer allocator.free(labels_json);
        const fields = [_]value.Field{
            .{ .name = "dataset", .value = try outputValue(args.dataset) },
            .{ .name = "dataset_id", .value = .{ .string = args.dataset_id } },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "enable_refresh", .value = .{ .boolean = args.enable_refresh } },
            .{ .name = "labels_json", .value = .{ .string = labels_json } },
            .{ .name = "materialized", .value = .{ .boolean = args.materialized } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "query", .value = .{ .string = args.query } },
            .{ .name = "refresh_interval_ms", .value = .{ .integer = @intCast(args.refresh_interval_ms) } },
            .{ .name = "use_legacy_sql", .value = .{ .boolean = false } },
            .{ .name = "view_id", .value = .{ .string = args.view_id } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.bigquery.View.{s}.{s}", .{ args.dataset_id, args.view_id });
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.bigquery.View", args.view_id, &fields, .{
            .retain_on_delete = args.retain_on_delete,
            .operation_timeout_millis = 10 * 60 * 1000,
        });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .etag = Outputs.Etag.fromResource(node.id) };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const RoutineType = enum {
    scalar_function,
    procedure,
    table_valued_function,

    pub fn apiName(self: RoutineType) []const u8 {
        return switch (self) {
            .scalar_function => "SCALAR_FUNCTION",
            .procedure => "PROCEDURE",
            .table_valued_function => "TABLE_VALUED_FUNCTION",
        };
    }
};

pub const RoutineLanguage = enum {
    sql,
    javascript,

    pub fn apiName(self: RoutineLanguage) []const u8 {
        return switch (self) {
            .sql => "SQL",
            .javascript => "JAVASCRIPT",
        };
    }
};

pub const RoutineArgument = struct {
    name: []const u8,
    data_type_json: []const u8,
};

pub const RoutineArgs = struct {
    dataset: output.Output([]const u8, .public),
    dataset_id: []const u8,
    routine_id: []const u8,
    routine_type: RoutineType,
    language: RoutineLanguage,
    arguments: []const RoutineArgument = &.{},
    return_type_json: []const u8 = "",
    definition_body: []const u8,
    description: []const u8 = "",
    imported_libraries: []const []const u8 = &.{},
    deterministic: ?bool = null,
    retain_on_delete: bool = true,
};

pub const Routine = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    etag: Outputs.Etag.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: RoutineArgs) BuildError!Routine {
        try provider.validate();
        try validateIdentifier(args.dataset_id, .dataset);
        try validateIdentifier(args.routine_id, .routine);
        if (args.definition_body.len == 0 or std.mem.indexOfScalar(u8, args.definition_body, 0) != null) return error.InvalidRoutine;
        if (args.routine_type == .procedure and args.return_type_json.len > 0) return error.InvalidRoutine;
        if (args.routine_type != .procedure and args.return_type_json.len == 0) return error.InvalidRoutine;
        if (args.language == .sql and args.imported_libraries.len > 0) return error.InvalidRoutine;
        try validateText(args.description, 16_384, error.InvalidRoutine);
        const arguments_json = try routineArgumentsJsonAlloc(allocator, args.arguments);
        defer allocator.free(arguments_json);
        if (args.return_type_json.len > 0) try validateJsonObject(allocator, args.return_type_json, error.InvalidRoutine);
        const libraries = try stringValuesAlloc(allocator, args.imported_libraries);
        defer allocator.free(libraries);
        const fields = [_]value.Field{
            .{ .name = "arguments_json", .value = .{ .string = arguments_json } },
            .{ .name = "dataset", .value = try outputValue(args.dataset) },
            .{ .name = "dataset_id", .value = .{ .string = args.dataset_id } },
            .{ .name = "definition_body", .value = .{ .string = args.definition_body } },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "determinism", .value = .{ .string = if (args.deterministic) |present| if (present) "DETERMINISTIC" else "NOT_DETERMINISTIC" else "DETERMINISM_LEVEL_UNSPECIFIED" } },
            .{ .name = "imported_libraries", .value = .{ .list = libraries } },
            .{ .name = "language", .value = .{ .string = args.language.apiName() } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "return_type_json", .value = .{ .string = args.return_type_json } },
            .{ .name = "routine_id", .value = .{ .string = args.routine_id } },
            .{ .name = "routine_type", .value = .{ .string = args.routine_type.apiName() } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.bigquery.Routine.{s}.{s}", .{ args.dataset_id, args.routine_id });
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.bigquery.Routine", args.routine_id, &fields, .{
            .retain_on_delete = args.retain_on_delete,
            .operation_timeout_millis = 10 * 60 * 1000,
        });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .etag = Outputs.Etag.fromResource(node.id) };
    }

    pub fn deinit(self: *Routine, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const ConnectionKind = enum { cloud_resource, cloud_spanner, cloud_sql };

pub const ConnectionArgs = struct {
    connection_id: []const u8,
    location: []const u8,
    kind: ConnectionKind,
    friendly_name: []const u8 = "",
    description: []const u8 = "",
    kms_key_name: []const u8 = "",
    cloud_spanner_database: []const u8 = "",
    cloud_sql_instance_id: []const u8 = "",
    cloud_sql_database: []const u8 = "",
    cloud_sql_type: []const u8 = "",
    credential_json: []const u8 = "",
    retain_on_delete: bool = true,
};

pub const Connection = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const ServiceAccountId = output.Descriptor("service_account_id", []const u8, .public);
        pub const HasCredential = output.Descriptor("has_credential", bool, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    service_account_id: Outputs.ServiceAccountId.OutputType,
    has_credential: Outputs.HasCredential.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ConnectionArgs) BuildError!Connection {
        try provider.validate();
        if (args.credential_json.len > 0) return error.CredentialMaterialRejected;
        try validateIdentifier(args.connection_id, .connection);
        try validateLocation(args.location);
        try validateText(args.friendly_name, 256, error.InvalidConnection);
        try validateText(args.description, 1024, error.InvalidConnection);
        try validateKmsKey(provider.project_id, args.kms_key_name);
        switch (args.kind) {
            .cloud_resource => if (args.cloud_spanner_database.len > 0 or args.cloud_sql_instance_id.len > 0) return error.InvalidConnection,
            .cloud_spanner => if (!std.mem.startsWith(u8, args.cloud_spanner_database, "projects/") or std.mem.indexOf(u8, args.cloud_spanner_database, "/databases/") == null) return error.InvalidConnection,
            .cloud_sql => if (args.cloud_sql_instance_id.len == 0 or args.cloud_sql_database.len == 0 or
                !containsString(&.{ "POSTGRES", "MYSQL" }, args.cloud_sql_type)) return error.InvalidConnection,
        }
        const fields = [_]value.Field{
            .{ .name = "cloud_spanner_database", .value = .{ .string = args.cloud_spanner_database } },
            .{ .name = "cloud_sql_database", .value = .{ .string = args.cloud_sql_database } },
            .{ .name = "cloud_sql_instance_id", .value = .{ .string = args.cloud_sql_instance_id } },
            .{ .name = "cloud_sql_type", .value = .{ .string = args.cloud_sql_type } },
            .{ .name = "connection_id", .value = .{ .string = args.connection_id } },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "friendly_name", .value = .{ .string = args.friendly_name } },
            .{ .name = "kind", .value = .{ .string = @tagName(args.kind) } },
            .{ .name = "kms_key_name", .value = .{ .string = args.kms_key_name } },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.bigquery.Connection.{s}.{s}", .{ args.location, args.connection_id });
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.bigquery.Connection", args.connection_id, &fields, .{
            .retain_on_delete = args.retain_on_delete,
            .operation_timeout_millis = 10 * 60 * 1000,
        });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .service_account_id = Outputs.ServiceAccountId.fromResource(node.id),
            .has_credential = Outputs.HasCredential.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Connection, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

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

pub const ReservationArgs = struct {
    reservation_id: []const u8,
    location: []const u8,
    slot_capacity: u64 = 0,
    max_slots: u64 = 0,
    ignore_idle_slots: bool = false,
    edition: Edition = .enterprise,
    secondary_location: []const u8 = "",
    retain_on_delete: bool = true,
};

pub const Reservation = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const SlotCapacity = output.Descriptor("slot_capacity", u64, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    slot_capacity: Outputs.SlotCapacity.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ReservationArgs) BuildError!Reservation {
        try provider.validate();
        try validateShortId(args.reservation_id, 64, error.InvalidReservation);
        try validateLocation(args.location);
        if (args.slot_capacity == 0 and args.max_slots == 0) return error.InvalidReservation;
        if (args.max_slots > 0 and args.max_slots < args.slot_capacity) return error.InvalidReservation;
        if (args.secondary_location.len > 0) try validateLocation(args.secondary_location);
        const fields = [_]value.Field{
            .{ .name = "edition", .value = .{ .string = args.edition.apiName() } },
            .{ .name = "ignore_idle_slots", .value = .{ .boolean = args.ignore_idle_slots } },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "max_slots", .value = .{ .integer = @intCast(args.max_slots) } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "reservation_id", .value = .{ .string = args.reservation_id } },
            .{ .name = "secondary_location", .value = .{ .string = args.secondary_location } },
            .{ .name = "slot_capacity", .value = .{ .integer = @intCast(args.slot_capacity) } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.bigquery.Reservation.{s}.{s}", .{ args.location, args.reservation_id });
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.bigquery.Reservation", args.reservation_id, &fields, .{
            .retain_on_delete = args.retain_on_delete,
            .operation_timeout_millis = 30 * 60 * 1000,
        });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .slot_capacity = Outputs.SlotCapacity.fromResource(node.id) };
    }

    pub fn deinit(self: *Reservation, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const CommitmentPlan = enum {
    flex,
    monthly,
    annual,
    three_year,

    pub fn apiName(self: CommitmentPlan) []const u8 {
        return switch (self) {
            .flex => "FLEX",
            .monthly => "MONTHLY",
            .annual => "ANNUAL",
            .three_year => "THREE_YEAR",
        };
    }
};

pub const CapacityCommitmentArgs = struct {
    commitment_id: []const u8,
    location: []const u8,
    slot_count: u64,
    plan: CommitmentPlan,
    edition: Edition = .enterprise,
    renewal_plan: ?CommitmentPlan = null,
};

pub const CapacityCommitment = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    state: Outputs.State.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: CapacityCommitmentArgs) BuildError!CapacityCommitment {
        try provider.validate();
        try validateShortId(args.commitment_id, 64, error.InvalidCommitment);
        try validateLocation(args.location);
        if (args.slot_count == 0) return error.InvalidCommitment;
        const fields = [_]value.Field{
            .{ .name = "commitment_id", .value = .{ .string = args.commitment_id } },
            .{ .name = "edition", .value = .{ .string = args.edition.apiName() } },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "plan", .value = .{ .string = args.plan.apiName() } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "renewal_plan", .value = .{ .string = if (args.renewal_plan) |plan| plan.apiName() else "" } },
            .{ .name = "slot_count", .value = .{ .integer = @intCast(args.slot_count) } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.bigquery.CapacityCommitment.{s}.{s}", .{ args.location, args.commitment_id });
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.bigquery.CapacityCommitment", args.commitment_id, &fields, .{
            .protect = true,
            .retain_on_delete = true,
            .operation_timeout_millis = 30 * 60 * 1000,
        });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .state = Outputs.State.fromResource(node.id) };
    }

    pub fn deinit(self: *CapacityCommitment, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const AssignmentJobType = enum {
    query,
    pipeline,
    ml_external,
    background,

    pub fn apiName(self: AssignmentJobType) []const u8 {
        return switch (self) {
            .query => "QUERY",
            .pipeline => "PIPELINE",
            .ml_external => "ML_EXTERNAL",
            .background => "BACKGROUND",
        };
    }
};

pub const ReservationAssignmentArgs = struct {
    name: []const u8,
    reservation: output.Output([]const u8, .public),
    location: []const u8,
    reservation_id: []const u8,
    assignee: []const u8,
    job_type: AssignmentJobType = .query,
    retain_on_delete: bool = true,
};

pub const ReservationAssignment = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
    };
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ReservationAssignmentArgs) BuildError!ReservationAssignment {
        try provider.validate();
        try validateShortId(args.name, 64, error.InvalidAssignment);
        try validateShortId(args.reservation_id, 64, error.InvalidAssignment);
        try validateLocation(args.location);
        if (!validAssignee(args.assignee)) return error.InvalidAssignment;
        const fields = [_]value.Field{
            .{ .name = "assignee", .value = .{ .string = args.assignee } },
            .{ .name = "job_type", .value = .{ .string = args.job_type.apiName() } },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "reservation", .value = try outputValue(args.reservation) },
            .{ .name = "reservation_id", .value = .{ .string = args.reservation_id } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.bigquery.ReservationAssignment.{s}.{s}", .{ args.location, args.name });
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.bigquery.ReservationAssignment", args.name, &fields, .{
            .retain_on_delete = args.retain_on_delete,
            .operation_timeout_millis = 30 * 60 * 1000,
        });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
    }

    pub fn deinit(self: *ReservationAssignment, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const DatasetIamMemberArgs = struct {
    name: []const u8,
    dataset: output.Output([]const u8, .public),
    dataset_id: []const u8,
    role: []const u8,
    member: []const u8,
    condition: ?iam.Condition = null,
};

pub const TableIamMemberArgs = struct {
    name: []const u8,
    table: output.Output([]const u8, .public),
    dataset_id: []const u8,
    table_id: []const u8,
    role: []const u8,
    member: []const u8,
    condition: ?iam.Condition = null,
};

pub const RoutineIamMemberArgs = struct {
    name: []const u8,
    routine: output.Output([]const u8, .public),
    dataset_id: []const u8,
    routine_id: []const u8,
    role: []const u8,
    member: []const u8,
    condition: ?iam.Condition = null,
};

pub const ConnectionIamMemberArgs = struct {
    name: []const u8,
    connection: output.Output([]const u8, .public),
    location: []const u8,
    connection_id: []const u8,
    role: []const u8,
    member: []const u8,
    condition: ?iam.Condition = null,
};

pub const ReservationIamMemberArgs = struct {
    name: []const u8,
    reservation: output.Output([]const u8, .public),
    location: []const u8,
    reservation_id: []const u8,
    role: []const u8,
    member: []const u8,
    condition: ?iam.Condition = null,
};

pub const DatasetIamMember = IamMemberResource("gcp.bigquery.DatasetIamMember", DatasetIamMemberArgs, .dataset);
pub const TableIamMember = IamMemberResource("gcp.bigquery.TableIamMember", TableIamMemberArgs, .table);
pub const RoutineIamMember = IamMemberResource("gcp.bigquery.RoutineIamMember", RoutineIamMemberArgs, .routine);
pub const ConnectionIamMember = IamMemberResource("gcp.bigquery.ConnectionIamMember", ConnectionIamMemberArgs, .connection);
pub const ReservationIamMember = IamMemberResource("gcp.bigquery.ReservationIamMember", ReservationIamMemberArgs, .reservation);

const IamTargetKind = enum { dataset, table, routine, connection, reservation };

fn IamMemberResource(comptime type_name: []const u8, comptime Args: type, comptime kind: IamTargetKind) type {
    return struct {
        pub const Outputs = struct {
            pub const BindingId = output.Descriptor("binding_id", []const u8, .public);
        };
        node: resource.ResourceNode,
        binding_id: Outputs.BindingId.OutputType,

        pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: Args) BuildError!@This() {
            try provider.validate();
            try validateShortId(args.name, 128, error.InvalidMember);
            try validateRole(args.role);
            try validateMember(args.member);
            try validateCondition(args.condition);
            const target = if (comptime kind == .dataset)
                args.dataset
            else if (comptime kind == .table)
                args.table
            else if (comptime kind == .routine)
                args.routine
            else if (comptime kind == .connection)
                args.connection
            else
                args.reservation;
            const resource_name = try iamResourceNameAlloc(allocator, provider.project_id, args, kind);
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
                .{ .name = "target", .value = try outputValue(target) },
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

fn nodeOwned(
    allocator: std.mem.Allocator,
    id: []const u8,
    type_name: []const u8,
    logical_id: []const u8,
    fields: []const value.Field,
    lifecycle: resource.Lifecycle,
) BuildError!resource.ResourceNode {
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

const IdentifierKind = enum { dataset, table, routine, connection };

fn validateIdentifier(identifier: []const u8, kind: IdentifierKind) BuildError!void {
    const maximum: usize = switch (kind) {
        .dataset, .table => 1024,
        .routine => 256,
        .connection => 63,
    };
    if (identifier.len == 0 or identifier.len > maximum) return switch (kind) {
        .dataset => error.InvalidDataset,
        .table => error.InvalidTable,
        .routine => error.InvalidRoutine,
        .connection => error.InvalidConnection,
    };
    for (identifier) |character| if (!std.ascii.isAlphanumeric(character) and character != '_') return switch (kind) {
        .dataset => error.InvalidDataset,
        .table => error.InvalidTable,
        .routine => error.InvalidRoutine,
        .connection => error.InvalidConnection,
    };
}

fn validateShortId(identifier: []const u8, maximum: usize, err: BuildError) BuildError!void {
    if (identifier.len == 0 or identifier.len > maximum or !std.ascii.isLower(identifier[0]) or identifier[identifier.len - 1] == '-') return err;
    for (identifier) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return err;
}

fn validateLocation(location: []const u8) BuildError!void {
    if (location.len == 0 or location.len > 128 or std.mem.indexOfAny(u8, location, "\x00\r\n /?") != null) return error.InvalidLocation;
}

fn validateExpiration(milliseconds: u64) BuildError!void {
    if (milliseconds > 0 and milliseconds < 60 * 60 * 1000) return error.InvalidDataset;
    if (milliseconds > std.math.maxInt(i64)) return error.InvalidDataset;
}

fn validateText(text: []const u8, maximum: usize, err: BuildError) BuildError!void {
    if (text.len > maximum or std.mem.indexOfScalar(u8, text, 0) != null) return err;
}

fn validateKmsKey(project_id: []const u8, key: []const u8) BuildError!void {
    if (key.len == 0) return;
    if (!std.mem.startsWith(u8, key, "projects/") or std.mem.indexOf(u8, key, project_id) == null or
        std.mem.indexOf(u8, key, "/cryptoKeys/") == null or std.mem.indexOfAny(u8, key, "\x00\r\n ") != null) return error.InvalidKmsKey;
}

fn validateSchema(fields: []const FieldSchema, depth: usize) BuildError!void {
    if (depth >= 15) return error.InvalidSchema;
    for (fields, 0..) |field, index| {
        if (field.name.len == 0 or field.name.len > 300 or (!std.ascii.isAlphabetic(field.name[0]) and field.name[0] != '_')) return error.InvalidSchema;
        for (field.name) |character| if (!std.ascii.isAlphanumeric(character) and character != '_') return error.InvalidSchema;
        try validateText(field.description, 1024, error.InvalidSchema);
        if (field.field_type == .record) {
            if (field.fields.len == 0) return error.InvalidSchema;
            try validateSchema(field.fields, depth + 1);
        } else if (field.fields.len > 0) return error.InvalidSchema;
        for (fields[index + 1 ..]) |other| if (std.ascii.eqlIgnoreCase(field.name, other.name)) return error.DuplicateField;
    }
}

fn schemaPathExists(fields: []const FieldSchema, path: []const u8) bool {
    var parts = std.mem.splitScalar(u8, path, '.');
    var current = fields;
    while (parts.next()) |part| {
        var found: ?FieldSchema = null;
        for (current) |field| if (std.mem.eql(u8, field.name, part)) {
            found = field;
            break;
        };
        const selected = found orelse return false;
        if (parts.peek() != null) current = selected.fields;
    }
    return true;
}

fn schemaJsonAlloc(allocator: std.mem.Allocator, fields: []const FieldSchema) BuildError![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const array = try schemaJsonArray(arena, fields);
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .array = array }, .{}) catch return error.OutOfMemory;
}

fn schemaJsonArray(allocator: std.mem.Allocator, fields: []const FieldSchema) !std.json.Array {
    var array = std.json.Array.init(allocator);
    for (fields) |field| {
        var object: std.json.ObjectMap = .empty;
        try object.put(allocator, "name", .{ .string = field.name });
        try object.put(allocator, "type", .{ .string = field.field_type.apiName() });
        try object.put(allocator, "mode", .{ .string = field.mode.apiName() });
        if (field.description.len > 0) try object.put(allocator, "description", .{ .string = field.description });
        if (field.fields.len > 0) try object.put(allocator, "fields", .{ .array = try schemaJsonArray(allocator, field.fields) });
        try array.append(.{ .object = object });
    }
    return array;
}

fn labelsJsonAlloc(allocator: std.mem.Allocator, labels: []const config_mod.Label) BuildError![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const sorted = try arena.dupe(config_mod.Label, labels);
    std.mem.sort(config_mod.Label, sorted, {}, lessThanLabel);
    var object: std.json.ObjectMap = .empty;
    for (sorted, 0..) |label, index| {
        if (label.key.len == 0 or label.key.len > 63 or label.value.len > 63 or std.mem.indexOfAny(u8, label.key, "\x00\r\n ") != null) return error.InvalidDataset;
        if (index > 0 and std.mem.eql(u8, sorted[index - 1].key, label.key)) return error.DuplicateLabel;
        try object.put(arena, label.key, .{ .string = label.value });
    }
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = object }, .{}) catch return error.OutOfMemory;
}

fn lessThanLabel(_: void, left: config_mod.Label, right: config_mod.Label) bool {
    return std.mem.lessThan(u8, left.key, right.key);
}

fn routineArgumentsJsonAlloc(allocator: std.mem.Allocator, arguments: []const RoutineArgument) BuildError![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var array = std.json.Array.init(arena);
    for (arguments, 0..) |argument, index| {
        try validateIdentifier(argument.name, .routine);
        for (arguments[index + 1 ..]) |other| if (std.mem.eql(u8, argument.name, other.name)) return error.DuplicateField;
        var parsed = std.json.parseFromSlice(std.json.Value, arena, argument.data_type_json, .{}) catch return error.InvalidRoutine;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidRoutine;
        var object: std.json.ObjectMap = .empty;
        try object.put(arena, "name", .{ .string = argument.name });
        try object.put(arena, "dataType", parsed.value);
        try array.append(.{ .object = object });
    }
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .array = array }, .{}) catch return error.OutOfMemory;
}

fn validateJsonObject(allocator: std.mem.Allocator, input: []const u8, err: BuildError) BuildError!void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch return err;
    defer parsed.deinit();
    if (parsed.value != .object) return err;
}

fn outputValue(selected: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (selected) {
        .value => |known| .{ .string = known },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn stringValuesAlloc(allocator: std.mem.Allocator, strings: []const []const u8) BuildError![]value.Value {
    const values = try allocator.alloc(value.Value, strings.len);
    for (strings, 0..) |text, index| {
        if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidTable;
        values[index] = .{ .string = text };
    }
    return values;
}

fn validateRole(role: []const u8) BuildError!void {
    if ((!std.mem.startsWith(u8, role, "roles/") and !std.mem.startsWith(u8, role, "projects/") and
        !std.mem.startsWith(u8, role, "organizations/")) or std.mem.indexOf(u8, role, "/roles/") == null and
        !std.mem.startsWith(u8, role, "roles/") or std.mem.indexOfAny(u8, role, "\x00\r\n ") != null) return error.InvalidRole;
}

fn validateMember(member: []const u8) BuildError!void {
    if (std.mem.eql(u8, member, "allUsers") or std.mem.eql(u8, member, "allAuthenticatedUsers")) return;
    const prefixes = [_][]const u8{ "user:", "serviceAccount:", "group:", "domain:", "principal:", "principalSet:" };
    for (prefixes) |prefix| if (std.mem.startsWith(u8, member, prefix) and member.len > prefix.len) return;
    return error.InvalidMember;
}

fn validateCondition(condition: ?iam.Condition) BuildError!void {
    const present = condition orelse return;
    if (present.title.len == 0 or present.title.len > 100 or present.description.len > 256 or
        present.expression.len == 0 or present.expression.len > 2048 or
        std.mem.indexOfAny(u8, present.title, "\x00\r\n") != null or
        std.mem.indexOfAny(u8, present.expression, "\x00\r\n") != null) return error.InvalidIamCondition;
}

fn iamResourceNameAlloc(allocator: std.mem.Allocator, project_id: []const u8, args: anytype, comptime kind: IamTargetKind) ![]const u8 {
    if (comptime kind == .dataset) return std.fmt.allocPrint(allocator, "projects/{s}/datasets/{s}", .{ project_id, args.dataset_id });
    if (comptime kind == .table) return std.fmt.allocPrint(allocator, "projects/{s}/datasets/{s}/tables/{s}", .{ project_id, args.dataset_id, args.table_id });
    if (comptime kind == .routine) return std.fmt.allocPrint(allocator, "projects/{s}/datasets/{s}/routines/{s}", .{ project_id, args.dataset_id, args.routine_id });
    if (comptime kind == .connection) return std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}/connections/{s}", .{ project_id, args.location, args.connection_id });
    return std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}/reservations/{s}", .{ project_id, args.location, args.reservation_id });
}

fn validAssignee(assignee: []const u8) bool {
    for ([_][]const u8{ "projects/", "folders/", "organizations/" }) |prefix| {
        if (!std.mem.startsWith(u8, assignee, prefix) or assignee.len == prefix.len) continue;
        for (assignee[prefix.len..]) |character| if (!std.ascii.isDigit(character)) return false;
        return true;
    }
    return false;
}

fn containsString(values: []const []const u8, expected: []const u8) bool {
    for (values) |item| if (std.mem.eql(u8, item, expected)) return true;
    return false;
}
