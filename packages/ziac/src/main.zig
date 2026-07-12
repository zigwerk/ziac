const std = @import("std");
const ziac = @import("ziac");
const build_options = @import("build_options");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var console = ziac.zstd.Console.CapturedConsole.init(allocator);
    defer console.deinit();

    var args = std.ArrayList([]const u8).empty;
    defer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }

    var iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer iterator.deinit();
    _ = iterator.skip();
    while (iterator.next()) |arg| {
        try args.append(allocator, try allocator.dupe(u8, arg));
    }

    var cwd = std.Io.Dir.cwd();
    if (args.items.len > 0 and std.mem.eql(u8, args.items[0], "init")) {
        const code = runInit(allocator, io, cwd, args.items[1..]);
        std.process.exit(code catch |err| {
            var error_buffer: [256]u8 = undefined;
            const message = std.fmt.bufPrint(&error_buffer, "ziac init: {s}\n", .{@errorName(err)}) catch "ziac init failed\n";
            std.Io.File.stderr().writeStreamingAll(io, message) catch {};
            return;
        });
    }
    if (args.items.len >= 2 and std.mem.eql(u8, args.items[0], "mcp") and std.mem.eql(u8, args.items[1], "serve")) {
        const executable_dir = try std.process.executableDirPathAlloc(io, allocator);
        defer allocator.free(executable_dir);
        const server_path = try std.fs.path.join(allocator, &.{ executable_dir, "ziac-mcp" });
        defer allocator.free(server_path);
        var server_args = try std.ArrayList([]const u8).initCapacity(allocator, args.items.len - 1);
        defer server_args.deinit(allocator);
        try server_args.append(allocator, server_path);
        try server_args.appendSlice(allocator, args.items[2..]);
        var child = try std.process.spawn(io, .{
            .argv = server_args.items,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        });
        const term = try child.wait(io);
        const code: u8 = switch (term) {
            .exited => |exit_code| @intCast(exit_code),
            else => ziac.cli.Exit.agent_error,
        };
        std.process.exit(code);
    }
    var local_fs = ziac.zstd.FileSystem.LocalFileSystem.init(&cwd, io);
    var auth_files = ziac.gcp.auth.localFileReader(&local_fs);
    var auth_env = ziac.zstd.Env.EnvMap.init(allocator);
    defer auth_env.deinit();
    for ([_][]const u8{ "GOOGLE_APPLICATION_CREDENTIALS", "HOME", "APPDATA" }) |name| {
        if (init.environ_map.get(name)) |value| try auth_env.put(name, value);
    }
    const live_project = init.environ_map.get("ZIAC_LIVE_PROJECT");
    const state_bucket = init.environ_map.get("ZIAC_STATE_BUCKET");
    const use_remote_state = state_bucket != null and !requestsStateFreeCommand(args.items);
    const live_regions = if (init.environ_map.get("ZIAC_LIVE_REGIONS")) |csv|
        try ziac.stack_registry.regionsFromCsvAlloc(allocator, csv)
    else
        null;
    defer if (live_regions) |regions| allocator.free(regions);
    const registry = if (live_project) |project_id|
        ziac.stack_registry.configuredRegistry(.{
            .project_id = project_id,
            .region = init.environ_map.get("ZIAC_LIVE_REGION") orelse "europe-west1",
            .regions = live_regions orelse &.{},
            .service_account = init.environ_map.get("ZIAC_LIVE_SERVICE_ACCOUNT"),
            .image = init.environ_map.get("ZIAC_LIVE_IMAGE"),
            .domain = init.environ_map.get("ZIAC_LIVE_DOMAIN"),
            .dns_zone = init.environ_map.get("ZIAC_LIVE_DNS_ZONE"),
            .http_redirect = !std.mem.eql(
                u8,
                init.environ_map.get("ZIAC_LIVE_HTTP_REDIRECT") orelse "true",
                "false",
            ),
        })
    else
        ziac.stack_registry.fixtureRegistry();

    var project_contract: ?ziac.agent_contract.Project = null;
    defer if (project_contract) |*project| project.deinit();
    var project_program: ?ziac.stack_registry.StackProgram = null;
    defer if (project_program) |*program| program.deinit();
    var project_loader: ziac.stack_registry.StaticProgramLoader = undefined;
    var selected_program_loader: ?ziac.stack_registry.ProgramLoader = null;
    if (ziac.project_program.targetFromArgs(args.items)) |target| {
        const project_path = optionValue(args.items, "--project") orelse "ziac.project.json";
        const project_bytes = cwd.readFileAlloc(io, project_path, allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (project_bytes) |bytes| {
            defer allocator.free(bytes);
            project_contract = try ziac.agent_contract.Project.parseAlloc(allocator, bytes);
            if (project_contract.?.program) |compiler| {
                var runner = ziac.project_program.NativeRunner{ .io = io };
                project_program = ziac.project_program.loadAlloc(allocator, compiler, runner.runner(), target) catch |err| {
                    try std.Io.File.stderr().writeStreamingAll(io, "ziac project compiler failed: ");
                    try std.Io.File.stderr().writeStreamingAll(io, @errorName(err));
                    try std.Io.File.stderr().writeStreamingAll(io, "\n");
                    std.process.exit(ziac.cli.Exit.invalid_graph);
                };
                project_loader = .{ .stack = target.stack, .stage = target.stage, .program = &project_program.? };
                selected_program_loader = project_loader.loader();
            }
        }
    }
    if (args.items.len > 0 and std.mem.eql(u8, args.items[0], "check")) {
        if (project_contract == null or project_program == null) {
            try std.Io.File.stderr().writeStreamingAll(io, "ziac check: project compiler is not configured\n");
            std.process.exit(ziac.cli.Exit.invalid_graph);
        }
        const receipt = try std.json.Stringify.valueAlloc(allocator, .{
            .schema = "ziac.check.v1",
            .status = "valid",
            .project = project_contract.?.id,
            .resources = project_program.?.graph.resources.items.len,
            .dependencies = project_program.?.graph.dependencies.items.len,
        }, .{});
        defer allocator.free(receipt);
        try std.Io.File.stdout().writeStreamingAll(io, receipt);
        try std.Io.File.stdout().writeStreamingAll(io, "\n");
        std.process.exit(ziac.cli.Exit.success);
    }
    if (args.items.len > 0 and std.mem.eql(u8, args.items[0], "dashboard")) {
        if (project_contract == null or project_program == null) {
            try std.Io.File.stderr().writeStreamingAll(io, "ziac dashboard: project compiler is not configured\n");
            std.process.exit(ziac.cli.Exit.invalid_graph);
        }
        const target = ziac.project_program.targetFromArgs(args.items).?;
        var artifact = try ziac.visual_artifact.serializeAlloc(allocator, &project_program.?.graph, null, .{
            .stack = target.stack,
            .stage = target.stage,
            .created_at_millis = @intCast(std.Io.Clock.real.now(io).toMilliseconds()),
        });
        defer artifact.deinit();
        const default_path = try std.fmt.allocPrint(allocator, ".ziac/dashboard/{s}/{s}/artifact.json", .{ target.stack, target.stage });
        defer allocator.free(default_path);
        const artifact_path = optionValue(args.items, "--out") orelse default_path;
        if (std.fs.path.dirname(artifact_path)) |parent| try cwd.createDirPath(io, parent);
        try cwd.writeFile(io, .{ .sub_path = artifact_path, .data = artifact.bytes });
        if (hasFlag(args.items, "--artifact-only")) {
            const receipt = try std.json.Stringify.valueAlloc(allocator, .{
                .schema = "ziac.dashboard-artifact.v1",
                .status = "ready",
                .path = artifact_path,
                .resources = project_program.?.graph.resources.items.len,
            }, .{});
            defer allocator.free(receipt);
            try std.Io.File.stdout().writeStreamingAll(io, receipt);
            try std.Io.File.stdout().writeStreamingAll(io, "\n");
            std.process.exit(ziac.cli.Exit.success);
        }
        const executable_dir = try std.process.executableDirPathAlloc(io, allocator);
        defer allocator.free(executable_dir);
        const host_path = try std.fs.path.join(allocator, &.{ executable_dir, "ziac-dashboard-host" });
        defer allocator.free(host_path);
        var host_args = std.ArrayList([]const u8).empty;
        defer host_args.deinit(allocator);
        try host_args.append(allocator, host_path);
        if (hasFlag(args.items, "--server-only")) try host_args.append(allocator, "--server-only");
        if (optionValue(args.items, "--session")) |session| try host_args.appendSlice(allocator, &.{ "--session", session });
        if (optionValue(args.items, "--logs")) |logs| try host_args.appendSlice(allocator, &.{ "--logs", logs });
        try host_args.append(allocator, artifact_path);
        var child = try std.process.spawn(io, .{
            .argv = host_args.items,
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .inherit,
        });
        const term = try child.wait(io);
        const code: u8 = switch (term) {
            .exited => |exit_code| @intCast(exit_code),
            else => ziac.cli.Exit.provider_error,
        };
        std.process.exit(code);
    }

    var local_http = ziac.zstd.Http.LocalClient.init(allocator, io);
    defer local_http.deinit();
    var resolved_adc: ?ziac.gcp.auth.ResolvedAdc = null;
    defer if (resolved_adc) |*resolved| resolved.deinit(allocator);
    var adc_source: ziac.gcp.auth.AdcTokenSource = undefined;
    var token_cache: ?ziac.gcp.auth.TokenCache = null;
    defer if (token_cache) |*cache| cache.deinit(allocator);
    var google_client: ziac.gcp.client.Client = undefined;
    var live_provider: ziac.gcp.live_provider.LiveProvider = undefined;
    var cockroach_client: ziac.cockroach.client.Client = undefined;
    var cockroach_provider: ziac.cockroach.live_provider.LiveProvider = undefined;
    var live_providers: ?ziac.provider.ProviderRegistry = null;
    if (requestsGoogleClient(args.items) or use_remote_state) {
        if (ziac.gcp.auth.resolveAdcAlloc(allocator, auth_env, &auth_files)) |resolved| {
            resolved_adc = resolved;
            adc_source = ziac.gcp.auth.AdcTokenSource.init(
                &resolved_adc.?,
                local_http.client(),
                auth_files,
            );
            token_cache = ziac.gcp.auth.TokenCache.init(adc_source.tokenSource(), 300);
            google_client = ziac.gcp.client.Client.init(local_http.client(), &token_cache.?, .{});
            live_provider = ziac.gcp.live_provider.LiveProvider.init(&google_client);
            var providers = ziac.provider.ProviderRegistry{};
            providers.register(.gcp, live_provider.provider());
            if (init.environ_map.get("COCKROACH_API_KEY")) |api_key| {
                if (api_key.len > 0) {
                    cockroach_client = ziac.cockroach.client.Client.init(local_http.client(), api_key, .{});
                    cockroach_provider = ziac.cockroach.live_provider.LiveProvider.init(&cockroach_client);
                    providers.register(.cockroach, cockroach_provider.provider());
                }
            }
            live_providers = providers;
        } else |_| {}
    }
    if (use_remote_state and token_cache == null) {
        try console.stderr.print(allocator, "state: {s}\n", .{@errorName(error.StateAuthenticationUnavailable)});
        try std.Io.File.stderr().writeStreamingAll(io, console.stderrText());
        std.process.exit(ziac.cli.Exit.auth_error);
    }
    if (requestsEstateScan(args.items) and token_cache == null) {
        try console.stderr.print(allocator, "estate-access: {s}\n", .{@errorName(error.GoogleApplicationDefaultCredentialsRequired)});
        try std.Io.File.stderr().writeStreamingAll(io, console.stderrText());
        std.process.exit(ziac.cli.Exit.auth_error);
    }

    var estate_context = ziac.provider.OperationContext.init(allocator);
    var estate_control: ?ziac.estate_access.HttpResolver = null;
    defer if (estate_control) |*control| control.deinit();
    var estate_adapter: ziac.gcp.estate_client.Adapter = undefined;
    var estate_adapter_initialized = false;
    defer if (estate_adapter_initialized) estate_adapter.deinit();
    var estate_scan_config: ?ziac.cli.EstateScanConfig = null;
    if (requestsEstateScan(args.items) and token_cache != null) {
        const control_url = init.environ_map.get("ZIAC_CONTROL_PLANE_URL");
        const session_assertion = init.environ_map.get("ZIAC_SESSION_ASSERTION");
        if (control_url != null and session_assertion != null) {
            estate_control = ziac.estate_access.HttpResolver.init(
                allocator,
                local_http.client(),
                control_url.?,
                session_assertion.?,
            ) catch |err| {
                try console.stderr.print(allocator, "estate-access: {s}\n", .{@errorName(err)});
                try std.Io.File.stderr().writeStreamingAll(io, console.stderrText());
                std.process.exit(ziac.cli.Exit.auth_error);
            };
            estate_adapter = ziac.gcp.estate_client.Adapter.init(&google_client, &estate_context);
            estate_adapter_initialized = true;
            estate_scan_config = .{
                .resolver = estate_control.?.resolver(),
                .client = estate_adapter.client(),
                .session_assertion = session_assertion.?,
                .now_millis = estate_context.nowMillis(),
            };
        }
    }
    var logging_context = ziac.provider.OperationContext.init(allocator);
    var logging_adapter: ziac.gcp.logging_client.Adapter = undefined;
    var logging_adapter_initialized = false;
    defer if (logging_adapter_initialized) logging_adapter.deinit();
    var cloud_logging_config: ?ziac.cli.CloudLoggingConfig = null;
    if (requestsCloudLogging(args.items) and token_cache != null and live_project != null) {
        logging_adapter = ziac.gcp.logging_client.Adapter.init(allocator, &google_client, &logging_context);
        logging_adapter_initialized = true;
        cloud_logging_config = .{
            .client = logging_adapter.client(),
            .project_id = live_project.?,
            .filter = init.environ_map.get("ZIAC_LOG_FILTER") orelse "resource.type=\"cloud_run_revision\"",
            .session_id = init.environ_map.get("ZIAC_LOG_SESSION") orelse "ziac-live",
        };
    }

    var watch_context = ziac.provider.OperationContext.init(allocator);
    var live_watch_runtime: ?ziac.gcp.watch_runtime.LiveRuntime = null;
    defer if (live_watch_runtime) |*runtime| runtime.deinit();
    var watch_stages: [1][]const u8 = undefined;
    var watch_projects: [1][]const u8 = undefined;
    var watch_config: ?ziac.cli.WatchDeployConfig = null;
    if (requestsWatchDeploy(args.items) and token_cache != null and live_project != null and project_program != null) {
        live_watch_runtime = ziac.gcp.watch_runtime.LiveRuntime.initForProjectAlloc(
            &google_client,
            &watch_context,
            &project_program.?.graph,
            live_project.?,
        ) catch |err| {
            try console.stderr.print(allocator, "watch-deploy: {s}\n", .{@errorName(err)});
            try std.Io.File.stderr().writeStreamingAll(io, console.stderrText());
            std.process.exit(ziac.cli.Exit.invalid_graph);
        };
        const stage = optionValue(args.items, "--stage") orelse "";
        watch_stages[0] = stage;
        watch_projects[0] = live_project.?;
        const now_millis: u64 = @intCast(std.Io.Clock.real.now(io).toMilliseconds());
        watch_config = .{
            .runtime = live_watch_runtime.?.runtime(),
            .envelope = .{
                .id = "ziac-cli-saved-plan-watch",
                .stages = &watch_stages,
                .projects = &watch_projects,
                .providers = &.{.gcp},
                .permissions = .{ .apply = true },
                .budget = .{
                    .max_updates = live_watch_runtime.?.regionCount(),
                    .max_regions = live_watch_runtime.?.regionCount(),
                },
                .expires_at_millis = now_millis + std.time.ms_per_hour,
            },
            .project = live_project.?,
            .now_millis = now_millis,
            .regions = live_watch_runtime.?.regionCount(),
            .require_saved_plan = true,
        };
    }

    var local_backend = ziac.state_backend.Local.init(ziac.local_state.Store.init(
        allocator,
        ziac.local_state.localFiles.store(&local_fs),
    ));
    var selected_state = local_backend.store();
    var state_context = ziac.provider.OperationContext.init(allocator);
    var gcs_objects: ziac.gcp.gcs_state.Store = undefined;
    var remote_state: ziac.state_backend.Remote = undefined;
    var remote_state_initialized = false;
    defer if (remote_state_initialized) remote_state.deinit();
    if (use_remote_state) {
        const bucket = state_bucket.?;
        gcs_objects = try ziac.gcp.gcs_state.Store.init(&google_client, &state_context, bucket);
        remote_state = try ziac.state_backend.Remote.init(allocator, gcs_objects.objectStore(), .{
            .prefix = init.environ_map.get("ZIAC_STATE_PREFIX") orelse "ziac/state",
        });
        remote_state_initialized = true;
        selected_state = remote_state.store();
    }
    var env = ziac.cli.Env{
        .console = &console,
        .registry = registry,
        .program_loader = selected_program_loader,
        .state = selected_state,
        .migration_source = if (remote_state_initialized) local_backend.delegate else null,
        .plan_files = ziac.local_state.localFiles.store(&local_fs),
        .agent_files = ziac.local_state.localFiles.store(&local_fs),
        .log_files = ziac.local_state.localFiles.store(&local_fs),
        .auth_env = &auth_env,
        .auth_files = auth_files,
        .live_providers = live_providers,
        .live_project_id = live_project,
        .watch_deploy = watch_config,
        .estate_scan = estate_scan_config,
        .dev_host = .{ .io = io, .root = cwd },
        .cloud_logging = cloud_logging_config,
    };
    var verification_runner = ziac.agent_tools.NativeVerificationRunner{ .io = io };
    env.verification_runner = verification_runner.runner();

    const code = try ziac.cli.run(allocator, args.items, &env);
    if (console.stdoutText().len > 0) {
        try std.Io.File.stdout().writeStreamingAll(io, console.stdoutText());
    }
    if (console.stderrText().len > 0) {
        try std.Io.File.stderr().writeStreamingAll(io, console.stderrText());
    }
    std.process.exit(code);
}

fn runInit(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    args: []const []const u8,
) !u8 {
    if (args.len == 0 or std.mem.startsWith(u8, args[0], "--")) return ziac.cli.Exit.usage;
    const name = args[0];
    const target = optionValue(args[1..], "--dir") orelse name;
    const package_path = optionValue(args[1..], "--ziac-path") orelse build_options.package_root;
    const force = hasFlag(args[1..], "--force");
    try cwd.createDirPath(io, target);
    const target_path = try cwd.realPathFileAlloc(io, target, allocator);
    defer allocator.free(target_path);
    const package_absolute = if (std.fs.path.isAbsolute(package_path))
        try std.Io.Dir.realPathFileAbsoluteAlloc(io, package_path, allocator)
    else
        try cwd.realPathFileAlloc(io, package_path, allocator);
    defer allocator.free(package_absolute);
    const dependency_path = try std.fs.path.relative(allocator, ".", null, target_path, package_absolute);
    defer allocator.free(dependency_path);
    var rendered = try ziac.scaffold.renderAlloc(allocator, .{
        .project_name = name,
        .ziac_path = dependency_path,
    });
    defer rendered.deinit();
    var target_dir = try cwd.openDir(io, target, .{});
    defer target_dir.close(io);
    try ziac.scaffold.write(target_dir, io, rendered, force);
    const message = try std.fmt.allocPrint(allocator, "Created Ziac project {s} in {s}\n", .{ name, target });
    defer allocator.free(message);
    try std.Io.File.stdout().writeStreamingAll(io, message);
    return ziac.cli.Exit.success;
}

fn optionValue(args: []const []const u8, name: []const u8) ?[]const u8 {
    for (args, 0..) |arg, index| if (std.mem.eql(u8, arg, name) and index + 1 < args.len) return args[index + 1];
    return null;
}

fn hasFlag(args: []const []const u8, name: []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, name)) return true;
    return false;
}

fn requestsGoogleClient(args: []const []const u8) bool {
    if (requestsEstateScan(args)) return true;
    if (requestsWatchDeploy(args)) return true;
    for (args, 0..) |arg, index| {
        if (!std.mem.eql(u8, arg, "--provider")) continue;
        if (index + 1 < args.len and std.mem.eql(u8, args[index + 1], "gcp")) return true;
    }
    return false;
}

fn requestsWatchDeploy(args: []const []const u8) bool {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "deploy")) return false;
    return hasFlag(args, "--watch");
}

fn requestsEstateScan(args: []const []const u8) bool {
    return args.len >= 2 and std.mem.eql(u8, args[0], "estate") and std.mem.eql(u8, args[1], "scan");
}

fn requestsCloudLogging(args: []const []const u8) bool {
    if (args.len == 0 or !std.mem.eql(u8, args[0], "tail")) return false;
    for (args, 0..) |arg, index| {
        if (std.mem.eql(u8, arg, "--provider") and index + 1 < args.len and std.mem.eql(u8, args[index + 1], "gcp")) return true;
    }
    return false;
}

fn requestsStateFreeCommand(args: []const []const u8) bool {
    if (args.len >= 1 and std.mem.eql(u8, args[0], "preview-stage")) return true;
    if (args.len >= 1 and std.mem.eql(u8, args[0], "dev")) return true;
    if (args.len >= 1 and (std.mem.eql(u8, args[0], "logs") or std.mem.eql(u8, args[0], "tail") or
        std.mem.eql(u8, args[0], "log-explain"))) return true;
    if (args.len >= 1 and std.mem.eql(u8, args[0], "agent")) return true;
    if (args.len >= 1 and std.mem.eql(u8, args[0], "estate")) return true;
    return args.len >= 2 and std.mem.eql(u8, args[0], "auth") and std.mem.eql(u8, args[1], "doctor");
}
