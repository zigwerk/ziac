const std = @import("std");
const fx = @import("zigeffect_std").fx;
const apply_mod = @import("apply.zig");
const plan_mod = @import("plan.zig");
const provider_mod = @import("provider.zig");
const state_mod = @import("state.zig");

pub const ScheduleError = error{
    DependencyCycle,
    DuplicateOperation,
    InvalidConcurrency,
    OutOfMemory,
};

pub const ExecuteError = ScheduleError || apply_mod.ApplyError || fx.DependencyError;

pub const CancellationToken = struct {
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn cancel(self: *CancellationToken) void {
        self.cancelled.store(true, .release);
    }

    pub fn isCancelled(self: *const CancellationToken) bool {
        return self.cancelled.load(.acquire);
    }
};

pub const ExecuteOptions = struct {
    max_concurrency: usize = 4,
    fiber_executor: ?fx.FiberExecutor = null,
    retry_schedule: fx.Schedule = fx.Schedule.exponential(.{
        .max_retries = 3,
        .base_delay_ms = 100,
        .max_delay_ms = 2_000,
    }),
    clock: ?*fx.Clock = null,
    cancellation: ?*CancellationToken = null,
    causal_store: ?*fx.CausalStore = null,
};

pub const ExecutionLevel = struct {
    operation_indexes: []usize,
};

pub const ExecutionSchedule = struct {
    allocator: std.mem.Allocator,
    levels: []ExecutionLevel,

    pub fn deinit(self: *ExecutionSchedule) void {
        for (self.levels) |level| self.allocator.free(level.operation_indexes);
        self.allocator.free(self.levels);
        self.* = undefined;
    }
};

const Phase = enum {
    apply,
    destroy,
};

pub fn buildSchedule(
    allocator: std.mem.Allocator,
    planned: *const plan_mod.Plan,
) ScheduleError!ExecutionSchedule {
    try validateUniqueOperations(planned);
    var levels = std.ArrayList(ExecutionLevel).empty;
    errdefer deinitLevelList(allocator, &levels);
    try appendPhaseLevels(allocator, &levels, planned, .apply);
    try appendPhaseLevels(allocator, &levels, planned, .destroy);
    return .{
        .allocator = allocator,
        .levels = try levels.toOwnedSlice(allocator),
    };
}

pub fn executePlan(
    allocator: std.mem.Allocator,
    planned: *const plan_mod.Plan,
    store: *state_mod.InMemoryStateStore,
    providers: provider_mod.ProviderRegistry,
    options: ExecuteOptions,
) ExecuteError!void {
    if (options.max_concurrency == 0) return error.InvalidConcurrency;
    if (options.cancellation) |token| {
        if (token.isCancelled()) return error.ProviderCancelled;
    }

    var schedule = try buildSchedule(allocator, planned);
    defer schedule.deinit();
    var system_clock = fx.Clock.system();
    var internal_cancellation = CancellationToken{};
    var environment = ExecutionEnvironment{
        .allocator = allocator,
        .planned = planned,
        .store = store,
        .providers = providers,
        .options = options,
        .clock = options.clock orelse &system_clock,
        .internal_cancellation = &internal_cancellation,
    };
    var runtime = fx.Runtime(ExecutionEnvironment).init(allocator, &environment);
    if (options.fiber_executor) |fiber_executor| {
        runtime = runtime.withExecutor(fiber_executor);
    }
    if (options.causal_store) |causal_store| {
        runtime = runtime.withCausalStore(causal_store);
    }

    for (schedule.levels) |level| {
        var batch_start: usize = 0;
        while (batch_start < level.operation_indexes.len) {
            const batch_end = @min(batch_start + options.max_concurrency, level.operation_indexes.len);
            const indexes = level.operation_indexes[batch_start..batch_end];
            const jobs = try allocator.alloc(ExecutionJob, indexes.len);
            defer allocator.free(jobs);
            for (indexes, 0..) |operation_index, index| {
                jobs[index] = .{ .operation_index = operation_index };
            }

            const program = fx.forEachPar(
                ExecutionJob,
                void,
                ExecuteError,
                ExecutionEnvironment,
                jobs,
                ExecutionJob.run,
            );
            const results = try runtime.run(program);
            allocator.free(results);
            batch_start = batch_end;
        }
    }
}

const ExecutionEnvironment = struct {
    allocator: std.mem.Allocator,
    planned: *const plan_mod.Plan,
    store: *state_mod.InMemoryStateStore,
    providers: provider_mod.ProviderRegistry,
    options: ExecuteOptions,
    clock: *fx.Clock,
    internal_cancellation: *CancellationToken,

    fn isCancelled(self: *const ExecutionEnvironment) bool {
        if (self.internal_cancellation.isCancelled()) return true;
        if (self.options.cancellation) |token| return token.isCancelled();
        return false;
    }
};

const ExecutionJob = struct {
    operation_index: usize,

    fn run(
        self: ExecutionJob,
        context: *fx.Context(ExecutionEnvironment),
    ) ExecuteError!void {
        const environment = context.env;
        if (environment.isCancelled()) return error.ProviderCancelled;
        const operation = environment.planned.operations[self.operation_index];
        recordFact(context, operation, "started");
        executeWithRetry(environment, context, operation) catch |err| {
            environment.internal_cancellation.cancel();
            recordFact(context, operation, "failure");
            return err;
        };
        recordFact(context, operation, "success");
    }
};

fn executeWithRetry(
    environment: *ExecutionEnvironment,
    context: *fx.Context(ExecutionEnvironment),
    operation: plan_mod.PlanOperation,
) ExecuteError!void {
    if (operation.kind == .noop or operation.kind == .read) return;
    const provider = try environment.providers.get(operation.resource.provider);
    const started_at = environment.clock.nowMs();
    const timeout_millis = operation.resource.lifecycle.operation_timeout_millis;
    var operation_context = provider_mod.OperationContext{
        .allocator = environment.allocator,
        .clock = environment.clock,
        .cancellation = .{
            .ptr = environment,
            .isCancelledFn = executionCancelled,
        },
        .deadline_millis = std.math.add(u64, started_at, timeout_millis) catch std.math.maxInt(u64),
    };
    var retry_index: usize = 0;

    while (true) {
        try operation_context.checkActive();
        apply_mod.applyOperationWithContext(
            &operation_context,
            operation,
            environment.store,
            provider,
        ) catch |err| {
            if (!isRetryable(err)) return err;
            const delay_millis = environment.options.retry_schedule.nextDelay(retry_index) orelse return err;
            const elapsed = environment.clock.nowMs() -| started_at;
            if (elapsed >= timeout_millis or delay_millis > timeout_millis - elapsed) return error.ProviderTimeout;
            _ = context.recordCausal(.{
                .kind = .schedule_decision,
                .label = operation.resource.id,
                .status = "retry",
                .type_name = @tagName(operation.kind),
            });
            environment.clock.sleep(delay_millis);
            retry_index += 1;
            continue;
        };
        return;
    }
}

fn executionCancelled(raw: *const anyopaque) bool {
    const environment: *const ExecutionEnvironment = @ptrCast(@alignCast(raw));
    return environment.isCancelled();
}

fn recordFact(
    context: *fx.Context(ExecutionEnvironment),
    operation: plan_mod.PlanOperation,
    status: []const u8,
) void {
    _ = context.recordCausal(.{
        .kind = .workflow_event_recorded,
        .label = operation.resource.id,
        .status = status,
        .type_name = @tagName(operation.kind),
    });
}

fn isRetryable(err: apply_mod.ApplyError) bool {
    return switch (err) {
        error.RateLimited, error.TransientFailure, error.ProviderTimeout => true,
        else => false,
    };
}

fn validateUniqueOperations(planned: *const plan_mod.Plan) ScheduleError!void {
    for (planned.operations, 0..) |operation, index| {
        for (planned.operations[index + 1 ..]) |other| {
            if (std.mem.eql(u8, operation.resource.id, other.resource.id)) {
                return error.DuplicateOperation;
            }
        }
    }
}

fn appendPhaseLevels(
    allocator: std.mem.Allocator,
    levels: *std.ArrayList(ExecutionLevel),
    planned: *const plan_mod.Plan,
    phase: Phase,
) ScheduleError!void {
    const completed = try allocator.alloc(bool, planned.operations.len);
    defer allocator.free(completed);
    @memset(completed, false);

    var remaining: usize = 0;
    for (planned.operations) |operation| {
        if (inPhase(operation.kind, phase)) remaining += 1;
    }

    while (remaining > 0) {
        var ready = std.ArrayList(usize).empty;
        defer ready.deinit(allocator);
        for (planned.operations, 0..) |_, operation_index| {
            if (completed[operation_index]) continue;
            if (!inPhase(planned.operations[operation_index].kind, phase)) continue;
            if (operationReady(planned, completed, operation_index, phase)) {
                try ready.append(allocator, operation_index);
            }
        }
        if (ready.items.len == 0) return error.DependencyCycle;
        std.mem.sort(usize, ready.items, planned, lessThanOperationId);
        const owned = try ready.toOwnedSlice(allocator);
        errdefer allocator.free(owned);
        try levels.append(allocator, .{ .operation_indexes = owned });
        for (owned) |operation_index| completed[operation_index] = true;
        remaining -= owned.len;
    }
}

fn operationReady(
    planned: *const plan_mod.Plan,
    completed: []const bool,
    operation_index: usize,
    phase: Phase,
) bool {
    const operation = planned.operations[operation_index];
    return switch (phase) {
        .apply => for (operation.dependencies) |dependency_id| {
            const dependency_index = phaseOperationIndex(planned, dependency_id, phase) orelse continue;
            if (!completed[dependency_index]) break false;
        } else true,
        .destroy => !hasRemainingConsumer(planned, completed, operation_index),
    };
}

fn hasRemainingConsumer(
    planned: *const plan_mod.Plan,
    completed: []const bool,
    operation_index: usize,
) bool {
    const resource_id = planned.operations[operation_index].resource.id;
    for (planned.operations, 0..) |candidate, candidate_index| {
        if (completed[candidate_index] or candidate.kind != .delete) continue;
        if (candidate_index == operation_index) continue;
        for (candidate.dependencies) |dependency_id| {
            if (std.mem.eql(u8, dependency_id, resource_id)) return true;
        }
    }
    return false;
}

fn phaseOperationIndex(
    planned: *const plan_mod.Plan,
    resource_id: []const u8,
    phase: Phase,
) ?usize {
    for (planned.operations, 0..) |operation, index| {
        if (!inPhase(operation.kind, phase)) continue;
        if (std.mem.eql(u8, operation.resource.id, resource_id)) return index;
    }
    return null;
}

fn inPhase(kind: plan_mod.OperationKind, phase: Phase) bool {
    return switch (phase) {
        .apply => kind != .delete,
        .destroy => kind == .delete,
    };
}

fn lessThanOperationId(
    planned: *const plan_mod.Plan,
    left_index: usize,
    right_index: usize,
) bool {
    return std.mem.lessThan(
        u8,
        planned.operations[left_index].resource.id,
        planned.operations[right_index].resource.id,
    );
}

fn deinitLevelList(
    allocator: std.mem.Allocator,
    levels: *std.ArrayList(ExecutionLevel),
) void {
    for (levels.items) |level| allocator.free(level.operation_indexes);
    levels.deinit(allocator);
}
