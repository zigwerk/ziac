const std = @import("std");
const ziac = @import("ziac");

const MainProgram = ziac.zstd.fx.kernel.Effect(void, anyerror, .{}).Stateful(std.process.Init);

pub fn main(init: std.process.Init) !void {
    return ziac.process_runtime.run(init, "ziac-provider-gcp", MainProgram.init(init, runMain));
}

fn runMain(init: std.process.Init, ctx: *MainProgram.Context) !void {
    _ = ctx.recordCausal(.{
        .kind = .service_provided,
        .service_key = "ziac/ProviderRegistry",
        .label = "gcp",
        .status = "ready",
        .redacted_detail = "ziac.provider.rpc.v1",
    });
    const allocator = init.gpa;
    var cwd = std.Io.Dir.cwd();
    var local_fs = ziac.zstd.FileSystem.LocalFileSystem.init(&cwd, init.io);
    var auth_files = ziac.gcp.auth.localFileReader(&local_fs);
    var auth_env = ziac.zstd.Env.EnvMap.init(allocator);
    defer auth_env.deinit();
    for ([_][]const u8{ "GOOGLE_APPLICATION_CREDENTIALS", "HOME", "APPDATA" }) |name| {
        if (init.environ_map.get(name)) |entry| try auth_env.put(name, entry);
    }

    var local_http = ziac.zstd.Http.LocalClient.init(allocator, init.io);
    defer local_http.deinit();
    var resolved = try ziac.gcp.auth.resolveAdcAlloc(allocator, auth_env, &auth_files);
    defer resolved.deinit(allocator);
    var adc_source = ziac.gcp.auth.AdcTokenSource.init(&resolved, local_http.client(), auth_files);
    var token_cache = ziac.gcp.auth.TokenCache.init(adc_source.tokenSource(), 300);
    defer token_cache.deinit(allocator);
    var client = ziac.gcp.client.Client.init(local_http.client(), &token_cache, .{});
    var live_provider = ziac.gcp.live_provider.LiveProvider.init(&client);
    var session = ziac.provider_rpc.ServerSession.init(allocator, .{
        .package_name = "ziac-provider/gcp",
        .package_version = "0.1.0",
        .provider = .gcp,
        .resource_type_prefixes = &.{"gcp."},
        .capabilities = .all,
        .max_inflight = 1,
    }, live_provider.provider());
    try ziac.provider_rpc.serveStdioEffectful(init.io, allocator, &session, ctx.runtime());
}
