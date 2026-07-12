const std = @import("std");
const ziac = @import("ziac");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const database_url = init.environ_map.get("DATABASE_URL") orelse return error.DatabaseUrlRequired;
    const google_client_id = init.environ_map.get("GOOGLE_OAUTH_CLIENT_ID") orelse return error.GoogleClientIdRequired;
    const google_client_secret = init.environ_map.get("GOOGLE_OAUTH_CLIENT_SECRET") orelse return error.GoogleClientSecretRequired;
    const kms_key = init.environ_map.get("ZIAC_ESTATE_KMS_KEY") orelse return error.KmsKeyRequired;
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

    var native_database = try ziac.estate_cockroach.NativeDatabase.init(allocator, io, database_url, .{});
    defer native_database.deinit();
    var repository = ziac.estate_cockroach.Repository.init(allocator, native_database.database());
    defer repository.deinit();
    var oauth = try ziac.gcp.oauth.Client.init(allocator, local_http.client(), .{
        .client_id = google_client_id,
        .client_secret = google_client_secret,
    });
    defer oauth.deinit();
    var kms = try ziac.gcp.kms_vault.Vault.init(
        allocator,
        &google_client,
        &operation_context,
        kms_key,
        repository.ciphertextStore(),
    );
    defer kms.deinit();
    var assertions = ziac.estate_cockroach.RandomAssertionIssuer.init(io);
    var service = ziac.estate_service.Service.initWithGoogle(repository.repository(), .{
        .oauth = oauth.exchanger(),
        .challenges = repository.challengeVerifier(),
        .assertions = assertions.issuer(),
        .vault = kms.credentialVault(),
    });

    var address = try std.Io.net.IpAddress.parseIp4("0.0.0.0", port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    while (true) {
        const stream = listener.accept(io) catch continue;
        handleConnection(allocator, io, stream, &service) catch {};
    }
}

fn handleConnection(
    allocator: std.mem.Allocator,
    io: std.Io,
    stream: std.Io.net.Stream,
    service: *ziac.estate_service.Service,
) !void {
    defer stream.close(io);
    var read_buffer: [16 * 1024]u8 = undefined;
    var stream_reader = stream.reader(io, &read_buffer);
    var write_buffer: [16 * 1024]u8 = undefined;
    var stream_writer = stream.writer(io, &write_buffer);
    var http_server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
    var request = try http_server.receiveHead();
    const method = try allocator.dupe(u8, @tagName(request.head.method));
    defer allocator.free(method);
    const target = try allocator.dupe(u8, request.head.target);
    defer allocator.free(target);
    var authorization: ?[]u8 = null;
    defer if (authorization) |value| {
        std.crypto.secureZero(u8, value);
        allocator.free(value);
    };
    var headers = request.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "authorization")) authorization = try allocator.dupe(u8, header.value);
    }
    var body_buffer: [64 * 1024]u8 = undefined;
    const body_reader = try request.readerExpectContinue(&body_buffer);
    const body = try body_reader.allocRemaining(allocator, .limited(64 * 1024));
    defer {
        std.crypto.secureZero(u8, body);
        allocator.free(body);
    }
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    const now_millis: u64 = @intCast(std.Io.Clock.real.now(io).toMilliseconds());
    var result = try service.handleAlloc(allocator, .{
        .method = method,
        .path = path,
        .authorization = authorization,
        .body = body,
        .now_millis = now_millis,
    });
    defer result.deinit();
    try request.respond(result.body, .{
        .status = @enumFromInt(result.status),
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}
