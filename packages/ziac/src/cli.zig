const std = @import("std");
const zstd = @import("zigeffect_std");
const checkpoint_mod = @import("checkpoint.zig");
const executor = @import("executor.zig");
const local_state = @import("local_state.zig");
const plan_mod = @import("plan.zig");
const provider_mod = @import("provider.zig");
const stack_registry = @import("stack_registry.zig");
const state_mod = @import("state.zig");

pub const Exit = struct {
    pub const success: u8 = 0;
    pub const usage: u8 = 2;
    pub const missing_stack: u8 = 3;
    pub const invalid_graph: u8 = 4;
    pub const state_error: u8 = 5;
    pub const provider_error: u8 = 6;
};

pub const Env = struct {
    console: *zstd.Console.CapturedConsole,
    registry: stack_registry.StackRegistry,
    state: local_state.Store,
};

const Args = struct {
    command: []const u8,
    stack: []const u8,
    stage: []const u8,
};

const command_options = [_]zstd.Cli.OptionSpec{
    .{
        .name = "stack",
        .kind = .string,
        .required = true,
        .help = "stack name",
    },
    .{
        .name = "stage",
        .kind = .string,
        .required = true,
        .help = "deployment stage",
    },
};

const subcommands = [_]zstd.Cli.CommandSpec{
    .{
        .name = "plan",
        .description = "preview resource changes",
        .options = command_options[0..],
    },
    .{
        .name = "deploy",
        .description = "apply resource changes",
        .options = command_options[0..],
    },
    .{
        .name = "destroy",
        .description = "delete managed resources",
        .options = command_options[0..],
    },
    .{
        .name = "outputs",
        .description = "print stack outputs",
        .options = command_options[0..],
    },
    .{
        .name = "state",
        .description = "print local state",
        .options = command_options[0..],
    },
};

pub fn commandSpec() zstd.Cli.CommandSpec {
    return .{
        .name = "ziac",
        .description = "Ziac local infrastructure commands",
        .subcommands = subcommands[0..],
    };
}

pub fn run(allocator: std.mem.Allocator, raw_args: []const []const u8, env: *Env) !u8 {
    const args = parseArgs(allocator, raw_args) catch |err| {
        try writeError(env, "usage", err);
        return Exit.usage;
    };

    if (std.mem.eql(u8, args.command, "plan")) return runPlan(allocator, env, args);
    if (std.mem.eql(u8, args.command, "deploy")) return runDeploy(allocator, env, args);
    if (std.mem.eql(u8, args.command, "destroy")) return runDestroy(allocator, env, args);
    if (std.mem.eql(u8, args.command, "outputs")) return runOutputs(allocator, env, args);
    if (std.mem.eql(u8, args.command, "state")) return runState(allocator, env, args);

    try writeError(env, "usage", error.UnknownSubcommand);
    return Exit.usage;
}

fn parseArgs(allocator: std.mem.Allocator, raw_args: []const []const u8) !Args {
    var parsed = try zstd.Cli.parse(allocator, commandSpec(), raw_args);
    defer parsed.deinit(allocator);

    if (std.mem.eql(u8, parsed.command, "ziac")) return error.MissingSubcommand;

    return .{
        .command = parsed.command,
        .stack = parsed.optionValue("stack") orelse return error.MissingRequiredOption,
        .stage = parsed.optionValue("stage") orelse return error.MissingRequiredOption,
    };
}

fn runPlan(allocator: std.mem.Allocator, env: *Env, args: Args) !u8 {
    var program = env.registry.build(allocator, .{ .stack = args.stack, .stage = args.stage }) catch |err| {
        return handleStackError(env, err);
    };
    defer program.deinit();

    var loaded = env.state.loadResourcesOrEmpty(args.stack, args.stage) catch |err| {
        return handleStateError(env, err);
    };
    defer loaded.deinit();

    var planned = plan_mod.buildPlan(allocator, &program.graph, &loaded.store) catch |err| {
        return handlePlanError(env, err);
    };
    defer planned.deinit();

    try writePlan(env, planned);
    return Exit.success;
}

fn runDeploy(allocator: std.mem.Allocator, env: *Env, args: Args) !u8 {
    var program = env.registry.build(allocator, .{ .stack = args.stack, .stage = args.stage }) catch |err| {
        return handleStackError(env, err);
    };
    defer program.deinit();

    var loaded = env.state.loadResourcesOrEmpty(args.stack, args.stage) catch |err| {
        return handleStateError(env, err);
    };
    defer loaded.deinit();

    var planned = plan_mod.buildPlan(allocator, &program.graph, &loaded.store) catch |err| {
        return handlePlanError(env, err);
    };
    defer planned.deinit();

    var fake_provider = provider_mod.FakeProvider.init(allocator);
    defer fake_provider.deinit();
    const providers = fakeProviderRegistry(&fake_provider);
    var checkpoint = checkpoint_mod.LocalResources{
        .store = env.state,
        .stack = args.stack,
        .stage = args.stage,
    };
    executor.executePlan(allocator, &planned, &loaded.store, providers, .{
        .checkpoint = checkpoint.checkpoint(),
    }) catch |err| {
        return handleApplyError(env, err);
    };

    env.state.saveResources(args.stack, args.stage, &loaded.store) catch |err| {
        return handleStateError(env, err);
    };
    env.state.saveOutputs(args.stack, args.stage, program.outputs.items) catch |err| {
        return handleStateError(env, err);
    };

    try writePlan(env, planned);
    try env.console.writeOut("Deploy complete\n");
    return Exit.success;
}

fn runDestroy(allocator: std.mem.Allocator, env: *Env, args: Args) !u8 {
    var loaded = env.state.loadResourcesOrEmpty(args.stack, args.stage) catch |err| {
        return handleStateError(env, err);
    };
    defer loaded.deinit();

    var planned = plan_mod.buildDestroyPlan(allocator, &loaded.store) catch |err| {
        return handlePlanError(env, err);
    };
    defer planned.deinit();

    var fake_provider = provider_mod.FakeProvider.init(allocator);
    defer fake_provider.deinit();
    const providers = fakeProviderRegistry(&fake_provider);
    var checkpoint = checkpoint_mod.LocalResources{
        .store = env.state,
        .stack = args.stack,
        .stage = args.stage,
    };
    executor.executePlan(allocator, &planned, &loaded.store, providers, .{
        .checkpoint = checkpoint.checkpoint(),
    }) catch |err| {
        return handleApplyError(env, err);
    };

    env.state.saveResources(args.stack, args.stage, &loaded.store) catch |err| {
        return handleStateError(env, err);
    };

    try writePlan(env, planned);
    try env.console.writeOut("Destroy complete\n");
    return Exit.success;
}

fn fakeProviderRegistry(fake: *provider_mod.FakeProvider) provider_mod.ProviderRegistry {
    const provider = fake.provider();
    var providers = provider_mod.ProviderRegistry{};
    providers.register(.local, provider);
    providers.register(.gcp, provider);
    providers.register(.cockroach, provider);
    return providers;
}

fn runOutputs(_: std.mem.Allocator, env: *Env, args: Args) !u8 {
    var outputs = env.state.loadOutputs(args.stack, args.stage) catch |err| {
        return handleStateError(env, err);
    };
    defer outputs.deinit();

    for (outputs.items) |entry| {
        try env.console.writeOut(entry.name);
        try env.console.writeOut("=");
        try env.console.writeOut(entry.value);
        try env.console.writeOut("\n");
    }
    return Exit.success;
}

fn runState(allocator: std.mem.Allocator, env: *Env, args: Args) !u8 {
    var loaded = env.state.loadResourcesOrEmpty(args.stack, args.stage) catch |err| {
        return handleStateError(env, err);
    };
    defer loaded.deinit();

    const records = loaded.store.recordsAlloc(allocator) catch |err| {
        return handleStateError(env, err);
    };
    defer allocator.free(records);

    for (records) |record| {
        try env.console.writeOut(record.resource_id);
        try env.console.writeOut(" ");
        try env.console.writeOut(local_state.statusName(record.status));
        try env.console.writeOut("\n");
    }
    return Exit.success;
}

fn writePlan(env: *Env, planned: plan_mod.Plan) !void {
    var counts = OperationCounts{};
    for (planned.operations) |operation| counts.add(operation.kind);

    try env.console.stdout.print(env.console.allocator, "Plan: {d} create, {d} update, {d} delete, {d} noop\n", .{
        counts.create,
        counts.update,
        counts.delete,
        counts.noop,
    });

    for (planned.operations) |operation| {
        try env.console.writeOut(operationSymbol(operation.kind));
        try env.console.writeOut(" ");
        try env.console.writeOut(operation.resource.type_name);
        try env.console.writeOut(" ");
        try env.console.writeOut(operation.resource.logical_id);
        try env.console.writeOut("\n");
    }
}

const OperationCounts = struct {
    create: usize = 0,
    update: usize = 0,
    delete: usize = 0,
    noop: usize = 0,

    fn add(self: *OperationCounts, kind: plan_mod.OperationKind) void {
        switch (kind) {
            .create => self.create += 1,
            .update, .replace => self.update += 1,
            .delete => self.delete += 1,
            .read, .noop => self.noop += 1,
        }
    }
};

fn operationSymbol(kind: plan_mod.OperationKind) []const u8 {
    return switch (kind) {
        .create => "+",
        .update, .replace => "~",
        .delete => "-",
        .read, .noop => "=",
    };
}

fn handleStackError(env: *Env, err: anyerror) !u8 {
    try writeError(env, "stack", err);
    return switch (err) {
        error.UnknownStack => Exit.missing_stack,
        else => Exit.invalid_graph,
    };
}

fn handlePlanError(env: *Env, err: anyerror) !u8 {
    try writeError(env, "plan", err);
    return Exit.invalid_graph;
}

fn handleApplyError(env: *Env, err: anyerror) !u8 {
    try writeError(env, "provider", err);
    return Exit.provider_error;
}

fn handleStateError(env: *Env, err: anyerror) !u8 {
    try writeError(env, "state", err);
    return Exit.state_error;
}

fn writeError(env: *Env, phase: []const u8, err: anyerror) !void {
    try env.console.stderr.print(env.console.allocator, "{s}: {s}\n", .{ phase, @errorName(err) });
}
