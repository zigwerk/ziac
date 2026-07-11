const std = @import("std");
const zstd = @import("zigeffect_std");
const source_archive = @import("build/source_archive.zig");
const dev = @import("dev.zig");

const max_body_bytes = 8 * 1024 * 1024;

pub const DigestSource = struct {
    ptr: *anyopaque,
    snapshot_alloc: *const fn (*anyopaque, std.mem.Allocator) anyerror![]u8,

    pub fn snapshotAlloc(self: DigestSource, allocator: std.mem.Allocator) ![]u8 {
        return self.snapshot_alloc(self.ptr, allocator);
    }
};

pub const DirectoryDigestSource = struct {
    io: std.Io,
    root: std.Io.Dir,

    pub fn init(io: std.Io, root: std.Io.Dir) DirectoryDigestSource {
        return .{ .io = io, .root = root };
    }

    pub fn source(self: *DirectoryDigestSource) DigestSource {
        return .{ .ptr = self, .snapshot_alloc = snapshotErased };
    }

    fn snapshotErased(raw: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
        const self: *DirectoryDigestSource = @ptrCast(@alignCast(raw));
        var archive = try source_archive.createAlloc(allocator, self.io, self.root, .{
            .ignore_file_name = null,
            .max_source_bytes = 64 * 1024 * 1024,
            .max_archive_bytes = 64 * 1024 * 1024,
        });
        defer archive.deinit();
        return allocator.dupe(u8, &archive.digest);
    }
};

pub const WatchSession = struct {
    allocator: std.mem.Allocator,
    supervisor: *dev.Supervisor,
    runtime_adapter: dev.Runtime,
    digest_source: DigestSource,
    base_port: u16,
    last_digest: ?[]u8 = null,
    next_generation: u64 = 1,

    pub fn init(
        allocator: std.mem.Allocator,
        supervisor: *dev.Supervisor,
        runtime_adapter: dev.Runtime,
        digest_source: DigestSource,
        base_port: u16,
    ) WatchSession {
        return .{
            .allocator = allocator,
            .supervisor = supervisor,
            .runtime_adapter = runtime_adapter,
            .digest_source = digest_source,
            .base_port = base_port,
        };
    }

    pub fn deinit(self: *WatchSession) void {
        if (self.last_digest) |digest| self.allocator.free(digest);
        self.* = undefined;
    }

    pub fn start(self: *WatchSession) !dev.ReloadReceipt {
        if (self.last_digest != null) return error.WatchAlreadyStarted;
        const digest = try self.digest_source.snapshotAlloc(self.allocator);
        errdefer self.allocator.free(digest);
        const receipt = try self.reloadDigest(digest);
        if (receipt.status == .promoted) {
            self.last_digest = digest;
        } else {
            self.allocator.free(digest);
        }
        return receipt;
    }

    pub fn pollOnce(self: *WatchSession) !?dev.ReloadReceipt {
        if (self.last_digest == null) return error.WatchNotStarted;
        const digest = try self.digest_source.snapshotAlloc(self.allocator);
        errdefer self.allocator.free(digest);
        if (std.mem.eql(u8, self.last_digest.?, digest)) {
            self.allocator.free(digest);
            return null;
        }
        const receipt = try self.reloadDigest(digest);
        if (receipt.status == .promoted) {
            self.allocator.free(self.last_digest.?);
            self.last_digest = digest;
        } else {
            self.allocator.free(digest);
        }
        return receipt;
    }

    fn reloadDigest(self: *WatchSession, digest: []const u8) !dev.ReloadReceipt {
        const generation_id = self.next_generation;
        self.next_generation +|= 1;
        const port_offset = std.math.cast(u16, generation_id) orelse return error.GenerationPortExhausted;
        const port = std.math.add(u16, self.base_port, port_offset) catch return error.GenerationPortExhausted;
        return dev.reload(self.supervisor, self.runtime_adapter, .{
            .id = generation_id,
            .digest = digest,
            .port = port,
        });
    }
};

pub const StableProxy = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    requested_port: u16,
    port: u16 = 0,
    target_port: std.atomic.Value(u16) = std.atomic.Value(u16).init(0),
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    server: ?std.Io.net.Server = null,
    thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, port: u16) StableProxy {
        return .{
            .allocator = allocator,
            .io = io,
            .requested_port = port,
        };
    }

    pub fn start(self: *StableProxy) !void {
        if (self.server != null) return error.ProxyAlreadyStarted;
        var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", self.requested_port);
        self.server = try address.listen(self.io, .{ .reuse_address = true });
        self.port = self.server.?.socket.address.getPort();
        self.thread = try std.Thread.spawn(.{}, serveProxy, .{self});
    }

    pub fn deinit(self: *StableProxy) void {
        self.stopping.store(true, .release);
        if (self.server) |*server| server.socket.close(self.io);
        if (self.thread) |thread| thread.join();
        self.server = null;
        self.thread = null;
    }

    pub fn promote(self: *StableProxy, port: u16) !void {
        if (port == 0) return error.InvalidTargetPort;
        if (self.server == null) return error.ProxyNotStarted;
        if (self.failed.load(.acquire)) return error.ProxyFailed;
        self.target_port.store(port, .release);
    }

    pub fn urlAlloc(self: *const StableProxy, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        if (self.port == 0) return error.ProxyNotStarted;
        if (path.len == 0 or path[0] != '/') return error.InvalidProxyPath;
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}{s}", .{ self.port, path });
    }

    fn serve(self: *StableProxy) !void {
        while (!self.stopping.load(.acquire)) {
            const stream = self.server.?.accept(self.io) catch |err| {
                if (self.stopping.load(.acquire)) return;
                return err;
            };
            self.handleConnection(stream) catch {};
        }
    }

    fn handleConnection(self: *StableProxy, stream: std.Io.net.Stream) !void {
        defer stream.close(self.io);
        var read_buffer: [64 * 1024]u8 = undefined;
        var write_buffer: [64 * 1024]u8 = undefined;
        var reader = stream.reader(self.io, &read_buffer);
        var writer = stream.writer(self.io, &write_buffer);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = try server.receiveHead();

        const target_port = self.target_port.load(.acquire);
        if (target_port == 0) {
            return request.respond("no healthy generation", .{
                .status = .service_unavailable,
                .keep_alive = false,
            });
        }

        const target = try self.allocator.dupe(u8, request.head.target);
        defer self.allocator.free(target);
        const headers = try requestHeadersAlloc(self.allocator, &request);
        defer freeHeaders(self.allocator, headers);
        var body_buffer: [16 * 1024]u8 = undefined;
        const body_reader = try request.readerExpectContinue(&body_buffer);
        const body = try body_reader.allocRemaining(self.allocator, .limited(max_body_bytes));
        defer self.allocator.free(body);
        const url = try std.fmt.allocPrint(
            self.allocator,
            "http://127.0.0.1:{d}{s}",
            .{ target_port, target },
        );
        defer self.allocator.free(url);

        var client = zstd.Http.LocalClient.init(self.allocator, self.io);
        defer client.deinit();
        var response = client.sendAlloc(self.allocator, .{
            .method = @tagName(request.head.method),
            .url = url,
            .headers = headers,
            .body = body,
        }) catch {
            return request.respond("upstream unavailable", .{
                .status = .bad_gateway,
                .keep_alive = false,
            });
        };
        defer response.deinit(self.allocator);
        const response_headers = try responseHeadersAlloc(self.allocator, response.headers);
        defer self.allocator.free(response_headers);
        try request.respond(response.body, .{
            .status = @enumFromInt(response.status),
            .keep_alive = false,
            .extra_headers = response_headers,
        });
    }
};

fn serveProxy(proxy: *StableProxy) void {
    proxy.serve() catch {
        if (!proxy.stopping.load(.acquire)) proxy.failed.store(true, .release);
    };
}

pub const Config = struct {
    cwd: []const u8 = "",
    build_argv: []const []const u8,
    process_argv: []const []const u8,
    health_path: []const u8 = "/health",
    readiness_attempts: usize = 40,
    readiness_interval_millis: i64 = 25,
    drain_millis: i64 = 0,
};

const ProcessGeneration = struct {
    id: u64,
    port: u16,
    child: std.process.Child,
};

pub const NativeRuntime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    proxy: *StableProxy,
    config: Config,
    processes: std.ArrayList(ProcessGeneration) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        proxy: *StableProxy,
        config: Config,
    ) NativeRuntime {
        return .{
            .allocator = allocator,
            .io = io,
            .proxy = proxy,
            .config = config,
        };
    }

    pub fn deinit(self: *NativeRuntime) void {
        for (self.processes.items) |*generation| {
            if (generation.child.id != null) generation.child.kill(self.io);
        }
        self.processes.deinit(self.allocator);
    }

    pub fn runtime(self: *NativeRuntime) dev.Runtime {
        return .{ .ptr = self, .vtable = &native_vtable };
    }

    fn build(raw: *anyopaque, _: []const u8) !void {
        const self: *NativeRuntime = @ptrCast(@alignCast(raw));
        if (self.config.build_argv.len == 0) return error.MissingBuildCommand;
        var runner = zstd.Process.LocalRunner.init(self.io);
        var output = try runner.runOutputAlloc(self.allocator, .{
            .argv = self.config.build_argv,
            .cwd = self.config.cwd,
        });
        defer output.deinit(self.allocator);
        if (output.receipt.exit_code != 0) return error.BuildFailed;
    }

    fn spawn(raw: *anyopaque, generation_id: u64, port: u16) !void {
        const self: *NativeRuntime = @ptrCast(@alignCast(raw));
        if (self.config.process_argv.len == 0) return error.MissingProcessCommand;
        const generation_text = try std.fmt.allocPrint(self.allocator, "{d}", .{generation_id});
        defer self.allocator.free(generation_text);
        const port_text = try std.fmt.allocPrint(self.allocator, "{d}", .{port});
        defer self.allocator.free(port_text);
        const argv = try self.allocator.alloc([]const u8, self.config.process_argv.len + 2);
        defer self.allocator.free(argv);
        @memcpy(argv[0..self.config.process_argv.len], self.config.process_argv);
        argv[self.config.process_argv.len] = generation_text;
        argv[self.config.process_argv.len + 1] = port_text;
        var child = try std.process.spawn(self.io, .{
            .argv = argv,
            .cwd = if (self.config.cwd.len == 0) .inherit else .{ .path = self.config.cwd },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .inherit,
        });
        errdefer child.kill(self.io);
        try self.processes.append(self.allocator, .{
            .id = generation_id,
            .port = port,
            .child = child,
        });
    }

    fn probe(raw: *anyopaque, generation_id: u64) !bool {
        const self: *NativeRuntime = @ptrCast(@alignCast(raw));
        const generation = self.find(generation_id) orelse return error.GenerationNotFound;
        const url = try std.fmt.allocPrint(
            self.allocator,
            "http://127.0.0.1:{d}{s}",
            .{ generation.port, self.config.health_path },
        );
        defer self.allocator.free(url);
        var client = zstd.Http.LocalClient.init(self.allocator, self.io);
        defer client.deinit();
        var attempt: usize = 0;
        while (attempt < self.config.readiness_attempts) : (attempt += 1) {
            if (client.sendAlloc(self.allocator, .{ .method = "GET", .url = url })) |response_value| {
                var response = response_value;
                defer response.deinit(self.allocator);
                if (response.status >= 200 and response.status < 400) return true;
            } else |_| {}
            if (attempt + 1 < self.config.readiness_attempts) {
                try self.io.sleep(.fromMilliseconds(self.config.readiness_interval_millis), .awake);
            }
        }
        return false;
    }

    fn promote(raw: *anyopaque, generation_id: u64) !void {
        const self: *NativeRuntime = @ptrCast(@alignCast(raw));
        const generation = self.find(generation_id) orelse return error.GenerationNotFound;
        try self.proxy.promote(generation.port);
    }

    fn drain(raw: *anyopaque, generation_id: u64) !void {
        const self: *NativeRuntime = @ptrCast(@alignCast(raw));
        if (self.config.drain_millis > 0) {
            try self.io.sleep(.fromMilliseconds(self.config.drain_millis), .awake);
        }
        try self.stopGeneration(generation_id);
    }

    fn stop(raw: *anyopaque, generation_id: u64) !void {
        const self: *NativeRuntime = @ptrCast(@alignCast(raw));
        try self.stopGeneration(generation_id);
    }

    fn stopGeneration(self: *NativeRuntime, generation_id: u64) !void {
        const generation = self.find(generation_id) orelse return error.GenerationNotFound;
        if (generation.child.id != null) generation.child.kill(self.io);
    }

    fn find(self: *NativeRuntime, generation_id: u64) ?*ProcessGeneration {
        for (self.processes.items) |*generation| {
            if (generation.id == generation_id) return generation;
        }
        return null;
    }
};

const native_vtable: dev.Runtime.VTable = .{
    .build = NativeRuntime.build,
    .spawn = NativeRuntime.spawn,
    .probe = NativeRuntime.probe,
    .promote = NativeRuntime.promote,
    .drain = NativeRuntime.drain,
    .stop = NativeRuntime.stop,
};

fn requestHeadersAlloc(
    allocator: std.mem.Allocator,
    request: *const std.http.Server.Request,
) ![]zstd.Http.Header {
    var headers: std.ArrayList(zstd.Http.Header) = .empty;
    errdefer freeHeaders(allocator, headers.items);
    var iterator = request.iterateHeaders();
    while (iterator.next()) |header| {
        if (isHopByHop(header.name)) continue;
        const name = try allocator.dupe(u8, header.name);
        errdefer allocator.free(name);
        const value = try allocator.dupe(u8, header.value);
        errdefer allocator.free(value);
        try headers.append(allocator, .{ .name = name, .value = value });
    }
    return headers.toOwnedSlice(allocator);
}

fn responseHeadersAlloc(
    allocator: std.mem.Allocator,
    headers: []const zstd.Http.Header,
) ![]std.http.Header {
    var output: std.ArrayList(std.http.Header) = .empty;
    errdefer output.deinit(allocator);
    for (headers) |header| {
        if (isHopByHop(header.name)) continue;
        try output.append(allocator, .{ .name = header.name, .value = header.value });
    }
    return output.toOwnedSlice(allocator);
}

fn freeHeaders(allocator: std.mem.Allocator, headers: []const zstd.Http.Header) void {
    for (headers) |header| {
        allocator.free(header.name);
        allocator.free(header.value);
    }
    allocator.free(headers);
}

fn isHopByHop(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "host") or
        std.ascii.eqlIgnoreCase(name, "connection") or
        std.ascii.eqlIgnoreCase(name, "content-length") or
        std.ascii.eqlIgnoreCase(name, "transfer-encoding") or
        std.ascii.eqlIgnoreCase(name, "keep-alive") or
        std.ascii.eqlIgnoreCase(name, "proxy-connection") or
        std.ascii.eqlIgnoreCase(name, "upgrade");
}
