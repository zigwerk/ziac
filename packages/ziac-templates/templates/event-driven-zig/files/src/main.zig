const std = @import("std");
const zstd = @import("zigeffect_std");
const event_workflow = @import("event_workflow.zig");
const kernel = zstd.fx.kernel;
const runtime_contract_source = zstd.Testing.Contract.SourceReference{ .id = "generated-runtime-contract", .path = "src/main.zig", .line = 128, .column = 1 };
const workflow_contract_source = zstd.Testing.Contract.SourceReference{ .id = "generated-workflow-contract", .path = "src/main.zig", .line = 218, .column = 1 };

pub const EventWorkerApi = struct {
    pub const operations: []const []const u8 = &.{ "EventWorker.route", "EventWorker.validate" };
};
pub const EventWorker = kernel.Service("application/EventWorker", EventWorkerApi);

const ValidateBase = kernel.Effect(bool, error{}, .{EventWorker});
const Validate = ValidateBase.Stateful([]const u8);

fn validateEvent(name: []const u8) Validate {
    return Validate.init(name, struct {
        fn run(event_name: []const u8, ctx: *Validate.Context) error{}!bool {
            _ = ctx.service(EventWorker);
            const valid = event_name.len > 0 and std.mem.indexOfAny(u8, event_name, "\r\n") == null;
            return valid;
        }
    }.run);
}

const RouteResult = struct { status: std.http.Status, body: []const u8 };
const RouteBase = kernel.Effect(RouteResult, error{}, .{EventWorker});
const Route = RouteBase.Stateful([]const u8);

fn route(target: []const u8) Route {
    return Route.init(target, struct {
        fn run(path: []const u8, ctx: *Route.Context) error{}!RouteResult {
            _ = ctx.service(EventWorker);
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
const Serve = kernel.Effect(void, anyerror, .{ EventWorker, ProcessInputsService });

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

pub fn rootLayer(workflow: event_workflow.EventWorkflowApi, inputs: ProcessInputs) @TypeOf(kernel.Layer.mergeAll(.{
    kernel.Layer.succeed(EventWorker, EventWorkerApi{}),
    kernel.Layer.succeed(event_workflow.EventWorkflow, workflow),
    kernel.Layer.succeed(ProcessInputsService, inputs),
})) {
    return kernel.Layer.mergeAll(.{
        kernel.Layer.succeed(EventWorker, .{}),
        kernel.Layer.succeed(event_workflow.EventWorkflow, workflow),
        kernel.Layer.succeed(ProcessInputsService, inputs),
    });
}

pub fn runWithOptions(init: std.process.Init, options: zstd.CausalRuntime.Options) !void {
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(init.io, ".zigeffect/workflows/event-worker");
    var workflow_dir = try cwd.openDir(init.io, ".zigeffect/workflows/event-worker", .{});
    defer workflow_dir.close(init.io);
    var journal = try zstd.fx.workflow.FileJournalStore.open(init.gpa, init.io, &workflow_dir, .{
        .fsync_policy = .after_append,
        .owner_id = "event-worker",
        .max_in_memory_events = 16 * 1024,
    });
    defer journal.deinit();
    try cwd.createDirPath(init.io, zstd.Statechart.default_path);
    var statechart_dir = try cwd.openDir(init.io, zstd.Statechart.default_path, .{});
    defer statechart_dir.close(init.io);
    try event_workflow.registerDefinitionAtomic(init.gpa, init.io, statechart_dir, 16 * 1024 * 1024);

    var worker = event_workflow.LocalWorker{ .io = init.io };
    const port = if (init.environ_map.get("PORT")) |value| try std.fmt.parseInt(u16, value, 10) else 8080;
    const main_layer = rootLayer(.{ .journal = journal.asJournalStore(), .worker = worker.runtime() }, .{ .io = init.io, .port = port });
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
        .project = "event-driven-zig",
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

    var journal = zstd.fx.workflow.InMemoryJournalStore.init(std.testing.allocator);
    defer journal.deinit();
    var worker = event_workflow.ScriptedWorker{};
    const main_layer = rootLayer(.{ .journal = journal.asJournalStore(), .worker = worker.runtime() }, .{ .io = std.testing.io, .port = 8080 });
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

    const valid = try runtime.run(validateEvent("order.created").named("test.event"));
    try assertions.boolean(.{
        .id = "event-valid",
        .label = "event validation succeeds",
        .source = runtime_contract_source,
        .repair_hint = "preserve the typed event worker service",
    }, valid);
    const result = try runtime.run(route("/health/live").named("test.health"));
    try assertions.equal(.{
        .id = "health-status",
        .label = "health route succeeds",
        .source = runtime_contract_source,
        .repair_hint = "preserve the typed health service",
    }, @as(u16, 200), @intFromEnum(result.status));
    _ = try assertions.event(.{
        .id = "event-causal",
        .label = "event validation is causal",
        .source = runtime_contract_source,
        .repair_hint = "run event validation as a named effect",
    }, .{ .kind = .effect_completed, .label = "test.event", .status = "success" });
    _ = try assertions.event(.{
        .id = "health-causal",
        .label = "health operation is causal",
        .source = runtime_contract_source,
        .repair_hint = "run the health route as a named effect",
    }, .{ .kind = .effect_completed, .label = "test.health", .status = "success" });

    var snapshot = try runtime.inspect(std.testing.allocator, .{ .max_recent_events = 128 });
    defer snapshot.deinit();
    try assertions.applicationService(.{
        .id = "health-service",
        .label = "health service is mapped",
        .source = runtime_contract_source,
        .repair_hint = "provide EventWorker from rootLayer",
    }, &snapshot, EventWorker.service_key, true);
    try assertions.applicationOperation(.{
        .id = "health-operation",
        .label = "health operation is mapped",
        .source = runtime_contract_source,
        .repair_hint = "declare EventWorker.route",
    }, &snapshot, EventWorker.service_key, "EventWorker.route");
    try assertions.noFindings(.{
        .id = "health-no-findings",
        .label = "runtime is causally healthy",
        .source = runtime_contract_source,
        .repair_hint = "close every effect and scope",
    });
    try assertions.noPendingFibers(.{
        .id = "health-no-pending",
        .label = "runtime has no pending fibers",
        .source = runtime_contract_source,
        .repair_hint = "join every request child",
    });
    try context.mapCausalEventIds(&runtime);
    try runtime.shutdown();
}

test "event workflow replays activities and records statechart decisions" {
    var context = try zstd.Testing.TestContext.init(std.testing.allocator, .{
        .project = "event-driven-zig",
        .suite = "app-tests",
        .scenario = .{
            .id = "event-workflow-replay",
            .label = "event workflow replay contract",
            .requirement = "event-workflow-control",
            .acceptance_check = "check-event-workflow-control",
            .component = "application",
            .command = "test",
        },
        .seed = 43,
    });
    defer context.deinit();
    const assertions = zstd.Testing.AssertionRecorder.init(&context);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var journal = zstd.fx.workflow.InMemoryJournalStore.init(std.testing.allocator);
    defer journal.deinit();
    var worker = event_workflow.ScriptedWorker{};
    const main_layer = rootLayer(.{ .journal = journal.asJournalStore(), .worker = worker.runtime() }, .{ .io = std.testing.io, .port = 8080 });
    var runtime = try zstd.ManagedRuntime(@TypeOf(main_layer)).make(
        std.testing.allocator,
        std.testing.io,
        tmp.dir,
        main_layer,
        // Test-only injection keeps assertions and the project graph on one runtime.
        .{ .causal_store = context.causalStore(), .graph = .{ .path = ".zigeffect/graph", .max_records = 4096 } },
    );
    defer runtime.deinit();

    try tmp.dir.createDirPath(std.testing.io, zstd.Statechart.default_path);
    var statechart_dir = try tmp.dir.openDir(std.testing.io, zstd.Statechart.default_path, .{});
    defer statechart_dir.close(std.testing.io);
    try event_workflow.registerDefinitionAtomic(std.testing.allocator, std.testing.io, statechart_dir, 1024 * 1024);
    var catalog = try zstd.Statechart.readCatalogRecovering(std.testing.allocator, std.testing.io, statechart_dir, 1024 * 1024);
    defer catalog.deinit();
    const input = event_workflow.EventInput{ .id = "event-42", .name = "order.created" };
    const first = try runtime.run(event_workflow.process(input).named("event.process.first"));
    const replayed = try runtime.run(event_workflow.process(input).named("event.process.replay"));

    try assertions.boolean(.{
        .id = "workflow-complete",
        .label = "event workflow reaches complete",
        .source = workflow_contract_source,
        .repair_hint = "feed each durable activity result into the typed statechart",
    }, first == .complete and replayed == .complete);
    try assertions.boolean(.{
        .id = "workflow-idempotent",
        .label = "event workflow replay does not repeat external activities",
        .source = workflow_contract_source,
        .repair_hint = "derive activity idempotency from the stable event id",
    }, worker.validate_count == 1 and worker.persist_count == 1 and worker.acknowledge_count == 1);
    try assertions.boolean(.{
        .id = "statechart-discoverable",
        .label = "event statechart is registered in the project catalog",
        .source = workflow_contract_source,
        .repair_hint = "register public machines without replacing unrelated catalog definitions",
    }, catalog.value.definition("application.event-workflow") != null);
    _ = try assertions.event(.{
        .id = "workflow-causal",
        .label = "event workflow activity is causal",
        .source = workflow_contract_source,
        .repair_hint = "record the workflow journal through the runtime causal store",
    }, .{ .kind = .workflow_event_recorded, .label = "application.event.acknowledge", .status = "completed" });
    _ = try assertions.event(.{
        .id = "statechart-causal",
        .label = "event statechart transition is causal",
        .source = workflow_contract_source,
        .repair_hint = "run decisions through the reusable workflow execution adapter",
    }, .{ .kind = .statechart_event_recorded, .label = "event-acknowledged", .status = "committed" });
    var causal_snapshot = try context.causalStore().snapshot(std.testing.allocator);
    defer causal_snapshot.deinit();
    var joined = false;
    for (causal_snapshot.events) |candidate| {
        if (candidate.kind != .statechart_event_recorded or !std.mem.eql(u8, candidate.label, "event-acknowledged")) continue;
        const parent_id = candidate.parent_id orelse continue;
        for (causal_snapshot.events) |parent| {
            if (parent.id != parent_id) continue;
            joined = parent.kind == .workflow_event_recorded and std.mem.eql(u8, parent.label, "application.event.acknowledge");
            break;
        }
        if (joined) break;
    }
    try assertions.boolean(.{
        .id = "workflow-statechart-joined",
        .label = "workflow activity and statechart decision share one causal chain",
        .source = workflow_contract_source,
        .repair_hint = "parent the statechart decision to the durable activity result",
    }, joined);
    try assertions.noFindings(.{ .id = "workflow-no-findings", .label = "workflow has no causal findings", .source = workflow_contract_source, .repair_hint = "terminate every activity and statechart execution" });
    try assertions.noPendingFibers(.{ .id = "workflow-no-pending", .label = "workflow has no pending fibers", .source = workflow_contract_source, .repair_hint = "join every workflow child" });
    try context.mapCausalEventIds(&runtime);
    try runtime.shutdown();
}
