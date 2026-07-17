const std = @import("std");
const zstd = @import("zigeffect_std");
const kernel = zstd.fx.kernel;

pub const HealthApi = struct {
    pub const operations: []const []const u8 = &.{"Health.route"};
};
pub const Health = kernel.Service("application/Health", HealthApi);

const RouteResult = struct { status: std.http.Status, body: []const u8 };
const RouteBase = kernel.Effect(RouteResult, error{}, .{Health});
const Route = RouteBase.Stateful([]const u8);

fn route(target: []const u8) Route {
    return Route.init(target, struct {
        fn run(path: []const u8, ctx: *Route.Context) error{}!RouteResult {
            _ = ctx.service(Health);
            const found = std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/health/live") or std.mem.eql(u8, path, "/health/startup");
            return .{
                .status = if (found) .ok else .not_found,
                .body = if (found) "{\"status\":\"ok\"}" else "{\"error\":\"not found\"}",
            };
        }
    }.run);
}

fn handleConnection(io: std.Io, stream: std.Io.net.Stream, runtime: anytype) void {
    defer stream.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    var request = server.receiveHead() catch return;
    const result = runtime.run(route(request.head.target).named("http.health")) catch return;
    request.respond(result.body, .{
        .status = result.status,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    }) catch {};
}

const ProcessInputs = struct { io: std.Io, port: u16 };
const ProcessInputsService = kernel.Service("application/ProcessInputs", ProcessInputs);
const Serve = kernel.Effect(void, anyerror, .{ Health, ProcessInputsService });

fn serve() Serve {
    return Serve.fromFn(struct {
        fn run(ctx: *Serve.Context) anyerror!void {
            const process = ctx.service(ProcessInputsService);
            var address = try std.Io.net.IpAddress.parseIp4("0.0.0.0", process.port);
            var listener = try address.listen(process.io, .{ .reuse_address = true });
            defer listener.deinit(process.io);
            while (true) {
                const stream = listener.accept(process.io) catch continue;
                var runtime = ctx.runtime();
                handleConnection(process.io, stream, &runtime);
            }
        }
    }.run);
}

pub fn rootLayer(inputs: ProcessInputs) @TypeOf(kernel.Layer.mergeAll(.{
    kernel.Layer.succeed(Health, HealthApi{}),
    kernel.Layer.succeed(ProcessInputsService, inputs),
})) {
    return kernel.Layer.mergeAll(.{
        kernel.Layer.succeed(Health, .{}),
        kernel.Layer.succeed(ProcessInputsService, inputs),
    });
}

pub fn runWithOptions(init: std.process.Init, options: zstd.CausalRuntime.Options) !void {
    const port = if (init.environ_map.get("PORT")) |value| try std.fmt.parseInt(u16, value, 10) else 8080;
    const main_layer = rootLayer(.{ .io = init.io, .port = port });
    var runtime = try zstd.ManagedRuntime(@TypeOf(main_layer)).make(
        init.gpa,
        init.io,
        std.Io.Dir.cwd(),
        main_layer,
        options,
    );
    defer runtime.deinit();
    try runtime.run(serve().named("application.serve"));
    try runtime.shutdown();
}

pub fn main(init: std.process.Init) !void {
    return runWithOptions(init, .{});
}

test "runtime causal contract" {
    var context = try zstd.Testing.TestContext.init(std.testing.allocator, .{
        .project = "global-zig-api",
        .suite = "app-tests",
        .scenario = .{
            .id = "runtime-causal-contract",
            .label = "runtime causal contract",
            .requirement = "runtime-causal-contract",
            .acceptance_check = "check-runtime-causal-contract",
            .component = "application",
            .command = "test",
        },
        .seed = 42,
    });
    defer context.deinit();
    const assertions = zstd.Testing.AssertionRecorder.init(&context);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const main_layer = rootLayer(.{ .io = std.testing.io, .port = 8080 });
    var runtime = try zstd.ManagedRuntime(@TypeOf(main_layer)).make(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        main_layer,
        .{
            // Test-only injection keeps assertions and the project graph on one runtime.
            .causal_store = context.causalStore(),
            .graph = .{ .path = ".zigeffect/graph", .max_records = 4096 },
        },
    );
    defer runtime.deinit();

    const result = try runtime.run(route("/health/live").named("test.health"));
    try assertions.equal(.{
        .id = "health-status",
        .label = "health route succeeds",
        .repair_hint = "preserve the typed health service",
    }, @as(u16, 200), @intFromEnum(result.status));
    _ = try assertions.event(.{
        .id = "health-causal",
        .label = "health operation is causal",
        .repair_hint = "run the named route effect through the owning runtime",
    }, .{ .kind = .effect_completed, .label = "test.health", .status = "success" });

    var snapshot = try runtime.inspect(std.testing.allocator, .{ .max_recent_events = 128 });
    defer snapshot.deinit();
    try assertions.applicationService(.{
        .id = "health-service",
        .label = "health service is mapped",
        .repair_hint = "provide Health from rootLayer",
    }, &snapshot, Health.service_key, true);
    try assertions.applicationOperation(.{
        .id = "health-operation",
        .label = "health operation is mapped",
        .repair_hint = "declare Health.route",
    }, &snapshot, Health.service_key, "Health.route");
    try assertions.noFindings(.{
        .id = "health-no-findings",
        .label = "runtime is causally healthy",
        .repair_hint = "close every effect and scope",
    });
    try assertions.noPendingFibers(.{
        .id = "health-no-pending",
        .label = "runtime has no pending fibers",
        .repair_hint = "join every request child",
    });
    try context.mapCausalEventIds(&runtime);
    try runtime.shutdown();
}
