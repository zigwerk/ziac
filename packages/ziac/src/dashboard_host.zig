const std = @import("std");
const builtin = @import("builtin");
const zstd = @import("zigeffect_std");
const dashboard_operation = @import("dashboard_operation.zig");
const agent_contract = @import("agent_contract.zig");
const workspace = @import("workspace.zig");

pub const max_artifact_bytes: usize = 16 * 1024 * 1024;
pub const max_session_bytes: usize = 2 * 1024 * 1024;
pub const max_log_bytes: usize = 8 * 1024 * 1024;

pub const bridge_names = .{
    .load_artifact = "ziac_load_artifact",
    .load_session = "ziac_load_session",
    .load_log_snapshot = "ziac_load_log_snapshot",
    .scan_estate = "ziac_scan_estate",
    .request_estate_access = "ziac_request_estate_access",
    .operation_plan = "ziac_operation_plan",
    .operation_apply = "ziac_operation_apply",
    .operation_watch = "ziac_operation_watch",
    .operation_status = "ziac_operation_status",
    .operation_cancel = "ziac_operation_cancel",
};

pub const LaunchMode = enum { window, server_only };

pub const Config = struct {
    artifact_path: []const u8,
    session_path: ?[]const u8 = null,
    log_path: ?[]const u8 = null,
    root_path: [:0]const u8 = "dashboard/dist",
    estate_scan_executable: ?[]const u8 = null,
    estate_connection_id: ?[]const u8 = null,
    refresh_executable: ?[]const u8 = null,
    refresh_root: ?[]const u8 = null,
    refresh_out: ?[]const u8 = null,
    refresh_project: ?[]const u8 = null,
};

pub const LaunchOptions = struct {
    mode: LaunchMode,
    artifact_path: [:0]const u8,
    session_path: ?[:0]const u8 = null,
    log_path: ?[:0]const u8 = null,
    root_path: [:0]const u8 = "dashboard/dist",
    estate_scan_executable: ?[:0]const u8 = null,
    estate_connection_id: ?[:0]const u8 = null,
    refresh_executable: ?[:0]const u8 = null,
    refresh_root: ?[:0]const u8 = null,
    refresh_out: ?[:0]const u8 = null,
    refresh_project: ?[:0]const u8 = null,
};

pub fn parseLaunchArgs(args: []const [:0]const u8) ?LaunchOptions {
    if (args.len < 2) return null;
    var options = LaunchOptions{ .mode = .window, .artifact_path = undefined };
    var artifact: ?[:0]const u8 = null;
    var index: usize = 1;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--server-only")) {
            options.mode = .server_only;
            index += 1;
        } else if (std.mem.eql(u8, arg, "--root")) {
            if (index + 1 >= args.len) return null;
            options.root_path = args[index + 1];
            index += 2;
        } else if (std.mem.eql(u8, arg, "--session")) {
            if (index + 1 >= args.len or options.session_path != null) return null;
            options.session_path = args[index + 1];
            index += 2;
        } else if (std.mem.eql(u8, arg, "--logs")) {
            if (index + 1 >= args.len or options.log_path != null) return null;
            options.log_path = args[index + 1];
            index += 2;
        } else if (std.mem.eql(u8, arg, "--estate-scan")) {
            if (index + 2 >= args.len or options.estate_scan_executable != null) return null;
            options.estate_scan_executable = args[index + 1];
            options.estate_connection_id = args[index + 2];
            index += 3;
        } else if (std.mem.eql(u8, arg, "--workspace-refresh")) {
            if (index + 3 >= args.len or options.refresh_executable != null) return null;
            options.refresh_executable = args[index + 1];
            options.refresh_root = args[index + 2];
            options.refresh_out = args[index + 3];
            index += 4;
        } else if (std.mem.eql(u8, arg, "--project")) {
            if (index + 1 >= args.len or options.refresh_project != null) return null;
            options.refresh_project = args[index + 1];
            index += 2;
        } else if (std.mem.startsWith(u8, arg, "--") or artifact != null) return null else {
            artifact = arg;
            index += 1;
        }
    }
    options.artifact_path = artifact orelse return null;
    return options;
}

pub const Host = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    config: Config,
    operations: dashboard_operation.Registry,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, config: Config) Host {
        return .{ .allocator = allocator, .io = io, .dir = dir, .config = config, .operations = .init(allocator) };
    }

    pub fn deinit(self: *Host) void {
        self.operations.deinit();
    }

    pub fn loadArtifactAlloc(self: Host) ![]u8 {
        return self.readBounded(self.config.artifact_path, max_artifact_bytes, error.DashboardArtifactUnavailable, error.DashboardArtifactTooLarge);
    }

    pub fn refreshArtifact(self: Host) !void {
        const executable = self.config.refresh_executable orelse return;
        const root = self.config.refresh_root orelse return error.InvalidWorkspaceRefresh;
        const out = self.config.refresh_out orelse return error.InvalidWorkspaceRefresh;
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(self.allocator);
        try argv.appendSlice(self.allocator, &.{ executable, "dashboard", "--root", root, "--out", out, "--artifact-only" });
        if (self.config.refresh_project) |project| try argv.appendSlice(self.allocator, &.{ "--project", project });
        const result = try std.process.run(self.allocator, self.io, .{
            .argv = argv.items,
            .stdout_limit = .limited(64 * 1024),
            .stderr_limit = .limited(64 * 1024),
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        const passed = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!passed) return error.WorkspaceRefreshFailed;
    }

    pub fn workspaceSourceRevision(self: *Host) ![32]u8 {
        const root_path = self.config.refresh_root orelse return error.InvalidWorkspaceRefresh;
        var root = try std.Io.Dir.openDirAbsolute(self.io, root_path, .{ .iterate = true });
        defer root.close(self.io);
        var discovery = try workspace.discoverProjectsAlloc(self.allocator, self.io, root);
        defer discovery.deinit();
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var included: usize = 0;
        for (discovery.projects) |project| {
            if (self.config.refresh_project) |selected| if (!std.mem.eql(u8, project.id, selected)) continue;
            const manifest_path = try std.fs.path.join(self.allocator, &.{ project.path, "ziac.project.json" });
            defer self.allocator.free(manifest_path);
            const manifest = try root.readFileAlloc(self.io, manifest_path, self.allocator, .limited(workspace.max_manifest_bytes));
            defer self.allocator.free(manifest);
            var contract = try agent_contract.Project.parseAlloc(self.allocator, manifest);
            defer contract.deinit();
            var project_dir = try root.openDir(self.io, project.path, .{ .iterate = true });
            defer project_dir.close(self.io);
            const project_revision = try workspace.projectRevision(self.allocator, self.io, project_dir, manifest, contract.source_roots);
            hasher.update(project.id);
            hasher.update("\x00");
            hasher.update(project.path);
            hasher.update("\x00");
            hasher.update(&project_revision);
            included += 1;
        }
        if (included == 0) return error.WorkspaceProjectNotFound;
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        return digest;
    }

    pub fn loadSessionAlloc(self: Host) ![]u8 {
        if (self.config.session_path) |path| return self.readBounded(path, max_session_bytes, error.DashboardSessionUnavailable, error.DashboardSessionTooLarge);
        const artifact = try self.loadArtifactAlloc();
        defer self.allocator.free(artifact);
        return std.json.Stringify.valueAlloc(self.allocator, .{
            .schema = "ziac.dashboard-session.v1",
            .read_only = true,
            .artifact_path = self.config.artifact_path,
            .artifact_bytes = artifact.len,
            .warnings = &[_][]const u8{},
        }, .{});
    }

    pub fn loadLogAlloc(self: Host) ![]u8 {
        const path = self.config.log_path orelse return self.allocator.dupe(u8, "");
        return self.readBounded(path, max_log_bytes, error.DashboardLogUnavailable, error.DashboardLogTooLarge);
    }

    pub fn runOperationAlloc(self: *Host, request_json: []const u8) ![]u8 {
        var request = dashboard_operation.Request.parseAlloc(self.allocator, request_json) catch return operationErrorAlloc(self.allocator, "invalid_request", null);
        defer request.deinit();
        if (request.kind == .watch or request.kind == .cancel or request.kind == .status) return operationErrorAlloc(self.allocator, "async_operation_required", null);
        var built = self.commandAlloc(request) catch return operationErrorAlloc(self.allocator, "command_rejected", null);
        defer built.deinit();
        const result = std.process.run(self.allocator, self.io, .{
            .argv = built.argv,
            .cwd = .{ .path = built.cwd },
            .stdout_limit = .limited(2 * 1024 * 1024),
            .stderr_limit = .limited(256 * 1024),
        }) catch return operationErrorAlloc(self.allocator, "process_unavailable", null);
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
        const exit_code: u8 = switch (result.term) {
            .exited => |code| code,
            else => 255,
        };
        const redacted_stderr = try zstd.Secrets.redactAlloc(self.allocator, result.stderr);
        defer self.allocator.free(redacted_stderr);
        if (exit_code != 0) return operationErrorAlloc(self.allocator, "command_failed", redacted_stderr);
        const stdout = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (stdout.len == 0) return operationErrorAlloc(self.allocator, "receipt_unavailable", null);
        return self.allocator.dupe(u8, stdout);
    }

    pub fn startWatchAlloc(self: *Host, request_json: []const u8) ![]u8 {
        var request = dashboard_operation.Request.parseAlloc(self.allocator, request_json) catch return operationErrorAlloc(self.allocator, "invalid_request", null);
        defer request.deinit();
        if (request.kind != .watch) return operationErrorAlloc(self.allocator, "invalid_request", null);
        var built = self.commandAlloc(request) catch return operationErrorAlloc(self.allocator, "command_rejected", null);
        defer built.deinit();
        const started_at = nowMillis(self.io);
        const operation_id = try self.operations.register(.watch, request.project, request.stack, request.stage, started_at);
        defer self.allocator.free(operation_id);
        const root_path = self.config.refresh_root orelse return operationErrorAlloc(self.allocator, "host_not_configured", null);
        var root = std.Io.Dir.openDirAbsolute(self.io, root_path, .{}) catch return operationErrorAlloc(self.allocator, "workspace_unavailable", null);
        defer root.close(self.io);
        root.createDirPath(self.io, ".ziac/dashboard/operations") catch return operationErrorAlloc(self.allocator, "operation_directory_unavailable", null);
        const stdout_path = try std.fmt.allocPrint(self.allocator, ".ziac/dashboard/operations/{s}.stdout.jsonl", .{operation_id});
        defer self.allocator.free(stdout_path);
        const stderr_path = try std.fmt.allocPrint(self.allocator, ".ziac/dashboard/operations/{s}.stderr.log", .{operation_id});
        defer self.allocator.free(stderr_path);
        var stdout_file = root.createFile(self.io, stdout_path, .{ .truncate = true }) catch return operationErrorAlloc(self.allocator, "operation_output_unavailable", null);
        defer stdout_file.close(self.io);
        var stderr_file = root.createFile(self.io, stderr_path, .{ .truncate = true }) catch return operationErrorAlloc(self.allocator, "operation_output_unavailable", null);
        defer stderr_file.close(self.io);
        var child = std.process.spawn(self.io, .{
            .argv = built.argv,
            .cwd = .{ .path = built.cwd },
            .stdin = .ignore,
            .stdout = .{ .file = stdout_file },
            .stderr = .{ .file = stderr_file },
        }) catch {
            try self.operations.finish(operation_id, .failed, nowMillis(self.io), null, "process unavailable");
            return self.operations.serializeAlloc(operation_id);
        };
        try self.operations.setProcessId(operation_id, childProcessId(child));
        try self.operations.markRunning(operation_id, nowMillis(self.io));
        const context = try self.allocator.create(OperationWaitContext);
        errdefer self.allocator.destroy(context);
        context.* = .{
            .host = self,
            .operation_id = try self.allocator.dupe(u8, operation_id),
            .root_path = try self.allocator.dupe(u8, root_path),
            .stderr_path = try self.allocator.dupe(u8, stderr_path),
            .child = child,
        };
        const thread = std.Thread.spawn(.{}, waitForOperation, .{context}) catch {
            child.kill(self.io);
            try self.operations.finish(operation_id, .failed, nowMillis(self.io), null, "operation supervisor unavailable");
            self.allocator.free(context.operation_id);
            self.allocator.free(context.root_path);
            self.allocator.free(context.stderr_path);
            self.allocator.destroy(context);
            return self.operations.serializeAlloc(operation_id);
        };
        thread.detach();
        return self.operations.serializeAlloc(operation_id);
    }

    pub fn operationStatusAlloc(self: *Host, request_json: []const u8) ![]u8 {
        const id = dashboard_operation.parseControlOperationIdAlloc(self.allocator, request_json) catch return operationErrorAlloc(self.allocator, "invalid_request", null);
        defer self.allocator.free(id);
        return self.operations.serializeAlloc(id) catch operationErrorAlloc(self.allocator, "operation_not_found", null);
    }

    pub fn cancelOperationAlloc(self: *Host, request_json: []const u8) ![]u8 {
        const id = dashboard_operation.parseControlOperationIdAlloc(self.allocator, request_json) catch return operationErrorAlloc(self.allocator, "invalid_request", null);
        defer self.allocator.free(id);
        const process_id = self.operations.processId(id) orelse return operationErrorAlloc(self.allocator, "operation_not_found", null);
        if (!(try self.operations.requestCancel(id))) return self.operations.serializeAlloc(id);
        terminateProcess(process_id);
        return self.operations.serializeAlloc(id);
    }

    fn commandAlloc(self: *Host, request: dashboard_operation.Request) !dashboard_operation.Command {
        const executable = self.config.refresh_executable orelse return error.HostNotConfigured;
        const root_path = self.config.refresh_root orelse return error.HostNotConfigured;
        var root = try std.Io.Dir.openDirAbsolute(self.io, root_path, .{ .iterate = true });
        defer root.close(self.io);
        var discovery = try workspace.discoverProjectsAlloc(self.allocator, self.io, root);
        defer discovery.deinit();
        var project_path: ?[]u8 = null;
        defer if (project_path) |path| self.allocator.free(path);
        for (discovery.projects) |project| {
            if (!std.mem.eql(u8, project.id, request.project)) continue;
            project_path = std.fs.path.join(self.allocator, &.{ root_path, project.path }) catch return error.OutOfMemory;
            break;
        }
        const selected_project = project_path orelse return error.ProjectNotFound;
        try root.createDirPath(self.io, ".ziac/dashboard/plans");
        const plan_root = try std.fs.path.join(self.allocator, &.{ root_path, ".ziac/dashboard/plans" });
        defer self.allocator.free(plan_root);
        return if (request.kind == .plan)
            dashboard_operation.planCommandAlloc(self.allocator, .{ .executable = executable, .project_root = selected_project, .plan_root = plan_root }, request)
        else
            dashboard_operation.applyCommandAlloc(self.allocator, .{ .executable = executable, .project_root = selected_project, .plan_root = plan_root }, request);
    }

    fn readBounded(self: Host, path: []const u8, limit: usize, comptime unavailable: anyerror, comptime too_large: anyerror) ![]u8 {
        const stat = self.dir.statFile(self.io, path, .{}) catch return unavailable;
        if (stat.size > limit) return too_large;
        return self.dir.readFileAlloc(self.io, path, self.allocator, .limited(limit + 1)) catch |err| switch (err) {
            error.StreamTooLong => too_large,
            else => unavailable,
        };
    }
};

const OperationWaitContext = struct {
    host: *Host,
    operation_id: []u8,
    root_path: []u8,
    stderr_path: []u8,
    child: std.process.Child,
};

fn waitForOperation(context: *OperationWaitContext) void {
    defer {
        context.host.allocator.free(context.operation_id);
        context.host.allocator.free(context.root_path);
        context.host.allocator.free(context.stderr_path);
        context.host.allocator.destroy(context);
    }
    const term = context.child.wait(context.host.io) catch {
        context.host.operations.finish(context.operation_id, .failed, nowMillis(context.host.io), null, "process wait failed") catch {};
        return;
    };
    var root = std.Io.Dir.openDirAbsolute(context.host.io, context.root_path, .{}) catch {
        context.host.operations.finish(context.operation_id, .failed, nowMillis(context.host.io), null, "operation output unavailable") catch {};
        return;
    };
    defer root.close(context.host.io);
    const diagnostic = root.readFileAlloc(context.host.io, context.stderr_path, context.host.allocator, .limited(256 * 1024)) catch null;
    defer if (diagnostic) |value| context.host.allocator.free(value);
    const was_cancelled = context.host.operations.phase(context.operation_id) == .cancelling;
    const exit_code: ?u8 = switch (term) {
        .exited => |code| code,
        else => null,
    };
    const terminal_phase: dashboard_operation.Phase = if (was_cancelled) .cancelled else switch (term) {
        .exited => |code| if (code == 0) .succeeded else .failed,
        else => .failed,
    };
    context.host.operations.finish(context.operation_id, terminal_phase, nowMillis(context.host.io), exit_code, diagnostic) catch {};
}

fn nowMillis(io: std.Io) u64 {
    const value = std.Io.Clock.real.now(io).toMilliseconds();
    return if (value <= 0) 0 else @intCast(value);
}

fn childProcessId(child: std.process.Child) usize {
    if (comptime builtin.os.tag == .windows) return @intFromPtr(child.id.?);
    if (comptime builtin.os.tag == .wasi) return 0;
    return @intCast(child.id.?);
}

fn terminateProcess(process_id: usize) void {
    if (comptime builtin.os.tag == .windows) {
        _ = std.os.windows.kernel32.TerminateProcess(@ptrFromInt(process_id), 1);
    } else if (comptime builtin.os.tag != .wasi) {
        std.posix.kill(@intCast(process_id), .TERM) catch {};
    }
}

fn operationErrorAlloc(allocator: std.mem.Allocator, code: []const u8, detail: ?[]const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .schema = "ziac.dashboard-operation-error.v1",
        .code = code,
        .detail = detail,
    }, .{});
}
