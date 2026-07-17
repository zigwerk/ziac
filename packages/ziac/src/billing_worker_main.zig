const std = @import("std");
const ziac = @import("ziac");

const Runtime = struct {
    reader: ziac.billing_worker.Reader,
    store: ziac.billing_worker.Store,
    billing_project: []const u8,
    export_table: []const u8,
    resource_project: []const u8,
    currency: []const u8,
};

const MainProgram = ziac.zstd.fx.kernel.Effect(void, anyerror, .{ziac.process_runtime.ProcessInputs});

pub fn main(init: std.process.Init) !void {
    return ziac.process_runtime.run(init, "ziac-billing-worker", MainProgram.fromFn(runMain));
}

fn runMain(ctx: *MainProgram.Context) !void {
    const init = ctx.service(ziac.process_runtime.ProcessInputs).init;
    const allocator = init.gpa;
    const io = init.io;
    const database_url = init.environ_map.get("DATABASE_URL") orelse return error.DatabaseUrlRequired;
    const billing_project = init.environ_map.get("ZIAC_BILLING_PROJECT") orelse return error.BillingProjectRequired;
    const export_table = init.environ_map.get("ZIAC_BILLING_EXPORT_TABLE") orelse return error.BillingExportRequired;
    const resource_project = init.environ_map.get("ZIAC_GCP_PROJECT") orelse return error.ResourceProjectRequired;
    const currency = init.environ_map.get("ZIAC_BILLING_CURRENCY") orelse "USD";
    const port = try std.fmt.parseInt(u16, init.environ_map.get("PORT") orelse "8080", 10);

    var local_http = ziac.zstd.Http.LocalClient.init(allocator, io);
    defer local_http.deinit();
    var cwd = std.Io.Dir.cwd();
    var local_fs = ziac.zstd.FileSystem.LocalFileSystem.init(&cwd, io);
    var auth_files = ziac.gcp.auth.localFileReader(&local_fs);
    var auth_env = ziac.zstd.Env.EnvMap.init(allocator);
    defer auth_env.deinit();
    for ([_][]const u8{ "GOOGLE_APPLICATION_CREDENTIALS", "HOME", "APPDATA" }) |name| {
        if (init.environ_map.get(name)) |value| try auth_env.put(name, value);
    }
    var resolved = try ziac.gcp.auth.resolveAdcAlloc(allocator, auth_env, &auth_files);
    defer resolved.deinit(allocator);
    var adc = ziac.gcp.auth.AdcTokenSource.init(&resolved, local_http.client(), auth_files);
    var token_cache = ziac.gcp.auth.TokenCache.init(adc.tokenSource(), 300);
    defer token_cache.deinit(allocator);
    var google_client = ziac.gcp.client.Client.init(local_http.client(), &token_cache, .{});
    var operation_context = ziac.provider.OperationContext.init(allocator);
    var adapter = ziac.gcp.billing.Adapter.init(&google_client, &operation_context);
    var bigquery = ziac.billing_bigquery.Reader{ .adapter = &adapter };

    var native_database = try ziac.estate_cockroach.NativeDatabase.init(allocator, io, database_url, .{});
    defer native_database.deinit();
    var repository = ziac.billing_cockroach.Repository.init(allocator, native_database.database());
    var runtime = Runtime{
        .reader = bigquery.reader(),
        .store = repository.store(),
        .billing_project = billing_project,
        .export_table = export_table,
        .resource_project = resource_project,
        .currency = currency,
    };

    var address = try std.Io.net.IpAddress.parseIp4("0.0.0.0", port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    while (true) {
        const stream = listener.accept(io) catch continue;
        var handle = ctx.runtime();
        _ = handle.run(requestEffect(.{
            .allocator = allocator,
            .io = io,
            .stream = stream,
            .runtime = &runtime,
        }).named("billing.http.request")) catch {};
    }
}

const RequestState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    runtime: *Runtime,
};
const RequestProgram = ziac.zstd.fx.kernel.Effect(void, anyerror, .{}).Stateful(RequestState);

fn requestEffect(state: RequestState) RequestProgram {
    return RequestProgram.init(state, struct {
        fn run(request: RequestState, _: *RequestProgram.Context) anyerror!void {
            try handleConnection(request.allocator, request.io, request.stream, request.runtime);
        }
    }.run);
}

fn handleConnection(allocator: std.mem.Allocator, io: std.Io, stream: std.Io.net.Stream, runtime: *Runtime) !void {
    defer stream.close(io);
    var read_buffer: [16 * 1024]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buffer);
    var write_buffer: [16 * 1024]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buffer);
    var server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
    var request = try server.receiveHead();
    const target = request.head.target;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    if (request.head.method == .GET and
        (std.mem.eql(u8, path, "/health/startup") or std.mem.eql(u8, path, "/health/live")))
    {
        return request.respond("{\"schema\":\"ziac.billing-health.v1\",\"status\":\"ready\"}", responseOptions(.ok));
    }
    if (request.head.method != .POST or !std.mem.eql(u8, path, "/v1/billing:ingest")) {
        return request.respond("{\"error_code\":\"not_found\"}", responseOptions(.not_found));
    }
    var body_buffer: [1024]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&body_buffer);
    const body = try body_reader.allocRemaining(allocator, .limited(1024));
    defer allocator.free(body);
    if (body.len > 0 and !std.mem.eql(u8, std.mem.trim(u8, body, " \t\r\n"), "{}")) {
        return request.respond("{\"error_code\":\"invalid_request\"}", responseOptions(.bad_request));
    }
    const now_millis: u64 = @intCast(std.Io.Clock.real.now(io).toMilliseconds());
    const hour_millis = std.time.ms_per_hour;
    const rounded_end = now_millis - (now_millis % hour_millis);
    const window_start = monthStartMillis(rounded_end);
    const window_end = if (rounded_end == window_start) window_start + 1 else rounded_end;
    const receipt = ziac.billing_worker.ingestAlloc(allocator, runtime.reader, runtime.store, .{
        .billing_project = runtime.billing_project,
        .export_table = runtime.export_table,
        .resource_project = runtime.resource_project,
        .currency = runtime.currency,
        .window_start_millis = window_start,
        .window_end_millis = window_end,
    }, &.{}, now_millis) catch {
        return request.respond("{\"schema\":\"ziac.billing-ingestion.v1\",\"status\":\"failed\",\"error_code\":\"ingestion_failed\"}", responseOptions(.service_unavailable));
    };
    const response = try std.json.Stringify.valueAlloc(allocator, .{
        .schema = "ziac.billing-ingestion.v1",
        .status = "complete",
        .billed_total_micros = receipt.billed_total_micros,
        .attributed_total_micros = receipt.attributed_total_micros,
        .unattributed_total_micros = receipt.unattributed_total_micros,
        .coverage_basis_points = receipt.coverage_basis_points,
        .resource_count = receipt.resource_count,
    }, .{});
    defer allocator.free(response);
    try request.respond(response, responseOptions(.ok));
}

fn monthStartMillis(now_millis: u64) u64 {
    const seconds = now_millis / std.time.ms_per_s;
    const epoch_day = (std.time.epoch.EpochSeconds{ .secs = seconds }).getEpochDay();
    const month_day = epoch_day.calculateYearDay().calculateMonthDay();
    return (epoch_day.day - month_day.day_index) * std.time.s_per_day * std.time.ms_per_s;
}

fn responseOptions(status: std.http.Status) std.http.Server.Request.RespondOptions {
    return .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    };
}
