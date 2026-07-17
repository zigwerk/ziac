const std = @import("std");
const webui = @import("webui");
const ziac = @import("ziac");
const dashboard_options = @import("dashboard_options");

var host: ziac.dashboard_host.Host = undefined;
var config: ziac.dashboard_host.Config = undefined;
var host_io: std.Io = undefined;
var observer_stop = std.atomic.Value(bool).init(false);
const MainProgram = ziac.zstd.fx.kernel.Effect(void, anyerror, .{ziac.process_runtime.ProcessInputs});
const DashboardRuntime = ziac.zstd.fx.kernel.RuntimeHandle(.{ziac.process_runtime.ProcessInputs});
var dashboard_runtime: DashboardRuntime = undefined;

fn returnStatic(event: *webui.Event, value: [:0]const u8) void {
    event.returnValue(value);
}

fn returnOwned(event: *webui.Event, bytes: []u8) void {
    defer std.heap.page_allocator.free(bytes);
    const terminated = std.heap.page_allocator.dupeZ(u8, bytes) catch {
        returnStatic(event, "{\"schema\":\"ziac.dashboard-error.v1\",\"code\":\"out_of_memory\"}");
        return;
    };
    defer std.heap.page_allocator.free(terminated);
    event.returnValue(terminated);
}

fn loadArtifactImpl(event: *webui.Event) void {
    returnOwned(event, host.loadArtifactAlloc() catch {
        returnStatic(event, "{\"schema\":\"ziac.dashboard-error.v1\",\"code\":\"artifact_unavailable\"}");
        return;
    });
}

fn observeWorkspace(window: *webui) void {
    var source_revision = host.workspaceSourceRevision() catch return;
    var current_artifact = host.loadArtifactAlloc() catch return;
    defer std.heap.page_allocator.free(current_artifact);
    while (!observer_stop.load(.acquire)) {
        std.Io.sleep(host_io, .fromMilliseconds(250), .awake) catch return;
        if (observer_stop.load(.acquire)) return;
        const next_source_revision = host.workspaceSourceRevision() catch continue;
        if (std.mem.eql(u8, &source_revision, &next_source_revision)) continue;
        host.refreshArtifact() catch continue;
        const next_artifact = host.loadArtifactAlloc() catch continue;
        const patch = ziac.workspace.patchAlloc(std.heap.page_allocator, current_artifact, next_artifact) catch {
            std.heap.page_allocator.free(next_artifact);
            continue;
        };
        if (!std.mem.eql(u8, ziac.workspace.revision(current_artifact) orelse "", ziac.workspace.revision(next_artifact) orelse "")) {
            const encoded = std.json.Stringify.valueAlloc(std.heap.page_allocator, patch, .{}) catch {
                std.heap.page_allocator.free(patch);
                std.heap.page_allocator.free(next_artifact);
                continue;
            };
            const script = std.fmt.allocPrintSentinel(
                std.heap.page_allocator,
                "window.dispatchEvent(new CustomEvent(\"ziac-workspace-patch\",{{detail:{s}}}));",
                .{encoded},
                0,
            ) catch {
                std.heap.page_allocator.free(encoded);
                std.heap.page_allocator.free(patch);
                std.heap.page_allocator.free(next_artifact);
                continue;
            };
            window.run(script);
            std.heap.page_allocator.free(script);
            std.heap.page_allocator.free(encoded);
        }
        std.heap.page_allocator.free(patch);
        std.heap.page_allocator.free(current_artifact);
        current_artifact = next_artifact;
        source_revision = next_source_revision;
    }
}

fn loadSessionImpl(event: *webui.Event) void {
    returnOwned(event, host.loadSessionAlloc() catch {
        returnStatic(event, "{\"schema\":\"ziac.dashboard-error.v1\",\"code\":\"session_unavailable\"}");
        return;
    });
}

fn loadLogsImpl(event: *webui.Event) void {
    returnOwned(event, host.loadLogAlloc() catch {
        returnStatic(event, "{\"schema\":\"ziac.dashboard-error.v1\",\"code\":\"logs_unavailable\"}");
        return;
    });
}

fn scanEstateImpl(event: *webui.Event) void {
    const executable = config.estate_scan_executable orelse {
        returnStatic(event, "{\"schema\":\"ziac.estate-scan-error.v1\",\"code\":\"host_not_configured\"}");
        return;
    };
    const connection = config.estate_connection_id orelse {
        returnStatic(event, "{\"schema\":\"ziac.estate-scan-error.v1\",\"code\":\"host_not_configured\"}");
        return;
    };
    const result = std.process.run(std.heap.page_allocator, host_io, .{
        .argv = &.{ executable, "estate", "scan", "--connection", connection, "--out", config.artifact_path, "--json" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch {
        returnStatic(event, "{\"schema\":\"ziac.estate-scan-error.v1\",\"code\":\"scanner_unavailable\"}");
        return;
    };
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);
    const succeeded = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!succeeded) {
        returnStatic(event, "{\"schema\":\"ziac.estate-scan-error.v1\",\"code\":\"scan_failed\"}");
        return;
    }
    const payload = std.heap.page_allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n")) catch {
        returnStatic(event, "{\"schema\":\"ziac.estate-scan-error.v1\",\"code\":\"receipt_unavailable\"}");
        return;
    };
    returnOwned(event, payload);
}

fn requestEstateAccessImpl(event: *webui.Event) void {
    returnStatic(event, "{\"schema\":\"ziac.estate-access.v1\",\"status\":\"control_plane_required\"}");
}

fn runOperationImpl(event: *webui.Event) void {
    returnOwned(event, host.runOperationAlloc(event.getString()) catch {
        returnStatic(event, "{\"schema\":\"ziac.dashboard-operation-error.v1\",\"code\":\"host_failure\"}");
        return;
    });
}

fn startWatchImpl(event: *webui.Event) void {
    returnOwned(event, host.startWatchAlloc(event.getString()) catch {
        returnStatic(event, "{\"schema\":\"ziac.dashboard-operation-error.v1\",\"code\":\"host_failure\"}");
        return;
    });
}

fn operationStatusImpl(event: *webui.Event) void {
    returnOwned(event, host.operationStatusAlloc(event.getString()) catch {
        returnStatic(event, "{\"schema\":\"ziac.dashboard-operation-error.v1\",\"code\":\"host_failure\"}");
        return;
    });
}

fn cancelOperationImpl(event: *webui.Event) void {
    returnOwned(event, host.cancelOperationAlloc(event.getString()) catch {
        returnStatic(event, "{\"schema\":\"ziac.dashboard-operation-error.v1\",\"code\":\"host_failure\"}");
        return;
    });
}

const CallbackKind = enum {
    load_artifact,
    load_session,
    load_logs,
    scan_estate,
    request_estate_access,
    run_operation,
    start_watch,
    operation_status,
    cancel_operation,
};
const CallbackState = struct {
    kind: CallbackKind,
    event: *webui.Event,
};
const CallbackProgram = ziac.zstd.fx.kernel.Effect(void, error{}, .{}).Stateful(CallbackState);

fn callbackEffect(state: CallbackState) CallbackProgram {
    return CallbackProgram.init(state, struct {
        fn run(callback: CallbackState, _: *CallbackProgram.Context) error{}!void {
            switch (callback.kind) {
                .load_artifact => loadArtifactImpl(callback.event),
                .load_session => loadSessionImpl(callback.event),
                .load_logs => loadLogsImpl(callback.event),
                .scan_estate => scanEstateImpl(callback.event),
                .request_estate_access => requestEstateAccessImpl(callback.event),
                .run_operation => runOperationImpl(callback.event),
                .start_watch => startWatchImpl(callback.event),
                .operation_status => operationStatusImpl(callback.event),
                .cancel_operation => cancelOperationImpl(callback.event),
            }
        }
    }.run);
}

fn runCallback(kind: CallbackKind, event: *webui.Event) void {
    dashboard_runtime.run(callbackEffect(.{ .kind = kind, .event = event }).named(@tagName(kind))) catch {
        returnStatic(event, "{\"schema\":\"ziac.dashboard-error.v1\",\"code\":\"runtime_failure\"}");
    };
}

fn loadArtifact(event: *webui.Event) void {
    runCallback(.load_artifact, event);
}

fn loadSession(event: *webui.Event) void {
    runCallback(.load_session, event);
}

fn loadLogs(event: *webui.Event) void {
    runCallback(.load_logs, event);
}

fn scanEstate(event: *webui.Event) void {
    runCallback(.scan_estate, event);
}

fn requestEstateAccess(event: *webui.Event) void {
    runCallback(.request_estate_access, event);
}

fn runOperation(event: *webui.Event) void {
    runCallback(.run_operation, event);
}

fn startWatch(event: *webui.Event) void {
    runCallback(.start_watch, event);
}

fn operationStatus(event: *webui.Event) void {
    runCallback(.operation_status, event);
}

fn cancelOperation(event: *webui.Event) void {
    runCallback(.cancel_operation, event);
}

fn configureWindow(window: *webui) !void {
    _ = try window.binding(ziac.dashboard_host.bridge_names.load_artifact, loadArtifact);
    _ = try window.binding(ziac.dashboard_host.bridge_names.load_session, loadSession);
    _ = try window.binding(ziac.dashboard_host.bridge_names.load_log_snapshot, loadLogs);
    _ = try window.binding(ziac.dashboard_host.bridge_names.scan_estate, scanEstate);
    _ = try window.binding(ziac.dashboard_host.bridge_names.request_estate_access, requestEstateAccess);
    _ = try window.binding(ziac.dashboard_host.bridge_names.operation_plan, runOperation);
    _ = try window.binding(ziac.dashboard_host.bridge_names.operation_apply, runOperation);
    _ = try window.binding(ziac.dashboard_host.bridge_names.operation_watch, startWatch);
    _ = try window.binding(ziac.dashboard_host.bridge_names.operation_status, operationStatus);
    _ = try window.binding(ziac.dashboard_host.bridge_names.operation_cancel, cancelOperation);
    try window.setRootFolder(config.root_path);
    window.setSize(1280, 860);
}

pub fn main(init: std.process.Init) !void {
    return ziac.process_runtime.run(init, "ziac-dashboard-host", MainProgram.fromFn(runMain));
}

fn runMain(ctx: *MainProgram.Context) !void {
    const init = ctx.service(ziac.process_runtime.ProcessInputs).init;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = ziac.dashboard_host.parseLaunchArgs(args) orelse {
        std.debug.print("usage: ziac-dashboard-host [--server-only] [--root path] [--session path] [--logs path] <artifact.json>\n", .{});
        return error.InvalidArguments;
    };
    dashboard_runtime = ctx.runtime();
    host_io = init.io;
    const installed_root = if (std.mem.eql(u8, options.root_path, "dashboard/dist"))
        try installedDashboardRootAlloc(init.gpa, init.io)
    else
        null;
    defer if (installed_root) |root| init.gpa.free(root);
    const selected_root = installed_root orelse options.root_path;
    const root_path = try init.gpa.dupeZ(u8, selected_root);
    defer init.gpa.free(root_path);
    config = .{
        .artifact_path = options.artifact_path,
        .session_path = options.session_path,
        .log_path = options.log_path,
        .root_path = root_path,
        .estate_scan_executable = options.estate_scan_executable,
        .estate_connection_id = options.estate_connection_id,
        .refresh_executable = options.refresh_executable,
        .refresh_root = options.refresh_root,
        .refresh_out = options.refresh_out,
        .refresh_project = options.refresh_project,
    };
    host = ziac.dashboard_host.Host.init(std.heap.page_allocator, init.io, std.Io.Dir.cwd(), config);
    const initial_artifact = try host.loadArtifactAlloc();
    std.heap.page_allocator.free(initial_artifact);

    webui.setConfig(.multi_client, true);
    var window = webui.newWindow();
    try configureWindow(&window);
    switch (options.mode) {
        .window => window.show("index.html") catch {
            window = webui.newWindow();
            try configureWindow(&window);
            const url = try window.startServer("index.html");
            std.debug.print("Ziac dashboard: {s}\n", .{url});
        },
        .server_only => {
            const url = try window.startServer("index.html");
            std.debug.print("Ziac dashboard: {s}\n", .{url});
        },
    }
    const observer = if (config.refresh_root != null)
        try std.Thread.spawn(.{}, observeWorkspace, .{&window})
    else
        null;
    webui.wait();
    observer_stop.store(true, .release);
    if (observer) |thread| thread.join();
    webui.clean();
}

fn installedDashboardRootAlloc(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    const executable_dir = try std.process.executableDirPathAlloc(io, allocator);
    defer allocator.free(executable_dir);
    const candidate = try std.fs.path.resolve(allocator, &.{ executable_dir, "..", "share", "ziac", "dashboard", "dist" });
    errdefer allocator.free(candidate);
    const index_path = try std.fs.path.join(allocator, &.{ candidate, "index.html" });
    defer allocator.free(index_path);
    var index = std.Io.Dir.openFileAbsolute(io, index_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            allocator.free(candidate);
            return @as(?[]u8, try allocator.dupe(u8, dashboard_options.dashboard_root));
        },
        else => return err,
    };
    index.close(io);
    return candidate;
}
