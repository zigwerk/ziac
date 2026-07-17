const std = @import("std");
const zstd = @import("zigeffect_std");

const fx = zstd.fx;
const kernel = fx.kernel;

pub const EventInput = struct {
    id: []const u8,
    name: []const u8,
};

pub const WorkerRuntime = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        validate: *const fn (*anyopaque, EventInput) anyerror!bool,
        persist: *const fn (*anyopaque, EventInput) anyerror!void,
        acknowledge: *const fn (*anyopaque, EventInput) anyerror!void,
        now_millis: *const fn (*anyopaque) u64,
    };

    pub fn validate(self: WorkerRuntime, input: EventInput) !bool {
        return self.vtable.validate(self.ptr, input);
    }

    pub fn persist(self: WorkerRuntime, input: EventInput) !void {
        try self.vtable.persist(self.ptr, input);
    }

    pub fn acknowledge(self: WorkerRuntime, input: EventInput) !void {
        try self.vtable.acknowledge(self.ptr, input);
    }

    pub fn nowMillis(self: WorkerRuntime) u64 {
        return self.vtable.now_millis(self.ptr);
    }
};

pub const EventWorkflowApi = struct {
    pub const operations: []const []const u8 = &.{"EventWorkflow.process"};
    journal: fx.workflow.JournalStore,
    worker: WorkerRuntime,
};
pub const EventWorkflow = kernel.Service("application/EventWorkflow", EventWorkflowApi);

pub const State = enum {
    received,
    validating,
    persisting,
    acknowledging,
    complete,
    rejected,
    failed,
};

pub const Failure = enum { none, validation, persistence, acknowledgement };

pub const Context = struct {
    failure: Failure = .none,
};

pub const Event = union(enum) {
    start,
    validation_succeeded,
    validation_rejected,
    validation_failed,
    persisted,
    persistence_failed,
    acknowledged,
    acknowledgement_failed,
};

pub const Command = enum { validate, persist, acknowledge };
pub const Definition = fx.statechart.Definition(State, Event, Context, Command);
pub const Machine = fx.statechart.Machine(Definition);

fn emitValidate(_: *Context, _: *const Event, commands: *Definition.CommandSink) anyerror!void {
    try commands.emit(.validate);
}

fn emitPersist(_: *Context, _: *const Event, commands: *Definition.CommandSink) anyerror!void {
    try commands.emit(.persist);
}

fn emitAcknowledge(_: *Context, _: *const Event, commands: *Definition.CommandSink) anyerror!void {
    try commands.emit(.acknowledge);
}

fn recordFailure(context: *Context, event: *const Event, _: *Definition.CommandSink) anyerror!void {
    context.failure = switch (event.*) {
        .validation_failed => .validation,
        .persistence_failed => .persistence,
        .acknowledgement_failed => .acknowledgement,
        else => return error.InvalidFailureEvent,
    };
}

const definition_source = fx.statechart.SourceRef{
    .file = "src/event_workflow.zig",
    .declaration = "definition",
    .line = 106,
    .column = 1,
};

pub const definition = Definition.init(.{
    .id = "application.event-workflow",
    .version = 1,
    .initial = .received,
    .states = &.{
        .{ .id = .received, .source = definition_source },
        .{ .id = .validating, .source = definition_source },
        .{ .id = .persisting, .source = definition_source },
        .{ .id = .acknowledging, .source = definition_source },
        .{ .id = .complete, .kind = .final, .source = definition_source },
        .{ .id = .rejected, .kind = .final, .source = definition_source },
        .{ .id = .failed, .kind = .final, .source = definition_source },
    },
    .transitions = &.{
        .{ .id = "event-received", .source = .received, .event = .start, .target = .validating, .actions = &.{.{ .id = "validate-event", .execute = emitValidate }}, .source_ref = definition_source },
        .{ .id = "event-valid", .source = .validating, .event = .validation_succeeded, .target = .persisting, .actions = &.{.{ .id = "persist-event", .execute = emitPersist }}, .source_ref = definition_source },
        .{ .id = "event-rejected", .source = .validating, .event = .validation_rejected, .target = .rejected, .source_ref = definition_source },
        .{ .id = "validation-failed", .source = .validating, .event = .validation_failed, .target = .failed, .actions = &.{.{ .id = "record-validation-failure", .execute = recordFailure }}, .source_ref = definition_source },
        .{ .id = "event-persisted", .source = .persisting, .event = .persisted, .target = .acknowledging, .actions = &.{.{ .id = "acknowledge-event", .execute = emitAcknowledge }}, .source_ref = definition_source },
        .{ .id = "persistence-failed", .source = .persisting, .event = .persistence_failed, .target = .failed, .actions = &.{.{ .id = "record-persistence-failure", .execute = recordFailure }}, .source_ref = definition_source },
        .{ .id = "event-acknowledged", .source = .acknowledging, .event = .acknowledged, .target = .complete, .source_ref = definition_source },
        .{ .id = "acknowledgement-failed", .source = .acknowledging, .event = .acknowledgement_failed, .target = .failed, .actions = &.{.{ .id = "record-acknowledgement-failure", .execute = recordFailure }}, .source_ref = definition_source },
    },
    .bounds = .{ .max_states = 8, .max_transitions = 12, .max_commands = 1, .max_internal_events = 1, .max_microsteps = 12, .max_hierarchy_depth = 1 },
    .description = "Replay-safe event validation, persistence, and acknowledgement",
    .source = definition_source,
});

pub fn registerDefinitionAtomic(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, max_bytes: usize) !void {
    try zstd.Statechart.registerDefinitionAtomic(allocator, io, dir, &definition, max_bytes);
}

const ActivityPayload = struct {
    worker: WorkerRuntime,
    input: EventInput,
    execution_key: []const u8,
};
const ActivityFailure = error{PhaseFailed};

fn activityKey(comptime phase: []const u8) *const fn (std.mem.Allocator, ActivityPayload) anyerror![]const u8 {
    return struct {
        fn key(allocator: std.mem.Allocator, payload: ActivityPayload) anyerror![]const u8 {
            return std.fmt.allocPrint(allocator, "{s}:{s}", .{ phase, payload.execution_key });
        }
    }.key;
}

const ValidateActivity = fx.workflow.Activity("application.event.validate", ActivityPayload, u64, ActivityFailure, void)
    .withIdempotencyKey(activityKey("validate"));
const PersistActivity = fx.workflow.Activity("application.event.persist", ActivityPayload, u64, ActivityFailure, void)
    .withIdempotencyKey(activityKey("persist"));
const AcknowledgeActivity = fx.workflow.Activity("application.event.acknowledge", ActivityPayload, u64, ActivityFailure, void)
    .withIdempotencyKey(activityKey("acknowledge"));

const u64_codec = fx.Codec(u64){
    .encode = struct {
        fn encode(allocator: std.mem.Allocator, value: u64) ![]const u8 {
            return std.fmt.allocPrint(allocator, "{d}", .{value});
        }
    }.encode,
    .decode = struct {
        fn decode(_: std.mem.Allocator, bytes: []const u8) !u64 {
            return std.fmt.parseInt(u64, bytes, 10);
        }
    }.decode,
};

fn validateActivity(payload: ActivityPayload) ActivityFailure!u64 {
    const valid = payload.worker.validate(payload.input) catch return error.PhaseFailed;
    return if (valid) 1 else 0;
}

fn persistActivity(payload: ActivityPayload) ActivityFailure!u64 {
    payload.worker.persist(payload.input) catch return error.PhaseFailed;
    return payload.worker.nowMillis();
}

fn acknowledgeActivity(payload: ActivityPayload) ActivityFailure!u64 {
    payload.worker.acknowledge(payload.input) catch return error.PhaseFailed;
    return payload.worker.nowMillis();
}

const ActivityAdapter = struct {
    payload: ActivityPayload,

    fn execute(self: ActivityAdapter, workflow: *fx.workflow.WorkflowContext, command: Command) !Event {
        return switch (command) {
            .validate => if (workflow.activity(ValidateActivity, self.payload, u64_codec, validateActivity)) |valid|
                if (valid == 1) .validation_succeeded else .validation_rejected
            else |_|
                .validation_failed,
            .persist => if (workflow.activity(PersistActivity, self.payload, u64_codec, persistActivity)) |_|
                .persisted
            else |_|
                .persistence_failed,
            .acknowledge => if (workflow.activity(AcknowledgeActivity, self.payload, u64_codec, acknowledgeActivity)) |_|
                .acknowledged
            else |_|
                .acknowledgement_failed,
        };
    }
};

pub const Outcome = enum { complete, rejected, failed };
const ProcessBase = kernel.Effect(Outcome, anyerror, .{EventWorkflow});
pub const Process = ProcessBase.Stateful(EventInput);

pub fn process(input: EventInput) Process {
    return Process.init(input, struct {
        fn run(event_input: EventInput, effect_context: *Process.Context) anyerror!Outcome {
            if (!validEnvelope(event_input)) return error.InvalidEventEnvelope;
            const service = effect_context.service(EventWorkflow);
            const allocator = effect_context.allocator();
            const workflow_id = fx.workflow.workflowId(definition.id);
            const execution_id = fx.workflow.executionId(definition.id, event_input.id);
            const execution_key = try std.fmt.allocPrint(allocator, "event:{s}", .{event_input.id});
            defer allocator.free(execution_key);

            var execution = zstd.Workflow.execution(effect_context, allocator, service.journal);
            defer execution.deinit();
            const journal = execution.journal();
            try ensureStarted(allocator, journal, workflow_id, execution_id, execution_key, service.worker.nowMillis());
            var workflow = try fx.workflow.WorkflowContext.init(allocator, journal, .{
                .workflow_id = workflow_id,
                .execution_id = execution_id,
            });
            defer workflow.deinit();

            var snapshot = Machine.initial(&definition, .{}, execution_id);
            var next_event: Event = .start;
            var parent_id: ?u64 = null;
            var transition_count: usize = 0;
            const adapter = ActivityAdapter{ .payload = .{
                .worker = service.worker,
                .input = event_input,
                .execution_key = execution_key,
            } };
            while (snapshot.status == .active) {
                if (transition_count >= definition.bounds.max_microsteps) return error.WorkflowTransitionLimitExceeded;
                transition_count += 1;
                const decision = try Machine.step(&definition, snapshot, next_event);
                if (decision.outcome != .transitioned) return error.WorkflowEventIgnored;
                parent_id = try execution.decision(
                    Definition,
                    &definition,
                    &decision,
                    parent_id,
                );
                snapshot = decision.next;
                if (snapshot.status != .active) break;
                if (decision.commands().len != 1) return error.InvalidWorkflowCommandCount;
                next_event = try adapter.execute(&workflow, decision.commands()[0]);
            }

            const outcome: Outcome = switch (snapshot.state) {
                .complete => .complete,
                .rejected => .rejected,
                .failed => .failed,
                else => return error.WorkflowDidNotTerminate,
            };
            try ensureTerminal(allocator, journal, workflow_id, execution_id, execution_key, outcome);
            return outcome;
        }
    }.run);
}

fn validEnvelope(input: EventInput) bool {
    return input.id.len > 0 and input.id.len <= 256 and input.name.len > 0 and input.name.len <= 256 and
        std.mem.indexOfAny(u8, input.id, "\r\n") == null and std.mem.indexOfAny(u8, input.name, "\r\n") == null;
}

fn ensureStarted(
    allocator: std.mem.Allocator,
    journal: fx.workflow.JournalStore,
    workflow_id: u64,
    execution_id: u64,
    execution_key: []const u8,
    now_millis: u64,
) !void {
    var events = try journal.readAll(allocator);
    defer events.deinit();
    for (events.events) |event| {
        if (event.workflow_id == workflow_id and event.execution_id == execution_id and event.kind == .workflow_started) return;
    }
    const detail = try std.fmt.allocPrint(allocator, "{d}", .{now_millis});
    defer allocator.free(detail);
    const sequence = nextSequence(events.events);
    _ = try journal.append(.{ .expected_next_sequence = sequence, .event = .{
        .sequence = sequence,
        .kind = .workflow_started,
        .workflow_id = workflow_id,
        .execution_id = execution_id,
        .name = definition.id,
        .status = "running",
        .redacted_detail = detail,
        .idempotency_key = execution_key,
    } });
}

fn ensureTerminal(
    allocator: std.mem.Allocator,
    journal: fx.workflow.JournalStore,
    workflow_id: u64,
    execution_id: u64,
    execution_key: []const u8,
    outcome: Outcome,
) !void {
    var events = try journal.readAll(allocator);
    defer events.deinit();
    for (events.events) |event| {
        if (event.workflow_id != workflow_id or event.execution_id != execution_id) continue;
        if (event.kind == .workflow_completed or event.kind == .workflow_failed) return;
    }
    const key = try std.fmt.allocPrint(allocator, "{s}:terminal", .{execution_key});
    defer allocator.free(key);
    const sequence = nextSequence(events.events);
    _ = try journal.append(.{ .expected_next_sequence = sequence, .event = .{
        .sequence = sequence,
        .kind = if (outcome == .complete or outcome == .rejected) .workflow_completed else .workflow_failed,
        .workflow_id = workflow_id,
        .execution_id = execution_id,
        .parent_sequence = if (events.events.len == 0) null else events.events[events.events.len - 1].sequence,
        .name = definition.id,
        .status = @tagName(outcome),
        .redacted_detail = @tagName(outcome),
        .idempotency_key = key,
    } });
}

fn nextSequence(events: []const fx.workflow.WorkflowEvent) u64 {
    return if (events.len == 0) 1 else events[events.len - 1].sequence + 1;
}

/// Safe local baseline. Replace persistence and acknowledgement with adapters
/// backed by application services; keep their interface and activity identity
/// stable so replay semantics do not change with the implementation.
pub const LocalWorker = struct {
    io: std.Io,

    pub fn runtime(self: *LocalWorker) WorkerRuntime {
        return .{ .ptr = self, .vtable = &local_vtable };
    }

    fn validate(_: *anyopaque, input: EventInput) !bool {
        return validEnvelope(input);
    }

    fn persist(_: *anyopaque, _: EventInput) !void {}

    fn acknowledge(_: *anyopaque, _: EventInput) !void {}

    fn nowMillis(raw: *anyopaque) u64 {
        const self: *LocalWorker = @ptrCast(@alignCast(raw));
        return @intCast(std.Io.Clock.real.now(self.io).toMilliseconds());
    }
};

const local_vtable = WorkerRuntime.VTable{
    .validate = LocalWorker.validate,
    .persist = LocalWorker.persist,
    .acknowledge = LocalWorker.acknowledge,
    .now_millis = LocalWorker.nowMillis,
};

pub const ScriptedWorker = struct {
    valid: bool = true,
    persist_error: ?anyerror = null,
    acknowledge_error: ?anyerror = null,
    validate_count: usize = 0,
    persist_count: usize = 0,
    acknowledge_count: usize = 0,
    now_millis: u64 = 1,

    pub fn runtime(self: *ScriptedWorker) WorkerRuntime {
        return .{ .ptr = self, .vtable = &scripted_vtable };
    }

    fn validate(raw: *anyopaque, _: EventInput) !bool {
        const self: *ScriptedWorker = @ptrCast(@alignCast(raw));
        self.validate_count += 1;
        return self.valid;
    }

    fn persist(raw: *anyopaque, _: EventInput) !void {
        const self: *ScriptedWorker = @ptrCast(@alignCast(raw));
        self.persist_count += 1;
        if (self.persist_error) |err| return err;
        self.now_millis += 1;
    }

    fn acknowledge(raw: *anyopaque, _: EventInput) !void {
        const self: *ScriptedWorker = @ptrCast(@alignCast(raw));
        self.acknowledge_count += 1;
        if (self.acknowledge_error) |err| return err;
        self.now_millis += 1;
    }

    fn nowMillis(raw: *anyopaque) u64 {
        const self: *ScriptedWorker = @ptrCast(@alignCast(raw));
        return self.now_millis;
    }
};

const scripted_vtable = WorkerRuntime.VTable{
    .validate = ScriptedWorker.validate,
    .persist = ScriptedWorker.persist,
    .acknowledge = ScriptedWorker.acknowledge,
    .now_millis = ScriptedWorker.nowMillis,
};
