const std = @import("std");
const zstd = @import("zigeffect_std");
const agent_mod = @import("agent.zig");
const agent_contract = @import("agent_contract.zig");
const agent_tools = @import("agent_tools.zig");
const checkpoint_mod = @import("checkpoint.zig");
const ci_mod = @import("ci.zig");
const dev_mod = @import("dev.zig");
const dev_native = @import("dev_native.zig");
const estate_mod = @import("estate.zig");
const estate_access = @import("estate_access.zig");
const executor = @import("executor.zig");
const gcp_auth = @import("gcp/auth/root.zig");
const gcp_coverage = @import("gcp/coverage.zig");
const importer = @import("importer.zig");
const local_state = @import("local_state.zig");
const log_mod = @import("log.zig");
const plan_mod = @import("plan.zig");
const plan_format = @import("plan_format.zig");
const provider_mod = @import("provider.zig");
const provider_error = @import("provider_error.zig");
const refresh = @import("refresh.zig");
const rollout_mod = @import("rollout.zig");
const stack_registry = @import("stack_registry.zig");
const state_mod = @import("state.zig");
const state_backend = @import("state_backend.zig");
const watch_deploy_mod = @import("watch_deploy.zig");

pub const Exit = struct {
    pub const success: u8 = 0;
    pub const usage: u8 = 2;
    pub const missing_stack: u8 = 3;
    pub const invalid_graph: u8 = 4;
    pub const state_error: u8 = 5;
    pub const provider_error: u8 = 6;
    pub const auth_error: u8 = 7;
    pub const agent_error: u8 = 8;
};

pub const WatchDeployConfig = struct {
    runtime: watch_deploy_mod.Runtime,
    workflow: watch_deploy_mod.WorkflowRuntime,
    envelope: agent_contract.CapabilityEnvelope,
    project: []const u8,
    now_millis: u64,
    regions: usize = 1,
    require_saved_plan: bool = false,
};

pub const EstateScanConfig = struct {
    resolver: estate_access.Resolver,
    client: estate_mod.Client,
    session_assertion: []const u8,
    now_millis: u64,
};

pub const NativeDevHost = struct {
    io: std.Io,
    root: std.Io.Dir,
    max_polls: ?usize = null,
};

pub const CloudLoggingConfig = struct {
    client: log_mod.CloudLoggingClient,
    project_id: []const u8,
    filter: []const u8,
    session_id: []const u8,
};

pub const Env = struct {
    console: *zstd.Console.CapturedConsole,
    registry: stack_registry.StackRegistry,
    program_loader: ?stack_registry.ProgramLoader = null,
    state: state_backend.Store,
    migration_source: ?local_state.Store = null,
    plan_files: ?local_state.FileStore = null,
    agent_files: ?local_state.FileStore = null,
    log_files: ?local_state.FileStore = null,
    auth_env: ?*zstd.Env.EnvMap = null,
    auth_files: ?gcp_auth.FileReader = null,
    live_providers: ?provider_mod.ProviderRegistry = null,
    live_project_id: ?[]const u8 = null,
    watch_deploy: ?WatchDeployConfig = null,
    estate_scan: ?EstateScanConfig = null,
    dev_host: ?NativeDevHost = null,
    cloud_logging: ?CloudLoggingConfig = null,
    verification_runner: ?agent_tools.VerificationRunner = null,
};

fn buildProgram(allocator: std.mem.Allocator, env: *Env, args: Args) !stack_registry.StackProgram {
    if (env.program_loader) |loader| return loader.build(allocator, .{ .stack = args.stack, .stage = args.stage });
    return env.registry.build(allocator, .{ .stack = args.stack, .stage = args.stage });
}

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
    project_path: []const u8 = "ziac.project.json",
    objective: ?[]const u8 = null,
    event_id: ?[]const u8 = null,
    root_cause: ?[]const u8 = null,
    trace_id: ?[]const u8 = null,
    minimum_severity: ?log_mod.Severity = null,
    watch: bool = false,
    image_ref: ?[]const u8 = null,
    plan_digest: ?[]const u8 = null,
    connection_id: ?[]const u8 = null,
    tool_arguments: ?[]const u8 = null,
    provider_service: ?gcp_coverage.Service = null,
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
    .{ .name = "watch", .kind = .boolean, .help = "watch and deploy immutable development revisions" },
    .{ .name = "image", .kind = .string, .help = "immutable image reference for watch deploy" },
    .{ .name = "plan-digest", .kind = .string, .help = "exact capability-approved watch plan digest" },
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

const estate_options = [_]zstd.Cli.OptionSpec{
    .{ .name = "connection", .kind = .string, .required = true, .help = "saved customer GCP connection ID" },
    .{ .name = "out", .kind = .string, .required = true, .help = "observed visual artifact path" },
    .{ .name = "json", .kind = .boolean, .help = "emit stable JSON" },
};

const estate_subcommands = [_]zstd.Cli.CommandSpec{
    .{ .name = "scan", .description = "scan an authorized GCP project read-only", .options = estate_options[0..] },
};

const provider_resource_options = [_]zstd.Cli.OptionSpec{
    .{ .name = "service", .kind = .string, .help = "filter by Google service family" },
    .{ .name = "json", .kind = .boolean, .help = "emit stable JSON" },
};

const provider_subcommands = [_]zstd.Cli.CommandSpec{
    .{ .name = "resources", .description = "report managed and planned GCP provider resources", .options = provider_resource_options[0..] },
};

const registry_options = [_]zstd.Cli.OptionSpec{
    .{ .name = "kind", .kind = .string, .help = "filter by component or template" },
    .{ .name = "json", .kind = .boolean, .help = "emit stable JSON" },
};

const registry_subcommands = [_]zstd.Cli.CommandSpec{
    .{ .name = "list", .description = "list verified bundled components and templates", .options = registry_options[0..] },
    .{ .name = "search", .description = "search verified bundled components and templates", .options = registry_options[0..] },
};

const package_subcommands = [_]zstd.Cli.CommandSpec{
    .{ .name = "verify", .description = "validate and digest a Ziac package manifest" },
};

const agent_options = [_]zstd.Cli.OptionSpec{
    .{ .name = "stack", .kind = .string, .required = true, .help = "stack name" },
    .{ .name = "stage", .kind = .string, .required = true, .help = "deployment stage" },
    .{ .name = "project", .kind = .string, .help = "agent project contract path" },
    .{ .name = "objective", .kind = .string, .help = "bounded agent objective" },
    .{ .name = "resource", .kind = .string, .help = "resource ID to query" },
    .{ .name = "event", .kind = .string, .help = "causal event ID to explain" },
    .{ .name = "root-cause", .kind = .string, .help = "redacted handoff root cause" },
    .{ .name = "json", .kind = .boolean, .help = "emit stable JSON" },
};

const agent_tool_options = [_]zstd.Cli.OptionSpec{
    .{ .name = "stack", .kind = .string, .required = true, .help = "stack name" },
    .{ .name = "stage", .kind = .string, .required = true, .help = "deployment stage" },
    .{ .name = "project", .kind = .string, .help = "agent project contract path" },
    .{ .name = "arguments", .kind = .string, .required = true, .help = "typed JSON tool arguments" },
    .{ .name = "json", .kind = .boolean, .help = "emit stable JSON" },
};

const dev_options = [_]zstd.Cli.OptionSpec{
    .{ .name = "stack", .kind = .string, .required = true, .help = "stack name" },
    .{ .name = "stage", .kind = .string, .required = true, .help = "personal development stage" },
    .{ .name = "project", .kind = .string, .help = "agent project contract path" },
    .{ .name = "json", .kind = .boolean, .help = "emit stable JSON" },
    .{ .name = "watch", .kind = .boolean, .help = "run the manifest-owned native hot-reload loop" },
};

const log_options = [_]zstd.Cli.OptionSpec{
    .{ .name = "stack", .kind = .string, .required = true, .help = "stack name" },
    .{ .name = "stage", .kind = .string, .required = true, .help = "deployment stage" },
    .{ .name = "resource", .kind = .string, .help = "resource ID filter" },
    .{ .name = "region", .kind = .string, .help = "region filter" },
    .{ .name = "trace", .kind = .string, .help = "trace ID filter" },
    .{ .name = "severity", .kind = .string, .help = "minimum severity" },
    .{ .name = "event", .kind = .string, .help = "event ID to explain" },
    .{ .name = "json", .kind = .boolean, .help = "emit stable JSON" },
    .{ .name = "provider", .kind = .string, .help = "live log provider: gcp" },
    .{ .name = "allow-live", .kind = .boolean, .help = "allow authenticated log ingestion" },
};

const agent_subcommands = [_]zstd.Cli.CommandSpec{
    .{ .name = "orient", .description = "validate intent and open an agent session", .options = agent_options[0..] },
    .{ .name = "status", .description = "inspect durable agent session status", .options = agent_options[0..] },
    .{ .name = "next", .description = "return one bounded next action", .options = agent_options[0..] },
    .{ .name = "query", .description = "query one resource and its graph neighborhood", .options = agent_options[0..] },
    .{ .name = "explain", .description = "explain a causal event chain", .options = agent_options[0..] },
    .{ .name = "handoff", .description = "emit a redacted structured handoff", .options = agent_options[0..] },
    .{ .name = "simulate", .description = "run a deterministic infrastructure scenario", .options = agent_tool_options[0..] },
    .{ .name = "propose", .description = "create an immutable evidence-backed repair proposal", .options = agent_tool_options[0..] },
    .{ .name = "verify", .description = "run one declared acceptance check", .options = agent_tool_options[0..] },
};

const subcommands = [_]zstd.Cli.CommandSpec{
    .{
        .name = "mcp",
        .description = "serve capability-gated Ziac tools over MCP stdio",
    },
    .{
        .name = "init",
        .description = "scaffold an agent-first global Zig backend",
    },
    .{
        .name = "check",
        .description = "compile and validate the user project program",
        .options = command_options[0..3],
    },
    .{
        .name = "dashboard",
        .description = "compile and open the live Ziac infrastructure dashboard",
        .options = command_options[0..3],
    },
    .{
        .name = "dev",
        .description = "compile the hybrid local development runtime",
        .options = dev_options[0..],
    },
    .{ .name = "logs", .description = "query durable causal logs", .options = log_options[0..] },
    .{ .name = "tail", .description = "read the latest durable causal log snapshot", .options = log_options[0..] },
    .{ .name = "log-explain", .description = "explain a causal log event", .options = log_options[0..] },
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
    .{
        .name = "estate",
        .description = "inspect paid existing-infrastructure visualization",
        .subcommands = estate_subcommands[0..],
    },
    .{
        .name = "provider",
        .description = "inspect provider contracts and resource coverage",
        .subcommands = provider_subcommands[0..],
    },
    .{
        .name = "registry",
        .description = "discover verified Ziac components and templates",
        .subcommands = registry_subcommands[0..],
    },
    .{
        .name = "package",
        .description = "inspect Ziac ecosystem package manifests",
        .subcommands = package_subcommands[0..],
    },
    .{
        .name = "agent",
        .description = "operate through structured agent artifacts",
        .subcommands = agent_subcommands[0..],
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

    if (std.mem.eql(u8, args.command, "resources")) return runProviderResources(allocator, env, args);
    if (std.mem.eql(u8, args.command, "plan")) return runPlan(allocator, env, args);
    if (std.mem.eql(u8, args.command, "dev")) return runDev(allocator, env, args);
    if (std.mem.eql(u8, args.command, "logs") or std.mem.eql(u8, args.command, "tail") or
        std.mem.eql(u8, args.command, "log-explain")) return runLogs(allocator, env, args);
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
    if (std.mem.eql(u8, args.command, "scan")) return runEstateScan(allocator, env, args);
    if (isAgentCommand(args.command)) return runAgent(allocator, env, args);

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
    if (std.mem.eql(u8, parsed.command, "resources")) {
        return .{
            .command = parsed.command,
            .stack = "",
            .stage = "",
            .json = parsed.optionValue("json") != null,
            .provider_service = if (parsed.optionValue("service")) |service|
                gcp_coverage.parseService(service) orelse return error.InvalidProviderService
            else
                null,
        };
    }
    if (std.mem.eql(u8, parsed.command, "scan")) {
        return .{
            .command = parsed.command,
            .stack = "",
            .stage = "",
            .json = true,
            .connection_id = parsed.optionValue("connection") orelse return error.MissingRequiredOption,
            .out_path = parsed.optionValue("out") orelse return error.MissingRequiredOption,
        };
    }
    if (isAgentCommand(parsed.command)) {
        return .{
            .command = parsed.command,
            .stack = parsed.optionValue("stack") orelse return error.MissingRequiredOption,
            .stage = parsed.optionValue("stage") orelse return error.MissingRequiredOption,
            .json = true,
            .project_path = parsed.optionValue("project") orelse "ziac.project.json",
            .objective = parsed.optionValue("objective"),
            .resource_id = parsed.optionValue("resource"),
            .event_id = parsed.optionValue("event"),
            .root_cause = parsed.optionValue("root-cause"),
            .tool_arguments = parsed.optionValue("arguments"),
        };
    }
    if (std.mem.eql(u8, parsed.command, "dev")) {
        return .{
            .command = parsed.command,
            .stack = parsed.optionValue("stack") orelse return error.MissingRequiredOption,
            .stage = parsed.optionValue("stage") orelse return error.MissingRequiredOption,
            .json = true,
            .project_path = parsed.optionValue("project") orelse "ziac.project.json",
            .watch = parsed.optionValue("watch") != null,
        };
    }
    if (std.mem.eql(u8, parsed.command, "logs") or std.mem.eql(u8, parsed.command, "tail") or
        std.mem.eql(u8, parsed.command, "log-explain"))
    {
        return .{
            .command = parsed.command,
            .stack = parsed.optionValue("stack") orelse return error.MissingRequiredOption,
            .stage = parsed.optionValue("stage") orelse return error.MissingRequiredOption,
            .json = true,
            .resource_id = parsed.optionValue("resource"),
            .region = parsed.optionValue("region"),
            .trace_id = parsed.optionValue("trace"),
            .event_id = parsed.optionValue("event"),
            .minimum_severity = if (parsed.optionValue("severity")) |severity| try parseLogSeverity(severity) else null,
            .provider_name = parsed.optionValue("provider") orelse "local",
            .allow_live = parsed.optionValue("allow-live") != null,
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
        .watch = parsed.optionValue("watch") != null,
        .image_ref = parsed.optionValue("image"),
        .plan_digest = parsed.optionValue("plan-digest"),
    };
}

fn runProviderResources(allocator: std.mem.Allocator, env: *Env, args: Args) !u8 {
    const filter = gcp_coverage.Filter{ .service = args.provider_service };
    const report = if (args.json)
        try gcp_coverage.jsonAlloc(allocator, filter)
    else
        try gcp_coverage.markdownAlloc(allocator, filter);
    defer allocator.free(report);
    try env.console.writeOut(report);
    if (report.len == 0 or report[report.len - 1] != '\n') try env.console.writeOut("\n");
    return Exit.success;
}

fn isAgentCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "orient") or
        std.mem.eql(u8, command, "status") or
        std.mem.eql(u8, command, "next") or
        std.mem.eql(u8, command, "query") or
        std.mem.eql(u8, command, "explain") or
        std.mem.eql(u8, command, "handoff") or
        std.mem.eql(u8, command, "simulate") or
        std.mem.eql(u8, command, "propose") or
        std.mem.eql(u8, command, "verify");
}

fn isGovernedToolCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "simulate") or std.mem.eql(u8, command, "propose") or std.mem.eql(u8, command, "verify");
}

fn runAgent(allocator: std.mem.Allocator, env: *Env, args: Args) !u8 {
    const files = env.agent_files orelse {
        try writeError(env, "agent", error.AgentFileSystemUnavailable);
        return Exit.agent_error;
    };
    const project_bytes = files.readFileAllocBounded(allocator, args.project_path, 4 * 1024 * 1024) catch |err| {
        try writeError(env, "agent", err);
        return Exit.agent_error;
    };
    defer allocator.free(project_bytes);
    var project = agent_contract.Project.parseAlloc(allocator, project_bytes) catch |err| {
        try writeError(env, "agent", err);
        return Exit.agent_error;
    };
    defer project.deinit();
    var program = buildProgram(allocator, env, args) catch |err| {
        try writeError(env, "agent", err);
        return Exit.agent_error;
    };
    defer program.deinit();

    if (isGovernedToolCommand(args.command)) {
        var unavailable = agent_tools.UnavailableVerificationRunner{};
        const verification_runner = env.verification_runner orelse unavailable.runner();
        var kernel = agent_tools.Kernel.init(allocator, project, verification_runner);
        defer kernel.deinit();
        const tool = if (std.mem.eql(u8, args.command, "simulate"))
            "ziac_simulate"
        else if (std.mem.eql(u8, args.command, "propose"))
            "ziac_propose"
        else
            "ziac_verify";
        const artifact = kernel.invoke(tool, args.tool_arguments orelse {
            try writeError(env, "agent", error.MissingToolArguments);
            return Exit.usage;
        }) catch |err| {
            try writeError(env, "agent", err);
            return Exit.agent_error;
        };
        try writeAgentArtifact(env, artifact);
        return Exit.success;
    }

    const sessions = agent_mod.SessionStore.init(allocator, files);
    if (std.mem.eql(u8, args.command, "orient")) {
        var session = sessions.load(args.stack, args.stage) catch |err| switch (err) {
            error.MissingAgentSession => createAgentSession(allocator, args) catch |create_err| {
                try writeError(env, "agent", create_err);
                return Exit.agent_error;
            },
            else => {
                try writeError(env, "agent", err);
                return Exit.agent_error;
            },
        };
        defer session.deinit();
        sessions.save(session) catch |err| {
            try writeError(env, "agent", err);
            return Exit.agent_error;
        };
        const artifact = agent_mod.statusJsonAlloc(allocator, project, session, &program.graph) catch |err| {
            try writeError(env, "agent", err);
            return Exit.agent_error;
        };
        defer allocator.free(artifact);
        try writeAgentArtifact(env, artifact);
        return Exit.success;
    }

    if (std.mem.eql(u8, args.command, "query")) {
        const resource_id = args.resource_id orelse {
            try writeError(env, "agent", error.MissingResourceId);
            return Exit.usage;
        };
        const artifact = agent_mod.queryResourceJsonAlloc(allocator, &program.graph, resource_id) catch |err| {
            try writeError(env, "agent", err);
            return Exit.agent_error;
        };
        defer allocator.free(artifact);
        try writeAgentArtifact(env, artifact);
        return Exit.success;
    }

    var session = sessions.load(args.stack, args.stage) catch |err| {
        try writeError(env, "agent", err);
        return Exit.agent_error;
    };
    defer session.deinit();
    const artifact = if (std.mem.eql(u8, args.command, "status"))
        agent_mod.statusJsonAlloc(allocator, project, session, &program.graph)
    else if (std.mem.eql(u8, args.command, "next"))
        agent_mod.nextJsonAlloc(allocator, project, session)
    else if (std.mem.eql(u8, args.command, "explain"))
        agent_mod.explainJsonAlloc(allocator, session, args.event_id orelse {
            try writeError(env, "agent", error.MissingEventId);
            return Exit.usage;
        })
    else
        agent_mod.handoffJsonAlloc(allocator, project, session, .{
            .root_cause = args.root_cause orelse "No unresolved root cause recorded",
        });
    const owned = artifact catch |err| {
        try writeError(env, "agent", err);
        return Exit.agent_error;
    };
    defer allocator.free(owned);
    try writeAgentArtifact(env, owned);
    return Exit.success;
}

fn createAgentSession(allocator: std.mem.Allocator, args: Args) !agent_mod.Session {
    const id = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ args.stack, args.stage });
    defer allocator.free(id);
    const generated_objective = if (args.objective == null)
        try std.fmt.allocPrint(allocator, "Manage {s} infrastructure", .{args.stack})
    else
        null;
    defer if (generated_objective) |owned| allocator.free(owned);
    var session = try agent_mod.Session.init(allocator, .{
        .id = id,
        .objective = args.objective orelse generated_objective.?,
        .stack = args.stack,
        .stage = args.stage,
    });
    errdefer session.deinit();
    try session.transition(.planning, .{
        .event_id = "orientation-complete",
        .summary = "project contract and resource graph validated",
    });
    return session;
}

fn writeAgentArtifact(env: *Env, artifact: []const u8) !void {
    try env.console.stdout.print(env.console.allocator, "{s}\n", .{artifact});
}

fn runDev(allocator: std.mem.Allocator, env: *Env, args: Args) !u8 {
    const files = env.agent_files orelse {
        try writeError(env, "dev", error.AgentFileSystemUnavailable);
        return Exit.agent_error;
    };
    const project_bytes = files.readFileAllocBounded(allocator, args.project_path, 4 * 1024 * 1024) catch |err| {
        try writeError(env, "dev", err);
        return Exit.agent_error;
    };
    defer allocator.free(project_bytes);
    var project = agent_contract.Project.parseAlloc(allocator, project_bytes) catch |err| {
        try writeError(env, "dev", err);
        return Exit.agent_error;
    };
    defer project.deinit();
    var program = buildProgram(allocator, env, args) catch |err| {
        try writeError(env, "dev", err);
        return Exit.agent_error;
    };
    defer program.deinit();
    const adaptations = dev_mod.planAdaptationsAlloc(allocator, project, &program.graph) catch |err| {
        try writeError(env, "dev", err);
        return Exit.agent_error;
    };
    defer allocator.free(adaptations);
    const receipt = dev_mod.receiptJsonAlloc(allocator, args.stack, args.stage, adaptations) catch |err| {
        try writeError(env, "dev", err);
        return Exit.agent_error;
    };
    defer allocator.free(receipt);
    try writeAgentArtifact(env, receipt);
    if (args.watch) return runNativeDev(allocator, env, project);
    return Exit.success;
}

fn runNativeDev(allocator: std.mem.Allocator, env: *Env, project: agent_contract.Project) !u8 {
    const host = env.dev_host orelse {
        try writeError(env, "dev", error.NativeDevHostUnavailable);
        return Exit.agent_error;
    };
    const development = project.development orelse {
        try writeError(env, "dev", error.NativeDevelopmentMissing);
        return Exit.agent_error;
    };
    var source_dir = host.root.openDir(host.io, development.source_root, .{ .iterate = true }) catch |err| {
        try writeError(env, "dev", err);
        return Exit.agent_error;
    };
    defer source_dir.close(host.io);
    var proxy = dev_native.StableProxy.init(allocator, host.io, development.proxy_port);
    proxy.start() catch |err| {
        try writeError(env, "dev", err);
        return Exit.agent_error;
    };
    defer proxy.deinit();
    var runtime = dev_native.NativeRuntime.init(allocator, host.io, &proxy, .{
        .cwd = development.source_root,
        .build_argv = development.build_argv,
        .process_argv = development.process_argv,
        .health_path = development.health_path,
    });
    defer runtime.deinit();
    var supervisor = dev_mod.Supervisor.init(allocator);
    defer supervisor.deinit();
    var digest_source = dev_native.DirectoryDigestSource.init(host.io, source_dir);
    var watcher = dev_native.WatchSession.init(
        allocator,
        &supervisor,
        runtime.runtime(),
        digest_source.source(),
        development.generation_base_port,
    );
    defer watcher.deinit();
    const stable_url = proxy.urlAlloc(allocator, "/") catch |err| {
        try writeError(env, "dev", err);
        return Exit.agent_error;
    };
    defer allocator.free(stable_url);
    const first = watcher.start() catch |err| {
        try writeError(env, "dev", err);
        return Exit.agent_error;
    };
    try writeDevReload(env, allocator, first, stable_url);
    if (first.status != .promoted) return Exit.agent_error;

    var polls: usize = 0;
    while (host.max_polls == null or polls < host.max_polls.?) : (polls += 1) {
        const delay = std.math.cast(i64, development.poll_millis) orelse return error.InvalidDevelopment;
        host.io.sleep(.fromMilliseconds(delay), .awake) catch |err| {
            try writeError(env, "dev", err);
            return Exit.agent_error;
        };
        const maybe_receipt = watcher.pollOnce() catch |err| {
            try writeError(env, "dev", err);
            return Exit.agent_error;
        };
        if (maybe_receipt) |reload_receipt| try writeDevReload(env, allocator, reload_receipt, stable_url);
    }
    return Exit.success;
}

fn writeDevReload(env: *Env, allocator: std.mem.Allocator, receipt: dev_mod.ReloadReceipt, stable_url: []const u8) !void {
    const artifact = try std.json.Stringify.valueAlloc(allocator, .{
        .schema = "ziac.dev-watch-event.v1",
        .stable_url = stable_url,
        .reload = receipt,
    }, .{});
    defer allocator.free(artifact);
    try writeAgentArtifact(env, artifact);
}

fn runLogs(allocator: std.mem.Allocator, env: *Env, args: Args) !u8 {
    const files = env.log_files orelse {
        try writeError(env, "logs", error.LogFileSystemUnavailable);
        return Exit.agent_error;
    };
    const sessions = log_mod.SessionStore.init(allocator, files, .{});
    var events = if (std.mem.eql(u8, args.command, "tail") and std.mem.eql(u8, args.provider_name, "gcp"))
        ingestCloudLogs(allocator, env, sessions, args) catch |err| {
            try writeError(env, "logs", err);
            return if (err == error.LiveLogsNotAllowed or err == error.CloudLoggingUnavailable) Exit.auth_error else Exit.agent_error;
        }
    else
        sessions.load(args.stack, args.stage) catch |err| {
            try writeError(env, "logs", err);
            return Exit.agent_error;
        };
    defer events.deinit();
    const artifact = if (std.mem.eql(u8, args.command, "log-explain"))
        events.explainJsonAlloc(allocator, args.event_id orelse {
            try writeError(env, "logs", error.MissingEventId);
            return Exit.usage;
        })
    else
        events.jsonLinesAlloc(allocator, .{
            .resource_id = args.resource_id,
            .region = args.region,
            .trace_id = args.trace_id,
            .minimum_severity = args.minimum_severity,
        });
    const owned = artifact catch |err| {
        try writeError(env, "logs", err);
        return Exit.agent_error;
    };
    defer allocator.free(owned);
    try env.console.stdout.print(env.console.allocator, "{s}", .{owned});
    if (owned.len == 0 or owned[owned.len - 1] != '\n') try env.console.stdout.print(env.console.allocator, "\n", .{});
    return Exit.success;
}

fn ingestCloudLogs(
    allocator: std.mem.Allocator,
    env: *Env,
    sessions: log_mod.SessionStore,
    args: Args,
) !log_mod.Store {
    if (!args.allow_live) return error.LiveLogsNotAllowed;
    const config = env.cloud_logging orelse return error.CloudLoggingUnavailable;
    var events = sessions.load(args.stack, args.stage) catch |err| switch (err) {
        error.MissingLogSession => log_mod.Store.init(allocator, .{}),
        else => return err,
    };
    errdefer events.deinit();
    var poller = log_mod.CloudLoggingPoller.init(allocator, config.client, .{
        .project_id = config.project_id,
        .filter = config.filter,
        .session_id = config.session_id,
    });
    defer poller.deinit();
    var batch = try poller.pollAlloc();
    defer batch.deinit();
    for (batch.events) |event| try events.append(.{
        .event_id = event.event_id,
        .parent_event_id = event.parent_event_id,
        .timestamp_millis = event.timestamp_millis,
        .source = event.source,
        .stream = event.stream,
        .severity = event.severity,
        .message = event.message,
        .session_id = event.session_id,
        .stack = args.stack,
        .stage = args.stage,
        .resource_id = event.resource_id,
        .region = event.region,
        .revision = event.revision,
        .trace_id = event.trace_id,
        .span_id = event.span_id,
        .request_id = event.request_id,
        .operation_id = event.operation_id,
        .fields = event.fields,
    });
    try sessions.save(args.stack, args.stage, &events);
    return events;
}

fn parseLogSeverity(value: []const u8) !log_mod.Severity {
    if (std.ascii.eqlIgnoreCase(value, "error")) return .err;
    return std.meta.stringToEnum(log_mod.Severity, value) orelse error.InvalidSeverity;
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

fn runEstateScan(allocator: std.mem.Allocator, env: *Env, args: Args) !u8 {
    const config = env.estate_scan orelse {
        try writeError(env, "estate", error.EstateScanUnavailable);
        return Exit.auth_error;
    };
    const files = env.plan_files orelse {
        try writeError(env, "estate", error.EstateArtifactFileSystemUnavailable);
        return Exit.state_error;
    };
    const access = estate_access.resolve(config.resolver, .{
        .session_assertion = config.session_assertion,
        .connection_id = args.connection_id orelse return Exit.usage,
        .now_millis = config.now_millis,
    }) catch |err| {
        try writeError(env, "estate-access", err);
        return Exit.auth_error;
    };
    var scan = estate_mod.scanAlloc(allocator, config.client, access.scan_input) catch |err| {
        try writeError(env, "estate-scan", err);
        return Exit.provider_error;
    };
    defer scan.deinit();
    const out_path = args.out_path orelse return Exit.usage;
    files.atomicWriteFile(allocator, out_path, scan.artifact) catch |err| {
        try writeError(env, "estate-artifact", err);
        return Exit.state_error;
    };
    const receipt = std.json.Stringify.valueAlloc(allocator, .{
        .schema = "ziac.estate-scan-receipt.v1",
        .project_id = access.scan_input.connection.project_id,
        .artifact_path = out_path,
        .resources = scan.resource_count,
        .edges = scan.edge_count,
        .pages = scan.page_count,
        .ownership = "observed",
        .mutation_authorized = false,
        .observed_at_millis = access.scan_input.observed_at_millis,
    }, .{}) catch return error.OutOfMemory;
    defer allocator.free(receipt);
    try env.console.writeOut(receipt);
    try env.console.writeOut("\n");
    return Exit.success;
}

fn runPlan(allocator: std.mem.Allocator, env: *Env, args: Args) !u8 {
    var program = buildProgram(allocator, env, args) catch |err| {
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
    if (args.watch) return runWatchDeploy(allocator, env, args);
    var program = buildProgram(allocator, env, args) catch |err| {
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

fn runWatchDeploy(allocator: std.mem.Allocator, env: *Env, args: Args) !u8 {
    const configured = env.watch_deploy orelse {
        try writeError(env, "watch-deploy", error.WatchDeployRuntimeUnavailable);
        return Exit.provider_error;
    };
    var loaded_plan: ?plan_format.LoadedPlan = null;
    defer if (loaded_plan) |*plan| plan.deinit();
    var verified_digest_buffer: [64]u8 = undefined;
    var verified_digest: ?[]const u8 = null;
    if (configured.require_saved_plan) {
        const path = args.plan_path orelse {
            try writeError(env, "watch-deploy", error.SavedPlanRequired);
            return Exit.usage;
        };
        const files = env.plan_files orelse {
            try writeError(env, "watch-deploy", error.PlanFileSystemUnavailable);
            return Exit.state_error;
        };
        loaded_plan = plan_format.load(files, allocator, path, .{}) catch |err| {
            return handlePlanError(env, err);
        };
        const saved = &loaded_plan.?;
        if (!std.mem.eql(u8, saved.stack, args.stack) or !std.mem.eql(u8, saved.stage, args.stage)) {
            return handlePlanError(env, error.PlanTargetMismatch);
        }
        if (plan_mod.hasDestructiveOperations(saved.plan.operations)) {
            try writeError(env, "watch-deploy", error.WatchDestructiveChange);
            return Exit.provider_error;
        }
        var program = buildProgram(allocator, env, args) catch |err| return handleStackError(env, err);
        defer program.deinit();
        const graph_digest = plan_mod.desiredGraphDigestAlloc(allocator, &program.graph) catch |err| {
            return handlePlanError(env, err);
        };
        if (!std.mem.eql(u8, &graph_digest, &saved.plan.preconditions.desired_graph_digest)) {
            return handlePlanError(env, error.PlanDesiredGraphMismatch);
        }
        verified_digest_buffer = saved.metadata().digestHex();
        verified_digest = &verified_digest_buffer;
        if (args.plan_digest) |claimed| {
            if (!std.mem.eql(u8, claimed, verified_digest.?)) {
                try writeError(env, "watch-deploy", error.PlanApprovalMismatch);
                return Exit.provider_error;
            }
        }
    }
    const plan_digest = verified_digest orelse args.plan_digest orelse {
        try writeError(env, "watch-deploy", error.MissingPlanDigest);
        return Exit.usage;
    };
    var envelope = configured.envelope;
    if (configured.require_saved_plan) envelope.approved_plan_digest = plan_digest;
    const receipt = watch_deploy_mod.executeWorkflow(allocator, configured.workflow, configured.runtime, envelope, .{
        .now_millis = configured.now_millis,
        .stage = args.stage,
        .project = configured.project,
        .plan_digest = plan_digest,
        .image_ref = args.image_ref orelse {
            try writeError(env, "watch-deploy", error.MissingImageReference);
            return Exit.usage;
        },
        .regions = configured.regions,
    }) catch |err| {
        try writeError(env, "watch-deploy", err);
        return Exit.provider_error;
    };
    const events = watch_deploy_mod.eventStreamJsonAlloc(allocator, receipt) catch |err| {
        try writeError(env, "watch-deploy", err);
        return Exit.provider_error;
    };
    defer allocator.free(events);
    persistWatchReceipt(allocator, env, args, plan_digest, receipt) catch |err| {
        try writeError(env, "watch-deploy-log", err);
        return Exit.agent_error;
    };
    try env.console.writeOut(events);
    return if (receipt.status == .complete) Exit.success else Exit.provider_error;
}

fn persistWatchReceipt(
    allocator: std.mem.Allocator,
    env: *Env,
    args: Args,
    plan_digest: []const u8,
    receipt: watch_deploy_mod.Receipt,
) !void {
    const files = env.log_files orelse return error.LogFileSystemUnavailable;
    const sessions = log_mod.SessionStore.init(allocator, files, .{});
    var log = sessions.load(args.stack, args.stage) catch |err| switch (err) {
        error.MissingLogSession, error.FileNotFound => log_mod.Store.init(allocator, .{}),
        else => return err,
    };
    defer log.deinit();
    const phase_names = [_][]const u8{ "image", "revision", "readiness", "traffic" };
    const phase_sources = [_]log_mod.Source{ .provider, .cloud_run, .health, .cloud_run };
    const phase_messages = [_][]const u8{
        "Immutable image verified",
        "Cloud Run revision created with prior traffic pinned",
        "Cloud Run revision readiness proved",
        "Healthy revision promoted to traffic",
    };
    const phase_durations = [_]u64{
        receipt.timings.push_millis,
        receipt.timings.revision_millis,
        receipt.timings.readiness_millis,
        receipt.timings.traffic_millis,
    };
    var elapsed: u64 = 0;
    var parent: ?[]const u8 = null;
    var owned_parent: ?[]const u8 = null;
    defer if (owned_parent) |value| allocator.free(value);
    for (phase_names, 0..) |phase, index| {
        elapsed +|= phase_durations[index];
        const event_id = try std.fmt.allocPrint(allocator, "watch-{s}-{s}", .{ plan_digest, phase });
        defer allocator.free(event_id);
        try log.append(.{
            .event_id = event_id,
            .parent_event_id = parent,
            .timestamp_millis = @intCast(env.watch_deploy.?.now_millis +| elapsed),
            .source = phase_sources[index],
            .stream = .system,
            .severity = if (receipt.status == .complete or index < failedPhaseIndex(receipt.status)) .info else .err,
            .message = phase_messages[index],
            .session_id = plan_digest,
            .stack = args.stack,
            .stage = args.stage,
            .revision = receipt.image_ref,
            .fields = &.{
                .{ .name = "phase", .value = phase },
                .{ .name = "duration_millis", .value = "recorded" },
            },
        });
        if (owned_parent) |value| allocator.free(value);
        owned_parent = try allocator.dupe(u8, event_id);
        parent = owned_parent;
        if (receipt.status != .complete and index >= failedPhaseIndex(receipt.status)) break;
    }
    try sessions.save(args.stack, args.stage, &log);
}

fn failedPhaseIndex(status: watch_deploy_mod.Status) usize {
    return switch (status) {
        .complete => 4,
        .push_failed => 0,
        .revision_failed => 1,
        .readiness_failed => 2,
        .traffic_failed => 3,
    };
}

fn runDestroy(allocator: std.mem.Allocator, env: *Env, args: Args) !u8 {
    if (args.preview_cleanup) {
        ci_mod.validatePreviewCleanup(args.stage) catch |err| return handlePlanError(env, err);
    }
    var program = buildProgram(allocator, env, args) catch |err| {
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
    var program = buildProgram(allocator, env, args) catch |err| {
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
    var program = buildProgram(allocator, env, args) catch |err| {
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
    var program = buildProgram(allocator, env, args) catch |err| {
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
    var program = buildProgram(allocator, env, args) catch |err| {
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
