const std = @import("std");
const local_state = @import("local_state.zig");

pub const Source = enum {
    compiler,
    process,
    proxy,
    provider,
    cloud_run,
    load_balancer,
    cockroach,
    health,
    test_runner,
    agent,
    repair,
};

pub const Stream = enum { stdout, stderr, system };

pub const Severity = enum(u8) { trace, debug, info, warn, err, critical };

pub const Field = struct {
    name: []const u8,
    value: []const u8,
    secret: bool = false,
};

pub const EventInput = struct {
    event_id: []const u8,
    parent_event_id: ?[]const u8 = null,
    timestamp_millis: i64,
    source: Source,
    stream: Stream,
    severity: Severity,
    message: []const u8,
    session_id: ?[]const u8 = null,
    stack: ?[]const u8 = null,
    stage: ?[]const u8 = null,
    resource_id: ?[]const u8 = null,
    region: ?[]const u8 = null,
    revision: ?[]const u8 = null,
    trace_id: ?[]const u8 = null,
    span_id: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
    operation_id: ?[]const u8 = null,
    fields: []const Field = &.{},
};

pub const Event = struct {
    sequence: u64,
    event_id: []const u8,
    parent_event_id: ?[]const u8,
    timestamp_millis: i64,
    source: Source,
    stream: Stream,
    severity: Severity,
    message: []const u8,
    session_id: ?[]const u8,
    stack: ?[]const u8,
    stage: ?[]const u8,
    resource_id: ?[]const u8,
    region: ?[]const u8,
    revision: ?[]const u8,
    trace_id: ?[]const u8,
    span_id: ?[]const u8,
    request_id: ?[]const u8,
    operation_id: ?[]const u8,
    fields: []const Field,
    truncated: bool,
    bytes: usize,
};

pub const Options = struct {
    max_events: usize = 4096,
    max_bytes: usize = 8 * 1024 * 1024,
    max_message_bytes: usize = 16 * 1024,
};

pub const Filter = struct {
    session_id: ?[]const u8 = null,
    resource_id: ?[]const u8 = null,
    region: ?[]const u8 = null,
    trace_id: ?[]const u8 = null,
    minimum_severity: ?Severity = null,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    options: Options,
    events: std.ArrayList(Event) = .empty,
    next_sequence: u64 = 1,
    bytes: usize = 0,
    dropped_count: u64 = 0,
    suppressed_count: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, options: Options) Store {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn deinit(self: *Store) void {
        for (self.events.items) |event| deinitEvent(self.allocator, event);
        self.events.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn append(self: *Store, input: EventInput) std.mem.Allocator.Error!void {
        if (self.find(input.event_id) != null) {
            self.suppressed_count += 1;
            return;
        }
        const event = try initEvent(self.allocator, self.next_sequence, input, self.options.max_message_bytes);
        errdefer deinitEvent(self.allocator, event);
        self.next_sequence += 1;
        try self.events.append(self.allocator, event);
        self.bytes += event.bytes;
        while (self.events.items.len > self.options.max_events or self.bytes > self.options.max_bytes) {
            const dropped = self.events.orderedRemove(0);
            self.bytes -= dropped.bytes;
            self.dropped_count += 1;
            deinitEvent(self.allocator, dropped);
        }
    }

    pub fn find(self: *const Store, id: []const u8) ?*const Event {
        for (self.events.items) |*event| if (std.mem.eql(u8, event.event_id, id)) return event;
        return null;
    }

    pub fn jsonLinesAlloc(self: *const Store, allocator: std.mem.Allocator, filter: Filter) std.mem.Allocator.Error![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        for (self.events.items) |event| {
            if (!matches(event, filter)) continue;
            const line = std.json.Stringify.valueAlloc(allocator, .{
                .schema = "ziac.log.v1",
                .sequence = event.sequence,
                .event_id = event.event_id,
                .parent_event_id = event.parent_event_id,
                .timestamp_millis = event.timestamp_millis,
                .source = event.source,
                .stream = event.stream,
                .severity = event.severity,
                .message = event.message,
                .session_id = event.session_id,
                .stack = event.stack,
                .stage = event.stage,
                .resource_id = event.resource_id,
                .region = event.region,
                .revision = event.revision,
                .trace_id = event.trace_id,
                .span_id = event.span_id,
                .request_id = event.request_id,
                .operation_id = event.operation_id,
                .fields = event.fields,
                .truncated = event.truncated,
                .dropped_count = self.dropped_count,
                .suppressed_count = self.suppressed_count,
            }, .{}) catch return error.OutOfMemory;
            defer allocator.free(line);
            try output.appendSlice(allocator, line);
            try output.append(allocator, '\n');
        }
        return output.toOwnedSlice(allocator);
    }

    pub fn explainJsonAlloc(self: *const Store, allocator: std.mem.Allocator, event_id: []const u8) (std.mem.Allocator.Error || error{EventNotFound})![]u8 {
        var chain: std.ArrayList(Event) = .empty;
        defer chain.deinit(allocator);
        var current = self.find(event_id) orelse return error.EventNotFound;
        while (chain.items.len <= self.events.items.len) {
            try chain.append(allocator, current.*);
            const parent = current.parent_event_id orelse break;
            if (containsEvent(chain.items, parent)) break;
            current = self.find(parent) orelse break;
        }
        return std.json.Stringify.valueAlloc(allocator, .{
            .schema = "ziac.log-explanation.v1",
            .event_id = event_id,
            .chain = chain.items,
            .complete = chain.items.len > 0 and chain.items[chain.items.len - 1].parent_event_id == null,
            .dropped_count = self.dropped_count,
        }, .{}) catch return error.OutOfMemory;
    }
};

pub const CloudBatch = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    events: []const Event,
    next_cursor: ?[]const u8,

    pub fn deinit(self: *CloudBatch) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.* = undefined;
    }
};

pub const SessionStore = struct {
    allocator: std.mem.Allocator,
    files: local_state.FileStore,
    options: Options = .{},

    pub fn init(allocator: std.mem.Allocator, files: local_state.FileStore, options: Options) SessionStore {
        return .{ .allocator = allocator, .files = files, .options = options };
    }

    pub fn pathAlloc(self: SessionStore, stack: []const u8, stage: []const u8) std.mem.Allocator.Error![]u8 {
        return std.fmt.allocPrint(self.allocator, ".ziac/logs/{s}/{s}/events.jsonl", .{ stack, stage });
    }

    pub fn save(self: SessionStore, stack: []const u8, stage: []const u8, events: *const Store) !void {
        const path = try self.pathAlloc(stack, stage);
        defer self.allocator.free(path);
        const content = try events.jsonLinesAlloc(self.allocator, .{});
        defer self.allocator.free(content);
        try self.files.atomicWriteFile(self.allocator, path, content);
    }

    pub fn load(self: SessionStore, stack: []const u8, stage: []const u8) !Store {
        const path = try self.pathAlloc(stack, stage);
        defer self.allocator.free(path);
        const content = self.files.readFileAllocBounded(self.allocator, path, self.options.max_bytes + 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return error.MissingLogSession,
            else => return err,
        };
        defer self.allocator.free(content);
        return parseJsonLinesAlloc(self.allocator, content, self.options);
    }
};

const LineSnapshot = struct {
    schema: []const u8,
    sequence: u64,
    event_id: []const u8,
    parent_event_id: ?[]const u8,
    timestamp_millis: i64,
    source: Source,
    stream: Stream,
    severity: Severity,
    message: []const u8,
    session_id: ?[]const u8,
    stack: ?[]const u8,
    stage: ?[]const u8,
    resource_id: ?[]const u8,
    region: ?[]const u8,
    revision: ?[]const u8,
    trace_id: ?[]const u8,
    span_id: ?[]const u8,
    request_id: ?[]const u8,
    operation_id: ?[]const u8,
    fields: []const Field,
    truncated: bool,
    dropped_count: u64,
    suppressed_count: u64,
};

pub fn parseJsonLinesAlloc(allocator: std.mem.Allocator, bytes: []const u8, options: Options) !Store {
    var store = Store.init(allocator, options);
    errdefer store.deinit();
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var parsed = std.json.parseFromSlice(LineSnapshot, allocator, line, .{}) catch return error.InvalidLogSession;
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.schema, "ziac.log.v1")) return error.InvalidLogSession;
        try store.append(.{
            .event_id = parsed.value.event_id,
            .parent_event_id = parsed.value.parent_event_id,
            .timestamp_millis = parsed.value.timestamp_millis,
            .source = parsed.value.source,
            .stream = parsed.value.stream,
            .severity = parsed.value.severity,
            .message = parsed.value.message,
            .session_id = parsed.value.session_id,
            .stack = parsed.value.stack,
            .stage = parsed.value.stage,
            .resource_id = parsed.value.resource_id,
            .region = parsed.value.region,
            .revision = parsed.value.revision,
            .trace_id = parsed.value.trace_id,
            .span_id = parsed.value.span_id,
            .request_id = parsed.value.request_id,
            .operation_id = parsed.value.operation_id,
            .fields = parsed.value.fields,
        });
        if (store.events.items.len > 0) store.events.items[store.events.items.len - 1].sequence = parsed.value.sequence;
        store.next_sequence = @max(store.next_sequence, parsed.value.sequence + 1);
        store.dropped_count = @max(store.dropped_count, parsed.value.dropped_count);
        store.suppressed_count = @max(store.suppressed_count, parsed.value.suppressed_count);
    }
    return store;
}

pub fn cloudLoggingListRequestJsonAlloc(
    allocator: std.mem.Allocator,
    project_id: []const u8,
    filter: []const u8,
    cursor: ?[]const u8,
) std.mem.Allocator.Error![]u8 {
    const resource_name = try std.fmt.allocPrint(allocator, "projects/{s}", .{project_id});
    defer allocator.free(resource_name);
    return std.json.Stringify.valueAlloc(allocator, .{
        .resourceNames = &.{resource_name},
        .filter = filter,
        .orderBy = "timestamp asc",
        .pageSize = @as(u16, 1000),
        .pageToken = cursor,
    }, .{}) catch return error.OutOfMemory;
}

pub const CloudLoggingClient = struct {
    ptr: *anyopaque,
    list_fn: *const fn (*anyopaque, []const u8) anyerror![]const u8,

    pub fn list(self: CloudLoggingClient, request_json: []const u8) ![]const u8 {
        return self.list_fn(self.ptr, request_json);
    }
};

pub const PollerOptions = struct {
    project_id: []const u8,
    filter: []const u8,
    session_id: []const u8,
};

pub const CloudLoggingPoller = struct {
    allocator: std.mem.Allocator,
    client: CloudLoggingClient,
    project_id: []const u8,
    filter: []const u8,
    session_id: []const u8,
    cursor: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, client: CloudLoggingClient, options: PollerOptions) CloudLoggingPoller {
        return .{
            .allocator = allocator,
            .client = client,
            .project_id = options.project_id,
            .filter = options.filter,
            .session_id = options.session_id,
        };
    }

    pub fn deinit(self: *CloudLoggingPoller) void {
        if (self.cursor) |cursor| self.allocator.free(cursor);
        self.* = undefined;
    }

    pub fn pollAlloc(self: *CloudLoggingPoller) !CloudBatch {
        const request = try cloudLoggingListRequestJsonAlloc(self.allocator, self.project_id, self.filter, self.cursor);
        defer self.allocator.free(request);
        const response = try self.client.list(request);
        var batch = try parseCloudLoggingResponseAlloc(self.allocator, response, self.session_id);
        errdefer batch.deinit();
        const next_cursor = if (batch.next_cursor) |cursor| try self.allocator.dupe(u8, cursor) else null;
        if (self.cursor) |cursor| self.allocator.free(cursor);
        self.cursor = next_cursor;
        return batch;
    }
};

pub const ScriptedCloudLoggingClient = struct {
    response: []const u8,
    call_count: usize = 0,
    last_request_buffer: [4096]u8 = undefined,
    last_request: ?[]const u8 = null,

    pub fn init(response: []const u8) ScriptedCloudLoggingClient {
        return .{ .response = response };
    }

    pub fn client(self: *ScriptedCloudLoggingClient) CloudLoggingClient {
        return .{ .ptr = self, .list_fn = list };
    }

    fn list(raw: *anyopaque, request_json: []const u8) ![]const u8 {
        const self: *ScriptedCloudLoggingClient = @ptrCast(@alignCast(raw));
        if (request_json.len > self.last_request_buffer.len) return error.RequestTooLarge;
        @memcpy(self.last_request_buffer[0..request_json.len], request_json);
        self.last_request = self.last_request_buffer[0..request_json.len];
        self.call_count += 1;
        return self.response;
    }
};

pub fn parseCloudLoggingResponseAlloc(allocator: std.mem.Allocator, bytes: []const u8, session_id: []const u8) !CloudBatch {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch return error.InvalidCloudLoggingResponse;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.InvalidCloudLoggingResponse;
    const values = if (root.get("entries")) |entries| jsonArray(entries) orelse return error.InvalidCloudLoggingResponse else &.{};
    const events = try a.alloc(Event, values.len);
    for (values, 0..) |value, index| {
        const entry = jsonObject(value) orelse return error.InvalidCloudLoggingResponse;
        const labels = if (entry.get("resource")) |resource_value|
            if (jsonObject(resource_value)) |resource_object|
                if (resource_object.get("labels")) |label_value| jsonObject(label_value) else null
            else
                null
        else
            null;
        const trace = optionalString(entry, "trace");
        const message = optionalString(entry, "textPayload") orelse messageFromJsonPayload(entry) orelse "Cloud Logging entry";
        events[index] = .{
            .sequence = @intCast(index + 1),
            .event_id = try a.dupe(u8, optionalString(entry, "insertId") orelse "cloud-entry"),
            .parent_event_id = null,
            .timestamp_millis = 0,
            .source = .cloud_run,
            .stream = .system,
            .severity = parseSeverity(optionalString(entry, "severity") orelse "DEFAULT"),
            .message = try a.dupe(u8, message),
            .session_id = try a.dupe(u8, session_id),
            .stack = null,
            .stage = null,
            .resource_id = if (labels) |map| try optionalDupe(a, optionalString(map, "service_name")) else null,
            .region = if (labels) |map| try optionalDupe(a, optionalString(map, "location")) else null,
            .revision = if (labels) |map| try optionalDupe(a, optionalString(map, "revision_name")) else null,
            .trace_id = try optionalDupe(a, if (trace) |value_trace| std.fs.path.basename(value_trace) else null),
            .span_id = try optionalDupe(a, optionalString(entry, "spanId")),
            .request_id = null,
            .operation_id = null,
            .fields = &.{},
            .truncated = false,
            .bytes = message.len,
        };
    }
    return .{
        .allocator = allocator,
        .arena = arena,
        .events = events,
        .next_cursor = try optionalDupe(a, optionalString(root, "nextPageToken")),
    };
}

fn initEvent(allocator: std.mem.Allocator, sequence: u64, input: EventInput, max_message_bytes: usize) std.mem.Allocator.Error!Event {
    const event_id = try allocator.dupe(u8, input.event_id);
    errdefer allocator.free(event_id);
    const parent_event_id = try optionalDupe(allocator, input.parent_event_id);
    errdefer freeOptional(allocator, parent_event_id);
    const redacted_message = try redactMessageAlloc(allocator, input.message);
    defer allocator.free(redacted_message);
    const message_len = @min(redacted_message.len, max_message_bytes);
    const message = try allocator.dupe(u8, redacted_message[0..message_len]);
    errdefer allocator.free(message);
    const fields = try allocator.alloc(Field, input.fields.len);
    errdefer allocator.free(fields);
    var field_count: usize = 0;
    errdefer for (fields[0..field_count]) |field| {
        allocator.free(field.name);
        allocator.free(field.value);
    };
    for (input.fields, 0..) |field, index| {
        const name = try allocator.dupe(u8, field.name);
        errdefer allocator.free(name);
        const secret = field.secret or secretFieldName(field.name);
        const value = try allocator.dupe(u8, if (secret) "[REDACTED]" else field.value);
        fields[index] = .{ .name = name, .value = value, .secret = secret };
        field_count += 1;
    }
    const session_id = try optionalDupe(allocator, input.session_id);
    errdefer freeOptional(allocator, session_id);
    const stack = try optionalDupe(allocator, input.stack);
    errdefer freeOptional(allocator, stack);
    const stage = try optionalDupe(allocator, input.stage);
    errdefer freeOptional(allocator, stage);
    const resource_id = try optionalDupe(allocator, input.resource_id);
    errdefer freeOptional(allocator, resource_id);
    const region = try optionalDupe(allocator, input.region);
    errdefer freeOptional(allocator, region);
    const revision = try optionalDupe(allocator, input.revision);
    errdefer freeOptional(allocator, revision);
    const trace_id = try optionalDupe(allocator, input.trace_id);
    errdefer freeOptional(allocator, trace_id);
    const span_id = try optionalDupe(allocator, input.span_id);
    errdefer freeOptional(allocator, span_id);
    const request_id = try optionalDupe(allocator, input.request_id);
    errdefer freeOptional(allocator, request_id);
    const operation_id = try optionalDupe(allocator, input.operation_id);
    errdefer freeOptional(allocator, operation_id);
    var total_bytes = event_id.len + message.len;
    for (fields) |field| total_bytes += field.name.len + field.value.len;
    return .{
        .sequence = sequence,
        .event_id = event_id,
        .parent_event_id = parent_event_id,
        .timestamp_millis = input.timestamp_millis,
        .source = input.source,
        .stream = input.stream,
        .severity = input.severity,
        .message = message,
        .session_id = session_id,
        .stack = stack,
        .stage = stage,
        .resource_id = resource_id,
        .region = region,
        .revision = revision,
        .trace_id = trace_id,
        .span_id = span_id,
        .request_id = request_id,
        .operation_id = operation_id,
        .fields = fields,
        .truncated = message_len != redacted_message.len,
        .bytes = total_bytes,
    };
}

fn deinitEvent(allocator: std.mem.Allocator, event: Event) void {
    allocator.free(event.event_id);
    freeOptional(allocator, event.parent_event_id);
    allocator.free(event.message);
    freeOptional(allocator, event.session_id);
    freeOptional(allocator, event.stack);
    freeOptional(allocator, event.stage);
    freeOptional(allocator, event.resource_id);
    freeOptional(allocator, event.region);
    freeOptional(allocator, event.revision);
    freeOptional(allocator, event.trace_id);
    freeOptional(allocator, event.span_id);
    freeOptional(allocator, event.request_id);
    freeOptional(allocator, event.operation_id);
    for (event.fields) |field| {
        allocator.free(field.name);
        allocator.free(field.value);
    }
    allocator.free(event.fields);
}

fn matches(event: Event, filter: Filter) bool {
    if (filter.session_id) |value| if (!optionalEqual(event.session_id, value)) return false;
    if (filter.resource_id) |value| if (!optionalEqual(event.resource_id, value)) return false;
    if (filter.region) |value| if (!optionalEqual(event.region, value)) return false;
    if (filter.trace_id) |value| if (!optionalEqual(event.trace_id, value)) return false;
    if (filter.minimum_severity) |value| if (@intFromEnum(event.severity) < @intFromEnum(value)) return false;
    return true;
}

fn secretFieldName(name: []const u8) bool {
    return containsIgnoreCase(name, "secret") or containsIgnoreCase(name, "token") or
        containsIgnoreCase(name, "password") or containsIgnoreCase(name, "database_url") or
        containsIgnoreCase(name, "authorization");
}

fn redactMessageAlloc(allocator: std.mem.Allocator, message: []const u8) std.mem.Allocator.Error![]u8 {
    const sensitive = containsIgnoreCase(message, "authorization=") or
        containsIgnoreCase(message, "password=") or
        containsIgnoreCase(message, "token=") or
        containsIgnoreCase(message, "secret=") or
        containsIgnoreCase(message, "postgres://") or
        containsIgnoreCase(message, "postgresql://") or
        containsIgnoreCase(message, "sentinel-secret");
    return allocator.dupe(u8, if (sensitive) "[REDACTED]" else message);
}

fn containsIgnoreCase(value: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or value.len < needle.len) return false;
    var index: usize = 0;
    while (index + needle.len <= value.len) : (index += 1) {
        if (std.ascii.eqlIgnoreCase(value[index .. index + needle.len], needle)) return true;
    }
    return false;
}

fn optionalDupe(allocator: std.mem.Allocator, value: ?[]const u8) std.mem.Allocator.Error!?[]const u8 {
    return if (value) |present| try allocator.dupe(u8, present) else null;
}

fn freeOptional(allocator: std.mem.Allocator, value: ?[]const u8) void {
    if (value) |present| allocator.free(present);
}

fn optionalEqual(value: ?[]const u8, expected: []const u8) bool {
    return if (value) |present| std.mem.eql(u8, present, expected) else false;
}

fn containsEvent(events: []const Event, id: []const u8) bool {
    for (events) |event| if (std.mem.eql(u8, event.event_id, id)) return true;
    return false;
}

fn jsonObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn jsonArray(value: std.json.Value) ?[]std.json.Value {
    return switch (value) {
        .array => |array| array.items,
        else => null,
    };
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn messageFromJsonPayload(entry: std.json.ObjectMap) ?[]const u8 {
    const payload = entry.get("jsonPayload") orelse return null;
    const object = jsonObject(payload) orelse return null;
    return optionalString(object, "message");
}

fn parseSeverity(value: []const u8) Severity {
    if (std.ascii.eqlIgnoreCase(value, "DEBUG")) return .debug;
    if (std.ascii.eqlIgnoreCase(value, "INFO") or std.ascii.eqlIgnoreCase(value, "NOTICE") or std.ascii.eqlIgnoreCase(value, "DEFAULT")) return .info;
    if (std.ascii.eqlIgnoreCase(value, "WARNING")) return .warn;
    if (std.ascii.eqlIgnoreCase(value, "ERROR")) return .err;
    if (std.ascii.eqlIgnoreCase(value, "CRITICAL") or std.ascii.eqlIgnoreCase(value, "ALERT") or std.ascii.eqlIgnoreCase(value, "EMERGENCY")) return .critical;
    return .info;
}
