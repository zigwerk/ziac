const std = @import("std");
const ziac = @import("ziac");

const MainProgram = ziac.zstd.fx.kernel.Effect(void, anyerror, .{}).Stateful(std.process.Init);

pub fn main(init: std.process.Init) !void {
    return ziac.process_runtime.run(init, "ziac-provider-cockroach", MainProgram.init(init, runMain));
}

fn runMain(init: std.process.Init, ctx: *MainProgram.Context) !void {
    _ = ctx.recordCausal(.{
        .kind = .service_provided,
        .service_key = "ziac/ProviderRegistry",
        .label = "cockroach",
        .status = "ready",
        .redacted_detail = "ziac.provider.rpc.v1",
    });
    const allocator = init.gpa;
    const api_key = init.environ_map.get("COCKROACH_API_KEY") orelse return error.AuthenticationFailed;
    if (api_key.len == 0) return error.AuthenticationFailed;
    var local_http = ziac.zstd.Http.LocalClient.init(allocator, init.io);
    defer local_http.deinit();
    var client = ziac.cockroach.client.Client.init(local_http.client(), api_key, .{});
    var live_provider = ziac.cockroach.live_provider.LiveProvider.init(&client);
    var session = ziac.provider_rpc.ServerSession.init(allocator, .{
        .package_name = "ziac-provider/cockroach",
        .package_version = "0.1.0",
        .provider = .cockroach,
        .resource_type_prefixes = &.{"cockroach."},
        .capabilities = .all,
        .max_inflight = 1,
    }, live_provider.provider());
    try ziac.provider_rpc.serveStdioEffectful(init.io, allocator, &session, ctx.runtime());
}
