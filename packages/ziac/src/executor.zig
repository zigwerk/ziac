const std = @import("std");
const fx = @import("zigeffect_std").fx;
const apply_mod = @import("apply.zig");
const checkpoint_mod = @import("checkpoint.zig");
const plan_mod = @import("plan.zig");
const provider_mod = @import("provider.zig");
const state_mod = @import("state.zig");

pub const ScheduleError = error{
    DependencyCycle,
    DuplicateOperation,
    InvalidConcurrency,
    OutOfMemory,
};

pub const PreconditionError = error{
    StalePlan,
    PlanLineageMismatch,
    PlanIntegrityMismatch,
    DestructiveConfirmationRequired,
};

pub const ExecuteError = ScheduleError || PreconditionError || apply_mod.ApplyError || fx.DependencyError;

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
    checkpoint: ?checkpoint_mod.Checkpoint = null,
    destructive_confirmation: bool = false,
    diagnostics: ?*provider_mod.ProviderDiagnosticRecorder = null,
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
    try validatePreconditions(allocator, planned, store, options);
    if (options.cancellation) |token| {
        if (token.isCancelled()) return error.ProviderCancelled;
    }

    var schedule = try buildSchedule(allocator, planned);
    defer schedule.deinit();
    var system_clock = fx.Clock.system();
    var internal_cancellation = CancellationToken{};
    var checkpoint_mutex = fx.SpinLock{};
    const resumed_operations = try allocator.alloc(bool, planned.operations.len);
    defer allocator.free(resumed_operations);
    @memset(resumed_operations, false);
    var execution_options = options;
    if (execution_options.checkpoint) |checkpoint| {
        execution_options.checkpoint = checkpoint.serialized(&checkpoint_mutex);
    }
    var environment = ExecutionEnvironment{
        .allocator = allocator,
        .planned = planned,
        .store = store,
        .providers = providers,
        .options = execution_options,
        .clock = options.clock orelse &system_clock,
        .internal_cancellation = &internal_cancellation,
        .resumed_operations = resumed_operations,
    };
    try resumeIncompleteOperations(&environment);
    for (schedule.levels) |level| {
        var batch_start: usize = 0;
        while (batch_start < level.operation_indexes.len) {
            const batch_end = @min(batch_start + options.max_concurrency, level.operation_indexes.len);
            const indexes = level.operation_indexes[batch_start..batch_end];
            const jobs = try allocator.alloc(ExecutionJobState, indexes.len);
            defer allocator.free(jobs);
            const handles = try allocator.alloc(?*anyopaque, indexes.len);
            defer allocator.free(handles);
            @memset(handles, null);
            for (indexes, 0..) |operation_index, index| {
                jobs[index] = .{ .environment = &environment, .operation_index = operation_index };
            }

            for (jobs, 0..) |*job, index| {
                if (options.fiber_executor) |executor| {
                    handles[index] = executor.vtable.spawn(executor.context, .{ .context = job, .run = ExecutionJobState.runOpaque });
                    if (handles[index] == null) job.run();
                } else job.run();
            }
            if (options.fiber_executor) |executor| {
                for (handles) |maybe_handle| if (maybe_handle) |handle| {
                    executor.vtable.join(executor.context, handle);
                    executor.vtable.destroy(executor.context, handle);
                };
            }
            for (jobs) |job| if (job.failure) |failure| return failure;
            batch_start = batch_end;
        }
    }
}

fn validatePreconditions(
    allocator: std.mem.Allocator,
    planned: *const plan_mod.Plan,
    store: *state_mod.InMemoryStateStore,
    options: ExecuteOptions,
) ExecuteError!void {
    const metadata = store.metadata();
    if (!std.mem.eql(u8, &metadata.lineage_hash, &planned.preconditions.lineage_hash)) {
        return error.PlanLineageMismatch;
    }
    if (metadata.serial != planned.preconditions.state_serial) return error.StalePlan;
    const operations_digest = try plan_mod.operationsDigestAlloc(allocator, planned.operations);
    if (!std.mem.eql(u8, &operations_digest, &planned.preconditions.operations_digest)) {
        return error.PlanIntegrityMismatch;
    }
    if (plan_mod.hasDestructiveOperations(planned.operations) and !options.destructive_confirmation) {
        return error.DestructiveConfirmationRequired;
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
    resumed_operations: []bool,

    fn isCancelled(self: *const ExecutionEnvironment) bool {
        if (self.internal_cancellation.isCancelled()) return true;
        if (self.options.cancellation) |token| return token.isCancelled();
        return false;
    }
};

const ExecutionJobState = struct {
    environment: *ExecutionEnvironment,
    operation_index: usize,
    failure: ?ExecuteError = null,

    fn run(self: *ExecutionJobState) void {
        self.runFallible() catch |failure| {
            self.failure = failure;
        };
    }

    fn runOpaque(raw: ?*anyopaque) void {
        const self: *ExecutionJobState = @ptrCast(@alignCast(raw.?));
        self.run();
    }

    fn runFallible(self: *ExecutionJobState) ExecuteError!void {
        const environment = self.environment;
        if (environment.isCancelled()) return error.ProviderCancelled;
        const operation = environment.planned.operations[self.operation_index];
        if (environment.resumed_operations[self.operation_index]) {
            recordFact(environment, operation, "resumed");
            return;
        }
        recordFact(environment, operation, "started");
        executeWithRetry(environment, operation) catch |err| {
            environment.internal_cancellation.cancel();
            recordFact(environment, operation, if (err == error.OperationPending) "incomplete" else "failure");
            return err;
        };
        recordFact(environment, operation, "success");
    }
};

fn executeWithRetry(
    environment: *ExecutionEnvironment,
    operation: plan_mod.PlanOperation,
) ExecuteError!void {
    if (operation.kind == .noop or operation.kind == .read) return;
    const provider = try environment.providers.get(operation.resource.provider);
    const started_at = environment.clock.nowMs();
    const timeout_millis = operation.resource.lifecycle.operation_timeout_millis;
    var operation_context = operationContext(environment, operation, started_at);
    var retry_index: usize = 0;

    while (true) {
        try operation_context.checkActive();
        apply_mod.applyOperationWithContext(
            &operation_context,
            operation,
            environment.store,
            provider,
            environment.options.checkpoint,
        ) catch |err| {
            if (!isRetryable(err)) return err;
            const delay_millis = environment.options.retry_schedule.nextDelay(retry_index) orelse return err;
            const elapsed = environment.clock.nowMs() -| started_at;
            if (elapsed >= timeout_millis or delay_millis > timeout_millis - elapsed) return error.ProviderTimeout;
            recordCausal(environment, .{
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

fn resumeIncompleteOperations(environment: *ExecutionEnvironment) ExecuteError!void {
    for (environment.planned.operations, 0..) |operation, operation_index| {
        const maybe_existing = try environment.store.getOwned(environment.allocator, operation.resource.id);
        if (maybe_existing == null) {
            if (operation.kind == .noop) {
                try adoptUntrackedNoop(environment, operation, operation_index);
            }
            continue;
        }
        var existing = maybe_existing.?;
        defer existing.deinit(environment.allocator);
        if (!isIncomplete(existing.status)) continue;

        const provider = try environment.providers.get(operation.resource.provider);
        const started_at = environment.clock.nowMs();
        var operation_context = operationContext(environment, operation, started_at);
        operation_context.physical_id = existing.physical_id;
        operation_context.operation_handle = existing.operation_handle;
        var read = try provider.readWithContext(&operation_context, operation.resource);
        defer read.deinit();
        switch (read) {
            .absent => {
                if (existing.status == .deleting) {
                    try apply_mod.completeAbsentDelete(
                        environment.allocator,
                        environment.store,
                        operation,
                        environment.options.checkpoint,
                    );
                    environment.resumed_operations[operation_index] = true;
                } else if (existing.operation_handle != null) {
                    return error.OperationPending;
                }
            },
            .present => |*observed| {
                if (existing.status == .deleting) continue;
                var diff = try provider.diffWithContext(&operation_context, operation.resource, observed);
                defer diff.deinit();
                if (diff.kind == .noop) {
                    try apply_mod.adoptObserved(
                        environment.store,
                        operation,
                        observed.*,
                        environment.options.checkpoint,
                    );
                    environment.resumed_operations[operation_index] = true;
                }
            },
        }
    }
}

fn adoptUntrackedNoop(
    environment: *ExecutionEnvironment,
    operation: plan_mod.PlanOperation,
    operation_index: usize,
) ExecuteError!void {
    const provider = try environment.providers.get(operation.resource.provider);
    const started_at = environment.clock.nowMs();
    var operation_context = operationContext(environment, operation, started_at);
    var read = try provider.readWithContext(&operation_context, operation.resource);
    defer read.deinit();
    switch (read) {
        .absent => return error.Conflict,
        .present => |*observed| {
            var diff = try provider.diffWithContext(&operation_context, operation.resource, observed);
            defer diff.deinit();
            if (diff.kind != .noop) return error.Conflict;
            try apply_mod.adoptObserved(
                environment.store,
                operation,
                observed.*,
                environment.options.checkpoint,
            );
            environment.resumed_operations[operation_index] = true;
        },
    }
}

fn operationContext(
    environment: *ExecutionEnvironment,
    operation: plan_mod.PlanOperation,
    started_at: u64,
) provider_mod.OperationContext {
    return .{
        .allocator = environment.allocator,
        .state = environment.store,
        .clock = environment.clock,
        .cancellation = .{
            .ptr = environment,
            .isCancelledFn = executionCancelled,
        },
        .deadline_millis = std.math.add(
            u64,
            started_at,
            operation.resource.lifecycle.operation_timeout_millis,
        ) catch std.math.maxInt(u64),
        .destructive_confirmation = environment.options.destructive_confirmation,
        .diagnostics = environment.options.diagnostics,
    };
}

fn isIncomplete(status: state_mod.ResourceStatus) bool {
    return switch (status) {
        .planned, .creating, .updating, .replacing, .deleting, .failed, .tainted => true,
        .created, .updated, .deleted, .adopted => false,
    };
}

fn executionCancelled(raw: *const anyopaque) bool {
    const environment: *const ExecutionEnvironment = @ptrCast(@alignCast(raw));
    return environment.isCancelled();
}

fn recordFact(
    environment: *ExecutionEnvironment,
    operation: plan_mod.PlanOperation,
    status: []const u8,
) void {
    recordCausal(environment, .{
        .kind = .workflow_event_recorded,
        .label = operation.resource.id,
        .status = status,
        .type_name = @tagName(operation.kind),
    });
}

fn recordCausal(environment: *ExecutionEnvironment, event: fx.CausalEvent) void {
    const store = environment.options.causal_store orelse return;
    _ = store.record(event) catch {};
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
