const std = @import("std");
const zstd = @import("zigeffect_std");
const checkpoint_mod = @import("checkpoint.zig");
const executor = @import("executor.zig");
const gcp_auth = @import("gcp/auth/root.zig");
const importer = @import("importer.zig");
const local_state = @import("local_state.zig");
const plan_mod = @import("plan.zig");
const provider_mod = @import("provider.zig");
const refresh = @import("refresh.zig");
const stack_registry = @import("stack_registry.zig");
const state_mod = @import("state.zig");
const state_backend = @import("state_backend.zig");

pub const Exit = struct {
    pub const success: u8 = 0;
    pub const usage: u8 = 2;
    pub const missing_stack: u8 = 3;
    pub const invalid_graph: u8 = 4;
    pub const state_error: u8 = 5;
    pub const provider_error: u8 = 6;
    pub const auth_error: u8 = 7;
};

pub const Env = struct {
    console: *zstd.Console.CapturedConsole,
    registry: stack_registry.StackRegistry,
    state: state_backend.Store,
    migration_source: ?local_state.Store = null,
    auth_env: ?*zstd.Env.EnvMap = null,
    auth_files: ?gcp_auth.FileReader = null,
    live_providers: ?provider_mod.ProviderRegistry = null,
    live_project_id: ?[]const u8 = null,
};

const Args = struct {
    command: []const u8,
    stack: []const u8,
    stage: []const u8,
    resource_id: ?[]const u8 = null,
    physical_id: ?[]const u8 = null,
    lineage: ?[]const u8 = null,
    force: bool = false,
    json: bool = false,
    provider_name: []const u8 = "fake",
    allow_live: bool = false,
    live_test: bool = false,
    region: ?[]const u8 = null,
    confirm: bool = false,
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
    .{
        .name = "json",
        .kind = .boolean,
        .help = "emit stable JSON",
    },
    .{
        .name = "provider",
        .kind = .string,
        .help = "provider runtime: fake or gcp",
    },
    .{
        .name = "allow-live",
        .kind = .boolean,
        .help = "allow authenticated provider calls",
    },
    .{
        .name = "live-test",
        .kind = .boolean,
        .help = "require a disposable live project",
    },
};

const import_options = [_]zstd.Cli.OptionSpec{
    command_options[0],
    command_options[1],
    command_options[2],
    command_options[3],
    command_options[4],
    command_options[5],
    .{ .name = "resource", .kind = .string, .required = true, .help = "logical resource ID" },
    .{ .name = "id", .kind = .string, .required = true, .help = "provider physical ID" },
};

const destroy_options = [_]zstd.Cli.OptionSpec{
    command_options[0],
    command_options[1],
    command_options[2],
    command_options[3],
    command_options[4],
    command_options[5],
    .{ .name = "confirm", .kind = .boolean, .help = "confirm destructive operations" },
};

const unlock_options = [_]zstd.Cli.OptionSpec{
    command_options[0],
    command_options[1],
    command_options[2],
    .{ .name = "lineage", .kind = .string, .help = "expected state lineage" },
    .{ .name = "force", .kind = .boolean, .help = "override lineage check" },
};

const fail_region_options = [_]zstd.Cli.OptionSpec{
    command_options[0],
    command_options[1],
    command_options[2],
    command_options[3],
    command_options[4],
    command_options[5],
    .{ .name = "region", .kind = .string, .required = true, .help = "Cloud Run region to delete for failover testing" },
};

const auth_subcommands = [_]zstd.Cli.CommandSpec{
    .{
        .name = "doctor",
        .description = "inspect Google Application Default Credentials",
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
        .options = destroy_options[0..],
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
    .{
        .name = "state-migrate",
        .description = "migrate local state to the selected backend",
        .options = command_options[0..3],
    },
    .{
        .name = "refresh",
        .description = "refresh observed provider state",
        .options = command_options[0..],
    },
    .{
        .name = "import",
        .description = "import an existing provider resource",
        .options = import_options[0..],
    },
    .{
        .name = "unlock",
        .description = "remove a local state writer lock",
        .options = unlock_options[0..],
    },
    .{
        .name = "fail-region",
        .description = "delete one regional service in a disposable live test",
        .options = fail_region_options[0..],
    },
    .{
        .name = "auth",
        .description = "inspect authentication",
        .subcommands = auth_subcommands[0..],
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
    if (std.mem.eql(u8, args.command, "state-migrate")) return runStateMigrate(allocator, env, args);
    if (std.mem.eql(u8, args.command, "refresh")) return runRefresh(allocator, env, args);
    if (std.mem.eql(u8, args.command, "import")) return runImport(allocator, env, args);
    if (std.mem.eql(u8, args.command, "unlock")) return runUnlock(env, args);
    if (std.mem.eql(u8, args.command, "fail-region")) return runFailRegion(allocator, env, args);
    if (std.mem.eql(u8, args.command, "doctor")) return runAuthDoctor(allocator, env);

    try writeError(env, "usage", error.UnknownSubcommand);
    return Exit.usage;
}

fn parseArgs(allocator: std.mem.Allocator, raw_args: []const []const u8) !Args {
    var parsed = try zstd.Cli.parse(allocator, commandSpec(), raw_args);
    defer parsed.deinit(allocator);

    if (std.mem.eql(u8, parsed.command, "ziac")) return error.MissingSubcommand;

    if (std.mem.eql(u8, parsed.command, "doctor")) {
        return .{
            .command = parsed.command,
            .stack = "",
            .stage = "",
        };
    }

    return .{
        .command = parsed.command,
        .stack = parsed.optionValue("stack") orelse return error.MissingRequiredOption,
        .stage = parsed.optionValue("stage") orelse return error.MissingRequiredOption,
        .resource_id = parsed.optionValue("resource"),
        .physical_id = parsed.optionValue("id"),
        .lineage = parsed.optionValue("lineage"),
        .force = parsed.optionValue("force") != null,
        .json = parsed.optionValue("json") != null,
        .provider_name = parsed.optionValue("provider") orelse "fake",
        .allow_live = parsed.optionValue("allow-live") != null,
        .live_test = parsed.optionValue("live-test") != null,
        .region = parsed.optionValue("region"),
        .confirm = parsed.optionValue("confirm") != null,
    };
}

fn runAuthDoctor(allocator: std.mem.Allocator, env: *Env) !u8 {
    const auth_env = env.auth_env orelse {
        try writeError(env, "auth", error.AuthEnvironmentUnavailable);
        return Exit.auth_error;
    };
    var auth_files = env.auth_files orelse {
        try writeError(env, "auth", error.AuthFileSystemUnavailable);
        return Exit.auth_error;
    };
    var resolved = gcp_auth.resolveAdcAlloc(allocator, auth_env.*, &auth_files) catch |err| {
        try writeError(env, "auth", err);
        return Exit.auth_error;
    };
    defer resolved.deinit(allocator);
    const diagnostic = resolved.doctorJsonAlloc(allocator) catch |err| {
        try writeError(env, "auth", err);
        return Exit.auth_error;
    };
    defer allocator.free(diagnostic);
    try env.console.writeOut(diagnostic);
    try env.console.writeOut("\n");
    return Exit.success;
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

    var fake_provider = provider_mod.FakeProvider.init(allocator);
    defer fake_provider.deinit();
    const providers = selectProviders(env, args, &program.graph, &fake_provider) catch |err| {
        return handleProviderSelectionError(env, err);
    };
    var planned = if (isLive(args))
        plan_mod.buildRefreshedPlan(allocator, &program.graph, &loaded.store, providers) catch |err| {
            return handlePlanError(env, err);
        }
    else
        plan_mod.buildPlan(allocator, &program.graph, &loaded.store) catch |err| {
            return handlePlanError(env, err);
        };
    defer planned.deinit();

    try writePlan(env, args, planned, loaded.store.serialValue());
    return Exit.success;
}

fn runDeploy(allocator: std.mem.Allocator, env: *Env, args: Args) !u8 {
    var program = env.registry.build(allocator, .{ .stack = args.stack, .stage = args.stage }) catch |err| {
        return handleStackError(env, err);
    };
    defer program.deinit();

    var fake_provider = provider_mod.FakeProvider.init(allocator);
    defer fake_provider.deinit();
    const providers = selectProviders(env, args, &program.graph, &fake_provider) catch |err| {
        return handleProviderSelectionError(env, err);
    };

    var command_lock = acquireCommandLock(allocator, env, args) catch |err| {
        return handleStateError(env, err);
    };
    defer command_lock.deinit();

    var loaded = env.state.loadResourcesOrEmpty(args.stack, args.stage) catch |err| {
        return handleStateError(env, err);
    };
    defer loaded.deinit();

    var planned = plan_mod.buildPlan(allocator, &program.graph, &loaded.store) catch |err| {
        return handlePlanError(env, err);
    };
    defer planned.deinit();

    var checkpoint = checkpoint_mod.Resources{
        .store = env.state,
        .stack = args.stack,
        .stage = args.stage,
        .lock_owner_id = command_lock.owner_id,
    };
    executor.executePlan(allocator, &planned, &loaded.store, providers, .{
        .checkpoint = checkpoint.checkpoint(),
    }) catch |err| {
        return handleApplyError(env, err);
    };

    env.state.saveResources(args.stack, args.stage, &loaded.store) catch |err| {
        return handleStateError(env, err);
    };
    const resolved_outputs = program.resolveOutputsAlloc(allocator, &loaded.store) catch |err| {
        return handleStateError(env, err);
    };
    defer stack_registry.StackProgram.freeResolvedOutputs(allocator, resolved_outputs);
    env.state.saveOutputs(args.stack, args.stage, resolved_outputs) catch |err| {
        return handleStateError(env, err);
    };

    try writePlan(env, args, planned, loaded.store.serialValue());
    if (!args.json) try env.console.writeOut("Deploy complete\n");
    return Exit.success;
}

fn runDestroy(allocator: std.mem.Allocator, env: *Env, args: Args) !u8 {
    var program = env.registry.build(allocator, .{ .stack = args.stack, .stage = args.stage }) catch |err| {
        return handleStackError(env, err);
    };
    defer program.deinit();
    var fake_provider = provider_mod.FakeProvider.init(allocator);
    defer fake_provider.deinit();
    const providers = selectProviders(env, args, &program.graph, &fake_provider) catch |err| {
        return handleProviderSelectionError(env, err);
    };
    var command_lock = acquireCommandLock(allocator, env, args) catch |err| {
        return handleStateError(env, err);
    };
    defer command_lock.deinit();

    var loaded = env.state.loadResourcesOrEmpty(args.stack, args.stage) catch |err| {
        return handleStateError(env, err);
    };
    defer loaded.deinit();

    var planned = plan_mod.buildDestroyPlan(allocator, &loaded.store) catch |err| {
        return handlePlanError(env, err);
    };
    defer planned.deinit();

    var checkpoint = checkpoint_mod.Resources{
        .store = env.state,
        .stack = args.stack,
        .stage = args.stage,
        .lock_owner_id = command_lock.owner_id,
    };
    executor.executePlan(allocator, &planned, &loaded.store, providers, .{
        .checkpoint = checkpoint.checkpoint(),
        .destructive_confirmation = args.confirm,
    }) catch |err| {
        return handleApplyError(env, err);
    };

    env.state.saveResources(args.stack, args.stage, &loaded.store) catch |err| {
        return handleStateError(env, err);
    };

    try writePlan(env, args, planned, loaded.store.serialValue());
    if (!args.json) try env.console.writeOut("Destroy complete\n");
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

const ProviderSelectionError = error{
    UnknownProvider,
    LiveMutationNotAllowed,
    LiveProviderUnavailable,
    LiveProjectUnavailable,
    LiveProjectMismatch,
    UnsafeLiveProject,
};

fn selectProviders(
    env: *Env,
    args: Args,
    graph: *const @import("resource.zig").ResourceGraph,
    fake: *provider_mod.FakeProvider,
) ProviderSelectionError!provider_mod.ProviderRegistry {
    if (!isLive(args)) {
        if (!std.mem.eql(u8, args.provider_name, "fake") or args.live_test) return error.UnknownProvider;
        return fakeProviderRegistry(fake);
    }
    if (!args.allow_live) return error.LiveMutationNotAllowed;
    const providers = env.live_providers orelse return error.LiveProviderUnavailable;
    const project_id = env.live_project_id orelse return error.LiveProjectUnavailable;
    if (args.live_test and !isDisposableProjectId(project_id)) return error.UnsafeLiveProject;
    for (graph.resources.items) |node| {
        if (node.provider != .gcp) continue;
        const desired_project = resourceProjectId(node) orelse return error.LiveProjectMismatch;
        if (!std.mem.eql(u8, desired_project, project_id)) return error.LiveProjectMismatch;
    }
    return providers;
}

fn isLive(args: Args) bool {
    return std.mem.eql(u8, args.provider_name, "gcp");
}

pub fn isDisposableProjectId(project_id: []const u8) bool {
    return project_id.len > "-ziac-disposable".len and std.mem.endsWith(u8, project_id, "-ziac-disposable");
}

fn resourceProjectId(node: @import("resource.zig").ResourceNode) ?[]const u8 {
    const fields = switch (node.inputs) {
        .object => |fields| fields,
        else => return null,
    };
    for (fields) |field| {
        if (!std.mem.eql(u8, field.name, "project_id")) continue;
        return switch (field.value) {
            .string => |project_id| project_id,
            else => null,
        };
    }
    return null;
}

fn runOutputs(_: std.mem.Allocator, env: *Env, args: Args) !u8 {
    var outputs = env.state.loadOutputs(args.stack, args.stage) catch |err| {
        return handleStateError(env, err);
    };
    defer outputs.deinit();

    if (args.json) {
        try writeCommandJson(env, args, 0, .{});
        return Exit.success;
    }

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

    if (args.json) {
        try writeCommandJson(env, args, loaded.store.serialValue(), .{});
        return Exit.success;
    }

    for (records) |record| {
        try env.console.writeOut(record.resource_id);
        try env.console.writeOut(" ");
        try env.console.writeOut(local_state.statusName(record.status));
        try env.console.writeOut("\n");
    }
    return Exit.success;
}

fn runStateMigrate(allocator: std.mem.Allocator, env: *Env, args: Args) !u8 {
    const source = env.migration_source orelse {
        try writeError(env, "state", error.MigrationSourceUnavailable);
        return Exit.state_error;
    };
    var command_lock = acquireCommandLock(allocator, env, args) catch |err| {
        return handleStateError(env, err);
    };
    defer command_lock.deinit();
    state_backend.migrateLocalToBackend(allocator, source, env.state, args.stack, args.stage) catch |err| {
        return handleStateError(env, err);
    };
    var loaded = env.state.loadResources(args.stack, args.stage) catch |err| {
        return handleStateError(env, err);
    };
    defer loaded.deinit();
    if (args.json) {
        try writeCommandJson(env, args, loaded.store.serialValue(), .{});
    } else {
        try env.console.writeOut("State migration complete\n");
    }
    return Exit.success;
}

fn runRefresh(allocator: std.mem.Allocator, env: *Env, args: Args) !u8 {
    var program = env.registry.build(allocator, .{ .stack = args.stack, .stage = args.stage }) catch |err| {
        return handleStackError(env, err);
    };
    defer program.deinit();
    var fake_provider = provider_mod.FakeProvider.init(allocator);
    defer fake_provider.deinit();
    const providers = selectProviders(env, args, &program.graph, &fake_provider) catch |err| {
        return handleProviderSelectionError(env, err);
    };
    var command_lock = acquireCommandLock(allocator, env, args) catch |err| {
        return handleStateError(env, err);
    };
    defer command_lock.deinit();
    var loaded = env.state.loadResourcesOrEmpty(args.stack, args.stage) catch |err| {
        return handleStateError(env, err);
    };
    defer loaded.deinit();
    var checkpoint = checkpoint_mod.Resources{
        .store = env.state,
        .stack = args.stack,
        .stage = args.stage,
        .lock_owner_id = command_lock.owner_id,
    };
    refresh.refreshGraph(allocator, &program.graph, &loaded.store, providers, checkpoint.checkpoint()) catch |err| {
        return handleApplyError(env, err);
    };
    env.state.saveResources(args.stack, args.stage, &loaded.store) catch |err| {
        return handleStateError(env, err);
    };
    if (args.json) try writeCommandJson(env, args, loaded.store.serialValue(), .{}) else try env.console.writeOut("Refresh complete\n");
    return Exit.success;
}

fn runImport(allocator: std.mem.Allocator, env: *Env, args: Args) !u8 {
    var program = env.registry.build(allocator, .{ .stack = args.stack, .stage = args.stage }) catch |err| {
        return handleStackError(env, err);
    };
    defer program.deinit();
    const node = findResource(&program.graph, args.resource_id.?) orelse {
        try writeError(env, "import", error.MissingResource);
        return Exit.invalid_graph;
    };
    var fake_provider = provider_mod.FakeProvider.init(allocator);
    defer fake_provider.deinit();
    const providers = selectProviders(env, args, &program.graph, &fake_provider) catch |err| {
        return handleProviderSelectionError(env, err);
    };
    var command_lock = acquireCommandLock(allocator, env, args) catch |err| {
        return handleStateError(env, err);
    };
    defer command_lock.deinit();
    var loaded = env.state.loadResourcesOrEmpty(args.stack, args.stage) catch |err| {
        return handleStateError(env, err);
    };
    defer loaded.deinit();
    var checkpoint = checkpoint_mod.Resources{
        .store = env.state,
        .stack = args.stack,
        .stage = args.stage,
        .lock_owner_id = command_lock.owner_id,
    };
    importer.importResource(
        allocator,
        node,
        args.physical_id.?,
        &loaded.store,
        providers,
        checkpoint.checkpoint(),
    ) catch |err| return handleApplyError(env, err);
    if (args.json) try writeCommandJson(env, args, loaded.store.serialValue(), .{}) else try env.console.writeOut("Import complete\n");
    return Exit.success;
}

fn runUnlock(env: *Env, args: Args) !u8 {
    if (!args.force and args.lineage == null) {
        try writeError(env, "usage", error.MissingRequiredOption);
        return Exit.usage;
    }
    env.state.forceUnlock(args.stack, args.stage, args.lineage orelse "", args.force) catch |err| {
        return handleStateError(env, err);
    };
    if (args.json) try writeCommandJson(env, args, 0, .{}) else try env.console.writeOut("Unlock complete\n");
    return Exit.success;
}

fn runFailRegion(allocator: std.mem.Allocator, env: *Env, args: Args) !u8 {
    if (!args.live_test) {
        try writeError(env, "auth", error.LiveTestRequired);
        return Exit.auth_error;
    }
    if (!isLive(args)) {
        try writeError(env, "auth", error.LiveProviderRequired);
        return Exit.auth_error;
    }
    const region = args.region orelse {
        try writeError(env, "usage", error.MissingRequiredOption);
        return Exit.usage;
    };
    var program = env.registry.build(allocator, .{ .stack = args.stack, .stage = args.stage }) catch |err| {
        return handleStackError(env, err);
    };
    defer program.deinit();
    const service = findRegionalService(&program.graph, region) orelse {
        try writeError(env, "stack", error.RegionServiceNotFound);
        return Exit.invalid_graph;
    };
    var fake_provider = provider_mod.FakeProvider.init(allocator);
    defer fake_provider.deinit();
    const providers = selectProviders(env, args, &program.graph, &fake_provider) catch |err| {
        return handleProviderSelectionError(env, err);
    };
    var command_lock = acquireCommandLock(allocator, env, args) catch |err| {
        return handleStateError(env, err);
    };
    defer command_lock.deinit();
    var loaded = env.state.loadResources(args.stack, args.stage) catch |err| {
        return handleStateError(env, err);
    };
    defer loaded.deinit();
    const record = loaded.store.get(service.id) orelse {
        try writeError(env, "state", error.MissingRecord);
        return Exit.state_error;
    };
    const physical_id = record.physical_id orelse {
        try writeError(env, "state", error.MissingPhysicalId);
        return Exit.state_error;
    };
    const provider = providers.get(service.provider) catch |err| return handleApplyError(env, err);
    var context = provider_mod.OperationContext.init(allocator);
    context.state = &loaded.store;
    context.physical_id = physical_id;
    provider.deleteWithContext(&context, service, physical_id) catch |err| return handleApplyError(env, err);

    if (args.json) {
        try writeCommandJson(env, args, loaded.store.serialValue(), .{ .delete = 1 });
    } else {
        try env.console.stdout.print(env.console.allocator, "Regional failure injected: {s}\n", .{region});
    }
    return Exit.success;
}

fn findResource(graph: *const @import("resource.zig").ResourceGraph, resource_id: []const u8) ?@import("resource.zig").ResourceNode {
    for (graph.resources.items) |node| {
        if (std.mem.eql(u8, node.id, resource_id)) return node;
    }
    return null;
}

fn findRegionalService(
    graph: *const @import("resource.zig").ResourceGraph,
    region: []const u8,
) ?@import("resource.zig").ResourceNode {
    for (graph.resources.items) |node| {
        if (!std.mem.eql(u8, node.type_name, "gcp.run.Service")) continue;
        if (resourceInputString(node, "region")) |node_region| {
            if (std.mem.eql(u8, node_region, region)) return node;
        }
    }
    return null;
}

fn resourceInputString(node: @import("resource.zig").ResourceNode, name: []const u8) ?[]const u8 {
    const fields = switch (node.inputs) {
        .object => |fields| fields,
        else => return null,
    };
    for (fields) |field| {
        if (!std.mem.eql(u8, field.name, name)) continue;
        return switch (field.value) {
            .string => |string| string,
            else => null,
        };
    }
    return null;
}

fn writePlan(env: *Env, args: Args, planned: plan_mod.Plan, serial: u64) !void {
    const counts = planCounts(planned);
    if (args.json) return writeCommandJson(env, args, serial, counts);

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

fn planCounts(planned: plan_mod.Plan) OperationCounts {
    var counts = OperationCounts{};
    for (planned.operations) |operation| counts.add(operation.kind);
    return counts;
}

const CommandReceipt = struct {
    schema: []const u8 = "ziac.command.v1",
    command: []const u8,
    status: []const u8 = "success",
    stack: []const u8,
    stage: []const u8,
    serial: u64,
    create: usize,
    update: usize,
    delete: usize,
    noop: usize,
};

fn writeCommandJson(env: *Env, args: Args, serial: u64, counts: OperationCounts) !void {
    const json = try std.json.Stringify.valueAlloc(env.console.allocator, CommandReceipt{
        .command = args.command,
        .stack = args.stack,
        .stage = args.stage,
        .serial = serial,
        .create = counts.create,
        .update = counts.update,
        .delete = counts.delete,
        .noop = counts.noop,
    }, .{});
    defer env.console.allocator.free(json);
    try env.console.writeOut(json);
    try env.console.writeOut("\n");
}

const CommandLock = struct {
    allocator: std.mem.Allocator,
    store: state_backend.Store,
    stack: []const u8,
    stage: []const u8,
    owner_id: []const u8,

    fn deinit(self: *CommandLock) void {
        self.store.releaseLock(self.stack, self.stage, self.owner_id) catch {};
        self.allocator.free(self.owner_id);
        self.* = undefined;
    }
};

fn acquireCommandLock(
    allocator: std.mem.Allocator,
    env: *Env,
    args: Args,
) !CommandLock {
    var clock = ziacClock();
    const owner_id = try std.fmt.allocPrint(allocator, "ziac/{s}/{d}", .{ args.command, clock.nowMs() });
    errdefer allocator.free(owner_id);
    try env.state.acquireLock(args.stack, args.stage, .{
        .owner_id = owner_id,
        .command = args.command,
        .acquired_at_millis = clock.nowMs(),
    });
    return .{
        .allocator = allocator,
        .store = env.state,
        .stack = args.stack,
        .stage = args.stage,
        .owner_id = owner_id,
    };
}

fn ziacClock() @import("zigeffect_std").fx.Clock {
    return @import("zigeffect_std").fx.Clock.system();
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

fn handleProviderSelectionError(env: *Env, err: ProviderSelectionError) !u8 {
    try writeError(env, "auth", err);
    return Exit.auth_error;
}

fn handleStateError(env: *Env, err: anyerror) !u8 {
    try writeError(env, "state", err);
    return Exit.state_error;
}

fn writeError(env: *Env, phase: []const u8, err: anyerror) !void {
    try env.console.stderr.print(env.console.allocator, "{s}: {s}\n", .{ phase, @errorName(err) });
}
