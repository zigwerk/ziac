const std = @import("std");
const ziac = @import("ziac");

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
    var local_fs = ziac.zstd.FileSystem.LocalFileSystem.init(&cwd, io);
    var auth_files = ziac.gcp.auth.localFileReader(&local_fs);
    var auth_env = ziac.zstd.Env.EnvMap.init(allocator);
    defer auth_env.deinit();
    for ([_][]const u8{ "GOOGLE_APPLICATION_CREDENTIALS", "HOME", "APPDATA" }) |name| {
        if (init.environ_map.get(name)) |value| try auth_env.put(name, value);
    }
    const live_project = init.environ_map.get("ZIAC_LIVE_PROJECT");
    const registry = if (live_project) |project_id|
        ziac.stack_registry.configuredRegistry(.{
            .project_id = project_id,
            .region = init.environ_map.get("ZIAC_LIVE_REGION") orelse "europe-west1",
            .service_account = init.environ_map.get("ZIAC_LIVE_SERVICE_ACCOUNT"),
            .image = init.environ_map.get("ZIAC_LIVE_IMAGE"),
        })
    else
        ziac.stack_registry.fixtureRegistry();

    var local_http = ziac.zstd.Http.LocalClient.init(allocator, io);
    defer local_http.deinit();
    var resolved_adc: ?ziac.gcp.auth.ResolvedAdc = null;
    defer if (resolved_adc) |*resolved| resolved.deinit(allocator);
    var adc_source: ziac.gcp.auth.AdcTokenSource = undefined;
    var token_cache: ?ziac.gcp.auth.TokenCache = null;
    defer if (token_cache) |*cache| cache.deinit(allocator);
    var google_client: ziac.gcp.client.Client = undefined;
    var live_provider: ziac.gcp.live_provider.LiveProvider = undefined;
    var live_providers: ?ziac.provider.ProviderRegistry = null;
    if (requestsLiveProvider(args.items)) {
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
            live_providers = providers;
        } else |_| {}
    }
    var env = ziac.cli.Env{
        .console = &console,
        .registry = registry,
        .state = ziac.local_state.Store.init(allocator, ziac.local_state.localFiles.store(&local_fs)),
        .auth_env = &auth_env,
        .auth_files = auth_files,
        .live_providers = live_providers,
        .live_project_id = live_project,
    };

    const code = try ziac.cli.run(allocator, args.items, &env);
    if (console.stdoutText().len > 0) {
        try std.Io.File.stdout().writeStreamingAll(io, console.stdoutText());
    }
    if (console.stderrText().len > 0) {
        try std.Io.File.stderr().writeStreamingAll(io, console.stderrText());
    }
    std.process.exit(code);
}

fn requestsLiveProvider(args: []const []const u8) bool {
    for (args, 0..) |arg, index| {
        if (!std.mem.eql(u8, arg, "--provider")) continue;
        if (index + 1 < args.len and std.mem.eql(u8, args[index + 1], "gcp")) return true;
    }
    return false;
}
