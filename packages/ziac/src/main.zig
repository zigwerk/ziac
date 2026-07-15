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
    if (args.items.len > 0 and std.mem.eql(u8, args.items[0], "registry")) {
        const code = runRegistry(allocator, io, args.items[1..]);
        std.process.exit(code catch |err| {
            var error_buffer: [256]u8 = undefined;
            const message = std.fmt.bufPrint(&error_buffer, "ziac registry: {s}\n", .{@errorName(err)}) catch "ziac registry failed\n";
            std.Io.File.stderr().writeStreamingAll(io, message) catch {};
            return;
        });
    }
    if (args.items.len > 0 and std.mem.eql(u8, args.items[0], "package")) {
        const code = runPackage(allocator, io, cwd, args.items[1..]);
        std.process.exit(code catch |err| {
            var error_buffer: [256]u8 = undefined;
            const message = std.fmt.bufPrint(&error_buffer, "ziac package: {s}\n", .{@errorName(err)}) catch "ziac package failed\n";
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
    if (args.items.len > 0 and std.mem.eql(u8, args.items[0], "dashboard")) {
        const code = runWorkspaceDashboard(allocator, io, cwd, args.items[1..]);
        std.process.exit(code catch |err| {
            var error_buffer: [256]u8 = undefined;
            const message = std.fmt.bufPrint(&error_buffer, "ziac dashboard: {s}\n", .{@errorName(err)}) catch "ziac dashboard failed\n";
            std.Io.File.stderr().writeStreamingAll(io, message) catch {};
            return;
        });
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

    var local_http = ziac.zstd.Http.LocalClient.init(allocator, io);
    defer local_http.deinit();
    var resolved_adc: ?ziac.gcp.auth.ResolvedAdc = null;
    defer if (resolved_adc) |*resolved| resolved.deinit(allocator);
    var adc_source: ziac.gcp.auth.AdcTokenSource = undefined;
    var token_cache: ?ziac.gcp.auth.TokenCache = null;
    defer if (token_cache) |*cache| cache.deinit(allocator);
    var google_client: ziac.gcp.client.Client = undefined;
    var gcp_process_provider: ?ziac.provider_rpc.ProcessProvider = null;
    defer if (gcp_process_provider) |*process_provider| process_provider.deinit();
    var cockroach_process_provider: ?ziac.provider_rpc.ProcessProvider = null;
    defer if (cockroach_process_provider) |*process_provider| process_provider.deinit();
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
            const executable_dir = try std.process.executableDirPathAlloc(io, allocator);
            defer allocator.free(executable_dir);
            const gcp_provider_path = try std.fs.path.join(allocator, &.{ executable_dir, "ziac-provider-gcp" });
            defer allocator.free(gcp_provider_path);
            gcp_process_provider = try ziac.provider_rpc.ProcessProvider.init(allocator, io, &.{gcp_provider_path}, .{
                .package_name = "ziac-provider/gcp",
                .package_version = "0.1.0",
                .provider = .gcp,
            });
            var providers = ziac.provider.ProviderRegistry{};
            providers.register(.gcp, gcp_process_provider.?.provider());
            if (init.environ_map.get("COCKROACH_API_KEY")) |api_key| {
                if (api_key.len > 0) {
                    const cockroach_provider_path = try std.fs.path.join(allocator, &.{ executable_dir, "ziac-provider-cockroach" });
                    defer allocator.free(cockroach_provider_path);
                    cockroach_process_provider = try ziac.provider_rpc.ProcessProvider.init(allocator, io, &.{cockroach_provider_path}, .{
                        .package_name = "ziac-provider/cockroach",
                        .package_version = "0.1.0",
                        .provider = .cockroach,
                    });
                    providers.register(.cockroach, cockroach_process_provider.?.provider());
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

fn runWorkspaceDashboard(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    args: []const []const u8,
) !u8 {
    if (hasFlag(args, "--help") or hasFlag(args, "-h")) {
        try std.Io.File.stdout().writeStreamingAll(io,
            \\Usage: ziac dashboard [options]
            \\
            \\Compile every nested Ziac project and open one local workspace dashboard.
            \\
            \\Options:
            \\  --root <path>       Workspace root (defaults to the Git root)
            \\  --project <id>      Compile one project into a focused workspace view
            \\  --stack <name>      Override the declared dashboard stack
            \\  --stage <name>      Override the declared dashboard stage
            \\  --out <path>        Workspace artifact output path
            \\  --artifact-only     Write the artifact without opening the host
            \\  --server-only       Serve without opening a native window
            \\  --session <path>    Agent session projection
            \\  --logs <path>       Causal log snapshot
            \\
        );
        return ziac.cli.Exit.success;
    }
    const root_path = try workspaceRootAlloc(allocator, io, cwd, optionValue(args, "--root"));
    defer allocator.free(root_path);
    var root = try std.Io.Dir.openDirAbsolute(io, root_path, .{ .iterate = true });
    defer root.close(io);
    var discovery = try ziac.workspace.discoverProjectsAlloc(allocator, io, root);
    defer discovery.deinit();
    if (discovery.projects.len == 0) return error.WorkspaceHasNoProjects;

    const selected_project = optionValue(args, "--project");
    const stack_override = optionValue(args, "--stack");
    const stage_override = optionValue(args, "--stage");
    var serialized = std.ArrayList(ziac.visual_artifact.SerializedArtifact).empty;
    defer {
        for (serialized.items) |*artifact| artifact.deinit();
        serialized.deinit(allocator);
    }
    var project_artifacts = std.ArrayList(ziac.workspace.ProjectVisualArtifact).empty;
    defer project_artifacts.deinit(allocator);
    var resource_count: usize = 0;
    const created_at_millis: u64 = @intCast(std.Io.Clock.real.now(io).toMilliseconds());
    try root.createDirPath(io, ".ziac/dashboard/cache");

    for (discovery.projects) |project| {
        if (selected_project) |selected| {
            if (!std.mem.eql(u8, selected, project.id) and !std.mem.eql(u8, selected, project.path)) continue;
        }
        const manifest_path = try std.fs.path.join(allocator, &.{ project.path, "ziac.project.json" });
        defer allocator.free(manifest_path);
        const manifest = try root.readFileAlloc(io, manifest_path, allocator, .limited(ziac.workspace.max_manifest_bytes));
        defer allocator.free(manifest);
        var contract = try ziac.agent_contract.Project.parseAlloc(allocator, manifest);
        defer contract.deinit();
        if (!std.mem.eql(u8, contract.id, project.id)) return error.WorkspaceProjectIdentityMismatch;
        const compiler = contract.program orelse return error.WorkspaceProjectCompilerMissing;
        const project_path = try std.fs.path.join(allocator, &.{ root_path, project.path });
        defer allocator.free(project_path);
        var project_dir = try std.Io.Dir.openDirAbsolute(io, project_path, .{ .iterate = true });
        defer project_dir.close(io);
        const target = ziac.program_format.Target{
            .stack = stack_override orelse project.stack,
            .stage = stage_override orelse project.stage,
        };
        const source_revision = try ziac.workspace.projectRevision(allocator, io, project_dir, manifest, contract.source_roots);
        const revision = workspaceTargetRevision(source_revision, target);
        const revision_hex = std.fmt.bytesToHex(revision, .lower);
        const cache_revision_path = try std.fmt.allocPrint(allocator, ".ziac/dashboard/cache/{s}.revision", .{project.id});
        defer allocator.free(cache_revision_path);
        const cache_artifact_path = try std.fmt.allocPrint(allocator, ".ziac/dashboard/cache/{s}.json", .{project.id});
        defer allocator.free(cache_artifact_path);
        const cached_revision = root.readFileAlloc(io, cache_revision_path, allocator, .limited(64)) catch null;
        defer if (cached_revision) |bytes| allocator.free(bytes);
        var cached_artifact: ?[]u8 = root.readFileAlloc(io, cache_artifact_path, allocator, .limited(ziac.dashboard_host.max_artifact_bytes)) catch null;
        defer if (cached_artifact) |bytes| allocator.free(bytes);
        const cache_hit = cached_revision != null and cached_artifact != null and std.mem.eql(u8, cached_revision.?, &revision_hex);
        var artifact: ziac.visual_artifact.SerializedArtifact = undefined;
        if (cache_hit) {
            const bytes = cached_artifact.?;
            cached_artifact = null;
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
            artifact = .{ .allocator = allocator, .bytes = bytes, .digest = digest };
        } else compile: {
            var runner = ziac.project_program.NativeRunner{ .io = io, .cwd_path = project_path };
            var program = ziac.project_program.loadAlloc(allocator, compiler, runner.runner(), target) catch |err| {
                if (cached_artifact) |bytes| {
                    cached_artifact = null;
                    var digest: [32]u8 = undefined;
                    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
                    artifact = .{ .allocator = allocator, .bytes = bytes, .digest = digest };
                    break :compile;
                }
                return err;
            };
            defer program.deinit();
            artifact = try ziac.visual_artifact.serializeAlloc(allocator, &program.graph, null, .{
                .stack = target.stack,
                .stage = target.stage,
                .created_at_millis = created_at_millis,
            });
            try writeAtomicFile(allocator, io, root, cache_artifact_path, artifact.bytes);
            try writeAtomicFile(allocator, io, root, cache_revision_path, &revision_hex);
        }
        resource_count += try visualResourceCount(allocator, artifact.bytes);
        errdefer artifact.deinit();
        try serialized.append(allocator, artifact);
        const stored = &serialized.items[serialized.items.len - 1];
        try project_artifacts.append(allocator, .{
            .id = project.id,
            .path = project.path,
            .stack = target.stack,
            .stage = target.stage,
            .artifact_json = stored.bytes,
        });
    }
    if (project_artifacts.items.len == 0) return error.WorkspaceProjectNotFound;

    const workspace_name = try ziac.scaffold.projectNameAlloc(allocator, std.fs.path.basename(root_path));
    defer allocator.free(workspace_name);
    const artifact = try ziac.workspace.serializeVisualAlloc(allocator, .{
        .workspace = workspace_name,
        .created_at_millis = created_at_millis,
        .projects = project_artifacts.items,
    });
    defer allocator.free(artifact);
    const artifact_path = optionValue(args, "--out") orelse ".ziac/dashboard/workspace/artifact.json";
    const absolute_artifact_path = if (std.fs.path.isAbsolute(artifact_path)) absolute: {
        const parent = std.fs.path.dirname(artifact_path) orelse return error.InvalidWorkspaceArtifactPath;
        var output_dir = try std.Io.Dir.openDirAbsolute(io, parent, .{});
        defer output_dir.close(io);
        const basename = std.fs.path.basename(artifact_path);
        try writeAtomicFile(allocator, io, output_dir, basename, artifact);
        break :absolute try allocator.dupe(u8, artifact_path);
    } else relative: {
        if (std.mem.indexOf(u8, artifact_path, "..") != null) return error.InvalidWorkspaceArtifactPath;
        if (std.fs.path.dirname(artifact_path)) |parent| try root.createDirPath(io, parent);
        try writeAtomicFile(allocator, io, root, artifact_path, artifact);
        break :relative try root.realPathFileAlloc(io, artifact_path, allocator);
    };
    defer allocator.free(absolute_artifact_path);

    if (hasFlag(args, "--artifact-only")) {
        const receipt = try std.json.Stringify.valueAlloc(allocator, .{
            .schema = "ziac.workspace-dashboard-artifact.v1",
            .status = "ready",
            .path = absolute_artifact_path,
            .workspace = workspace_name,
            .projects = project_artifacts.items.len,
            .resources = resource_count,
        }, .{});
        defer allocator.free(receipt);
        try std.Io.File.stdout().writeStreamingAll(io, receipt);
        try std.Io.File.stdout().writeStreamingAll(io, "\n");
        return ziac.cli.Exit.success;
    }

    const executable_dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(executable_dir);
    const host_path = try std.fs.path.join(allocator, &.{ executable_dir, "ziac-dashboard-host" });
    defer allocator.free(host_path);
    const executable_path = try std.fs.path.join(allocator, &.{ executable_dir, "ziac" });
    defer allocator.free(executable_path);
    var host_args = std.ArrayList([]const u8).empty;
    defer host_args.deinit(allocator);
    try host_args.append(allocator, host_path);
    if (hasFlag(args, "--server-only")) try host_args.append(allocator, "--server-only");
    try host_args.appendSlice(allocator, &.{ "--workspace-refresh", executable_path, root_path, artifact_path });
    if (selected_project) |selected| try host_args.appendSlice(allocator, &.{ "--project", selected });
    if (optionValue(args, "--session")) |session| try host_args.appendSlice(allocator, &.{ "--session", session });
    if (optionValue(args, "--logs")) |logs| try host_args.appendSlice(allocator, &.{ "--logs", logs });
    try host_args.append(allocator, absolute_artifact_path);
    var child = try std.process.spawn(io, .{
        .argv = host_args.items,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |exit_code| @intCast(exit_code),
        else => ziac.cli.Exit.provider_error,
    };
}

fn writeAtomicFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    content: []const u8,
) !void {
    const temporary_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(temporary_path);
    try dir.writeFile(io, .{ .sub_path = temporary_path, .data = content });
    dir.rename(temporary_path, dir, path, io) catch |err| {
        dir.deleteFile(io, temporary_path) catch {};
        return err;
    };
}

fn workspaceTargetRevision(source_revision: [32]u8, target: ziac.program_format.Target) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&source_revision);
    hasher.update(target.stack);
    hasher.update(target.stage);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}

fn visualResourceCount(allocator: std.mem.Allocator, bytes: []const u8) !usize {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidWorkspaceVisualArtifact;
    const resources = parsed.value.object.get("resources") orelse return error.InvalidWorkspaceVisualArtifact;
    return switch (resources) {
        .array => |items| items.items.len,
        else => error.InvalidWorkspaceVisualArtifact,
    };
}

fn workspaceRootAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    explicit_root: ?[]const u8,
) ![]u8 {
    if (explicit_root) |path| {
        return if (std.fs.path.isAbsolute(path))
            std.Io.Dir.realPathFileAbsoluteAlloc(io, path, allocator)
        else
            cwd.realPathFileAlloc(io, path, allocator);
    }
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "rev-parse", "--show-toplevel" },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    }) catch return cwd.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);
    const succeeded = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!succeeded) return cwd.realPathFileAlloc(io, ".", allocator);
    const path = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (path.len == 0 or !std.fs.path.isAbsolute(path)) return error.InvalidWorkspaceRoot;
    return allocator.dupe(u8, path);
}

fn runInit(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    args: []const []const u8,
) !u8 {
    if (optionValue(args, "--preset")) |preset| {
        if (!std.mem.eql(u8, preset, "ziac-cloud")) return error.UnknownInitPreset;
        return runZiacCloudInit(allocator, io, cwd, args);
    }
    if (optionValue(args, "--template")) |template| return runTemplateInit(allocator, io, cwd, args, template);
    const explicit_name = if (args.len > 0 and !std.mem.startsWith(u8, args[0], "--")) args[0] else null;
    const options = if (explicit_name == null) args else args[1..];
    const current_path = try cwd.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(current_path);
    const inferred_name = if (explicit_name == null)
        try ziac.scaffold.projectNameAlloc(allocator, std.fs.path.basename(current_path))
    else
        null;
    defer if (inferred_name) |name| allocator.free(name);
    const name = explicit_name orelse inferred_name.?;
    const target = optionValue(options, "--dir") orelse if (explicit_name == null) "." else name;
    const workspace_root = try workspaceRootAlloc(allocator, io, cwd, null);
    defer allocator.free(workspace_root);
    if (!hasFlag(options, "--yes") and try shouldPromptForInit(io)) {
        const confirmed = try confirmInit(io, name, target, workspace_root);
        if (!confirmed) {
            try std.Io.File.stdout().writeStreamingAll(io, "Ziac project setup cancelled.\n");
            return ziac.cli.Exit.success;
        }
    }
    const owned_package_path = if (optionValue(options, "--ziac-path")) |path|
        try allocator.dupe(u8, path)
    else
        try defaultPackagePathAlloc(allocator, io);
    defer allocator.free(owned_package_path);
    const package_path = owned_package_path;
    const force = hasFlag(options, "--force");
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
    var workspace_dir = try std.Io.Dir.openDirAbsolute(io, workspace_root, .{});
    defer workspace_dir.close(io);
    try ziac.scaffold.writeWorkspaceAgentFiles(workspace_dir, io, rendered);
    const message = try std.fmt.allocPrint(allocator, "Created Ziac project {s} in {s}\n", .{ name, target });
    defer allocator.free(message);
    try std.Io.File.stdout().writeStreamingAll(io, message);
    return ziac.cli.Exit.success;
}

const RegistryRecord = struct {
    name: []const u8,
    version: []const u8,
    kind: []const u8,
    summary: []const u8,
    qualification: []const u8,
    manifest_sha256: []const u8,
};

fn runRegistry(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    if (args.len == 0 or (!std.mem.eql(u8, args[0], "list") and !std.mem.eql(u8, args[0], "search"))) return error.UnknownRegistryCommand;
    const root_path = try ecosystemRootAlloc(allocator, io);
    defer allocator.free(root_path);
    var root = try std.Io.Dir.openDirAbsolute(io, root_path, .{});
    defer root.close(io);
    const index_bytes = try root.readFileAlloc(io, "index.json", allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(index_bytes);
    var registry = try ziac.ecosystem.Registry.parseAlloc(allocator, index_bytes);
    defer registry.deinit();
    try verifyRegistryManifests(allocator, io, root, registry);

    const kind = if (optionValue(args, "--kind")) |value|
        std.meta.stringToEnum(ziac.ecosystem.Kind, value) orelse return error.InvalidPackageKind
    else
        null;
    const query = if (std.mem.eql(u8, args[0], "search") and args.len > 1 and !std.mem.startsWith(u8, args[1], "--")) args[1] else "";
    const matches = try registry.searchAlloc(allocator, .{ .query = query, .kind = kind, .limit = 100 });
    defer allocator.free(matches);
    const records = try allocator.alloc(RegistryRecord, matches.len);
    defer allocator.free(records);
    for (matches, 0..) |entry_index, index| {
        const entry = registry.entries[entry_index];
        records[index] = .{
            .name = entry.name,
            .version = entry.version,
            .kind = @tagName(entry.kind),
            .summary = entry.summary,
            .qualification = @tagName(entry.qualification),
            .manifest_sha256 = entry.manifest_sha256,
        };
    }
    const artifact = try std.json.Stringify.valueAlloc(allocator, .{
        .schema = "ziac.registry-search.v1",
        .query = query,
        .count = records.len,
        .packages = records,
    }, .{});
    defer allocator.free(artifact);
    try std.Io.File.stdout().writeStreamingAll(io, artifact);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
    return ziac.cli.Exit.success;
}

fn runPackage(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, args: []const []const u8) !u8 {
    if (args.len < 2 or !std.mem.eql(u8, args[0], "verify")) return error.UnknownPackageCommand;
    const requested = args[1];
    const manifest_path = if (std.mem.endsWith(u8, requested, ".json"))
        try allocator.dupe(u8, requested)
    else
        try std.fs.path.join(allocator, &.{ requested, "ziac.package.json" });
    defer allocator.free(manifest_path);
    const bytes = if (std.fs.path.isAbsolute(manifest_path))
        try readAbsoluteFileAlloc(allocator, io, manifest_path, ziac.ecosystem.max_manifest_bytes)
    else
        try cwd.readFileAlloc(io, manifest_path, allocator, .limited(ziac.ecosystem.max_manifest_bytes));
    defer allocator.free(bytes);
    var manifest = try ziac.ecosystem.Manifest.parseAlloc(allocator, bytes);
    defer manifest.deinit();
    const digest = std.fmt.bytesToHex(manifest.digest(), .lower);
    const artifact = try std.json.Stringify.valueAlloc(allocator, .{
        .schema = "ziac.package-verification.v1",
        .status = "valid",
        .name = manifest.name,
        .version = manifest.version,
        .kind = @tagName(manifest.kind),
        .manifest_sha256 = &digest,
    }, .{});
    defer allocator.free(artifact);
    try std.Io.File.stdout().writeStreamingAll(io, artifact);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
    return ziac.cli.Exit.success;
}

fn runTemplateInit(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    args: []const []const u8,
    template_name: []const u8,
) !u8 {
    const explicit_name = if (args.len > 0 and !std.mem.startsWith(u8, args[0], "--")) args[0] else null;
    const options = if (explicit_name == null) args else args[1..];
    const current_path = try cwd.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(current_path);
    const inferred_name = if (explicit_name == null) try ziac.scaffold.projectNameAlloc(allocator, std.fs.path.basename(current_path)) else null;
    defer if (inferred_name) |name| allocator.free(name);
    const name = explicit_name orelse inferred_name.?;
    const normalized = try ziac.scaffold.projectNameAlloc(allocator, name);
    defer allocator.free(normalized);
    if (!std.mem.eql(u8, normalized, name)) return error.InvalidProjectName;
    const target = optionValue(options, "--dir") orelse if (explicit_name == null) "." else name;
    const workspace_root = try workspaceRootAlloc(allocator, io, cwd, null);
    defer allocator.free(workspace_root);
    if (!hasFlag(options, "--yes") and try shouldPromptForInit(io)) {
        const confirmed = try confirmTemplateInit(io, name, target, workspace_root, template_name);
        if (!confirmed) return ziac.cli.Exit.success;
    }

    const package_path = if (optionValue(options, "--ziac-path")) |path| try allocator.dupe(u8, path) else try defaultPackagePathAlloc(allocator, io);
    defer allocator.free(package_path);
    const gcpx_path = if (optionValue(options, "--gcpx-path")) |path| try allocator.dupe(u8, path) else try defaultGcpxPathAlloc(allocator, io);
    defer allocator.free(gcpx_path);
    const ecosystem_path = try ecosystemRootAlloc(allocator, io);
    defer allocator.free(ecosystem_path);
    try cwd.createDirPath(io, target);
    const target_path = try cwd.realPathFileAlloc(io, target, allocator);
    defer allocator.free(target_path);
    const package_absolute = try absolutePackagePathAlloc(allocator, io, cwd, package_path);
    defer allocator.free(package_absolute);
    const gcpx_absolute = try absolutePackagePathAlloc(allocator, io, cwd, gcpx_path);
    defer allocator.free(gcpx_absolute);
    const dependency_path = try std.fs.path.relative(allocator, ".", null, target_path, package_absolute);
    defer allocator.free(dependency_path);
    const gcpx_dependency_path = try std.fs.path.relative(allocator, ".", null, target_path, gcpx_absolute);
    defer allocator.free(gcpx_dependency_path);
    const dependency_json = try std.json.Stringify.valueAlloc(allocator, dependency_path, .{});
    defer allocator.free(dependency_json);
    const gcpx_dependency_json = try std.json.Stringify.valueAlloc(allocator, gcpx_dependency_path, .{});
    defer allocator.free(gcpx_dependency_json);
    const zig_name = try allocator.dupe(u8, name);
    defer allocator.free(zig_name);
    for (zig_name) |*char| {
        if (char.* == '-') char.* = '_';
    }
    var name_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(name, &name_digest, .{});
    const package_id = std.mem.readInt(u32, name_digest[0..4], .little) | 1;
    const fingerprint = (@as(u64, std.hash.Crc32.hash(zig_name)) << 32) | package_id;
    var fingerprint_buffer: [16]u8 = undefined;
    const fingerprint_text = try std.fmt.bufPrint(&fingerprint_buffer, "{x}", .{fingerprint});

    var ecosystem_root = try std.Io.Dir.openDirAbsolute(io, ecosystem_path, .{});
    defer ecosystem_root.close(io);
    const index_bytes = try ecosystem_root.readFileAlloc(io, "index.json", allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(index_bytes);
    var registry = try ziac.ecosystem.Registry.parseAlloc(allocator, index_bytes);
    defer registry.deinit();
    try verifyRegistryManifests(allocator, io, ecosystem_root, registry);
    const qualified_name = if (std.mem.indexOfScalar(u8, template_name, '/') != null)
        try allocator.dupe(u8, template_name)
    else
        try std.fmt.allocPrint(allocator, "ziac/{s}", .{template_name});
    defer allocator.free(qualified_name);
    const entry = findRegistryEntry(registry, qualified_name, .template) orelse return error.UnknownTemplate;
    var template_root = try ecosystem_root.openDir(io, entry.path, .{});
    defer template_root.close(io);
    var target_dir = try cwd.openDir(io, target, .{});
    defer target_dir.close(io);
    try ziac.ecosystem.renderTemplate(allocator, io, template_root, target_dir, .{
        .project_name = name,
        .zig_package_name = zig_name,
        .package_fingerprint = fingerprint_text,
        .ziac_path_json = dependency_json,
        .ziac_gcpx_path_json = gcpx_dependency_json,
    }, hasFlag(options, "--force"));

    var agent_files = try ziac.scaffold.renderAlloc(allocator, .{ .project_name = name, .ziac_path = dependency_path });
    defer agent_files.deinit();
    var workspace_dir = try std.Io.Dir.openDirAbsolute(io, workspace_root, .{});
    defer workspace_dir.close(io);
    try ziac.scaffold.writeWorkspaceAgentFiles(workspace_dir, io, agent_files);
    try std.Io.File.stdout().writeStreamingAll(io, "Created Ziac project ");
    try std.Io.File.stdout().writeStreamingAll(io, name);
    try std.Io.File.stdout().writeStreamingAll(io, " from template ");
    try std.Io.File.stdout().writeStreamingAll(io, entry.name);
    try std.Io.File.stdout().writeStreamingAll(io, " in ");
    try std.Io.File.stdout().writeStreamingAll(io, target);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
    return ziac.cli.Exit.success;
}

fn verifyRegistryManifests(allocator: std.mem.Allocator, io: std.Io, root: std.Io.Dir, registry: ziac.ecosystem.Registry) !void {
    for (registry.entries) |entry| {
        const manifest_path = try std.fs.path.join(allocator, &.{ entry.path, "ziac.package.json" });
        defer allocator.free(manifest_path);
        const bytes = try root.readFileAlloc(io, manifest_path, allocator, .limited(ziac.ecosystem.max_manifest_bytes));
        defer allocator.free(bytes);
        try registry.verifyManifest(entry, bytes);
    }
}

fn findRegistryEntry(registry: ziac.ecosystem.Registry, name: []const u8, kind: ziac.ecosystem.Kind) ?ziac.ecosystem.RegistryEntry {
    for (registry.entries) |entry| if (entry.kind == kind and std.mem.eql(u8, entry.name, name)) return entry;
    return null;
}

fn confirmTemplateInit(io: std.Io, name: []const u8, target: []const u8, workspace_root: []const u8, template: []const u8) !bool {
    var buffer: [2048]u8 = undefined;
    const summary = try std.fmt.bufPrint(&buffer,
        \\Ziac project setup
        \\  Project        {s}
        \\  Directory      {s}
        \\  Workspace      {s}
        \\  Template       {s}
        \\  Agent skills   Ziac + GCP researcher for Codex, Claude, Gemini
        \\
        \\Create project? [Y/n]
    , .{ name, target, workspace_root, template });
    try std.Io.File.stdout().writeStreamingAll(io, summary);
    var read_buffer: [128]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &read_buffer);
    const line = (try reader.interface.takeDelimiter('\n')) orelse return true;
    const answer = std.mem.trim(u8, line, " \t\r\n");
    return answer.len == 0 or std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes");
}

fn absolutePackagePathAlloc(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, path: []const u8) ![:0]u8 {
    return if (std.fs.path.isAbsolute(path)) std.Io.Dir.realPathFileAbsoluteAlloc(io, path, allocator) else cwd.realPathFileAlloc(io, path, allocator);
}

fn ecosystemRootAlloc(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    return installedOrSourceRootAlloc(allocator, io, "ziac-templates", "index.json", "../ziac-templates");
}

fn defaultGcpxPathAlloc(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    return installedOrSourceRootAlloc(allocator, io, "ziac-gcpx", "build.zig.zon", "../ziac-gcpx");
}

fn installedOrSourceRootAlloc(allocator: std.mem.Allocator, io: std.Io, share_name: []const u8, marker: []const u8, source_relative: []const u8) ![]u8 {
    const executable_dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(executable_dir);
    const installed = try std.fs.path.resolve(allocator, &.{ executable_dir, "..", "share", share_name });
    errdefer allocator.free(installed);
    const installed_marker = try std.fs.path.join(allocator, &.{ installed, marker });
    defer allocator.free(installed_marker);
    var file = std.Io.Dir.openFileAbsolute(io, installed_marker, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            allocator.free(installed);
            return std.fs.path.resolve(allocator, &.{ build_options.package_root, source_relative });
        },
        else => return err,
    };
    file.close(io);
    return installed;
}

fn readAbsoluteFileAlloc(allocator: std.mem.Allocator, io: std.Io, path: []const u8, limit: usize) ![]u8 {
    const parent = std.fs.path.dirname(path) orelse return error.InvalidPackageEntry;
    const basename = std.fs.path.basename(path);
    var dir = try std.Io.Dir.openDirAbsolute(io, parent, .{});
    defer dir.close(io);
    return dir.readFileAlloc(io, basename, allocator, .limited(limit));
}

fn runZiacCloudInit(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    args: []const []const u8,
) !u8 {
    const target = optionValue(args, "--dir") orelse ".";
    const force = hasFlag(args, "--force");
    const package_path = if (optionValue(args, "--ziac-path")) |path|
        try allocator.dupe(u8, path)
    else
        try defaultPackagePathAlloc(allocator, io);
    defer allocator.free(package_path);
    try cwd.createDirPath(io, target);
    const target_path = try cwd.realPathFileAlloc(io, target, allocator);
    defer allocator.free(target_path);
    const package_absolute = if (std.fs.path.isAbsolute(package_path))
        try std.Io.Dir.realPathFileAbsoluteAlloc(io, package_path, allocator)
    else
        try cwd.realPathFileAlloc(io, package_path, allocator);
    defer allocator.free(package_absolute);
    var workspace_dir = try std.Io.Dir.openDirAbsolute(io, target_path, .{});
    defer workspace_dir.close(io);
    const projects = [_]struct { path: []const u8, name: []const u8, kind: ziac.scaffold.SelfHostProject }{
        .{ .path = "platform/bootstrap", .name = "ziac-cloud-bootstrap", .kind = .bootstrap },
        .{ .path = "platform/data", .name = "ziac-cloud-data", .kind = .data },
        .{ .path = "platform/control-plane", .name = "ziac-cloud-control-plane", .kind = .control_plane },
        .{ .path = "platform/billing", .name = "ziac-cloud-billing", .kind = .billing },
    };
    var wrote_skills = false;
    for (projects) |project| {
        try workspace_dir.createDirPath(io, project.path);
        const project_path = try std.fs.path.join(allocator, &.{ target_path, project.path });
        defer allocator.free(project_path);
        const dependency_path = try std.fs.path.relative(allocator, ".", null, project_path, package_absolute);
        defer allocator.free(dependency_path);
        var rendered = try ziac.scaffold.renderSelfHostAlloc(allocator, .{ .project_name = project.name, .ziac_path = dependency_path }, project.kind);
        defer rendered.deinit();
        var project_dir = try workspace_dir.openDir(io, project.path, .{});
        defer project_dir.close(io);
        try ziac.scaffold.write(project_dir, io, rendered, force);
        if (!wrote_skills) {
            try ziac.scaffold.writeWorkspaceAgentFiles(workspace_dir, io, rendered);
            wrote_skills = true;
        }
    }
    try workspace_dir.writeFile(io, .{ .sub_path = "README.md", .data = self_host_readme });
    try std.Io.File.stdout().writeStreamingAll(io, "Created Ziac Cloud workspace in ");
    try std.Io.File.stdout().writeStreamingAll(io, target);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
    return ziac.cli.Exit.success;
}

const self_host_readme =
    \\# Ziac Cloud
    \\
    \\This workspace deploys Ziac with Ziac. Start with `platform/bootstrap` using local state, migrate that state into the emitted GCS bucket, then deploy `platform/data`, `platform/control-plane`, and `platform/billing` with the remote backend.
    \\
    \\The bootstrap owns Artifact Registry and Cloud Build. `scripts/qualify-ziac-cloud.sh` builds immutable control-plane and billing-worker images when image refs are not supplied, deploys all four projects, and proves the hourly billing scheduler.
    \\
    \\Populate explicit Secret Manager versions for the Cockroach admin URL and Google OAuth client credentials before the authenticated qualification. Secret values never belong in this repository or a Ziac artifact.
    \\
    \\Run `ziac dashboard` at this repository root to compile and visualize all four projects together.
    \\
;

fn shouldPromptForInit(io: std.Io) !bool {
    return std.Io.File.stdin().isTty(io) catch false;
}

fn confirmInit(io: std.Io, name: []const u8, target: []const u8, workspace_root: []const u8) !bool {
    var summary_buffer: [2048]u8 = undefined;
    const summary = try std.fmt.bufPrint(&summary_buffer,
        \\Ziac project setup
        \\  Project        {s}
        \\  Directory      {s}
        \\  Workspace      {s}
        \\  Template       Global Zig service on GCP
        \\  Dashboard      global-api / dev
        \\  Agent skills   Ziac + GCP researcher for Codex, Claude, Gemini
        \\
        \\Create project? [Y/n]
    , .{ name, target, workspace_root });
    try std.Io.File.stdout().writeStreamingAll(io, summary);
    var read_buffer: [128]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &read_buffer);
    const line = (try reader.interface.takeDelimiter('\n')) orelse return true;
    const answer = std.mem.trim(u8, line, " \t\r\n");
    return answer.len == 0 or std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes");
}

fn defaultPackagePathAlloc(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const executable_dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(executable_dir);
    const installed_candidate = try std.fs.path.resolve(allocator, &.{ executable_dir, "..", "share", "ziac" });
    errdefer allocator.free(installed_candidate);
    const installed_manifest = try std.fs.path.join(allocator, &.{ installed_candidate, "build.zig.zon" });
    defer allocator.free(installed_manifest);
    var installed = std.Io.Dir.openFileAbsolute(io, installed_manifest, .{}) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, build_options.package_root),
        else => return err,
    };
    installed.close(io);
    return installed_candidate;
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
    if (args.len >= 1 and std.mem.eql(u8, args[0], "provider")) return true;
    if (args.len >= 1 and std.mem.eql(u8, args[0], "preview-stage")) return true;
    if (args.len >= 1 and std.mem.eql(u8, args[0], "dev")) return true;
    if (args.len >= 1 and (std.mem.eql(u8, args[0], "logs") or std.mem.eql(u8, args[0], "tail") or
        std.mem.eql(u8, args[0], "log-explain"))) return true;
    if (args.len >= 1 and std.mem.eql(u8, args[0], "agent")) return true;
    if (args.len >= 1 and std.mem.eql(u8, args[0], "estate")) return true;
    return args.len >= 2 and std.mem.eql(u8, args[0], "auth") and std.mem.eql(u8, args[1], "doctor");
}
