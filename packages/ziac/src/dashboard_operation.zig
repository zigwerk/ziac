const std = @import("std");
const zstd = @import("zigeffect_std");

pub const Kind = enum { plan, apply, watch, cancel, status };
pub const Provider = enum { fake, gcp };
pub const Phase = enum { queued, running, cancelling, cancelled, succeeded, failed };
pub const max_diagnostic_bytes: usize = 2048;

pub const Registry = struct {
    allocator: std.mem.Allocator,
    mutex: SpinLock = .{},
    next_id: u64 = 1,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        id: []u8,
        kind: Kind,
        project: []u8,
        stack: []u8,
        stage: []u8,
        phase: Phase,
        started_at_millis: u64,
        finished_at_millis: ?u64 = null,
        exit_code: ?u8 = null,
        diagnostic: ?[]u8 = null,
        process_id: ?usize = null,

        fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
            allocator.free(self.id);
            allocator.free(self.project);
            allocator.free(self.stack);
            allocator.free(self.stage);
            if (self.diagnostic) |value| allocator.free(value);
        }
    };

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        self.mutex.lock();
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.mutex.unlock();
        self.* = undefined;
    }

    pub fn register(self: *Registry, kind: Kind, project: []const u8, stack: []const u8, stage: []const u8, started_at_millis: u64) ![]u8 {
        if (kind != .apply and kind != .watch) return error.InvalidOperationRequest;
        self.mutex.lock();
        defer self.mutex.unlock();
        const id = try std.fmt.allocPrint(self.allocator, "op-{d:0>8}", .{self.next_id});
        errdefer self.allocator.free(id);
        self.next_id += 1;
        try self.entries.append(self.allocator, .{
            .id = id,
            .kind = kind,
            .project = try self.allocator.dupe(u8, project),
            .stack = try self.allocator.dupe(u8, stack),
            .stage = try self.allocator.dupe(u8, stage),
            .phase = .queued,
            .started_at_millis = started_at_millis,
        });
        return self.allocator.dupe(u8, id);
    }

    pub fn markRunning(self: *Registry, id: []const u8, started_at_millis: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.findEntry(id) orelse return error.UnknownDashboardOperation;
        if (entry.phase != .queued) return error.InvalidOperationTransition;
        entry.phase = .running;
        entry.started_at_millis = started_at_millis;
    }

    pub fn requestCancel(self: *Registry, id: []const u8) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.findEntry(id) orelse return false;
        switch (entry.phase) {
            .queued, .running => {
                entry.phase = .cancelling;
                return true;
            },
            .cancelling => return true,
            .cancelled, .succeeded, .failed => return false,
        }
    }

    pub fn finish(self: *Registry, id: []const u8, terminal_phase: Phase, finished_at_millis: u64, exit_code: ?u8, diagnostic: ?[]const u8) !void {
        if (terminal_phase != .cancelled and terminal_phase != .succeeded and terminal_phase != .failed) return error.InvalidOperationTransition;
        const safe_diagnostic = if (diagnostic) |value| try boundedDiagnosticAlloc(self.allocator, value) else null;
        errdefer if (safe_diagnostic) |value| self.allocator.free(value);
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.findEntry(id) orelse return error.UnknownDashboardOperation;
        if (entry.diagnostic) |value| self.allocator.free(value);
        entry.phase = terminal_phase;
        entry.finished_at_millis = finished_at_millis;
        entry.exit_code = exit_code;
        entry.diagnostic = safe_diagnostic;
    }

    pub fn phase(self: *Registry, id: []const u8) ?Phase {
        self.mutex.lock();
        defer self.mutex.unlock();
        return if (self.findEntry(id)) |entry| entry.phase else null;
    }

    pub fn setProcessId(self: *Registry, id: []const u8, process_id: usize) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.findEntry(id) orelse return error.UnknownDashboardOperation;
        entry.process_id = process_id;
    }

    pub fn processId(self: *Registry, id: []const u8) ?usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return if (self.findEntry(id)) |entry| entry.process_id else null;
    }

    pub fn serializeAlloc(self: *Registry, id: []const u8) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.findEntry(id) orelse return error.UnknownDashboardOperation;
        return std.json.Stringify.valueAlloc(self.allocator, .{
            .schema = "ziac.dashboard-operation.v1",
            .operation_id = entry.id,
            .kind = @tagName(entry.kind),
            .phase = @tagName(entry.phase),
            .project = entry.project,
            .stack = entry.stack,
            .stage = entry.stage,
            .started_at_millis = entry.started_at_millis,
            .finished_at_millis = entry.finished_at_millis,
            .exit_code = entry.exit_code,
            .diagnostic = entry.diagnostic,
        }, .{ .emit_null_optional_fields = false });
    }

    fn findEntry(self: *Registry, id: []const u8) ?*Entry {
        for (self.entries.items) |*entry| if (std.mem.eql(u8, entry.id, id)) return entry;
        return null;
    }
};

const SpinLock = struct {
    state: std.atomic.Mutex = .unlocked,

    fn lock(self: *SpinLock) void {
        while (!self.state.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *SpinLock) void {
        self.state.unlock();
    }
};

fn boundedDiagnosticAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const redacted = try zstd.Secrets.redactAlloc(allocator, input);
    defer allocator.free(redacted);
    return allocator.dupe(u8, redacted[0..@min(redacted.len, max_diagnostic_bytes)]);
}

pub fn parseControlOperationIdAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (bytes.len == 0 or bytes.len > 4096) return error.InvalidOperationRequest;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return error.InvalidOperationRequest;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidOperationRequest;
    const root = parsed.value.object;
    if (!equals(jsonString(root.get("schema")), "ziac.dashboard-operation-control.v1")) return error.InvalidOperationRequest;
    const id = jsonString(root.get("operation_id")) orelse return error.InvalidOperationRequest;
    if (id.len < 11 or id.len > 64 or !std.mem.startsWith(u8, id, "op-")) return error.InvalidOperationRequest;
    for (id[3..]) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidOperationRequest;
    return allocator.dupe(u8, id);
}

pub const Request = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    kind: Kind,
    project: []const u8,
    stack: []const u8,
    stage: []const u8,
    provider: Provider,
    plan_digest: ?[]const u8 = null,
    image_ref: ?[]const u8 = null,
    confirm_destructive: bool = false,

    pub fn parseAlloc(allocator: std.mem.Allocator, bytes: []const u8) !Request {
        if (bytes.len == 0 or bytes.len > 16 * 1024) return error.InvalidOperationRequest;
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch return error.InvalidOperationRequest;
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |object| object,
            else => return error.InvalidOperationRequest,
        };
        if (!equals(jsonString(root.get("schema")), "ziac.dashboard-operation-request.v1")) return error.InvalidOperationRequest;
        const kind = parseKind(jsonString(root.get("operation")) orelse return error.InvalidOperationRequest) orelse return error.InvalidOperationRequest;
        const project = jsonString(root.get("project")) orelse return error.InvalidOperationRequest;
        const stack = jsonString(root.get("stack")) orelse return error.InvalidOperationRequest;
        const stage = jsonString(root.get("stage")) orelse return error.InvalidOperationRequest;
        const provider = parseProvider(jsonString(root.get("provider")) orelse return error.InvalidOperationRequest) orelse return error.InvalidOperationRequest;
        if (!validIdentifier(project) or !validIdentifier(stack) or !validIdentifier(stage)) return error.InvalidOperationRequest;
        const plan_digest = jsonString(root.get("plan_digest"));
        if ((kind == .apply or kind == .watch) and (plan_digest == null or !validDigest(plan_digest.?))) return error.InvalidOperationRequest;
        const image_ref = jsonString(root.get("image_ref"));
        if (image_ref) |image| if (!validImage(image)) return error.InvalidOperationRequest;
        return .{
            .allocator = allocator,
            .arena = arena,
            .kind = kind,
            .project = try a.dupe(u8, project),
            .stack = try a.dupe(u8, stack),
            .stage = try a.dupe(u8, stage),
            .provider = provider,
            .plan_digest = if (plan_digest) |value| try a.dupe(u8, value) else null,
            .image_ref = if (image_ref) |value| try a.dupe(u8, value) else null,
            .confirm_destructive = jsonBool(root.get("confirm_destructive")) orelse false,
        };
    }

    pub fn deinit(self: *Request) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.* = undefined;
    }
};

pub const CommandConfig = struct {
    executable: []const u8,
    project_root: []const u8,
    plan_root: []const u8,
};

pub const Command = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    cwd: []const u8,
    argv: []const []const u8,
    plan_path: ?[]const u8,

    pub fn deinit(self: *Command) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.* = undefined;
    }
};

pub fn planCommandAlloc(allocator: std.mem.Allocator, config: CommandConfig, request: Request) !Command {
    if (request.kind != .plan) return error.InvalidOperationRequest;
    return commandAlloc(allocator, config, request, false);
}

pub fn applyCommandAlloc(allocator: std.mem.Allocator, config: CommandConfig, request: Request) !Command {
    if (request.kind != .apply and request.kind != .watch) return error.InvalidOperationRequest;
    return commandAlloc(allocator, config, request, true);
}

fn commandAlloc(allocator: std.mem.Allocator, config: CommandConfig, request: Request, apply: bool) !Command {
    if (!std.fs.path.isAbsolute(config.executable) or !std.fs.path.isAbsolute(config.project_root) or !std.fs.path.isAbsolute(config.plan_root)) return error.InvalidOperationConfig;
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const plan_path = try std.fmt.allocPrint(a, "{s}/{s}-{s}-{s}.ziac-plan.json", .{ config.plan_root, request.project, request.stack, request.stage });
    var argv = std.ArrayList([]const u8).empty;
    try argv.appendSlice(a, &.{
        try a.dupe(u8, config.executable),
        if (apply) "deploy" else "plan",
        "--stack",
        try a.dupe(u8, request.stack),
        "--stage",
        try a.dupe(u8, request.stage),
        "--json",
    });
    if (apply) {
        try argv.appendSlice(a, &.{ "--plan", plan_path, "--approval", try a.dupe(u8, request.plan_digest.?) });
        if (request.confirm_destructive) try argv.append(a, "--confirm");
        if (request.kind == .watch) {
            try argv.append(a, "--watch");
            if (request.image_ref) |image| try argv.appendSlice(a, &.{ "--image", try a.dupe(u8, image) });
        }
    } else try argv.appendSlice(a, &.{ "--out", plan_path });
    try argv.appendSlice(a, &.{ "--provider", @tagName(request.provider) });
    if (request.provider == .gcp) try argv.append(a, "--allow-live");
    return .{
        .allocator = allocator,
        .arena = arena,
        .cwd = try a.dupe(u8, config.project_root),
        .argv = try argv.toOwnedSlice(a),
        .plan_path = plan_path,
    };
}

fn parseKind(value: []const u8) ?Kind {
    inline for (std.meta.fields(Kind)) |field| if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    return null;
}
fn parseProvider(value: []const u8) ?Provider {
    inline for (std.meta.fields(Provider)) |field| if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    return null;
}
fn validIdentifier(value: []const u8) bool {
    if (value.len == 0 or value.len > 63 or !std.ascii.isAlphanumeric(value[0])) return false;
    for (value) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_')) return false;
    return true;
}
fn validDigest(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| if (!(std.ascii.isDigit(byte) or byte >= 'a' and byte <= 'f')) return false;
    return true;
}
fn validImage(value: []const u8) bool {
    return value.len > 0 and value.len <= 2048 and std.mem.indexOfAny(u8, value, "\x00\r\n ") == null;
}
fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const present = value orelse return null;
    return switch (present) {
        .string => |text| text,
        else => null,
    };
}
fn jsonBool(value: ?std.json.Value) ?bool {
    const present = value orelse return null;
    return switch (present) {
        .bool => |flag| flag,
        else => null,
    };
}
fn equals(value: ?[]const u8, expected: []const u8) bool {
    return if (value) |present| std.mem.eql(u8, present, expected) else false;
}
