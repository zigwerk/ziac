const std = @import("std");
const zstd = @import("zigeffect_std");
const checkpoint_mod = @import("checkpoint.zig");
const ci_mod = @import("ci.zig");
const executor = @import("executor.zig");
const gcp_auth = @import("gcp/auth/root.zig");
const importer = @import("importer.zig");
const local_state = @import("local_state.zig");
const plan_mod = @import("plan.zig");
const plan_format = @import("plan_format.zig");
const provider_mod = @import("provider.zig");
const provider_error = @import("provider_error.zig");
const refresh = @import("refresh.zig");
const rollout_mod = @import("rollout.zig");
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
    plan_files: ?local_state.FileStore = null,
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
    out_path: ?[]const u8 = null,
    plan_path: ?[]const u8 = null,
    approval: ?[]const u8 = null,
    repository: ?[]const u8 = null,
    change_number: ?u64 = null,
    preview_cleanup: bool = false,
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

const plan_options = [_]zstd.Cli.OptionSpec{
    command_options[0],
    command_options[1],
    command_options[2],
    command_options[3],
    command_options[4],
    command_options[5],
    .{ .name = "out", .kind = .string, .help = "create an immutable saved plan" },
};

const deploy_options = [_]zstd.Cli.OptionSpec{
    command_options[0],
    command_options[1],
    command_options[2],
    command_options[3],
    command_options[4],
    command_options[5],
    .{ .name = "plan", .kind = .string, .help = "apply an immutable saved plan" },
    .{ .name = "approve", .kind = .string, .help = "approve the exact destructive plan digest" },
    .{ .name = "confirm", .kind = .boolean, .help = "confirm direct destructive operations" },
};

const destroy_options = [_]zstd.Cli.OptionSpec{
    command_options[0],
    command_options[1],
    command_options[2],
    command_options[3],
    command_options[4],
    command_options[5],
    .{ .name = "confirm", .kind = .boolean, .help = "confirm destructive operations" },
    .{ .name = "preview-cleanup", .kind = .boolean, .help = "require an exact preview stage" },
};

const rollback_options = [_]zstd.Cli.OptionSpec{
    command_options[0],
    command_options[1],
    command_options[2],
    command_options[3],
    command_options[4],
    command_options[5],
    .{ .name = "confirm", .kind = .boolean, .help = "confirm rollback to prior immutable images" },
};

const preview_stage_options = [_]zstd.Cli.OptionSpec{
    .{ .name = "repository", .kind = .string, .required = true, .help = "GitHub owner/repository" },
    .{ .name = "change", .kind = .string, .required = true, .help = "positive pull request number" },
    .{ .name = "json", .kind = .boolean, .help = "emit stable JSON" },
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
        .name = "preview-stage",
        .description = "derive a repository-bound preview stage",
        .options = preview_stage_options[0..],
    },
    .{
        .name = "plan",
        .description = "preview resource changes",
        .options = plan_options[0..],
    },
    .{
        .name = "deploy",
        .description = "apply resource changes",
        .options = deploy_options[0..],
    },
    .{
        .name = "destroy",
        .description = "delete managed resources",
        .options = destroy_options[0..],
    },
    .{
        .name = "rollback",
        .description = "restore previous regional Cloud Run images",
        .options = rollback_options[0..],
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
    if (std.mem.eql(u8, args.command, "preview-stage")) return runPreviewStage(allocator, env, args);
    if (std.mem.eql(u8, args.command, "deploy")) return runDeploy(allocator, env, args);
    if (std.mem.eql(u8, args.command, "destroy")) return runDestroy(allocator, env, args);
    if (std.mem.eql(u8, args.command, "rollback")) return runRollback(allocator, env, args);
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
    if (std.mem.eql(u8, parsed.command, "preview-stage")) {
        const change_text = parsed.optionValue("change") orelse return error.MissingRequiredOption;
        const change_number = std.fmt.parseInt(u64, change_text, 10) catch return error.InvalidChangeNumber;
        if (change_number == 0) return error.InvalidChangeNumber;
        return .{
            .command = parsed.command,
            .stack = "",
            .stage = "",
            .repository = parsed.optionValue("repository") orelse return error.MissingRequiredOption,
            .change_number = change_number,
            .json = parsed.optionValue("json") != null,
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
        .out_path = parsed.optionValue("out"),
        .plan_path = parsed.optionValue("plan"),
        .approval = parsed.optionValue("approve"),
        .preview_cleanup = parsed.optionValue("preview-cleanup") != null,
    };
}

fn runPreviewStage(allocator: std.mem.Allocator, env: *Env, args: Args) !u8 {
    const stage = ci_mod.previewStageAlloc(allocator, .{
        .repository = args.repository orelse return error.MissingRequiredOption,
        .change_number = args.change_number orelse return error.MissingRequiredOption,
    }) catch |err| {
        try writeError(env, "usage", err);
        return Exit.usage;
    };
    defer allocator.free(stage);
    if (args.json) {
        const receipt = try std.json.Stringify.valueAlloc(allocator, PreviewStageReceipt{
            .repository = args.repository.?,
            .change_number = args.change_number.?,
            .stage = stage,
        }, .{});
        defer allocator.free(receipt);
        try env.console.writeOut(receipt);
        try env.console.writeOut("\n");
    } else {
        try env.console.writeOut(stage);
        try env.console.writeOut("\n");
    }
    return Exit.success;
}

const PreviewStageReceipt = struct {
    schema: []const u8 = "ziac.preview-stage.v1",
    repository: []const u8,
    change_number: u64,
    stage: []const u8,
};

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

    var saved_metadata: ?PlanOutputMetadata = null;
    if (args.out_path) |path| {
        const files = env.plan_files orelse {
            return handlePlanError(env, error.PlanFileSystemUnavailable);
        };
        var clock = ziacClock();
        const metadata = plan_format.save(files, allocator, path, &planned, .{
            .stack = args.stack,
            .stage = args.stage,
            .created_at_millis = clock.nowMs(),
        }) catch |err| return handlePlanError(env, err);
        saved_metadata = .{
            .digest = metadata.digest,
            .path = path,
            .approval_required = metadata.approval_required,
        };
    }
    try writePlan(env, args, &planned, loaded.store.serialValue(), saved_metadata);
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

    var generated_plan: ?plan_mod.Plan = null;
    defer if (generated_plan) |*planned| planned.deinit();
    var saved_plan: ?plan_format.LoadedPlan = null;
    defer if (saved_plan) |*planned| planned.deinit();
    var planned: *const plan_mod.Plan = undefined;
    var plan_metadata: ?PlanOutputMetadata = null;
    var destructive_confirmation = args.confirm;
    if (args.plan_path) |path| {
        const files = env.plan_files orelse {
            return handlePlanError(env, error.PlanFileSystemUnavailable);
        };
        saved_plan = plan_format.load(files, allocator, path, .{}) catch |err| {
            return handlePlanError(env, err);
        };
        const loaded_plan = &saved_plan.?;
        if (!std.mem.eql(u8, loaded_plan.stack, args.stack) or !std.mem.eql(u8, loaded_plan.stage, args.stage)) {
            return handlePlanError(env, error.PlanTargetMismatch);
        }
        const graph_digest = plan_mod.desiredGraphDigestAlloc(allocator, &program.graph) catch |err| {
            return handlePlanError(env, err);
        };
        if (!std.mem.eql(u8, &graph_digest, &loaded_plan.plan.preconditions.desired_graph_digest)) {
            return handlePlanError(env, error.PlanDesiredGraphMismatch);
        }
        if (loaded_plan.approval_required) {
            const approval = args.approval orelse return handlePlanError(env, error.PlanApprovalRequired);
            const expected = loaded_plan.metadata().digestHex();
            if (!std.mem.eql(u8, approval, &expected)) return handlePlanError(env, error.PlanApprovalMismatch);
            destructive_confirmation = true;
        }
        plan_metadata = .{
            .digest = loaded_plan.digest,
            .path = path,
            .approval_required = loaded_plan.approval_required,
        };
        planned = &loaded_plan.plan;
    } else {
        generated_plan = plan_mod.buildPlan(allocator, &program.graph, &loaded.store) catch |err| {
            return handlePlanError(env, err);
        };
        planned = &generated_plan.?;
    }

    var checkpoint = checkpoint_mod.Resources{
        .store = env.state,
        .stack = args.stack,
        .stage = args.stage,
        .lock_owner_id = command_lock.owner_id,
    };
    var diagnostics = provider_error.DiagnosticRecorder.init(allocator);
    defer diagnostics.deinit();
    executor.executePlan(allocator, planned, &loaded.store, providers, .{
        .checkpoint = checkpoint.checkpoint(),
        .destructive_confirmation = destructive_confirmation,
        .diagnostics = &diagnostics,
    }) catch |err| {
        return handleApplyErrorWithDiagnostics(env, err, &diagnostics);
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

    try writePlan(env, args, planned, loaded.store.serialValue(), plan_metadata);
    if (!args.json) try env.console.writeOut("Deploy complete\n");
    return Exit.success;
}

fn runDestroy(allocator: std.mem.Allocator, env: *Env, args: Args) !u8 {
    if (args.preview_cleanup) {
        ci_mod.validatePreviewCleanup(args.stage) catch |err| return handlePlanError(env, err);
    }
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

    try writePlan(env, args, &planned, loaded.store.serialValue(), null);
    if (!args.json) try env.console.writeOut("Destroy complete\n");
    return Exit.success;
}

fn runRollback(allocator: std.mem.Allocator, env: *Env, args: Args) !u8 {
    if (!args.confirm) return handleApplyError(env, error.DestructiveConfirmationRequired);
    var program = env.registry.build(allocator, .{ .stack = args.stack, .stage = args.stage }) catch |err| {
        return handleStackError(env, err);
    };
    defer program.deinit();
    var command_lock = acquireCommandLock(allocator, env, args) catch |err| {
        return handleStateError(env, err);
    };
    defer command_lock.deinit();
    var loaded = env.state.loadResources(args.stack, args.stage) catch |err| {
        return handleStateError(env, err);
    };
    defer loaded.deinit();
    var rollback = rollout_mod.buildRollbackGraphAlloc(allocator, &program.graph, &loaded.store) catch |err| {
        return handlePlanError(env, err);
    };
    defer rollback.deinit();
    var planned = plan_mod.buildPlan(allocator, &rollback.graph, &loaded.store) catch |err| {
        return handlePlanError(env, err);
    };
    defer planned.deinit();
    validateRollbackPlan(&planned, rollback.target_count) catch |err| return handlePlanError(env, err);

    var fake_provider = provider_mod.FakeProvider.init(allocator);
    defer fake_provider.deinit();
    const providers = selectProviders(env, args, &rollback.graph, &fake_provider) catch |err| {
        return handleProviderSelectionError(env, err);
    };
    var checkpoint = checkpoint_mod.Resources{
        .store = env.state,
        .stack = args.stack,
        .stage = args.stage,
        .lock_owner_id = command_lock.owner_id,
    };
    var diagnostics = provider_error.DiagnosticRecorder.init(allocator);
    defer diagnostics.deinit();
    executor.executePlan(allocator, &planned, &loaded.store, providers, .{
        .checkpoint = checkpoint.checkpoint(),
        .diagnostics = &diagnostics,
    }) catch |err| return handleApplyErrorWithDiagnostics(env, err, &diagnostics);
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
    try writePlan(env, args, &planned, loaded.store.serialValue(), null);
    if (!args.json) try env.console.writeOut("Rollback complete\n");
    return Exit.success;
}

fn validateRollbackPlan(planned: *const plan_mod.Plan, target_count: usize) error{RollbackPlanUnsafe}!void {
    var updates: usize = 0;
    for (planned.operations) |operation| switch (operation.kind) {
        .update => {
            if (!std.mem.eql(u8, operation.resource.type_name, "gcp.run.Service")) return error.RollbackPlanUnsafe;
            updates += 1;
        },
        .noop, .read => {},
        .create, .replace, .delete => return error.RollbackPlanUnsafe,
    };
    if (updates < target_count) return error.RollbackPlanUnsafe;
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

const PlanOutputMetadata = struct {
    digest: [32]u8,
    path: []const u8,
    approval_required: bool,
};

fn writePlan(
    env: *Env,
    args: Args,
    planned: *const plan_mod.Plan,
    serial: u64,
    metadata: ?PlanOutputMetadata,
) !void {
    const counts = planCounts(planned);
    if (args.json) return writeCommandJsonWithPlan(env, args, serial, counts, metadata);

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
    if (metadata) |saved| {
        const digest = std.fmt.bytesToHex(saved.digest, .lower);
        try env.console.stdout.print(env.console.allocator, "Plan digest: {s}\n", .{&digest});
        try env.console.stdout.print(env.console.allocator, "Approval required: {s}\n", .{if (saved.approval_required) "yes" else "no"});
    }
}

fn planCounts(planned: *const plan_mod.Plan) OperationCounts {
    var counts = OperationCounts{};
    for (planned.operations) |operation| counts.add(operation.kind);
    return counts;
}

const CommandReceipt = struct {
    schema: []const u8 = "ziac.command.v2",
    command: []const u8,
    status: []const u8 = "success",
    stack: []const u8,
    stage: []const u8,
    serial: u64,
    create: usize,
    update: usize,
    delete: usize,
    noop: usize,
    plan_digest: ?[]const u8,
    plan_path: ?[]const u8,
    approval_required: bool,
};

fn writeCommandJson(env: *Env, args: Args, serial: u64, counts: OperationCounts) !void {
    return writeCommandJsonWithPlan(env, args, serial, counts, null);
}

fn writeCommandJsonWithPlan(
    env: *Env,
    args: Args,
    serial: u64,
    counts: OperationCounts,
    metadata: ?PlanOutputMetadata,
) !void {
    var digest_buffer: [64]u8 = undefined;
    const digest: ?[]const u8 = if (metadata) |saved| blk: {
        digest_buffer = std.fmt.bytesToHex(saved.digest, .lower);
        break :blk &digest_buffer;
    } else null;
    const json = try std.json.Stringify.valueAlloc(env.console.allocator, CommandReceipt{
        .command = args.command,
        .stack = args.stack,
        .stage = args.stage,
        .serial = serial,
        .create = counts.create,
        .update = counts.update,
        .delete = counts.delete,
        .noop = counts.noop,
        .plan_digest = digest,
        .plan_path = if (metadata) |saved| saved.path else null,
        .approval_required = if (metadata) |saved| saved.approval_required else false,
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

fn handleApplyErrorWithDiagnostics(
    env: *Env,
    err: anyerror,
    diagnostics: *provider_error.DiagnosticRecorder,
) !u8 {
    try writeError(env, "provider", err);
    if (try diagnostics.snapshotAlloc(env.console.allocator)) |owned| {
        var diagnostic = owned;
        defer diagnostic.deinit();
        const rendered = try diagnostic.formatAlloc(env.console.allocator);
        defer env.console.allocator.free(rendered);
        try env.console.stderr.print(env.console.allocator, "provider diagnostic: {s}\n", .{rendered});
    }
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
