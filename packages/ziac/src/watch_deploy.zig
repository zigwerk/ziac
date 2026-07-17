const std = @import("std");
const zstd = @import("zigeffect_std");
const contract = @import("agent_contract.zig");

const fx = zstd.fx;
const runtime_events = @import("runtime_events.zig");

pub const ActiveResult = enum { complete, cancelled, failed };

pub const Controller = struct {
    allocator: std.mem.Allocator,
    pending: ?[]const u8 = null,
    active: ?[]const u8 = null,
    cancel_requested: bool = false,
    superseded_count: u64 = 0,
    cancelled_count: u64 = 0,
    completed_count: u64 = 0,
    failed_count: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Controller {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Controller) void {
        if (self.pending) |value| self.allocator.free(value);
        if (self.active) |value| self.allocator.free(value);
        self.* = undefined;
    }

    pub fn submit(self: *Controller, digest: []const u8) std.mem.Allocator.Error!void {
        if (self.pending) |current| {
            if (std.mem.eql(u8, current, digest)) return;
            const replacement = try self.allocator.dupe(u8, digest);
            self.allocator.free(current);
            self.pending = replacement;
            self.superseded_count += 1;
        } else {
            self.pending = try self.allocator.dupe(u8, digest);
        }
        if (self.active != null) self.cancel_requested = true;
    }

    pub fn startNext(self: *Controller) error{ActiveDeployment}!?[]const u8 {
        if (self.active != null) return error.ActiveDeployment;
        const next = self.pending orelse return null;
        self.pending = null;
        self.active = next;
        self.cancel_requested = false;
        return next;
    }

    pub fn finishActive(self: *Controller, result: ActiveResult) error{NoActiveDeployment}!void {
        const active = self.active orelse return error.NoActiveDeployment;
        self.allocator.free(active);
        self.active = null;
        self.cancel_requested = false;
        switch (result) {
            .complete => self.completed_count += 1,
            .cancelled => self.cancelled_count += 1,
            .failed => self.failed_count += 1,
        }
    }

    pub fn cancelRequested(self: *const Controller) bool {
        return self.cancel_requested;
    }

    pub fn pendingDigest(self: *const Controller) ?[]const u8 {
        return self.pending;
    }

    pub fn activeDigest(self: *const Controller) ?[]const u8 {
        return self.active;
    }
};

pub const Runtime = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        push_image: *const fn (*anyopaque, []const u8) anyerror!void,
        create_revision: *const fn (*anyopaque, []const u8, bool) anyerror!void,
        wait_ready: *const fn (*anyopaque, []const u8) anyerror!bool,
        promote_traffic: *const fn (*anyopaque, []const u8) anyerror!void,
        now_millis: *const fn (*anyopaque) u64,
    };

    pub fn pushImage(self: Runtime, image_ref: []const u8) !void {
        try self.vtable.push_image(self.ptr, image_ref);
    }

    pub fn createRevision(self: Runtime, image_ref: []const u8, no_traffic: bool) !void {
        try self.vtable.create_revision(self.ptr, image_ref, no_traffic);
    }

    pub fn waitReady(self: Runtime, image_ref: []const u8) !bool {
        return self.vtable.wait_ready(self.ptr, image_ref);
    }

    pub fn promoteTraffic(self: Runtime, image_ref: []const u8) !void {
        try self.vtable.promote_traffic(self.ptr, image_ref);
    }

    pub fn nowMillis(self: Runtime) u64 {
        return self.vtable.now_millis(self.ptr);
    }
};

pub const ExecuteInput = struct {
    now_millis: u64,
    started_at_millis: u64 = 0,
    stage: []const u8,
    project: []const u8,
    plan_digest: []const u8,
    image_ref: []const u8,
    regions: usize,
    monthly_cost_minor: u64 = 0,
    destructive: bool = false,
    slo_target_millis: u64 = 15_000,
};

pub const Status = enum {
    complete,
    push_failed,
    revision_failed,
    readiness_failed,
    traffic_failed,
};

pub const Receipt = struct {
    schema: []const u8 = "ziac.watch-deploy.v1",
    status: Status,
    image_ref: []const u8,
    no_traffic_verified: bool,
    traffic_promoted: bool,
    timings: Timings,
    slo_target_millis: u64,
    slo_miss: bool,
};

pub const Timings = struct {
    total_millis: u64,
    push_millis: u64,
    revision_millis: u64,
    readiness_millis: u64,
    traffic_millis: u64,
};

pub const RolloutState = enum {
    pending,
    pushing,
    creating_revision,
    waiting_ready,
    promoting_traffic,
    complete,
    failed,
};

pub const RolloutFailure = enum {
    none,
    push,
    revision,
    readiness,
    traffic,
};

pub const RolloutContext = struct {
    started_at_millis: u64,
    pushed_at_millis: u64 = 0,
    revisioned_at_millis: u64 = 0,
    readied_at_millis: u64 = 0,
    ended_at_millis: u64 = 0,
    failure: RolloutFailure = .none,
};

pub const RolloutEvent = union(enum) {
    start,
    push_succeeded: u64,
    push_failed: u64,
    revision_succeeded: u64,
    revision_failed: u64,
    readiness_succeeded: u64,
    readiness_failed: u64,
    traffic_succeeded: u64,
    traffic_failed: u64,
};

pub const RolloutCommand = enum {
    push_image,
    create_revision,
    wait_ready,
    promote_traffic,
};

pub const RolloutDefinition = fx.statechart.Definition(RolloutState, RolloutEvent, RolloutContext, RolloutCommand);
pub const RolloutMachine = fx.statechart.Machine(RolloutDefinition);

fn emitPush(_: *RolloutContext, _: *const RolloutEvent, commands: *RolloutDefinition.CommandSink) anyerror!void {
    try commands.emit(.push_image);
}

fn acceptPush(context: *RolloutContext, event: *const RolloutEvent, commands: *RolloutDefinition.CommandSink) anyerror!void {
    context.pushed_at_millis = event.push_succeeded;
    try commands.emit(.create_revision);
}

fn acceptRevision(context: *RolloutContext, event: *const RolloutEvent, commands: *RolloutDefinition.CommandSink) anyerror!void {
    context.revisioned_at_millis = event.revision_succeeded;
    try commands.emit(.wait_ready);
}

fn acceptReadiness(context: *RolloutContext, event: *const RolloutEvent, commands: *RolloutDefinition.CommandSink) anyerror!void {
    context.readied_at_millis = event.readiness_succeeded;
    try commands.emit(.promote_traffic);
}

fn acceptTraffic(context: *RolloutContext, event: *const RolloutEvent, _: *RolloutDefinition.CommandSink) anyerror!void {
    context.ended_at_millis = event.traffic_succeeded;
}

fn recordFailure(context: *RolloutContext, event: *const RolloutEvent, _: *RolloutDefinition.CommandSink) anyerror!void {
    const ended = switch (event.*) {
        .push_failed => |value| failure: {
            context.failure = .push;
            context.pushed_at_millis = value;
            context.revisioned_at_millis = value;
            context.readied_at_millis = value;
            break :failure value;
        },
        .revision_failed => |value| failure: {
            context.failure = .revision;
            context.revisioned_at_millis = value;
            context.readied_at_millis = value;
            break :failure value;
        },
        .readiness_failed => |value| failure: {
            context.failure = .readiness;
            context.readied_at_millis = value;
            break :failure value;
        },
        .traffic_failed => |value| failure: {
            context.failure = .traffic;
            break :failure value;
        },
        else => return error.InvalidRolloutFailureEvent,
    };
    context.ended_at_millis = ended;
}

const rollout_source = fx.statechart.SourceRef{
    .file = "packages/ziac/src/watch_deploy.zig",
    .declaration = "rollout_definition",
    .line = 257,
    .column = 1,
};

pub const rollout_definition = RolloutDefinition.init(.{
    .id = "ziac.watch-deploy",
    .version = 1,
    .initial = .pending,
    .states = &.{
        .{ .id = .pending, .source = rollout_source },
        .{ .id = .pushing, .source = rollout_source },
        .{ .id = .creating_revision, .source = rollout_source },
        .{ .id = .waiting_ready, .source = rollout_source },
        .{ .id = .promoting_traffic, .source = rollout_source },
        .{ .id = .complete, .kind = .final, .source = rollout_source },
        .{ .id = .failed, .kind = .final, .source = rollout_source },
    },
    .transitions = &.{
        .{ .id = "start-rollout", .source = .pending, .event = .start, .target = .pushing, .actions = &.{.{ .id = "emit-push", .execute = emitPush }}, .source_ref = rollout_source },
        .{ .id = "image-pushed", .source = .pushing, .event = .push_succeeded, .target = .creating_revision, .actions = &.{.{ .id = "record-push", .execute = acceptPush }}, .source_ref = rollout_source },
        .{ .id = "push-failed", .source = .pushing, .event = .push_failed, .target = .failed, .actions = &.{.{ .id = "record-failure", .execute = recordFailure }}, .source_ref = rollout_source },
        .{ .id = "revision-created", .source = .creating_revision, .event = .revision_succeeded, .target = .waiting_ready, .actions = &.{.{ .id = "record-revision", .execute = acceptRevision }}, .source_ref = rollout_source },
        .{ .id = "revision-failed", .source = .creating_revision, .event = .revision_failed, .target = .failed, .actions = &.{.{ .id = "record-failure", .execute = recordFailure }}, .source_ref = rollout_source },
        .{ .id = "revision-ready", .source = .waiting_ready, .event = .readiness_succeeded, .target = .promoting_traffic, .actions = &.{.{ .id = "record-readiness", .execute = acceptReadiness }}, .source_ref = rollout_source },
        .{ .id = "readiness-failed", .source = .waiting_ready, .event = .readiness_failed, .target = .failed, .actions = &.{.{ .id = "record-failure", .execute = recordFailure }}, .source_ref = rollout_source },
        .{ .id = "traffic-promoted", .source = .promoting_traffic, .event = .traffic_succeeded, .target = .complete, .actions = &.{.{ .id = "record-traffic", .execute = acceptTraffic }}, .source_ref = rollout_source },
        .{ .id = "traffic-failed", .source = .promoting_traffic, .event = .traffic_failed, .target = .failed, .actions = &.{.{ .id = "record-failure", .execute = recordFailure }}, .source_ref = rollout_source },
    },
    .bounds = .{ .max_states = 8, .max_transitions = 16, .max_commands = 1, .max_internal_events = 1, .max_microsteps = 16, .max_hierarchy_depth = 1 },
    .description = "Replay-safe immutable Cloud Run watch deployment",
    .source = rollout_source,
});

pub fn registerStatechart(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    max_bytes: usize,
) !void {
    try zstd.Statechart.registerDefinitionAtomic(allocator, io, dir, &rollout_definition, max_bytes);
}

pub const WorkflowRuntime = struct {
    journal: fx.workflow.JournalStore,
    events: runtime_events.Recorder = .disabled,

    /// Application-facing constructor. The caller supplies the durable
    /// journal; Ziac derives semantic recording from the owning effect runtime.
    pub fn init(ctx: anytype, journal: fx.workflow.JournalStore) WorkflowRuntime {
        return .{
            .journal = journal,
            .events = runtime_events.Recorder.fromContext(ctx),
        };
    }

    /// Controlled test constructor used to inspect and publish causal proof.
    pub fn initTest(journal: fx.workflow.JournalStore, events: runtime_events.Recorder) WorkflowRuntime {
        return .{ .journal = journal, .events = events };
    }
};

const ActivityFailure = error{PhaseFailed};
const ActivityPayload = struct {
    runtime: Runtime,
    execution_key: []const u8,
    image_ref: []const u8,
};

fn activityKey(comptime phase: []const u8) *const fn (std.mem.Allocator, ActivityPayload) anyerror![]const u8 {
    return struct {
        fn key(allocator: std.mem.Allocator, payload: ActivityPayload) anyerror![]const u8 {
            return std.fmt.allocPrint(allocator, "{s}:{s}", .{ phase, payload.execution_key });
        }
    }.key;
}

const PushActivity = fx.workflow.Activity("ziac.watch-deploy.push-image", ActivityPayload, u64, ActivityFailure, void)
    .withIdempotencyKey(activityKey("push-image"));
const RevisionActivity = fx.workflow.Activity("ziac.watch-deploy.create-revision", ActivityPayload, u64, ActivityFailure, void)
    .withIdempotencyKey(activityKey("create-revision"));
const ReadinessActivity = fx.workflow.Activity("ziac.watch-deploy.wait-ready", ActivityPayload, u64, ActivityFailure, void)
    .withIdempotencyKey(activityKey("wait-ready"));
const TrafficActivity = fx.workflow.Activity("ziac.watch-deploy.promote-traffic", ActivityPayload, u64, ActivityFailure, void)
    .withIdempotencyKey(activityKey("promote-traffic"));

const timestamp_codec = fx.Codec(u64){
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

fn pushImageActivity(payload: ActivityPayload) ActivityFailure!u64 {
    payload.runtime.pushImage(payload.image_ref) catch return error.PhaseFailed;
    return payload.runtime.nowMillis();
}

fn createRevisionActivity(payload: ActivityPayload) ActivityFailure!u64 {
    payload.runtime.createRevision(payload.image_ref, true) catch return error.PhaseFailed;
    return payload.runtime.nowMillis();
}

fn waitReadyActivity(payload: ActivityPayload) ActivityFailure!u64 {
    const ready = payload.runtime.waitReady(payload.image_ref) catch return error.PhaseFailed;
    if (!ready) return error.PhaseFailed;
    return payload.runtime.nowMillis();
}

fn promoteTrafficActivity(payload: ActivityPayload) ActivityFailure!u64 {
    payload.runtime.promoteTraffic(payload.image_ref) catch return error.PhaseFailed;
    return payload.runtime.nowMillis();
}

const ActivityAdapter = struct {
    runtime: Runtime,
    execution_key: []const u8,
    image_ref: []const u8,

    fn execute(self: ActivityAdapter, workflow: *fx.workflow.WorkflowContext, command: RolloutCommand) !RolloutEvent {
        const payload = ActivityPayload{
            .runtime = self.runtime,
            .execution_key = self.execution_key,
            .image_ref = self.image_ref,
        };
        return switch (command) {
            .push_image => if (workflow.activity(PushActivity, payload, timestamp_codec, pushImageActivity)) |at|
                .{ .push_succeeded = at }
            else |_|
                .{ .push_failed = self.runtime.nowMillis() },
            .create_revision => if (workflow.activity(RevisionActivity, payload, timestamp_codec, createRevisionActivity)) |at|
                .{ .revision_succeeded = at }
            else |_|
                .{ .revision_failed = self.runtime.nowMillis() },
            .wait_ready => if (workflow.activity(ReadinessActivity, payload, timestamp_codec, waitReadyActivity)) |at|
                .{ .readiness_succeeded = at }
            else |_|
                .{ .readiness_failed = self.runtime.nowMillis() },
            .promote_traffic => if (workflow.activity(TrafficActivity, payload, timestamp_codec, promoteTrafficActivity)) |at|
                .{ .traffic_succeeded = at }
            else |_|
                .{ .traffic_failed = self.runtime.nowMillis() },
        };
    }
};

pub fn executeWorkflow(
    allocator: std.mem.Allocator,
    workflow_runtime: WorkflowRuntime,
    runtime: Runtime,
    envelope: contract.CapabilityEnvelope,
    input: ExecuteInput,
) !Receipt {
    if (!isDevelopmentStage(input.stage)) return error.WatchProductionForbidden;
    if (input.destructive) return error.WatchDestructiveChange;
    if (!isImmutableImage(input.image_ref)) return error.MutableWatchImage;
    try envelope.require(.{
        .now_millis = input.now_millis,
        .started_at_millis = input.started_at_millis,
        .stage = input.stage,
        .project = input.project,
        .provider = .gcp,
        .action = .apply,
        .updates = 1,
        .regions = input.regions,
        .monthly_cost_minor = input.monthly_cost_minor,
        .plan_digest = input.plan_digest,
    });

    const execution_key = try std.fmt.allocPrint(allocator, "{s}:{s}:{s}", .{ input.project, input.stage, input.plan_digest });
    defer allocator.free(execution_key);
    const workflow_id = fx.workflow.workflowId(rollout_definition.id);
    const execution_id = fx.workflow.executionId(rollout_definition.id, execution_key);

    var recording = workflow_runtime.events.workflow(allocator, workflow_runtime.journal);
    defer recording.deinit();
    const journal = recording.journal();

    const started = try ensureWorkflowStarted(allocator, journal, workflow_id, execution_id, execution_key, runtime.nowMillis());
    const workflow_started = workflow_runtime.events.workflowCheckpoint(rollout_definition.id, "started", execution_key);
    var workflow = try fx.workflow.WorkflowContext.init(allocator, journal, .{
        .workflow_id = workflow_id,
        .execution_id = execution_id,
    });
    defer workflow.deinit();

    var snapshot = RolloutMachine.initial(&rollout_definition, .{ .started_at_millis = started }, execution_id);
    var event: RolloutEvent = .start;
    var causal_parent: ?u64 = null;
    var transitions: usize = 0;
    const adapter = ActivityAdapter{ .runtime = runtime, .execution_key = execution_key, .image_ref = input.image_ref };
    while (snapshot.status == .active) {
        if (transitions >= rollout_definition.bounds.max_microsteps) return error.RolloutTransitionLimitExceeded;
        transitions += 1;
        const decision = try RolloutMachine.step(&rollout_definition, snapshot, event);
        if (decision.outcome != .transitioned) return error.RolloutEventIgnored;
        causal_parent = try recording.recordDecision(
            RolloutDefinition,
            &rollout_definition,
            &decision,
            causal_parent orelse workflow_started,
        );
        snapshot = decision.next;
        if (snapshot.status != .active) break;
        if (decision.commands().len != 1) return error.InvalidRolloutCommandCount;
        event = try adapter.execute(&workflow, decision.commands()[0]);
    }

    const status: Status = switch (snapshot.context.failure) {
        .none => .complete,
        .push => .push_failed,
        .revision => .revision_failed,
        .readiness => .readiness_failed,
        .traffic => .traffic_failed,
    };
    const result = receipt(
        input,
        status,
        status == .complete or status == .readiness_failed or status == .traffic_failed,
        status == .complete,
        timings(
            snapshot.context.started_at_millis,
            snapshot.context.pushed_at_millis,
            snapshot.context.revisioned_at_millis,
            snapshot.context.readied_at_millis,
            snapshot.context.ended_at_millis,
        ),
    );
    try ensureWorkflowTerminal(allocator, journal, workflow_id, execution_id, execution_key, result.status);
    _ = workflow_runtime.events.child(recording.latestCausalId() orelse causal_parent).workflowCheckpoint(
        rollout_definition.id,
        "committed",
        @tagName(result.status),
    );
    return result;
}

fn ensureWorkflowStarted(
    allocator: std.mem.Allocator,
    journal: fx.workflow.JournalStore,
    workflow_id: u64,
    execution_id: u64,
    execution_key: []const u8,
    started_at_millis: u64,
) !u64 {
    var events = try journal.readAll(allocator);
    defer events.deinit();
    for (events.events) |event| {
        if (event.workflow_id == workflow_id and event.execution_id == execution_id and event.kind == .workflow_started) {
            return std.fmt.parseInt(u64, event.redacted_detail, 10) catch started_at_millis;
        }
    }
    const detail = try std.fmt.allocPrint(allocator, "{d}", .{started_at_millis});
    defer allocator.free(detail);
    _ = try journal.append(.{
        .expected_next_sequence = nextWorkflowSequence(events.events),
        .event = .{
            .sequence = nextWorkflowSequence(events.events),
            .kind = .workflow_started,
            .workflow_id = workflow_id,
            .execution_id = execution_id,
            .name = rollout_definition.id,
            .status = "running",
            .redacted_detail = detail,
            .idempotency_key = execution_key,
        },
    });
    return started_at_millis;
}

fn ensureWorkflowTerminal(
    allocator: std.mem.Allocator,
    journal: fx.workflow.JournalStore,
    workflow_id: u64,
    execution_id: u64,
    execution_key: []const u8,
    status: Status,
) !void {
    var events = try journal.readAll(allocator);
    defer events.deinit();
    for (events.events) |event| {
        if (event.workflow_id != workflow_id or event.execution_id != execution_id) continue;
        if (event.kind == .workflow_completed or event.kind == .workflow_failed) return;
    }
    const idempotency_key = try std.fmt.allocPrint(allocator, "{s}:terminal", .{execution_key});
    defer allocator.free(idempotency_key);
    const sequence = nextWorkflowSequence(events.events);
    _ = try journal.append(.{
        .expected_next_sequence = sequence,
        .event = .{
            .sequence = sequence,
            .kind = if (status == .complete) .workflow_completed else .workflow_failed,
            .workflow_id = workflow_id,
            .execution_id = execution_id,
            .parent_sequence = if (events.events.len == 0) null else events.events[events.events.len - 1].sequence,
            .name = rollout_definition.id,
            .status = @tagName(status),
            .redacted_detail = @tagName(status),
            .idempotency_key = idempotency_key,
        },
    });
}

fn nextWorkflowSequence(events: []const fx.workflow.WorkflowEvent) u64 {
    return if (events.len == 0) 1 else events[events.len - 1].sequence + 1;
}

pub const ScriptedRuntime = struct {
    push_error: ?anyerror = null,
    revision_error: ?anyerror = null,
    readiness_error: ?anyerror = null,
    traffic_error: ?anyerror = null,
    ready: bool = true,
    push_count: usize = 0,
    revision_count: usize = 0,
    readiness_count: usize = 0,
    traffic_count: usize = 0,
    now_millis: u64 = 0,
    push_millis: u64 = 0,
    revision_millis: u64 = 0,
    readiness_millis: u64 = 0,
    traffic_millis: u64 = 0,

    pub fn init() ScriptedRuntime {
        return .{};
    }

    pub fn runtime(self: *ScriptedRuntime) Runtime {
        return .{ .ptr = self, .vtable = &scripted_vtable };
    }

    fn pushImage(raw: *anyopaque, _: []const u8) !void {
        const self: *ScriptedRuntime = @ptrCast(@alignCast(raw));
        self.push_count += 1;
        self.now_millis +|= self.push_millis;
        if (self.push_error) |err| return err;
    }

    fn createRevision(raw: *anyopaque, _: []const u8, no_traffic: bool) !void {
        const self: *ScriptedRuntime = @ptrCast(@alignCast(raw));
        if (!no_traffic) return error.TrafficMustRemainZero;
        self.revision_count += 1;
        self.now_millis +|= self.revision_millis;
        if (self.revision_error) |err| return err;
    }

    fn waitReady(raw: *anyopaque, _: []const u8) !bool {
        const self: *ScriptedRuntime = @ptrCast(@alignCast(raw));
        self.readiness_count += 1;
        self.now_millis +|= self.readiness_millis;
        if (self.readiness_error) |err| return err;
        return self.ready;
    }

    fn promoteTraffic(raw: *anyopaque, _: []const u8) !void {
        const self: *ScriptedRuntime = @ptrCast(@alignCast(raw));
        if (self.traffic_error) |err| return err;
        self.traffic_count += 1;
        self.now_millis +|= self.traffic_millis;
    }

    fn nowMillis(raw: *anyopaque) u64 {
        const self: *ScriptedRuntime = @ptrCast(@alignCast(raw));
        return self.now_millis;
    }
};

const scripted_vtable: Runtime.VTable = .{
    .push_image = ScriptedRuntime.pushImage,
    .create_revision = ScriptedRuntime.createRevision,
    .wait_ready = ScriptedRuntime.waitReady,
    .promote_traffic = ScriptedRuntime.promoteTraffic,
    .now_millis = ScriptedRuntime.nowMillis,
};

fn receipt(
    input: ExecuteInput,
    status: Status,
    no_traffic_verified: bool,
    traffic_promoted: bool,
    phase_timings: Timings,
) Receipt {
    return .{
        .status = status,
        .image_ref = input.image_ref,
        .no_traffic_verified = no_traffic_verified,
        .traffic_promoted = traffic_promoted,
        .timings = phase_timings,
        .slo_target_millis = input.slo_target_millis,
        .slo_miss = phase_timings.total_millis > input.slo_target_millis,
    };
}

pub fn eventStreamJsonAlloc(allocator: std.mem.Allocator, deployment: Receipt) std.mem.Allocator.Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    const phases = [_]struct { name: []const u8, duration: u64 }{
        .{ .name = "push", .duration = deployment.timings.push_millis },
        .{ .name = "revision", .duration = deployment.timings.revision_millis },
        .{ .name = "readiness", .duration = deployment.timings.readiness_millis },
        .{ .name = "traffic", .duration = deployment.timings.traffic_millis },
    };
    for (phases) |phase| {
        const line = std.json.Stringify.valueAlloc(allocator, .{
            .schema = "ziac.watch-deploy-event.v1",
            .phase = phase.name,
            .duration_millis = phase.duration,
            .image_ref = deployment.image_ref,
        }, .{}) catch return error.OutOfMemory;
        defer allocator.free(line);
        try output.appendSlice(allocator, line);
        try output.append(allocator, '\n');
    }
    const receipt_json = std.json.Stringify.valueAlloc(allocator, deployment, .{}) catch return error.OutOfMemory;
    defer allocator.free(receipt_json);
    try output.appendSlice(allocator, receipt_json);
    try output.append(allocator, '\n');
    return output.toOwnedSlice(allocator);
}

fn timings(started: u64, pushed: u64, revisioned: u64, readied: u64, ended: u64) Timings {
    return .{
        .total_millis = ended -| started,
        .push_millis = pushed -| started,
        .revision_millis = revisioned -| pushed,
        .readiness_millis = readied -| revisioned,
        .traffic_millis = ended -| readied,
    };
}

fn isDevelopmentStage(stage: []const u8) bool {
    return std.mem.eql(u8, stage, "dev") or std.mem.startsWith(u8, stage, "dev_") or
        std.mem.startsWith(u8, stage, "dev-") or std.mem.startsWith(u8, stage, "pr-");
}

fn isImmutableImage(image: []const u8) bool {
    const marker = "@sha256:";
    const index = std.mem.lastIndexOf(u8, image, marker) orelse return false;
    if (index == 0 or image.len != index + marker.len + 64) return false;
    for (image[index + marker.len ..]) |character| if (!std.ascii.isHex(character)) return false;
    return true;
}
