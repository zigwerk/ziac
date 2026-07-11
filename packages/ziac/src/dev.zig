const std = @import("std");
const contract = @import("agent_contract.zig");
const resource = @import("resource.zig");

pub const Phase = enum { dev };

pub const Fidelity = enum {
    exact,
    representative,
    remote_required,
};

pub const AdaptationDecision = struct {
    resource_id: []const u8,
    resource_type: []const u8,
    strategy: contract.AdaptationStrategy,
    fidelity: Fidelity,
};

pub fn planAdaptationsAlloc(
    allocator: std.mem.Allocator,
    project: contract.Project,
    graph: *const resource.ResourceGraph,
) (std.mem.Allocator.Error || error{MissingDevAdaptation})![]AdaptationDecision {
    const decisions = try allocator.alloc(AdaptationDecision, graph.resources.items.len);
    errdefer allocator.free(decisions);
    for (graph.resources.items, 0..) |node, index| {
        const strategy = project.adaptationFor(node.type_name) orelse return error.MissingDevAdaptation;
        decisions[index] = .{
            .resource_id = node.id,
            .resource_type = node.type_name,
            .strategy = strategy,
            .fidelity = fidelityFor(strategy),
        };
    }
    return decisions;
}

pub const ChangeKind = enum {
    source_only,
    image_only,
    runtime_config,
    secret_reference,
    graph_topology,
    destructive,
};

pub fn classifyPath(path: []const u8) ChangeKind {
    const basename = std.fs.path.basename(path);
    if (containsIgnoreCase(basename, "drop") or containsIgnoreCase(basename, "delete")) return .destructive;
    if (std.mem.startsWith(u8, path, "secrets/") or std.mem.endsWith(u8, path, ".secret") or
        std.mem.endsWith(u8, path, ".ref")) return .secret_reference;
    if (std.mem.eql(u8, basename, "ziac.project.json") or std.mem.eql(u8, basename, "alchemy.run.zig")) return .graph_topology;
    if (std.mem.eql(u8, basename, "Dockerfile") or std.mem.eql(u8, basename, "build.zig") or
        std.mem.eql(u8, basename, "build.zig.zon")) return .image_only;
    if (std.mem.startsWith(u8, path, "config/") or std.mem.endsWith(u8, path, ".env") or
        std.mem.endsWith(u8, path, ".json")) return .runtime_config;
    return .source_only;
}

pub fn affectedSubgraphAlloc(
    allocator: std.mem.Allocator,
    graph: *const resource.ResourceGraph,
    changed: []const []const u8,
) (std.mem.Allocator.Error || error{MissingResource})![][]const u8 {
    var affected: std.ArrayList([]const u8) = .empty;
    errdefer affected.deinit(allocator);
    for (changed) |id| {
        if (!graphContains(graph, id)) return error.MissingResource;
        if (!containsString(affected.items, id)) try affected.append(allocator, id);
    }

    var cursor: usize = 0;
    while (cursor < affected.items.len) : (cursor += 1) {
        const dependency_id = affected.items[cursor];
        for (graph.dependencies.items) |edge| {
            if (std.mem.eql(u8, edge.to, dependency_id) and !containsString(affected.items, edge.from)) {
                try affected.append(allocator, edge.from);
            }
        }
    }
    std.mem.sort([]const u8, affected.items, {}, lessThanString);
    return affected.toOwnedSlice(allocator);
}

pub const GenerationStatus = enum {
    starting,
    active,
    draining,
    stopped,
    failed,
    superseded,
};

pub const GenerationInput = struct {
    id: u64,
    digest: []const u8,
    port: u16,
};

pub const Generation = struct {
    id: u64,
    digest: []const u8,
    port: u16,
    status: GenerationStatus,
    failure: ?[]const u8 = null,
};

pub const Supervisor = struct {
    allocator: std.mem.Allocator,
    generations: std.ArrayList(Generation) = .empty,
    active_id: ?u64 = null,
    candidate_id: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator) Supervisor {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Supervisor) void {
        for (self.generations.items) |item| {
            self.allocator.free(item.digest);
            if (item.failure) |failure| self.allocator.free(failure);
        }
        self.generations.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn begin(self: *Supervisor, input: GenerationInput) (std.mem.Allocator.Error || error{DuplicateGeneration})!void {
        if (self.generation(input.id) != null) return error.DuplicateGeneration;
        if (self.candidate_id) |candidate| {
            const current = self.generationMut(candidate).?;
            if (current.status == .starting) current.status = .superseded;
        }
        const digest = try self.allocator.dupe(u8, input.digest);
        errdefer self.allocator.free(digest);
        try self.generations.append(self.allocator, .{
            .id = input.id,
            .digest = digest,
            .port = input.port,
            .status = .starting,
        });
        self.candidate_id = input.id;
    }

    pub fn markReady(self: *Supervisor, id: u64) error{ GenerationNotFound, StaleGeneration, InvalidGenerationState }!void {
        if (self.candidate_id == null or self.candidate_id.? != id) return error.StaleGeneration;
        const candidate = self.generationMut(id) orelse return error.GenerationNotFound;
        if (candidate.status != .starting) return error.InvalidGenerationState;
        if (self.active_id) |active| {
            const previous = self.generationMut(active) orelse return error.GenerationNotFound;
            previous.status = .draining;
        }
        candidate.status = .active;
        self.active_id = id;
        self.candidate_id = null;
    }

    pub fn markFailed(self: *Supervisor, id: u64, reason: []const u8) (std.mem.Allocator.Error || error{ GenerationNotFound, InvalidGenerationState })!void {
        const candidate = self.generationMut(id) orelse return error.GenerationNotFound;
        if (candidate.status != .starting) return error.InvalidGenerationState;
        const failure = try self.allocator.dupe(u8, reason);
        if (candidate.failure) |previous| self.allocator.free(previous);
        candidate.failure = failure;
        candidate.status = .failed;
        if (self.candidate_id != null and self.candidate_id.? == id) self.candidate_id = null;
    }

    pub fn completeDrain(self: *Supervisor, id: u64) error{ GenerationNotFound, InvalidGenerationState }!void {
        const previous = self.generationMut(id) orelse return error.GenerationNotFound;
        if (previous.status != .draining) return error.InvalidGenerationState;
        previous.status = .stopped;
    }

    pub fn activeGeneration(self: *const Supervisor) ?u64 {
        return self.active_id;
    }

    pub fn candidateGeneration(self: *const Supervisor) ?u64 {
        return self.candidate_id;
    }

    pub fn generation(self: *const Supervisor, id: u64) ?*const Generation {
        for (self.generations.items) |*item| if (item.id == id) return item;
        return null;
    }

    fn generationMut(self: *Supervisor, id: u64) ?*Generation {
        for (self.generations.items) |*item| if (item.id == id) return item;
        return null;
    }
};

pub const Runtime = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        build: *const fn (*anyopaque, []const u8) anyerror!void,
        spawn: *const fn (*anyopaque, u64, u16) anyerror!void,
        probe: *const fn (*anyopaque, u64) anyerror!bool,
        promote: *const fn (*anyopaque, u64) anyerror!void,
        drain: *const fn (*anyopaque, u64) anyerror!void,
        stop: *const fn (*anyopaque, u64) anyerror!void,
    };

    pub fn build(self: Runtime, digest: []const u8) !void {
        try self.vtable.build(self.ptr, digest);
    }

    pub fn spawn(self: Runtime, generation_id: u64, port: u16) !void {
        try self.vtable.spawn(self.ptr, generation_id, port);
    }

    pub fn probe(self: Runtime, generation_id: u64) !bool {
        return self.vtable.probe(self.ptr, generation_id);
    }

    pub fn promote(self: Runtime, generation_id: u64) !void {
        try self.vtable.promote(self.ptr, generation_id);
    }

    pub fn drain(self: Runtime, generation_id: u64) !void {
        try self.vtable.drain(self.ptr, generation_id);
    }

    pub fn stop(self: Runtime, generation_id: u64) !void {
        try self.vtable.stop(self.ptr, generation_id);
    }
};

pub const ReloadStatus = enum {
    promoted,
    build_failed,
    spawn_failed,
    readiness_failed,
    promotion_failed,
    drain_failed,
};

pub const ReloadReceipt = struct {
    schema: []const u8 = "ziac.dev-reload.v1",
    generation_id: u64,
    previous_generation_id: ?u64,
    active_generation_id: ?u64,
    status: ReloadStatus,
    candidate_stopped: bool = false,
};

pub fn reload(supervisor: *Supervisor, runtime: Runtime, input: GenerationInput) !ReloadReceipt {
    const previous = supervisor.activeGeneration();
    try supervisor.begin(input);
    runtime.build(input.digest) catch |err| {
        try supervisor.markFailed(input.id, @errorName(err));
        return reloadReceipt(supervisor, input.id, previous, .build_failed, false);
    };
    runtime.spawn(input.id, input.port) catch |err| {
        try supervisor.markFailed(input.id, @errorName(err));
        return reloadReceipt(supervisor, input.id, previous, .spawn_failed, false);
    };
    const ready = runtime.probe(input.id) catch false;
    if (!ready) {
        try supervisor.markFailed(input.id, "readiness probe failed");
        const stopped = if (runtime.stop(input.id)) true else |_| false;
        return reloadReceipt(supervisor, input.id, previous, .readiness_failed, stopped);
    }
    runtime.promote(input.id) catch |err| {
        try supervisor.markFailed(input.id, @errorName(err));
        const stopped = if (runtime.stop(input.id)) true else |_| false;
        return reloadReceipt(supervisor, input.id, previous, .promotion_failed, stopped);
    };
    try supervisor.markReady(input.id);
    if (previous) |old_id| {
        runtime.drain(old_id) catch {
            return reloadReceipt(supervisor, input.id, previous, .drain_failed, false);
        };
        try supervisor.completeDrain(old_id);
    }
    return reloadReceipt(supervisor, input.id, previous, .promoted, false);
}

pub const ScriptedRuntime = struct {
    build_error: ?anyerror = null,
    spawn_error: ?anyerror = null,
    probe_error: ?anyerror = null,
    promote_error: ?anyerror = null,
    drain_error: ?anyerror = null,
    stop_error: ?anyerror = null,
    ready: bool = true,
    build_count: usize = 0,
    spawn_count: usize = 0,
    probe_count: usize = 0,
    promote_count: usize = 0,
    drain_count: usize = 0,
    stop_count: usize = 0,

    pub fn init() ScriptedRuntime {
        return .{};
    }

    pub fn runtime(self: *ScriptedRuntime) Runtime {
        return .{ .ptr = self, .vtable = &scripted_vtable };
    }

    fn build(raw: *anyopaque, _: []const u8) !void {
        const self: *ScriptedRuntime = @ptrCast(@alignCast(raw));
        self.build_count += 1;
        if (self.build_error) |err| return err;
    }

    fn spawn(raw: *anyopaque, _: u64, _: u16) !void {
        const self: *ScriptedRuntime = @ptrCast(@alignCast(raw));
        self.spawn_count += 1;
        if (self.spawn_error) |err| return err;
    }

    fn probe(raw: *anyopaque, _: u64) !bool {
        const self: *ScriptedRuntime = @ptrCast(@alignCast(raw));
        self.probe_count += 1;
        if (self.probe_error) |err| return err;
        return self.ready;
    }

    fn promote(raw: *anyopaque, _: u64) !void {
        const self: *ScriptedRuntime = @ptrCast(@alignCast(raw));
        if (self.promote_error) |err| return err;
        self.promote_count += 1;
    }

    fn drain(raw: *anyopaque, _: u64) !void {
        const self: *ScriptedRuntime = @ptrCast(@alignCast(raw));
        if (self.drain_error) |err| return err;
        self.drain_count += 1;
    }

    fn stop(raw: *anyopaque, _: u64) !void {
        const self: *ScriptedRuntime = @ptrCast(@alignCast(raw));
        if (self.stop_error) |err| return err;
        self.stop_count += 1;
    }
};

const scripted_vtable: Runtime.VTable = .{
    .build = ScriptedRuntime.build,
    .spawn = ScriptedRuntime.spawn,
    .probe = ScriptedRuntime.probe,
    .promote = ScriptedRuntime.promote,
    .drain = ScriptedRuntime.drain,
    .stop = ScriptedRuntime.stop,
};

pub const Binding = struct {
    name: []const u8,
    value: []const u8,
    secret: bool = false,
};

const BindingArtifact = struct {
    name: []const u8,
    value: []const u8,
    secret: bool,
};

pub fn bindingsJsonAlloc(allocator: std.mem.Allocator, bindings: []const Binding) std.mem.Allocator.Error![]u8 {
    const artifacts = try allocator.alloc(BindingArtifact, bindings.len);
    defer allocator.free(artifacts);
    for (bindings, 0..) |binding, index| artifacts[index] = .{
        .name = binding.name,
        .value = if (binding.secret) "[REDACTED]" else binding.value,
        .secret = binding.secret,
    };
    return std.json.Stringify.valueAlloc(allocator, .{
        .schema = "ziac.dev-bindings.v1",
        .bindings = artifacts,
        .redacted = countSecretBindings(bindings),
    }, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
}

pub fn receiptJsonAlloc(
    allocator: std.mem.Allocator,
    stack: []const u8,
    stage: []const u8,
    decisions: []const AdaptationDecision,
) std.mem.Allocator.Error![]u8 {
    var remote_required: usize = 0;
    for (decisions) |decision| if (decision.fidelity == .remote_required) {
        remote_required += 1;
    };
    return std.json.Stringify.valueAlloc(allocator, .{
        .schema = "ziac.dev-plan.v1",
        .phase = Phase.dev,
        .stack = stack,
        .stage = stage,
        .adaptations = decisions,
        .remote_qualification_required = remote_required,
        .provider_mutations = @as(usize, 0),
    }, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
}

fn fidelityFor(strategy: contract.AdaptationStrategy) Fidelity {
    return switch (strategy) {
        .local_process, .local_service, .mock => .exact,
        .local_proxy, .cloud_read, .cloud_resource, .skip => .representative,
        .remote_only => .remote_required,
    };
}

fn graphContains(graph: *const resource.ResourceGraph, id: []const u8) bool {
    for (graph.resources.items) |node| if (std.mem.eql(u8, node.id, id)) return true;
    return false;
}

fn containsString(values: []const []const u8, value: []const u8) bool {
    for (values) |candidate| if (std.mem.eql(u8, candidate, value)) return true;
    return false;
}

fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn containsIgnoreCase(value: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or value.len < needle.len) return false;
    var start: usize = 0;
    while (start + needle.len <= value.len) : (start += 1) {
        if (std.ascii.eqlIgnoreCase(value[start .. start + needle.len], needle)) return true;
    }
    return false;
}

fn countSecretBindings(bindings: []const Binding) usize {
    var count: usize = 0;
    for (bindings) |binding| if (binding.secret) {
        count += 1;
    };
    return count;
}

fn reloadReceipt(
    supervisor: *const Supervisor,
    generation_id: u64,
    previous: ?u64,
    status: ReloadStatus,
    candidate_stopped: bool,
) ReloadReceipt {
    return .{
        .generation_id = generation_id,
        .previous_generation_id = previous,
        .active_generation_id = supervisor.activeGeneration(),
        .status = status,
        .candidate_stopped = candidate_stopped,
    };
}
