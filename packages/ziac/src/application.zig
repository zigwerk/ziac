const std = @import("std");
const zstd = @import("zigeffect_std");
const agent_tools = @import("agent_tools.zig");
const executor_mod = @import("executor.zig");
const plan_mod = @import("plan.zig");
const provider_mod = @import("provider.zig");
const resource_mod = @import("resource.zig");
const runtime_events = @import("runtime_events.zig");
const stack_registry = @import("stack_registry.zig");
const state_mod = @import("state.zig");

const kernel = zstd.fx.kernel;
const ErasedServiceState = *anyopaque;

/// Stable project-program compilation capability. Implementations may invoke a
/// checked native compiler or serve an already compiled program; adapters do
/// not know which one they received.
pub const ProjectCompilerApi = struct {
    pub const operations: []const []const u8 = &.{"ProjectCompiler.build"};
    state: ErasedServiceState,
    build_fn: *const fn (ErasedServiceState, std.mem.Allocator, stack_registry.StackArgs) anyerror!stack_registry.StackProgram,

    pub fn from(comptime Implementation: type, implementation: *Implementation) ProjectCompilerApi {
        return .{
            .state = implementation,
            .build_fn = struct {
                fn call(raw: ErasedServiceState, allocator: std.mem.Allocator, args: stack_registry.StackArgs) anyerror!stack_registry.StackProgram {
                    const typed: *Implementation = @ptrCast(@alignCast(raw));
                    return typed.build(allocator, args);
                }
            }.call,
        };
    }

    pub fn build(self: ProjectCompilerApi, allocator: std.mem.Allocator, args: stack_registry.StackArgs) !stack_registry.StackProgram {
        return self.build_fn(self.state, allocator, args);
    }
};
pub const ProjectCompiler = kernel.Service("ziac/ProjectCompiler", ProjectCompilerApi);

/// Application-scoped state capability used by command effects. Stack locks
/// and checkpoints remain child-scope resources rather than fields on this tag.
pub const StateStoreApi = struct {
    pub const operations: []const []const u8 = &.{ "StateStore.read", "StateStore.write", "StateStore.checkpoint" };
    store: *state_mod.InMemoryStateStore,
};
pub const StateStore = kernel.Service("ziac/StateStore", StateStoreApi);

/// Already-acquired provider clients plus the command execution policy. Scoped
/// provider-process layers own process startup and finalization.
pub const ProviderRegistryApi = struct {
    pub const operations: []const []const u8 = &.{ "ProviderRegistry.resolve", "ProviderRegistry.execute" };
    registry: provider_mod.ProviderRegistry,
    options: executor_mod.ExecuteOptions = .{},
};
pub const ProviderRegistry = kernel.Service("ziac/ProviderRegistry", ProviderRegistryApi);

/// Bounded process capability for provider RPC and declared verification.
pub const ProcessSpawnerApi = struct {
    pub const operations: []const []const u8 = &.{ "ProcessSpawner.provider", "ProcessSpawner.verify" };
    verification: ?agent_tools.VerificationRunner = null,
};
pub const ProcessSpawner = kernel.Service("ziac/ProcessSpawner", ProcessSpawnerApi);

/// Desired infrastructure supplied to the canonical one-shot application.
/// The graph remains caller-owned and immutable for the lifetime of the root
/// layer.
pub const StackApi = struct {
    pub const operations: []const []const u8 = &.{"Stack.plan"};
    graph: *const resource_mod.ResourceGraph,
};
pub const Stack = kernel.Service("ziac/Stack", StackApi);

pub fn rootLayer(
    compiler: ProjectCompilerApi,
    state: *state_mod.InMemoryStateStore,
    providers: provider_mod.ProviderRegistry,
    spawner: ProcessSpawnerApi,
    options: executor_mod.ExecuteOptions,
) @TypeOf(kernel.Layer.mergeAll(.{
    kernel.Layer.succeed(ProjectCompiler, compiler),
    kernel.Layer.succeed(StateStore, StateStoreApi{ .store = state }),
    kernel.Layer.succeed(ProviderRegistry, ProviderRegistryApi{ .registry = providers, .options = options }),
    kernel.Layer.succeed(ProcessSpawner, spawner),
})) {
    return kernel.Layer.mergeAll(.{
        kernel.Layer.succeed(ProjectCompiler, compiler),
        kernel.Layer.succeed(StateStore, StateStoreApi{ .store = state }),
        kernel.Layer.succeed(ProviderRegistry, ProviderRegistryApi{ .registry = providers, .options = options }),
        kernel.Layer.succeed(ProcessSpawner, spawner),
    });
}

const PlanBase = kernel.Effect(plan_mod.Plan, plan_mod.BuildPlanError, .{StateStore});
pub const PlanEffect = PlanBase.Stateful(*const resource_mod.ResourceGraph);

pub fn planEffect(desired: *const resource_mod.ResourceGraph) PlanEffect {
    return PlanEffect.init(desired, struct {
        fn run(graph: *const resource_mod.ResourceGraph, ctx: *PlanEffect.Context) plan_mod.BuildPlanError!plan_mod.Plan {
            const state = ctx.service(StateStore).store;
            const events = runtime_events.Recorder.fromContext(ctx);
            const planned = plan_mod.buildPlan(ctx.allocator(), graph, state) catch |failure| {
                _ = events.plan("ziac.plan.build", "failure", @errorName(failure));
                return failure;
            };
            _ = events.plan("ziac.plan.build", "success", "deterministic-plan");
            return planned;
        }
    }.run);
}

const ExecuteBase = kernel.Effect(void, executor_mod.ExecuteError, .{ StateStore, ProviderRegistry });
pub const ExecuteEffect = ExecuteBase.Stateful(*const plan_mod.Plan);

pub fn executeEffect(planned: *const plan_mod.Plan) ExecuteEffect {
    return ExecuteEffect.init(planned, struct {
        fn run(value: *const plan_mod.Plan, ctx: *ExecuteEffect.Context) executor_mod.ExecuteError!void {
            const state = ctx.service(StateStore).store;
            const providers = ctx.service(ProviderRegistry);
            var options = providers.options;
            options.fiber_executor = ctx.executor();
            return executor_mod.executePlanObserved(
                ctx.allocator(),
                value,
                state,
                providers.registry,
                options,
                runtime_events.Recorder.fromContext(ctx),
            );
        }
    }.run);
}

const ApplicationProgram = kernel.Effect(void, anyerror, .{ Stack, StateStore, ProviderRegistry });

fn applicationProgram(ctx: *ApplicationProgram.Context) anyerror!void {
    const stack = ctx.service(Stack).graph;
    const state = ctx.service(StateStore).store;
    const providers = ctx.service(ProviderRegistry);
    const events = runtime_events.Recorder.fromContext(ctx);

    const plan_started = events.plan("ziac.application.plan", "started", "deterministic-plan");
    var planned = plan_mod.buildPlan(ctx.allocator(), stack, state) catch |failure| {
        _ = events.child(plan_started).plan("ziac.application.plan", "failure", @errorName(failure));
        return failure;
    };
    defer planned.deinit();
    const plan_completed = events.child(plan_started).plan("ziac.application.plan", "success", "deterministic-plan");

    var options = providers.options;
    options.fiber_executor = ctx.executor();
    try executor_mod.executePlanObserved(
        ctx.allocator(),
        &planned,
        state,
        providers.registry,
        options,
        events.child(plan_completed),
    );
}

/// Canonical composition and checked lifecycle for a one-shot Ziac
/// infrastructure program. Applications declare stack, state and providers;
/// runtime causal storage and Ziac semantic instrumentation are automatic.
pub const Application = struct {
    pub const Config = struct {
        stack: *const resource_mod.ResourceGraph,
        state: *state_mod.InMemoryStateStore,
        providers: provider_mod.ProviderRegistry,
        options: executor_mod.ExecuteOptions = .{},
    };

    pub fn layer(config: Config) @TypeOf(kernel.Layer.mergeAll(.{
        kernel.Layer.succeed(Stack, .{ .graph = config.stack }),
        kernel.Layer.succeed(StateStore, .{ .store = config.state }),
        kernel.Layer.succeed(ProviderRegistry, .{ .registry = config.providers, .options = config.options }),
    })) {
        return kernel.Layer.mergeAll(.{
            kernel.Layer.succeed(Stack, .{ .graph = config.stack }),
            kernel.Layer.succeed(StateStore, .{ .store = config.state }),
            kernel.Layer.succeed(ProviderRegistry, .{ .registry = config.providers, .options = config.options }),
        });
    }

    pub fn program() ApplicationProgram {
        return ApplicationProgram.fromFn(applicationProgram);
    }

    /// Interpret the application, require a healthy durable graph, then flush
    /// and release the managed runtime. Tests that need to inspect evidence run
    /// `program()` directly and perform checked shutdown after publication.
    pub fn run(runtime: anytype) !void {
        errdefer runtime.shutdown() catch {};
        try runtime.run(program().named("ziac.application"));
        if (runtime.graphSummary().records == 0 or runtime.causalHealth().status != .healthy) {
            return error.UnhealthyCausalRuntime;
        }
        try runtime.shutdown();
    }
};
