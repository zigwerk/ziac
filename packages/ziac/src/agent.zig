const std = @import("std");
const contract = @import("agent_contract.zig");
const local_state = @import("local_state.zig");
const resource = @import("resource.zig");

pub const State = enum {
    orienting,
    planning,
    preflighting,
    simulating,
    awaiting_approval,
    applying,
    verifying,
    diagnosing,
    proposing_repair,
    complete,
    blocked,
    cancelled,
    failed,
};

pub const EventInput = struct {
    event_id: []const u8,
    parent_event_id: ?[]const u8 = null,
    evidence_id: ?[]const u8 = null,
    resource_id: ?[]const u8 = null,
    summary: []const u8 = "",
};

pub const Event = struct {
    event_id: []const u8,
    parent_event_id: ?[]const u8,
    evidence_id: ?[]const u8,
    resource_id: ?[]const u8,
    summary: []const u8,
    state: State,
};

pub const SessionInput = struct {
    id: []const u8,
    objective: []const u8,
    stack: []const u8,
    stage: []const u8,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    objective: []const u8,
    stack: []const u8,
    stage: []const u8,
    state: State = .orienting,
    events: std.ArrayList(Event) = .empty,

    pub fn init(allocator: std.mem.Allocator, input: SessionInput) std.mem.Allocator.Error!Session {
        const id = try allocator.dupe(u8, input.id);
        errdefer allocator.free(id);
        const objective = try allocator.dupe(u8, input.objective);
        errdefer allocator.free(objective);
        const stack = try allocator.dupe(u8, input.stack);
        errdefer allocator.free(stack);
        const stage = try allocator.dupe(u8, input.stage);
        errdefer allocator.free(stage);
        return .{
            .allocator = allocator,
            .id = id,
            .objective = objective,
            .stack = stack,
            .stage = stage,
        };
    }

    pub fn parseAlloc(allocator: std.mem.Allocator, bytes: []const u8) (std.mem.Allocator.Error || error{ InvalidSessionSnapshot, DuplicateEvent })!Session {
        var parsed = std.json.parseFromSlice(Snapshot, allocator, bytes, .{}) catch return error.InvalidSessionSnapshot;
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.schema, session_schema)) return error.InvalidSessionSnapshot;
        var session = try Session.init(allocator, .{
            .id = parsed.value.id,
            .objective = parsed.value.objective,
            .stack = parsed.value.stack,
            .stage = parsed.value.stage,
        });
        errdefer session.deinit();
        session.state = parsed.value.state;
        for (parsed.value.events) |event| {
            try session.appendEvent(event.state, .{
                .event_id = event.event_id,
                .parent_event_id = event.parent_event_id,
                .evidence_id = event.evidence_id,
                .resource_id = event.resource_id,
                .summary = event.summary,
            });
        }
        return session;
    }

    pub fn deinit(self: *Session) void {
        self.allocator.free(self.id);
        self.allocator.free(self.objective);
        self.allocator.free(self.stack);
        self.allocator.free(self.stage);
        for (self.events.items) |event| deinitEvent(self.allocator, event);
        self.events.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn transition(self: *Session, next: State, input: EventInput) (std.mem.Allocator.Error || error{ InvalidSessionTransition, DuplicateEvent })!void {
        if (!canTransition(self.state, next)) return error.InvalidSessionTransition;
        try self.appendEvent(next, input);
        self.state = next;
    }

    pub fn record(self: *Session, input: EventInput) (std.mem.Allocator.Error || error{DuplicateEvent})!void {
        try self.appendEvent(self.state, input);
    }

    pub fn jsonAlloc(self: Session, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return std.json.Stringify.valueAlloc(allocator, .{
            .schema = session_schema,
            .id = self.id,
            .objective = self.objective,
            .stack = self.stack,
            .stage = self.stage,
            .state = self.state,
            .events = self.events.items,
        }, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
    }

    fn appendEvent(self: *Session, state: State, input: EventInput) (std.mem.Allocator.Error || error{DuplicateEvent})!void {
        if (self.findEvent(input.event_id) != null) return error.DuplicateEvent;
        const event = try initEvent(self.allocator, state, input);
        errdefer deinitEvent(self.allocator, event);
        try self.events.append(self.allocator, event);
    }

    pub fn findEvent(self: Session, id: []const u8) ?Event {
        for (self.events.items) |event| if (std.mem.eql(u8, event.event_id, id)) return event;
        return null;
    }
};

const session_schema = "ziac.agent-session.v1";

const Snapshot = struct {
    schema: []const u8,
    id: []const u8,
    objective: []const u8,
    stack: []const u8,
    stage: []const u8,
    state: State,
    events: []const Event,
};

pub const SessionStore = struct {
    allocator: std.mem.Allocator,
    files: local_state.FileStore,

    pub fn init(allocator: std.mem.Allocator, files: local_state.FileStore) SessionStore {
        return .{ .allocator = allocator, .files = files };
    }

    pub fn pathAlloc(self: SessionStore, stack: []const u8, stage: []const u8) std.mem.Allocator.Error![]u8 {
        return std.fmt.allocPrint(self.allocator, ".ziac/agent/{s}/{s}/session.json", .{ stack, stage });
    }

    pub fn save(self: SessionStore, session: Session) !void {
        const path = try self.pathAlloc(session.stack, session.stage);
        defer self.allocator.free(path);
        const content = try session.jsonAlloc(self.allocator);
        defer self.allocator.free(content);
        try self.files.atomicWriteFile(self.allocator, path, content);
    }

    pub fn load(self: SessionStore, stack: []const u8, stage: []const u8) !Session {
        const path = try self.pathAlloc(stack, stage);
        defer self.allocator.free(path);
        const content = self.files.readFileAllocBounded(self.allocator, path, 4 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return error.MissingAgentSession,
            else => return err,
        };
        defer self.allocator.free(content);
        return Session.parseAlloc(self.allocator, content);
    }
};

pub fn statusJsonAlloc(
    allocator: std.mem.Allocator,
    project: contract.Project,
    session: Session,
    graph: *const resource.ResourceGraph,
) std.mem.Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .schema = "ziac.agent-status.v1",
        .project = project.id,
        .session = session.id,
        .objective = session.objective,
        .stack = session.stack,
        .stage = session.stage,
        .state = @tagName(session.state),
        .requirements_total = project.requirements.len,
        .acceptance_checks_total = project.acceptance_checks.len,
        .resources_total = graph.resources.items.len,
        .events_total = session.events.items.len,
        .complete = session.state == .complete,
    }, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
}

pub fn nextJsonAlloc(allocator: std.mem.Allocator, project: contract.Project, session: Session) std.mem.Allocator.Error![]u8 {
    const action = nextAction(session.state);
    const requirement = firstRequiredRequirement(project);
    return std.json.Stringify.valueAlloc(allocator, .{
        .schema = "ziac.agent-next.v1",
        .session = session.id,
        .state = @tagName(session.state),
        .action = action.action,
        .command = action.command,
        .requirement = if (requirement) |item| item.id else null,
        .summary = if (requirement) |item| item.summary else "No required work remains",
        .requires_approval = session.state == .awaiting_approval,
    }, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
}

pub fn queryResourceJsonAlloc(
    allocator: std.mem.Allocator,
    graph: *const resource.ResourceGraph,
    id: []const u8,
) (std.mem.Allocator.Error || error{ResourceNotFound})![]u8 {
    const node = findNode(graph, id) orelse return error.ResourceNotFound;
    var dependencies: std.ArrayList([]const u8) = .empty;
    defer dependencies.deinit(allocator);
    var dependents: std.ArrayList([]const u8) = .empty;
    defer dependents.deinit(allocator);
    for (graph.dependencies.items) |edge| {
        if (std.mem.eql(u8, edge.from, id)) try dependencies.append(allocator, edge.to);
        if (std.mem.eql(u8, edge.to, id)) try dependents.append(allocator, edge.from);
    }
    std.mem.sort([]const u8, dependencies.items, {}, lessThanString);
    std.mem.sort([]const u8, dependents.items, {}, lessThanString);
    return std.json.Stringify.valueAlloc(allocator, .{
        .schema = "ziac.agent-query.v1",
        .resource = .{
            .id = node.id,
            .type = node.type_name,
            .provider = @tagName(node.provider),
            .logical_id = node.logical_id,
        },
        .dependencies = dependencies.items,
        .dependents = dependents.items,
    }, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
}

pub fn explainJsonAlloc(allocator: std.mem.Allocator, session: Session, event_id: []const u8) (std.mem.Allocator.Error || error{EventNotFound})![]u8 {
    var chain: std.ArrayList(Event) = .empty;
    defer chain.deinit(allocator);
    var current = session.findEvent(event_id) orelse return error.EventNotFound;
    var depth: usize = 0;
    while (true) : (depth += 1) {
        if (depth > session.events.items.len) break;
        try chain.append(allocator, current);
        const parent_id = current.parent_event_id orelse break;
        if (containsEvent(chain.items, parent_id)) break;
        current = session.findEvent(parent_id) orelse break;
    }
    return std.json.Stringify.valueAlloc(allocator, .{
        .schema = "ziac.agent-explanation.v1",
        .session = session.id,
        .event = event_id,
        .chain = chain.items,
        .complete = chain.items.len > 0 and chain.items[chain.items.len - 1].parent_event_id == null,
    }, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
}

pub const HandoffInput = struct {
    root_cause: []const u8,
    plan_digest: ?[]const u8 = null,
    verification: []const []const u8 = &.{},
    blocked_by: []const []const u8 = &.{},
};

pub fn handoffJsonAlloc(
    allocator: std.mem.Allocator,
    project: contract.Project,
    session: Session,
    input: HandoffInput,
) std.mem.Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .schema = "ziac.handoff.v1",
        .project = project.id,
        .session = session.id,
        .objective = session.objective,
        .status = @tagName(session.state),
        .root_cause = input.root_cause,
        .plan_digest = input.plan_digest,
        .verification = input.verification,
        .blocked_by = input.blocked_by,
        .events = session.events.items,
        .complete = session.state == .complete and input.blocked_by.len == 0,
    }, .{ .whitespace = .indent_2 }) catch return error.OutOfMemory;
}

fn canTransition(current: State, next: State) bool {
    if (next == .blocked or next == .cancelled or next == .failed) return !isTerminal(current);
    return switch (current) {
        .orienting => next == .planning,
        .planning => next == .preflighting or next == .diagnosing,
        .preflighting => next == .simulating or next == .diagnosing,
        .simulating => next == .awaiting_approval or next == .applying or next == .diagnosing,
        .awaiting_approval => next == .applying or next == .proposing_repair,
        .applying => next == .verifying or next == .diagnosing,
        .verifying => next == .complete or next == .diagnosing,
        .diagnosing => next == .proposing_repair,
        .proposing_repair => next == .simulating or next == .awaiting_approval or next == .verifying,
        .complete, .blocked, .cancelled, .failed => false,
    };
}

fn isTerminal(state: State) bool {
    return state == .complete or state == .blocked or state == .cancelled or state == .failed;
}

fn initEvent(allocator: std.mem.Allocator, state: State, input: EventInput) std.mem.Allocator.Error!Event {
    const event_id = try allocator.dupe(u8, input.event_id);
    errdefer allocator.free(event_id);
    const parent_event_id = if (input.parent_event_id) |value| try allocator.dupe(u8, value) else null;
    errdefer if (parent_event_id) |value| allocator.free(value);
    const evidence_id = if (input.evidence_id) |value| try allocator.dupe(u8, value) else null;
    errdefer if (evidence_id) |value| allocator.free(value);
    const resource_id = if (input.resource_id) |value| try allocator.dupe(u8, value) else null;
    errdefer if (resource_id) |value| allocator.free(value);
    const summary = try allocator.dupe(u8, input.summary);
    errdefer allocator.free(summary);
    return .{
        .event_id = event_id,
        .parent_event_id = parent_event_id,
        .evidence_id = evidence_id,
        .resource_id = resource_id,
        .summary = summary,
        .state = state,
    };
}

fn deinitEvent(allocator: std.mem.Allocator, event: Event) void {
    allocator.free(event.event_id);
    if (event.parent_event_id) |value| allocator.free(value);
    if (event.evidence_id) |value| allocator.free(value);
    if (event.resource_id) |value| allocator.free(value);
    allocator.free(event.summary);
}

const NextAction = struct { action: []const u8, command: []const u8 };

fn nextAction(state: State) NextAction {
    return switch (state) {
        .orienting => .{ .action = "orient", .command = "ziac agent orient --json" },
        .planning => .{ .action = "plan", .command = "ziac plan --json" },
        .preflighting => .{ .action = "preflight", .command = "ziac agent verify --json" },
        .simulating => .{ .action = "simulate", .command = "ziac agent simulate --json" },
        .awaiting_approval => .{ .action = "approve", .command = "ziac deploy --plan <path> --approve <digest> --json" },
        .applying => .{ .action = "observe", .command = "ziac agent status --json" },
        .verifying => .{ .action = "verify", .command = "ziac agent verify --json" },
        .diagnosing => .{ .action = "explain", .command = "ziac agent explain --json" },
        .proposing_repair => .{ .action = "propose", .command = "ziac agent propose --out repair.plan.json --json" },
        .complete, .blocked, .cancelled, .failed => .{ .action = "handoff", .command = "ziac agent handoff --json" },
    };
}

fn firstRequiredRequirement(project: contract.Project) ?contract.Requirement {
    for (project.requirements) |item| if (item.required) return item;
    return null;
}

fn findNode(graph: *const resource.ResourceGraph, id: []const u8) ?resource.ResourceNode {
    for (graph.resources.items) |node| if (std.mem.eql(u8, node.id, id)) return node;
    return null;
}

fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn containsEvent(events: []const Event, id: []const u8) bool {
    for (events) |event| if (std.mem.eql(u8, event.event_id, id)) return true;
    return false;
}
