const std = @import("std");
const webui = @import("webui");
const ziac = @import("ziac");
const dashboard_options = @import("dashboard_options");

var host: ziac.dashboard_host.Host = undefined;
var config: ziac.dashboard_host.Config = undefined;
var host_io: std.Io = undefined;

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

fn loadArtifact(event: *webui.Event) void {
    returnOwned(event, host.loadArtifactAlloc() catch {
        returnStatic(event, "{\"schema\":\"ziac.dashboard-error.v1\",\"code\":\"artifact_unavailable\"}");
        return;
    });
}

fn loadSession(event: *webui.Event) void {
    returnOwned(event, host.loadSessionAlloc() catch {
        returnStatic(event, "{\"schema\":\"ziac.dashboard-error.v1\",\"code\":\"session_unavailable\"}");
        return;
    });
}

fn loadLogs(event: *webui.Event) void {
    returnOwned(event, host.loadLogAlloc() catch {
        returnStatic(event, "{\"schema\":\"ziac.dashboard-error.v1\",\"code\":\"logs_unavailable\"}");
        return;
    });
}

fn scanEstate(event: *webui.Event) void {
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

fn requestEstateAccess(event: *webui.Event) void {
    returnStatic(event, "{\"schema\":\"ziac.estate-access.v1\",\"status\":\"control_plane_required\"}");
}

fn configureWindow(window: *webui) !void {
    _ = try window.binding(ziac.dashboard_host.bridge_names.load_artifact, loadArtifact);
    _ = try window.binding(ziac.dashboard_host.bridge_names.load_session, loadSession);
    _ = try window.binding(ziac.dashboard_host.bridge_names.load_log_snapshot, loadLogs);
    _ = try window.binding(ziac.dashboard_host.bridge_names.scan_estate, scanEstate);
    _ = try window.binding(ziac.dashboard_host.bridge_names.request_estate_access, requestEstateAccess);
    try window.setRootFolder(config.root_path);
    window.setSize(1280, 860);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = ziac.dashboard_host.parseLaunchArgs(args) orelse {
        std.debug.print("usage: ziac-dashboard-host [--server-only] [--root path] [--session path] [--logs path] <artifact.json>\n", .{});
        std.process.exit(2);
    };
    host_io = init.io;
    const selected_root = if (std.mem.eql(u8, options.root_path, "dashboard/dist")) dashboard_options.dashboard_root else options.root_path;
    const root_path = try init.gpa.dupeZ(u8, selected_root);
    defer init.gpa.free(root_path);
    config = .{
        .artifact_path = options.artifact_path,
        .session_path = options.session_path,
        .log_path = options.log_path,
        .root_path = root_path,
        .estate_scan_executable = options.estate_scan_executable,
        .estate_connection_id = options.estate_connection_id,
    };
    host = ziac.dashboard_host.Host.init(std.heap.page_allocator, init.io, std.Io.Dir.cwd(), config);
    const initial_artifact = try host.loadArtifactAlloc();
    std.heap.page_allocator.free(initial_artifact);

    webui.setConfig(.multi_client, true);
    var window = webui.newWindow();
    try configureWindow(&window);
    switch (options.mode) {
        .window => window.show("index.html") catch {
            var server = webui.newWindow();
            try configureWindow(&server);
            const url = try server.startServer("index.html");
            std.debug.print("Ziac dashboard: {s}\n", .{url});
        },
        .server_only => {
            const url = try window.startServer("index.html");
            std.debug.print("Ziac dashboard: {s}\n", .{url});
        },
    }
    webui.wait();
    webui.clean();
}
