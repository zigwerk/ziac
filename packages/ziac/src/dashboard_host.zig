const std = @import("std");

pub const max_artifact_bytes: usize = 16 * 1024 * 1024;
pub const max_session_bytes: usize = 2 * 1024 * 1024;
pub const max_log_bytes: usize = 8 * 1024 * 1024;

pub const bridge_names = .{
    .load_artifact = "ziac_load_artifact",
    .load_session = "ziac_load_session",
    .load_log_snapshot = "ziac_load_log_snapshot",
    .scan_estate = "ziac_scan_estate",
    .request_estate_access = "ziac_request_estate_access",
};

pub const LaunchMode = enum { window, server_only };

pub const Config = struct {
    artifact_path: []const u8,
    session_path: ?[]const u8 = null,
    log_path: ?[]const u8 = null,
    root_path: [:0]const u8 = "dashboard/dist",
    estate_scan_executable: ?[]const u8 = null,
    estate_connection_id: ?[]const u8 = null,
};

pub const LaunchOptions = struct {
    mode: LaunchMode,
    artifact_path: [:0]const u8,
    session_path: ?[:0]const u8 = null,
    log_path: ?[:0]const u8 = null,
    root_path: [:0]const u8 = "dashboard/dist",
    estate_scan_executable: ?[:0]const u8 = null,
    estate_connection_id: ?[:0]const u8 = null,
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

    pub fn init(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, config: Config) Host {
        return .{ .allocator = allocator, .io = io, .dir = dir, .config = config };
    }

    pub fn loadArtifactAlloc(self: Host) ![]u8 {
        return self.readBounded(self.config.artifact_path, max_artifact_bytes, error.DashboardArtifactUnavailable, error.DashboardArtifactTooLarge);
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

    fn readBounded(self: Host, path: []const u8, limit: usize, comptime unavailable: anyerror, comptime too_large: anyerror) ![]u8 {
        const stat = self.dir.statFile(self.io, path, .{}) catch return unavailable;
        if (stat.size > limit) return too_large;
        return self.dir.readFileAlloc(self.io, path, self.allocator, .limited(limit + 1)) catch |err| switch (err) {
            error.StreamTooLong => too_large,
            else => unavailable,
        };
    }
};
