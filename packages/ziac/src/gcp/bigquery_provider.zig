const std = @import("std");
const client_mod = @import("client.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;

const Kind = enum {
    dataset,
    table,
    view,
    routine,
    connection,
    reservation,
    commitment,
    assignment,
};

pub const Handler = struct {
    client: *client_mod.Client,

    pub fn read(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_override: ?[]const u8,
    ) ProviderError!provider_mod.ReadResult {
        const resource_kind = kind(node) orelse return error.InvalidConfiguration;
        const physical = try canonicalPhysicalAlloc(context, node, physical_override);
        defer context.allocator.free(physical);
        const path = try itemPathAlloc(context.allocator, node, resource_kind, physical);
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = apiForKind(resource_kind), .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try resultFromJson(context, node, resource_kind, physical, response.body) };
    }

    pub fn diff(
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        observed: *const provider_mod.ResourceResult,
    ) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        const resource_kind = kind(node) orelse return error.InvalidConfiguration;
        if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash)) {
            return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        }
        const replacement = identityChanged(node, observed.observed_inputs) or
            resource_kind == .assignment or resource_kind == .commitment;
        return provider_mod.DiffResult.init(
            context.allocator,
            if (replacement) .replace else .update,
            &.{if (replacement) "BigQuery resource identity or immutable capacity changed" else "BigQuery remote configuration differs"},
        );
    }

    pub fn create(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        const resource_kind = kind(node) orelse return error.InvalidConfiguration;
        const path = try createPathAlloc(context, node, resource_kind);
        defer context.allocator.free(path);
        const body = try bodyAlloc(context, node, resource_kind);
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = apiForKind(resource_kind), .method = "POST", .path = path, .body = body });
        defer response.deinit(context.allocator);
        const expected = if (resource_kind == .assignment)
            jsonNameAlloc(context.allocator, response.body)
        else
            physicalIdAlloc(context, node, resource_kind);
        const physical = try expected;
        defer context.allocator.free(physical);
        return resultFromJson(context, node, resource_kind, physical, response.body);
    }

    pub fn update(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        observed: *const provider_mod.ResourceResult,
    ) ProviderError!provider_mod.ResourceResult {
        const resource_kind = kind(node) orelse return error.InvalidConfiguration;
        if (resource_kind == .assignment or resource_kind == .commitment) return error.InvalidConfiguration;
        const expected = try physicalIdAlloc(context, node, resource_kind);
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, observed.physical_id)) return error.InvalidConfiguration;
        const path = try updatePathAlloc(context.allocator, node, resource_kind, observed.physical_id);
        defer context.allocator.free(path);
        const body = try bodyAlloc(context, node, resource_kind);
        defer context.allocator.free(body);
        const etag = if (resource_kind == .dataset or resource_kind == .table or resource_kind == .view or resource_kind == .routine)
            outputString(observed, "etag") orelse return error.Conflict
        else
            null;
        const headers: []const @import("zigeffect_std").Http.Header = if (etag) |present| &.{.{ .name = "if-match", .value = present }} else &.{};
        var response = try self.request(context, .{
            .api = apiForKind(resource_kind),
            .method = if (resource_kind == .routine) "PUT" else "PATCH",
            .path = path,
            .body = body,
            .headers = headers,
        });
        defer response.deinit(context.allocator);
        return resultFromJson(context, node, resource_kind, observed.physical_id, response.body);
    }

    pub fn delete(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!void {
        const resource_kind = kind(node) orelse return error.InvalidConfiguration;
        if (node.lifecycle.retain_on_delete) return;
        if (resource_kind == .commitment) return error.DestructiveConfirmationRequired;
        const expected = if (resource_kind == .assignment)
            try context.allocator.dupe(u8, physical_id)
        else
            try physicalIdAlloc(context, node, resource_kind);
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        var path = try itemPathAlloc(context.allocator, node, resource_kind, physical_id);
        defer context.allocator.free(path);
        if (resource_kind == .dataset and try requiredBool(node.inputs, "delete_contents_on_destroy")) {
            if (!context.destructive_confirmation) return error.DestructiveConfirmationRequired;
            const with_contents = try std.fmt.allocPrint(context.allocator, "{s}?deleteContents=true", .{path});
            context.allocator.free(path);
            path = with_contents;
        }
        var response = self.request(context, .{ .api = apiForKind(resource_kind), .method = "DELETE", .path = path }) catch |err| {
            if (err == error.NotFound) return;
            if (err == error.Conflict and resource_kind == .dataset) return error.ResourceNotEmpty;
            return err;
        };
        response.deinit(context.allocator);
    }

    fn request(
        self: Handler,
        context: *provider_mod.OperationContext,
        request_value: client_mod.Request,
    ) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, request_value, &diagnostic);
    }
};

pub fn supports(node: resource.ResourceNode) bool {
    return kind(node) != null;
}

fn apiForKind(resource_kind: Kind) client_mod.Api {
    return switch (resource_kind) {
        .dataset, .table, .view, .routine => .bigquery,
        .connection => .bigquery_connection,
        .reservation, .commitment, .assignment => .bigquery_reservation,
    };
}

fn kind(node: resource.ResourceNode) ?Kind {
    const entries = [_]struct { []const u8, Kind }{
        .{ "gcp.bigquery.Dataset", .dataset },
        .{ "gcp.bigquery.Table", .table },
        .{ "gcp.bigquery.View", .view },
        .{ "gcp.bigquery.Routine", .routine },
        .{ "gcp.bigquery.Connection", .connection },
        .{ "gcp.bigquery.Reservation", .reservation },
        .{ "gcp.bigquery.CapacityCommitment", .commitment },
        .{ "gcp.bigquery.ReservationAssignment", .assignment },
    };
    inline for (entries) |entry| if (std.mem.eql(u8, node.type_name, entry[0])) return entry[1];
    return null;
}

fn canonicalPhysicalAlloc(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    override: ?[]const u8,
) ProviderError![]const u8 {
    const resource_kind = kind(node) orelse return error.InvalidConfiguration;
    if (override) |provided| return normalizeImportAlloc(context.allocator, node, resource_kind, provided);
    if (resource_kind == .assignment) {
        const provided = context.physical_id orelse return error.InvalidConfiguration;
        return normalizeImportAlloc(context.allocator, node, resource_kind, provided);
    }
    return physicalIdAlloc(context, node, resource_kind);
}

fn physicalIdAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, resource_kind: Kind) ProviderError![]const u8 {
    const project = try requiredString(node.inputs, "project_id");
    return switch (resource_kind) {
        .dataset => std.fmt.allocPrint(context.allocator, "projects/{s}/datasets/{s}", .{ project, try requiredString(node.inputs, "dataset_id") }),
        .table => std.fmt.allocPrint(context.allocator, "projects/{s}/datasets/{s}/tables/{s}", .{ project, try requiredString(node.inputs, "dataset_id"), try requiredString(node.inputs, "table_id") }),
        .view => std.fmt.allocPrint(context.allocator, "projects/{s}/datasets/{s}/tables/{s}", .{ project, try requiredString(node.inputs, "dataset_id"), try requiredString(node.inputs, "view_id") }),
        .routine => std.fmt.allocPrint(context.allocator, "projects/{s}/datasets/{s}/routines/{s}", .{ project, try requiredString(node.inputs, "dataset_id"), try requiredString(node.inputs, "routine_id") }),
        .connection => std.fmt.allocPrint(context.allocator, "projects/{s}/locations/{s}/connections/{s}", .{ project, try requiredString(node.inputs, "location"), try requiredString(node.inputs, "connection_id") }),
        .reservation => std.fmt.allocPrint(context.allocator, "projects/{s}/locations/{s}/reservations/{s}", .{ project, try requiredString(node.inputs, "location"), try requiredString(node.inputs, "reservation_id") }),
        .commitment => std.fmt.allocPrint(context.allocator, "projects/{s}/locations/{s}/capacityCommitments/{s}", .{ project, try requiredString(node.inputs, "location"), try requiredString(node.inputs, "commitment_id") }),
        .assignment => error.InvalidConfiguration,
    } catch error.OutOfMemory;
}

fn normalizeImportAlloc(
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    resource_kind: Kind,
    provided: []const u8,
) ProviderError![]const u8 {
    if (std.mem.startsWith(u8, provided, "projects/")) return allocator.dupe(u8, provided) catch error.OutOfMemory;
    const project = try requiredString(node.inputs, "project_id");
    if (resource_kind == .dataset) {
        if (std.mem.indexOfScalar(u8, provided, ':')) |separator| {
            return std.fmt.allocPrint(allocator, "projects/{s}/datasets/{s}", .{ provided[0..separator], provided[separator + 1 ..] }) catch error.OutOfMemory;
        }
        return std.fmt.allocPrint(allocator, "projects/{s}/datasets/{s}", .{ project, provided }) catch error.OutOfMemory;
    }
    if (resource_kind == .table or resource_kind == .view) {
        const colon = std.mem.indexOfScalar(u8, provided, ':') orelse return error.InvalidConfiguration;
        const dot = std.mem.indexOfScalarPos(u8, provided, colon + 1, '.') orelse return error.InvalidConfiguration;
        return std.fmt.allocPrint(allocator, "projects/{s}/datasets/{s}/tables/{s}", .{ provided[0..colon], provided[colon + 1 .. dot], provided[dot + 1 ..] }) catch error.OutOfMemory;
    }
    if (resource_kind == .assignment and std.mem.indexOf(u8, provided, "/assignments/") != null) {
        return allocator.dupe(u8, provided) catch error.OutOfMemory;
    }
    return error.InvalidConfiguration;
}

fn itemPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, resource_kind: Kind, physical: []const u8) ProviderError![]const u8 {
    _ = node;
    const prefix: []const u8 = switch (resource_kind) {
        .dataset, .table, .view, .routine => "/bigquery/v2/",
        else => "/v1/",
    };
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, physical }) catch error.OutOfMemory;
}

fn createPathAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, resource_kind: Kind) ProviderError![]const u8 {
    const project = try requiredString(node.inputs, "project_id");
    return switch (resource_kind) {
        .dataset => std.fmt.allocPrint(context.allocator, "/bigquery/v2/projects/{s}/datasets", .{project}),
        .table, .view => std.fmt.allocPrint(context.allocator, "/bigquery/v2/projects/{s}/datasets/{s}/tables", .{ project, try requiredString(node.inputs, "dataset_id") }),
        .routine => std.fmt.allocPrint(context.allocator, "/bigquery/v2/projects/{s}/datasets/{s}/routines", .{ project, try requiredString(node.inputs, "dataset_id") }),
        .connection => std.fmt.allocPrint(context.allocator, "/v1/projects/{s}/locations/{s}/connections?connectionId={s}", .{ project, try requiredString(node.inputs, "location"), try requiredString(node.inputs, "connection_id") }),
        .reservation => std.fmt.allocPrint(context.allocator, "/v1/projects/{s}/locations/{s}/reservations?reservationId={s}", .{ project, try requiredString(node.inputs, "location"), try requiredString(node.inputs, "reservation_id") }),
        .commitment => std.fmt.allocPrint(context.allocator, "/v1/projects/{s}/locations/{s}/capacityCommitments?capacityCommitmentId={s}", .{ project, try requiredString(node.inputs, "location"), try requiredString(node.inputs, "commitment_id") }),
        .assignment => blk: {
            const reservation = try resolveString(context, try requiredValue(node.inputs, "reservation"));
            break :blk std.fmt.allocPrint(context.allocator, "/v1/{s}/assignments", .{reservation});
        },
    } catch error.OutOfMemory;
}

fn updatePathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, resource_kind: Kind, physical: []const u8) ProviderError![]const u8 {
    const base = try itemPathAlloc(allocator, node, resource_kind, physical);
    defer allocator.free(base);
    const query: []const u8 = switch (resource_kind) {
        .dataset => "?updateMode=UPDATE_METADATA",
        .table, .view, .routine => "",
        .connection => "friendlyName%2Cdescription",
        .reservation => "slotCapacity%2CmaxSlots%2CignoreIdleSlots%2Cedition%2CsecondaryLocation",
        .commitment, .assignment => return error.InvalidConfiguration,
    };
    if (resource_kind == .connection or resource_kind == .reservation) {
        return std.fmt.allocPrint(allocator, "{s}?updateMask={s}", .{ base, query }) catch error.OutOfMemory;
    }
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ base, query }) catch error.OutOfMemory;
}

fn bodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, resource_kind: Kind) ProviderError![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root: std.json.ObjectMap = .empty;
    switch (resource_kind) {
        .dataset => try datasetBody(arena, node, &root),
        .table => try tableBody(arena, node, &root, false),
        .view => try tableBody(arena, node, &root, true),
        .routine => try routineBody(arena, node, &root),
        .connection => try connectionBody(arena, node, &root),
        .reservation => try reservationBody(arena, node, &root),
        .commitment => try commitmentBody(arena, node, &root),
        .assignment => try assignmentBody(arena, node, &root),
    }
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch error.OutOfMemory;
}

fn datasetBody(allocator: std.mem.Allocator, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    var reference: std.json.ObjectMap = .empty;
    try reference.put(allocator, "projectId", .{ .string = try requiredString(node.inputs, "project_id") });
    try reference.put(allocator, "datasetId", .{ .string = try requiredString(node.inputs, "dataset_id") });
    try root.put(allocator, "datasetReference", .{ .object = reference });
    try putNonEmpty(allocator, root, "location", try requiredString(node.inputs, "location"));
    try putNonEmpty(allocator, root, "friendlyName", try requiredString(node.inputs, "friendly_name"));
    try putNonEmpty(allocator, root, "description", try requiredString(node.inputs, "description"));
    try putIntegerString(allocator, root, "defaultTableExpirationMs", try requiredInteger(node.inputs, "default_table_expiration_ms"));
    try putIntegerString(allocator, root, "defaultPartitionExpirationMs", try requiredInteger(node.inputs, "default_partition_expiration_ms"));
    try putParsed(allocator, root, "labels", try requiredString(node.inputs, "labels_json"));
    const kms = try requiredString(node.inputs, "default_kms_key_name");
    if (kms.len > 0) {
        var encryption: std.json.ObjectMap = .empty;
        try encryption.put(allocator, "kmsKeyName", .{ .string = kms });
        try root.put(allocator, "defaultEncryptionConfiguration", .{ .object = encryption });
    }
}

fn tableBody(allocator: std.mem.Allocator, node: resource.ResourceNode, root: *std.json.ObjectMap, view: bool) ProviderError!void {
    var reference: std.json.ObjectMap = .empty;
    try reference.put(allocator, "projectId", .{ .string = try requiredString(node.inputs, "project_id") });
    try reference.put(allocator, "datasetId", .{ .string = try requiredString(node.inputs, "dataset_id") });
    try reference.put(allocator, "tableId", .{ .string = try requiredString(node.inputs, if (view) "view_id" else "table_id") });
    try root.put(allocator, "tableReference", .{ .object = reference });
    try putNonEmpty(allocator, root, "friendlyName", if (view) "" else try requiredString(node.inputs, "friendly_name"));
    try putNonEmpty(allocator, root, "description", try requiredString(node.inputs, "description"));
    try putParsed(allocator, root, "labels", try requiredString(node.inputs, "labels_json"));
    if (view) {
        var definition: std.json.ObjectMap = .empty;
        try definition.put(allocator, "query", .{ .string = try requiredString(node.inputs, "query") });
        try definition.put(allocator, "useLegacySql", .{ .bool = false });
        if (try requiredBool(node.inputs, "materialized")) {
            try definition.put(allocator, "enableRefresh", .{ .bool = try requiredBool(node.inputs, "enable_refresh") });
            try definition.put(allocator, "refreshIntervalMs", .{ .string = try integerStringAlloc(allocator, try requiredInteger(node.inputs, "refresh_interval_ms")) });
            try root.put(allocator, "materializedView", .{ .object = definition });
        } else try root.put(allocator, "view", .{ .object = definition });
        return;
    }
    var schema: std.json.ObjectMap = .empty;
    try schema.put(allocator, "fields", try parseJson(allocator, try requiredString(node.inputs, "schema_json")));
    try root.put(allocator, "schema", .{ .object = schema });
    const partition_type = try requiredString(node.inputs, "partition_type");
    if (partition_type.len > 0) {
        var partition: std.json.ObjectMap = .empty;
        try partition.put(allocator, "type", .{ .string = partition_type });
        try putNonEmpty(allocator, &partition, "field", try requiredString(node.inputs, "partition_field"));
        try putIntegerString(allocator, &partition, "expirationMs", try requiredInteger(node.inputs, "partition_expiration_ms"));
        try root.put(allocator, "timePartitioning", .{ .object = partition });
    }
    const clustering = try requiredList(node.inputs, "clustering_fields");
    if (clustering.len > 0) {
        var array = std.json.Array.init(allocator);
        for (clustering) |entry| try array.append(.{ .string = stringValue(entry) orelse return error.InvalidConfiguration });
        var object: std.json.ObjectMap = .empty;
        try object.put(allocator, "fields", .{ .array = array });
        try root.put(allocator, "clustering", .{ .object = object });
    }
    try root.put(allocator, "requirePartitionFilter", .{ .bool = try requiredBool(node.inputs, "require_partition_filter") });
    try putIntegerString(allocator, root, "expirationTime", try requiredInteger(node.inputs, "expiration_time_ms"));
    const kms = try requiredString(node.inputs, "kms_key_name");
    if (kms.len > 0) {
        var encryption: std.json.ObjectMap = .empty;
        try encryption.put(allocator, "kmsKeyName", .{ .string = kms });
        try root.put(allocator, "encryptionConfiguration", .{ .object = encryption });
    }
}

fn routineBody(allocator: std.mem.Allocator, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    var reference: std.json.ObjectMap = .empty;
    try reference.put(allocator, "projectId", .{ .string = try requiredString(node.inputs, "project_id") });
    try reference.put(allocator, "datasetId", .{ .string = try requiredString(node.inputs, "dataset_id") });
    try reference.put(allocator, "routineId", .{ .string = try requiredString(node.inputs, "routine_id") });
    try root.put(allocator, "routineReference", .{ .object = reference });
    try root.put(allocator, "routineType", .{ .string = try requiredString(node.inputs, "routine_type") });
    try root.put(allocator, "language", .{ .string = try requiredString(node.inputs, "language") });
    try root.put(allocator, "arguments", try parseJson(allocator, try requiredString(node.inputs, "arguments_json")));
    const return_type = try requiredString(node.inputs, "return_type_json");
    if (return_type.len > 0) try root.put(allocator, "returnType", try parseJson(allocator, return_type));
    try root.put(allocator, "definitionBody", .{ .string = try requiredString(node.inputs, "definition_body") });
    try putNonEmpty(allocator, root, "description", try requiredString(node.inputs, "description"));
    try root.put(allocator, "determinismLevel", .{ .string = try requiredString(node.inputs, "determinism") });
    const libraries = try requiredList(node.inputs, "imported_libraries");
    if (libraries.len > 0) {
        var array = std.json.Array.init(allocator);
        for (libraries) |entry| try array.append(.{ .string = stringValue(entry) orelse return error.InvalidConfiguration });
        try root.put(allocator, "importedLibraries", .{ .array = array });
    }
}

fn connectionBody(allocator: std.mem.Allocator, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    try putNonEmpty(allocator, root, "friendlyName", try requiredString(node.inputs, "friendly_name"));
    try putNonEmpty(allocator, root, "description", try requiredString(node.inputs, "description"));
    const connection_kind = try requiredString(node.inputs, "kind");
    if (std.mem.eql(u8, connection_kind, "cloud_resource")) {
        try root.put(allocator, "cloudResource", .{ .object = .empty });
    } else if (std.mem.eql(u8, connection_kind, "cloud_spanner")) {
        var config: std.json.ObjectMap = .empty;
        try config.put(allocator, "database", .{ .string = try requiredString(node.inputs, "cloud_spanner_database") });
        try root.put(allocator, "cloudSpanner", .{ .object = config });
    } else if (std.mem.eql(u8, connection_kind, "cloud_sql")) {
        var config: std.json.ObjectMap = .empty;
        try config.put(allocator, "instanceId", .{ .string = try requiredString(node.inputs, "cloud_sql_instance_id") });
        try config.put(allocator, "database", .{ .string = try requiredString(node.inputs, "cloud_sql_database") });
        try config.put(allocator, "type", .{ .string = try requiredString(node.inputs, "cloud_sql_type") });
        try root.put(allocator, "cloudSql", .{ .object = config });
    } else return error.InvalidConfiguration;
}

fn reservationBody(allocator: std.mem.Allocator, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    try root.put(allocator, "slotCapacity", .{ .string = try integerStringAlloc(allocator, try requiredInteger(node.inputs, "slot_capacity")) });
    try putIntegerString(allocator, root, "maxSlots", try requiredInteger(node.inputs, "max_slots"));
    try root.put(allocator, "ignoreIdleSlots", .{ .bool = try requiredBool(node.inputs, "ignore_idle_slots") });
    try root.put(allocator, "edition", .{ .string = try requiredString(node.inputs, "edition") });
    try putNonEmpty(allocator, root, "secondaryLocation", try requiredString(node.inputs, "secondary_location"));
}

fn commitmentBody(allocator: std.mem.Allocator, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    try root.put(allocator, "slotCount", .{ .string = try integerStringAlloc(allocator, try requiredInteger(node.inputs, "slot_count")) });
    try root.put(allocator, "plan", .{ .string = try requiredString(node.inputs, "plan") });
    try root.put(allocator, "edition", .{ .string = try requiredString(node.inputs, "edition") });
    try putNonEmpty(allocator, root, "renewalPlan", try requiredString(node.inputs, "renewal_plan"));
}

fn assignmentBody(allocator: std.mem.Allocator, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    try root.put(allocator, "assignee", .{ .string = try requiredString(node.inputs, "assignee") });
    try root.put(allocator, "jobType", .{ .string = try requiredString(node.inputs, "job_type") });
}

fn resultFromJson(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    resource_kind: Kind,
    physical: []const u8,
    body: []const u8,
) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    if (!remoteIdentityMatches(root, resource_kind, physical)) return error.InvalidConfiguration;
    const matches = try remoteMatches(context.allocator, node, resource_kind, root);
    const drift_fields = [_]value.Field{.{ .name = "__remote_json", .value = .{ .string = body } }};
    const observed = if (matches) node.inputs else value.Value{ .object = &drift_fields };
    var outputs: [5]state.StateOutput = undefined;
    var count: usize = 0;
    outputs[count] = .{ .name = "name", .value = .{ .string = physical } };
    count += 1;
    switch (resource_kind) {
        .dataset => {
            outputs[count] = .{ .name = "etag", .value = .{ .string = jsonString(root.get("etag")) orelse "" } };
            count += 1;
            outputs[count] = .{ .name = "location", .value = .{ .string = jsonString(root.get("location")) orelse try requiredString(node.inputs, "location") } };
            count += 1;
        },
        .table => {
            outputs[count] = .{ .name = "etag", .value = .{ .string = jsonString(root.get("etag")) orelse "" } };
            count += 1;
            outputs[count] = .{ .name = "num_rows", .value = .{ .integer = jsonIntegerString(root.get("numRows")) } };
            count += 1;
            outputs[count] = .{ .name = "num_bytes", .value = .{ .integer = jsonIntegerString(root.get("numBytes")) } };
            count += 1;
        },
        .view, .routine => {
            outputs[count] = .{ .name = "etag", .value = .{ .string = jsonString(root.get("etag")) orelse "" } };
            count += 1;
        },
        .connection => {
            const cloud_resource = jsonObject(root.get("cloudResource") orelse .{ .object = .empty }) orelse return error.ProviderBug;
            outputs[count] = .{ .name = "service_account_id", .value = .{ .string = jsonString(cloud_resource.get("serviceAccountId")) orelse "" } };
            count += 1;
            outputs[count] = .{ .name = "has_credential", .value = .{ .boolean = jsonBool(root.get("hasCredential")) } };
            count += 1;
        },
        .reservation => {
            outputs[count] = .{ .name = "slot_capacity", .value = .{ .integer = jsonIntegerString(root.get("slotCapacity")) } };
            count += 1;
        },
        .commitment => {
            outputs[count] = .{ .name = "state", .value = .{ .string = jsonString(root.get("state")) orelse "STATE_UNSPECIFIED" } };
            count += 1;
        },
        .assignment => {},
    }
    return provider_mod.ResourceResult.init(context.allocator, physical, observed, outputs[0..count], null);
}

fn remoteIdentityMatches(root: std.json.ObjectMap, resource_kind: Kind, physical: []const u8) bool {
    if (resource_kind == .dataset) {
        const reference = jsonObject(root.get("datasetReference") orelse return false) orelse return false;
        return physicalEndsWith(reference, physical, "datasetId", "/datasets/");
    }
    if (resource_kind == .table or resource_kind == .view) {
        const reference = jsonObject(root.get("tableReference") orelse return false) orelse return false;
        return physicalEndsWith(reference, physical, "tableId", "/tables/");
    }
    if (resource_kind == .routine) {
        const reference = jsonObject(root.get("routineReference") orelse return false) orelse return false;
        return physicalEndsWith(reference, physical, "routineId", "/routines/");
    }
    return std.mem.eql(u8, jsonString(root.get("name")) orelse return false, physical);
}

fn physicalEndsWith(reference: std.json.ObjectMap, physical: []const u8, field: []const u8, delimiter: []const u8) bool {
    const id = jsonString(reference.get(field)) orelse return false;
    const index = std.mem.lastIndexOf(u8, physical, delimiter) orelse return false;
    return std.mem.eql(u8, physical[index + delimiter.len ..], id);
}

fn remoteMatches(allocator: std.mem.Allocator, node: resource.ResourceNode, resource_kind: Kind, remote: std.json.ObjectMap) ProviderError!bool {
    return switch (resource_kind) {
        .dataset => optionalStringEquals(remote.get("location"), try requiredString(node.inputs, "location")) and
            optionalStringEquals(remote.get("friendlyName"), try requiredString(node.inputs, "friendly_name")) and
            optionalStringEquals(remote.get("description"), try requiredString(node.inputs, "description")) and
            integerStringEquals(remote.get("defaultTableExpirationMs"), try requiredInteger(node.inputs, "default_table_expiration_ms")) and
            integerStringEquals(remote.get("defaultPartitionExpirationMs"), try requiredInteger(node.inputs, "default_partition_expiration_ms")) and
            try optionalJsonSourceEquals(allocator, remote.get("labels"), try requiredString(node.inputs, "labels_json")) and
            optionalStringEquals(nestedValue(remote, "defaultEncryptionConfiguration", "kmsKeyName"), try requiredString(node.inputs, "default_kms_key_name")),
        .table => optionalStringEquals(remote.get("friendlyName"), try requiredString(node.inputs, "friendly_name")) and
            optionalStringEquals(remote.get("description"), try requiredString(node.inputs, "description")) and
            try optionalJsonSourceEquals(allocator, nestedValue(remote, "schema", "fields"), try requiredString(node.inputs, "schema_json")) and
            jsonBool(remote.get("requirePartitionFilter")) == try requiredBool(node.inputs, "require_partition_filter") and
            integerStringEquals(remote.get("expirationTime"), try requiredInteger(node.inputs, "expiration_time_ms")) and
            optionalStringEquals(nestedValue(remote, "encryptionConfiguration", "kmsKeyName"), try requiredString(node.inputs, "kms_key_name")) and
            try timePartitionMatches(node, remote) and try clusteringMatches(node, remote),
        .view => try viewMatches(node, remote),
        .routine => optionalStringEquals(remote.get("routineType"), try requiredString(node.inputs, "routine_type")) and
            optionalStringEquals(remote.get("language"), try requiredString(node.inputs, "language")) and
            optionalStringEquals(remote.get("definitionBody"), try requiredString(node.inputs, "definition_body")) and
            optionalStringEquals(remote.get("description"), try requiredString(node.inputs, "description")) and
            try optionalJsonSourceEquals(allocator, remote.get("arguments"), try requiredString(node.inputs, "arguments_json")) and
            try optionalJsonSourceEquals(allocator, remote.get("returnType"), try requiredString(node.inputs, "return_type_json")),
        .connection => optionalStringEquals(remote.get("friendlyName"), try requiredString(node.inputs, "friendly_name")) and
            optionalStringEquals(remote.get("description"), try requiredString(node.inputs, "description")) and try connectionKindMatches(node, remote),
        .reservation => integerStringEquals(remote.get("slotCapacity"), try requiredInteger(node.inputs, "slot_capacity")) and
            integerStringEquals(remote.get("maxSlots"), try requiredInteger(node.inputs, "max_slots")) and
            jsonBool(remote.get("ignoreIdleSlots")) == try requiredBool(node.inputs, "ignore_idle_slots") and
            optionalStringEquals(remote.get("edition"), try requiredString(node.inputs, "edition")) and
            optionalStringEquals(remote.get("secondaryLocation"), try requiredString(node.inputs, "secondary_location")),
        .commitment => integerStringEquals(remote.get("slotCount"), try requiredInteger(node.inputs, "slot_count")) and
            optionalStringEquals(remote.get("plan"), try requiredString(node.inputs, "plan")) and
            optionalStringEquals(remote.get("edition"), try requiredString(node.inputs, "edition")),
        .assignment => optionalStringEquals(remote.get("assignee"), try requiredString(node.inputs, "assignee")) and
            optionalStringEquals(remote.get("jobType"), try requiredString(node.inputs, "job_type")),
    };
}

fn timePartitionMatches(node: resource.ResourceNode, remote: std.json.ObjectMap) ProviderError!bool {
    const expected_type = try requiredString(node.inputs, "partition_type");
    const partition = jsonObject(remote.get("timePartitioning") orelse return expected_type.len == 0) orelse return false;
    return optionalStringEquals(partition.get("type"), expected_type) and
        optionalStringEquals(partition.get("field"), try requiredString(node.inputs, "partition_field")) and
        integerStringEquals(partition.get("expirationMs"), try requiredInteger(node.inputs, "partition_expiration_ms"));
}

fn clusteringMatches(node: resource.ResourceNode, remote: std.json.ObjectMap) ProviderError!bool {
    const expected = try requiredList(node.inputs, "clustering_fields");
    const clustering = jsonObject(remote.get("clustering") orelse return expected.len == 0) orelse return false;
    const fields = switch (clustering.get("fields") orelse return expected.len == 0) {
        .array => |array| array.items,
        else => return false,
    };
    if (fields.len != expected.len) return false;
    for (fields, expected) |actual, desired| {
        if (!std.mem.eql(u8, jsonString(actual) orelse return false, stringValue(desired) orelse return false)) return false;
    }
    return true;
}

fn viewMatches(node: resource.ResourceNode, remote: std.json.ObjectMap) ProviderError!bool {
    const materialized = try requiredBool(node.inputs, "materialized");
    const definition = jsonObject(remote.get(if (materialized) "materializedView" else "view") orelse return false) orelse return false;
    return optionalStringEquals(definition.get("query"), try requiredString(node.inputs, "query")) and
        (!materialized or
            (jsonBool(definition.get("enableRefresh")) == try requiredBool(node.inputs, "enable_refresh") and
                integerStringEquals(definition.get("refreshIntervalMs"), try requiredInteger(node.inputs, "refresh_interval_ms"))));
}

fn connectionKindMatches(node: resource.ResourceNode, remote: std.json.ObjectMap) ProviderError!bool {
    const desired = try requiredString(node.inputs, "kind");
    if (std.mem.eql(u8, desired, "cloud_resource")) return remote.get("cloudResource") != null;
    if (std.mem.eql(u8, desired, "cloud_spanner")) return remote.get("cloudSpanner") != null;
    if (std.mem.eql(u8, desired, "cloud_sql")) return remote.get("cloudSql") != null;
    return false;
}

fn optionalJsonSourceEquals(allocator: std.mem.Allocator, actual: ?std.json.Value, source: []const u8) ProviderError!bool {
    if (source.len == 0) return actual == null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, source, .{}) catch return error.InvalidConfiguration;
    defer parsed.deinit();
    const present = actual orelse return jsonEmpty(parsed.value);
    return jsonValuesEqual(present, parsed.value);
}

fn jsonEmpty(input: std.json.Value) bool {
    return switch (input) {
        .object => |object| object.count() == 0,
        .array => |array| array.items.len == 0,
        else => false,
    };
}

fn jsonValuesEqual(left: std.json.Value, right: std.json.Value) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .null => true,
        .bool => |value_bool| value_bool == right.bool,
        .integer => |number| number == right.integer,
        .float => |number| number == right.float,
        .number_string => |text| std.mem.eql(u8, text, right.number_string),
        .string => |text| std.mem.eql(u8, text, right.string),
        .array => |array| blk: {
            if (array.items.len != right.array.items.len) break :blk false;
            for (array.items, right.array.items) |a, b| if (!jsonValuesEqual(a, b)) break :blk false;
            break :blk true;
        },
        .object => |object| blk: {
            if (object.count() != right.object.count()) break :blk false;
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const other = right.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!jsonValuesEqual(entry.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn nestedValue(root: std.json.ObjectMap, object_name: []const u8, field_name: []const u8) ?std.json.Value {
    const object = jsonObject(root.get(object_name) orelse return null) orelse return null;
    return object.get(field_name);
}

fn outputString(result: *const provider_mod.ResourceResult, name: []const u8) ?[]const u8 {
    for (result.outputs) |entry| if (std.mem.eql(u8, entry.name, name)) return switch (entry.value) {
        .string => |text| if (text.len > 0) text else null,
        else => null,
    };
    return null;
}

fn identityChanged(node: resource.ResourceNode, observed: value.Value) bool {
    const resource_kind = kind(node) orelse return true;
    const fields: []const []const u8 = switch (resource_kind) {
        .dataset => &.{ "project_id", "dataset_id", "location" },
        .table => &.{ "project_id", "dataset_id", "table_id" },
        .view => &.{ "project_id", "dataset_id", "view_id", "materialized" },
        .routine => &.{ "project_id", "dataset_id", "routine_id", "routine_type", "language" },
        .connection => &.{ "project_id", "location", "connection_id", "kind" },
        .reservation => &.{ "project_id", "location", "reservation_id" },
        .commitment => &.{ "project_id", "location", "commitment_id", "slot_count", "plan", "edition" },
        .assignment => &.{ "project_id", "location", "assignee", "job_type" },
    };
    for (fields) |field| if (!valueFieldEquals(node.inputs, observed, field)) return true;
    return false;
}

fn valueFieldEquals(left: value.Value, right: value.Value, name: []const u8) bool {
    const a = requiredValue(left, name) catch return false;
    const b = requiredValue(right, name) catch return false;
    return switch (a) {
        .string => |text| switch (b) {
            .string => |other| std.mem.eql(u8, text, other),
            else => false,
        },
        .integer => |number| switch (b) {
            .integer => |other| number == other,
            else => false,
        },
        .boolean => |boolean| switch (b) {
            .boolean => |other| boolean == other,
            else => false,
        },
        else => false,
    };
}

fn jsonNameAlloc(allocator: std.mem.Allocator, body: []const u8) ProviderError![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    return allocator.dupe(u8, jsonString(root.get("name")) orelse return error.ProviderBug) catch error.OutOfMemory;
}

fn putNonEmpty(allocator: std.mem.Allocator, object: *std.json.ObjectMap, name: []const u8, text: []const u8) ProviderError!void {
    if (text.len > 0) try object.put(allocator, name, .{ .string = text });
}

fn putIntegerString(allocator: std.mem.Allocator, object: *std.json.ObjectMap, name: []const u8, number: i64) ProviderError!void {
    if (number > 0) try object.put(allocator, name, .{ .string = try integerStringAlloc(allocator, number) });
}

fn integerStringAlloc(allocator: std.mem.Allocator, number: i64) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{number}) catch error.OutOfMemory;
}

fn putParsed(allocator: std.mem.Allocator, object: *std.json.ObjectMap, name: []const u8, source: []const u8) ProviderError!void {
    const parsed = try parseJson(allocator, source);
    if (parsed == .object and parsed.object.count() == 0) return;
    try object.put(allocator, name, parsed);
}

fn parseJson(allocator: std.mem.Allocator, source: []const u8) ProviderError!std.json.Value {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, source, .{}) catch return error.InvalidConfiguration;
    return parsed.value;
}

fn requiredValue(input: value.Value, name: []const u8) ProviderError!value.Value {
    if (input != .object) return error.InvalidConfiguration;
    for (input.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return error.InvalidConfiguration;
}

fn requiredString(input: value.Value, name: []const u8) ProviderError![]const u8 {
    return switch (try requiredValue(input, name)) {
        .string => |text| text,
        else => error.InvalidConfiguration,
    };
}

fn requiredInteger(input: value.Value, name: []const u8) ProviderError!i64 {
    return switch (try requiredValue(input, name)) {
        .integer => |number| number,
        else => error.InvalidConfiguration,
    };
}

fn requiredBool(input: value.Value, name: []const u8) ProviderError!bool {
    return switch (try requiredValue(input, name)) {
        .boolean => |boolean| boolean,
        else => error.InvalidConfiguration,
    };
}

fn requiredList(input: value.Value, name: []const u8) ProviderError![]const value.Value {
    return switch (try requiredValue(input, name)) {
        .list => |items| items,
        else => error.InvalidConfiguration,
    };
}

fn resolveString(context: *provider_mod.OperationContext, input: value.Value) ProviderError![]const u8 {
    return switch (input) {
        .string => |text| text,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}

fn stringValue(input: value.Value) ?[]const u8 {
    return switch (input) {
        .string => |text| text,
        else => null,
    };
}

fn optionalStringEquals(input: ?std.json.Value, expected: []const u8) bool {
    return std.mem.eql(u8, jsonString(input) orelse "", expected);
}

fn integerStringEquals(input: ?std.json.Value, expected: i64) bool {
    return jsonIntegerString(input) == expected;
}

fn jsonIntegerString(input: ?std.json.Value) i64 {
    const present = input orelse return 0;
    return switch (present) {
        .string => |text| std.fmt.parseInt(i64, text, 10) catch 0,
        .integer => |number| number,
        else => 0,
    };
}

fn jsonObject(input: std.json.Value) ?std.json.ObjectMap {
    return switch (input) {
        .object => |object| object,
        else => null,
    };
}

fn jsonString(input: ?std.json.Value) ?[]const u8 {
    const present = input orelse return null;
    return switch (present) {
        .string => |text| text,
        else => null,
    };
}

fn jsonBool(input: ?std.json.Value) bool {
    const present = input orelse return false;
    return switch (present) {
        .bool => |boolean| boolean,
        else => false,
    };
}
