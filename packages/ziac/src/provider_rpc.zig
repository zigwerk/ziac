const std = @import("std");
const fx = @import("zigeffect_std").fx;
const local_state = @import("local_state.zig");
const provider_mod = @import("provider.zig");
const provider_error = @import("provider_error.zig");
const resource = @import("resource.zig");
const state = @import("state.zig");
const value = @import("value.zig");

pub const schema = "ziac.provider.rpc.v1";
pub const protocol_major: u16 = 1;
pub const protocol_minor: u16 = 0;
pub const max_frame_bytes: usize = 8 * 1024 * 1024;

pub const ProtocolError = std.mem.Allocator.Error || error{
    InvalidFrame,
    FrameTooLarge,
    UnsupportedProtocol,
    HandshakeRequired,
    HandshakeAlreadyCompleted,
    ProviderIdentityMismatch,
    RequestIdMismatch,
    InvalidResponse,
    TransportFailure,
};

pub const Method = enum {
    handshake,
    read,
    diff,
    create,
    update,
    delete,
    import,
};

pub const Capabilities = struct {
    read: bool = false,
    diff: bool = false,
    create: bool = false,
    update: bool = false,
    delete: bool = false,
    import: bool = false,

    pub const all: Capabilities = .{
        .read = true,
        .diff = true,
        .create = true,
        .update = true,
        .delete = true,
        .import = true,
    };

    fn supports(self: Capabilities, method: Method) bool {
        return switch (method) {
            .handshake => true,
            .read => self.read,
            .diff => self.diff,
            .create => self.create,
            .update => self.update,
            .delete => self.delete,
            .import => self.import,
        };
    }
};

pub const Descriptor = struct {
    package_name: []const u8,
    package_version: []const u8,
    provider: resource.ProviderId,
    resource_type_prefixes: []const []const u8,
    capabilities: Capabilities,
    max_inflight: u16 = 1,
};

pub const ExpectedIdentity = struct {
    package_name: []const u8,
    package_version: []const u8,
    provider: resource.ProviderId,
};

pub const NegotiatedDescriptor = struct {
    allocator: std.mem.Allocator,
    protocol_major: u16,
    protocol_minor: u16,
    package_name: []const u8,
    package_version: []const u8,
    provider: resource.ProviderId,
    resource_type_prefixes: []const []const u8,
    capabilities: Capabilities,
    max_inflight: u16,

    fn initOwned(allocator: std.mem.Allocator, wire: WireDescriptor) !NegotiatedDescriptor {
        const package_name = try allocator.dupe(u8, wire.package_name);
        errdefer allocator.free(package_name);
        const package_version = try allocator.dupe(u8, wire.package_version);
        errdefer allocator.free(package_version);
        const prefixes = try cloneStrings(allocator, wire.resource_type_prefixes);
        errdefer freeStrings(allocator, prefixes);
        return .{
            .allocator = allocator,
            .protocol_major = wire.protocol_major,
            .protocol_minor = wire.protocol_minor,
            .package_name = package_name,
            .package_version = package_version,
            .provider = wire.provider,
            .resource_type_prefixes = prefixes,
            .capabilities = wire.capabilities,
            .max_inflight = wire.max_inflight,
        };
    }

    fn deinit(self: *NegotiatedDescriptor) void {
        self.allocator.free(self.package_name);
        self.allocator.free(self.package_version);
        freeStrings(self.allocator, self.resource_type_prefixes);
        self.* = undefined;
    }
};

pub const Transport = struct {
    ptr: *anyopaque,
    callAllocFn: *const fn (*anyopaque, std.mem.Allocator, []const u8) anyerror![]u8,

    pub fn callAlloc(self: Transport, allocator: std.mem.Allocator, request: []const u8) anyerror![]u8 {
        if (request.len == 0 or request.len > max_frame_bytes) return error.FrameTooLarge;
        const response = try self.callAllocFn(self.ptr, allocator, request);
        if (response.len == 0 or response.len > max_frame_bytes) {
            allocator.free(response);
            return error.FrameTooLarge;
        }
        return response;
    }
};

pub const LoopbackTransport = struct {
    session: *ServerSession,
    last_request: []const u8 = &.{},

    pub fn init(session: *ServerSession) LoopbackTransport {
        return .{ .session = session };
    }

    pub fn deinit(self: *LoopbackTransport) void {
        if (self.last_request.len != 0) self.session.allocator.free(self.last_request);
        self.* = undefined;
    }

    pub fn transport(self: *LoopbackTransport) Transport {
        return .{ .ptr = self, .callAllocFn = callAlloc };
    }

    fn callAlloc(raw: *anyopaque, allocator: std.mem.Allocator, request: []const u8) anyerror![]u8 {
        const self: *LoopbackTransport = @ptrCast(@alignCast(raw));
        if (self.last_request.len != 0) self.session.allocator.free(self.last_request);
        self.last_request = try self.session.allocator.dupe(u8, request);
        return self.session.handleAlloc(allocator, request);
    }
};

pub const ProcessProvider = struct {
    const Inner = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        child: std.process.Child,
        read_buffer: []u8,

        fn transport(self: *Inner) Transport {
            return .{ .ptr = self, .callAllocFn = callAlloc };
        }

        fn initAlloc(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !*Inner {
            const inner = try allocator.create(Inner);
            errdefer allocator.destroy(inner);
            const read_buffer = try allocator.alloc(u8, max_frame_bytes + 1);
            errdefer allocator.free(read_buffer);
            var child = try std.process.spawn(io, .{
                .argv = argv,
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .inherit,
            });
            errdefer child.kill(io);
            inner.* = .{
                .allocator = allocator,
                .io = io,
                .child = child,
                .read_buffer = read_buffer,
            };
            return inner;
        }

        fn callAlloc(raw: *anyopaque, allocator: std.mem.Allocator, request: []const u8) anyerror![]u8 {
            const self: *Inner = @ptrCast(@alignCast(raw));
            const stdin = self.child.stdin orelse return error.TransportFailure;
            try stdin.writeStreamingAll(self.io, request);
            try stdin.writeStreamingAll(self.io, "\n");
            const stdout = self.child.stdout orelse return error.TransportFailure;
            var reader = stdout.reader(self.io, self.read_buffer);
            const line = reader.interface.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => return error.FrameTooLarge,
                else => return error.TransportFailure,
            } orelse return error.TransportFailure;
            if (line.len == 0 or line.len > max_frame_bytes) return error.FrameTooLarge;
            return allocator.dupe(u8, line);
        }

        fn deinit(self: *Inner) void {
            if (self.child.stdin) |stdin| {
                stdin.close(self.io);
                self.child.stdin = null;
            }
            _ = self.child.wait(self.io) catch {
                self.child.kill(self.io);
            };
            self.allocator.free(self.read_buffer);
            self.* = undefined;
        }
    };

    allocator: std.mem.Allocator,
    inner: *Inner,
    client: Client,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        argv: []const []const u8,
        expected: ExpectedIdentity,
    ) anyerror!ProcessProvider {
        if (argv.len == 0) return error.InvalidConfiguration;
        const inner = try Inner.initAlloc(allocator, io, argv);
        errdefer {
            inner.deinit();
            allocator.destroy(inner);
        }
        const client = try Client.init(allocator, inner.transport(), expected);
        return .{ .allocator = allocator, .inner = inner, .client = client };
    }

    pub fn deinit(self: *ProcessProvider) void {
        self.client.deinit();
        self.inner.deinit();
        self.allocator.destroy(self.inner);
        self.* = undefined;
    }

    pub fn provider(self: *ProcessProvider) provider_mod.Provider {
        return self.client.provider();
    }
};

pub fn serveStdio(io: std.Io, allocator: std.mem.Allocator, session: *ServerSession) !void {
    const DirectHandle = struct {
        fn handle(_: *@This(), target: *ServerSession, frame: []const u8) anyerror![]u8 {
            return target.handleAlloc(target.allocator, frame);
        }
    };
    var direct = DirectHandle{};
    return serveStdioWith(io, allocator, session, &direct, DirectHandle.handle);
}

/// Serve a provider process through one owning ManagedRuntime. Every protocol
/// frame is a child effect, so handshake and lifecycle failures have their own
/// scope, fiber, and durable causal lineage without rebuilding provider state.
pub fn serveStdioEffectful(
    io: std.Io,
    allocator: std.mem.Allocator,
    session: *ServerSession,
    runtime: anytype,
) !void {
    const Handle = struct {
        runtime: @TypeOf(runtime),

        fn handle(self: *@This(), target: *ServerSession, frame: []const u8) anyerror![]u8 {
            return self.runtime.run(frameEffect(.{
                .session = target,
                .frame = frame,
            }).named("provider.rpc.frame"));
        }
    };
    var handle = Handle{ .runtime = runtime };
    return serveStdioWith(io, allocator, session, &handle, Handle.handle);
}

fn serveStdioWith(
    io: std.Io,
    allocator: std.mem.Allocator,
    session: *ServerSession,
    handler: anytype,
    comptime handle: anytype,
) !void {
    const read_buffer = try allocator.alloc(u8, max_frame_bytes + 1);
    defer allocator.free(read_buffer);
    var reader = std.Io.File.stdin().reader(io, read_buffer);
    var write_buffer: [16 * 1024]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &write_buffer);
    while (reader.interface.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => return error.FrameTooLarge,
        else => return err,
    }) |line| {
        if (line.len == 0) continue;
        const response = try handle(handler, session, line);
        defer allocator.free(response);
        try writer.interface.writeAll(response);
        try writer.interface.writeByte('\n');
        try writer.interface.flush();
    }
}

const FrameState = struct {
    session: *ServerSession,
    frame: []const u8,
};
const FrameProgram = fx.kernel.Effect([]u8, anyerror, .{}).Stateful(FrameState);

fn frameEffect(frame_state: FrameState) FrameProgram {
    return FrameProgram.init(frame_state, struct {
        fn run(request: FrameState, ctx: *FrameProgram.Context) anyerror![]u8 {
            _ = ctx.recordCausal(.{
                .kind = .workflow_event_recorded,
                .service_key = "ziac/ProviderRegistry",
                .label = "provider.rpc.frame",
                .status = "received",
                .redacted_detail = "bounded-protocol-frame",
            });
            return request.session.handleAlloc(ctx.allocator(), request.frame);
        }
    }.run);
}

pub const ServerSession = struct {
    allocator: std.mem.Allocator,
    descriptor: Descriptor,
    provider: provider_mod.Provider,
    handshaken: bool = false,

    pub fn init(allocator: std.mem.Allocator, descriptor: Descriptor, provider: provider_mod.Provider) ServerSession {
        return .{ .allocator = allocator, .descriptor = descriptor, .provider = provider };
    }

    pub fn handleAlloc(self: *ServerSession, allocator: std.mem.Allocator, frame: []const u8) anyerror![]u8 {
        if (frame.len == 0) return error.InvalidFrame;
        if (frame.len > max_frame_bytes) return error.FrameTooLarge;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const parsed = std.json.parseFromSlice(WireRequest, arena.allocator(), frame, .{
            .ignore_unknown_fields = false,
        }) catch return error.InvalidFrame;
        const request = parsed.value;
        if (!std.mem.eql(u8, request.schema, schema) or request.id == 0) return error.InvalidFrame;

        if (request.method == .handshake) return self.handleHandshakeAlloc(allocator, request);
        if (!self.handshaken) return error.HandshakeRequired;
        if (!self.descriptor.capabilities.supports(request.method)) {
            return failureResponseAlloc(allocator, request.id, error.InvalidConfiguration, null);
        }
        const wire_node = request.node orelse return error.InvalidFrame;
        var node = decodeNode(allocator, wire_node) catch return error.InvalidFrame;
        defer node.deinit(allocator);
        if (!self.authorizes(node)) return failureResponseAlloc(allocator, request.id, error.InvalidConfiguration, null);

        var decoded_context = try DecodedContext.init(allocator, request.context orelse .{});
        defer decoded_context.deinit();
        if (decoded_context.loaded) |*loaded| decoded_context.context.state = &loaded.store;
        var recorder = provider_error.DiagnosticRecorder.init(allocator);
        defer recorder.deinit();
        decoded_context.context.diagnostics = &recorder;

        return switch (request.method) {
            .handshake => unreachable,
            .read => blk: {
                var result = self.provider.readWithContext(&decoded_context.context, node) catch |err|
                    break :blk try failureFromRecorderAlloc(allocator, request.id, err, &recorder);
                defer result.deinit();
                break :blk try readResponseAlloc(allocator, request.id, result);
            },
            .diff => blk: {
                const observed_wire = request.observed orelse return error.InvalidFrame;
                var observed = decodeResourceResult(allocator, observed_wire) catch return error.InvalidFrame;
                defer observed.deinit();
                var result = self.provider.diffWithContext(&decoded_context.context, node, &observed) catch |err|
                    break :blk try failureFromRecorderAlloc(allocator, request.id, err, &recorder);
                defer result.deinit();
                break :blk try diffResponseAlloc(allocator, request.id, result);
            },
            .create => blk: {
                var result = self.provider.createWithContext(&decoded_context.context, node) catch |err|
                    break :blk try failureFromRecorderAlloc(allocator, request.id, err, &recorder);
                defer result.deinit();
                break :blk try resourceResponseAlloc(allocator, request.id, result);
            },
            .update => blk: {
                const observed_wire = request.observed orelse return error.InvalidFrame;
                var observed = decodeResourceResult(allocator, observed_wire) catch return error.InvalidFrame;
                defer observed.deinit();
                var result = self.provider.updateWithContext(&decoded_context.context, node, &observed) catch |err|
                    break :blk try failureFromRecorderAlloc(allocator, request.id, err, &recorder);
                defer result.deinit();
                break :blk try resourceResponseAlloc(allocator, request.id, result);
            },
            .delete => blk: {
                const physical_id = request.physical_id orelse return error.InvalidFrame;
                self.provider.deleteWithContext(&decoded_context.context, node, physical_id) catch |err|
                    break :blk try failureFromRecorderAlloc(allocator, request.id, err, &recorder);
                break :blk try successResponseAlloc(allocator, request.id);
            },
            .import => blk: {
                const physical_id = request.physical_id orelse return error.InvalidFrame;
                var result = self.provider.importWithContext(&decoded_context.context, node, physical_id) catch |err|
                    break :blk try failureFromRecorderAlloc(allocator, request.id, err, &recorder);
                defer result.deinit();
                break :blk try resourceResponseAlloc(allocator, request.id, result);
            },
        };
    }

    fn handleHandshakeAlloc(self: *ServerSession, allocator: std.mem.Allocator, request: WireRequest) ![]u8 {
        if (self.handshaken) return error.HandshakeAlreadyCompleted;
        const handshake = request.handshake orelse return error.InvalidFrame;
        if (handshake.protocol_major != protocol_major or handshake.protocol_minor > protocol_minor) return error.UnsupportedProtocol;
        if (self.descriptor.max_inflight != 1 or self.descriptor.resource_type_prefixes.len == 0) return error.InvalidFrame;
        self.handshaken = true;
        return stringifyBounded(allocator, WireResponse{
            .schema = schema,
            .id = request.id,
            .ok = true,
            .descriptor = .{
                .protocol_major = protocol_major,
                .protocol_minor = protocol_minor,
                .package_name = self.descriptor.package_name,
                .package_version = self.descriptor.package_version,
                .provider = self.descriptor.provider,
                .resource_type_prefixes = self.descriptor.resource_type_prefixes,
                .capabilities = self.descriptor.capabilities,
                .max_inflight = self.descriptor.max_inflight,
            },
        });
    }

    fn authorizes(self: ServerSession, node: resource.ResourceNode) bool {
        if (node.provider != self.descriptor.provider) return false;
        for (self.descriptor.resource_type_prefixes) |prefix| {
            if (std.mem.startsWith(u8, node.type_name, prefix)) return true;
        }
        return false;
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    negotiated: NegotiatedDescriptor,
    next_id: u64 = 2,
    mutex: fx.SpinLock = .{},

    pub fn init(allocator: std.mem.Allocator, transport: Transport, expected: ExpectedIdentity) anyerror!Client {
        const request = WireRequest{
            .schema = schema,
            .id = 1,
            .method = .handshake,
            .handshake = .{ .protocol_major = protocol_major, .protocol_minor = protocol_minor },
        };
        const frame = try stringifyBounded(allocator, request);
        defer allocator.free(frame);
        const response_frame = try transport.callAlloc(allocator, frame);
        defer allocator.free(response_frame);
        var parsed = std.json.parseFromSlice(WireResponse, allocator, response_frame, .{ .ignore_unknown_fields = false }) catch return error.InvalidResponse;
        defer parsed.deinit();
        const response = parsed.value;
        if (!std.mem.eql(u8, response.schema, schema) or response.id != 1 or !response.ok) return error.InvalidResponse;
        const wire = response.descriptor orelse return error.InvalidResponse;
        if (wire.protocol_major != protocol_major or wire.protocol_minor > protocol_minor or wire.max_inflight != 1) return error.UnsupportedProtocol;
        if (!std.mem.eql(u8, wire.package_name, expected.package_name) or
            !std.mem.eql(u8, wire.package_version, expected.package_version) or wire.provider != expected.provider)
            return error.ProviderIdentityMismatch;
        const negotiated = try NegotiatedDescriptor.initOwned(allocator, wire);
        return .{
            .allocator = allocator,
            .transport = transport,
            .negotiated = negotiated,
        };
    }

    pub fn deinit(self: *Client) void {
        self.negotiated.deinit();
        self.* = undefined;
    }

    pub fn provider(self: *Client) provider_mod.Provider {
        return .{
            .ptr = self,
            .readFn = read,
            .diffFn = diff,
            .createFn = create,
            .updateFn = update,
            .deleteFn = delete,
            .importFn = importResource,
        };
    }

    fn nextRequestId(self: *Client) u64 {
        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;
        return id;
    }

    fn read(raw: *anyopaque, context: *provider_mod.OperationContext, node: resource.ResourceNode) provider_mod.ProviderError!provider_mod.ReadResult {
        const self: *Client = @ptrCast(@alignCast(raw));
        self.mutex.lock();
        defer self.mutex.unlock();
        context.checkActive() catch |err| return err;
        var request_encoding = RequestEncoding.init(context.allocator, self.nextRequestId(), .read, context, node, null, null) catch |err| return mapClientError(err);
        defer request_encoding.deinit();
        var response = self.call(context, request_encoding.wire) catch |err| return mapClientError(err);
        defer response.deinit();
        const wire = response.value.read orelse return error.ProviderBug;
        return if (wire.absent) .absent else .{ .present = decodeResourceResult(context.allocator, wire.resource orelse return error.ProviderBug) catch return error.ProviderBug };
    }

    fn diff(raw: *anyopaque, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) provider_mod.ProviderError!provider_mod.DiffResult {
        const self: *Client = @ptrCast(@alignCast(raw));
        self.mutex.lock();
        defer self.mutex.unlock();
        context.checkActive() catch |err| return err;
        var request_encoding = RequestEncoding.init(context.allocator, self.nextRequestId(), .diff, context, node, observed, null) catch |err| return mapClientError(err);
        defer request_encoding.deinit();
        var response = self.call(context, request_encoding.wire) catch |err| return mapClientError(err);
        defer response.deinit();
        const wire = response.value.diff orelse return error.ProviderBug;
        return provider_mod.DiffResult.init(context.allocator, wire.kind, wire.reasons);
    }

    fn create(raw: *anyopaque, context: *provider_mod.OperationContext, node: resource.ResourceNode) provider_mod.ProviderError!provider_mod.ResourceResult {
        const self: *Client = @ptrCast(@alignCast(raw));
        return self.resourceCall(context, node, .create, null, null);
    }

    fn update(raw: *anyopaque, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) provider_mod.ProviderError!provider_mod.ResourceResult {
        const self: *Client = @ptrCast(@alignCast(raw));
        return self.resourceCall(context, node, .update, observed, null);
    }

    fn importResource(raw: *anyopaque, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) provider_mod.ProviderError!provider_mod.ResourceResult {
        const self: *Client = @ptrCast(@alignCast(raw));
        return self.resourceCall(context, node, .import, null, physical_id);
    }

    fn resourceCall(self: *Client, context: *provider_mod.OperationContext, node: resource.ResourceNode, method: Method, observed: ?*const provider_mod.ResourceResult, physical_id: ?[]const u8) provider_mod.ProviderError!provider_mod.ResourceResult {
        self.mutex.lock();
        defer self.mutex.unlock();
        context.checkActive() catch |err| return err;
        var request_encoding = RequestEncoding.init(context.allocator, self.nextRequestId(), method, context, node, observed, physical_id) catch |err| return mapClientError(err);
        defer request_encoding.deinit();
        var response = self.call(context, request_encoding.wire) catch |err| return mapClientError(err);
        defer response.deinit();
        return decodeResourceResult(context.allocator, response.value.resource orelse return error.ProviderBug) catch return error.ProviderBug;
    }

    fn delete(raw: *anyopaque, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) provider_mod.ProviderError!void {
        const self: *Client = @ptrCast(@alignCast(raw));
        self.mutex.lock();
        defer self.mutex.unlock();
        context.checkActive() catch |err| return err;
        var request_encoding = RequestEncoding.init(context.allocator, self.nextRequestId(), .delete, context, node, null, physical_id) catch |err| return mapClientError(err);
        defer request_encoding.deinit();
        var response = self.call(context, request_encoding.wire) catch |err| return mapClientError(err);
        response.deinit();
    }

    fn call(self: *Client, context: *provider_mod.OperationContext, request: WireRequest) anyerror!std.json.Parsed(WireResponse) {
        const frame = try stringifyBounded(context.allocator, request);
        defer context.allocator.free(frame);
        const response_frame = self.transport.callAlloc(context.allocator, frame) catch return error.TransportFailure;
        defer context.allocator.free(response_frame);
        var parsed = std.json.parseFromSlice(WireResponse, context.allocator, response_frame, .{
            .ignore_unknown_fields = false,
            .allocate = .alloc_always,
        }) catch return error.InvalidResponse;
        errdefer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.schema, schema) or parsed.value.id != request.id) return error.RequestIdMismatch;
        if (!parsed.value.ok) {
            const failure = parsed.value.failure orelse return error.InvalidResponse;
            if (failure.diagnostic) |diagnostic| context.recordDiagnostic(diagnostic);
            return providerErrorFromName(failure.tag) orelse error.ProviderBug;
        }
        return parsed;
    }
};

const WireHandshake = struct { protocol_major: u16, protocol_minor: u16 };
const WireDescriptor = struct {
    protocol_major: u16,
    protocol_minor: u16,
    package_name: []const u8,
    package_version: []const u8,
    provider: resource.ProviderId,
    resource_type_prefixes: []const []const u8,
    capabilities: Capabilities,
    max_inflight: u16,
};
const WireLifecycle = struct {
    protect: bool,
    retain_on_delete: bool,
    replace_before_delete: bool,
    ignore_changes: []const []const u8,
    operation_timeout_millis: u64,
};
const WireNode = struct {
    id: []const u8,
    provider: resource.ProviderId,
    type_name: []const u8,
    schema_version: u32,
    logical_id: []const u8,
    inputs_json: []const u8,
    lifecycle: WireLifecycle,
};
const WireContext = struct {
    deadline_millis: ?u64 = null,
    physical_id: ?[]const u8 = null,
    operation_handle: ?[]const u8 = null,
    destructive_confirmation: bool = false,
    state_json: ?[]const u8 = null,
};
const WireOutput = struct { name: []const u8, value_json: []const u8 };
const WireResourceResult = struct {
    physical_id: []const u8,
    observed_inputs_json: []const u8,
    outputs: []const WireOutput,
    operation_handle: ?[]const u8 = null,
    completed: bool = true,
};
const WireReadResult = struct { absent: bool, resource: ?WireResourceResult = null };
const WireDiffResult = struct { kind: provider_mod.DiffKind, reasons: []const []const u8 };
const WireFailure = struct { tag: []const u8, diagnostic: ?provider_error.DiagnosticSource = null };
const WireRequest = struct {
    schema: []const u8,
    id: u64,
    method: Method,
    handshake: ?WireHandshake = null,
    node: ?WireNode = null,
    context: ?WireContext = null,
    observed: ?WireResourceResult = null,
    physical_id: ?[]const u8 = null,
};
const WireResponse = struct {
    schema: []const u8,
    id: u64,
    ok: bool,
    descriptor: ?WireDescriptor = null,
    read: ?WireReadResult = null,
    diff: ?WireDiffResult = null,
    resource: ?WireResourceResult = null,
    failure: ?WireFailure = null,
};

const EncodedResult = struct {
    allocator: std.mem.Allocator,
    wire: WireResourceResult,
    value_json: [][]const u8,

    fn init(allocator: std.mem.Allocator, result: provider_mod.ResourceResult) !EncodedResult {
        const observed_inputs_json = try result.observed_inputs.canonicalJsonAlloc(allocator);
        errdefer allocator.free(observed_inputs_json);
        const outputs = try allocator.alloc(WireOutput, result.outputs.len);
        errdefer allocator.free(outputs);
        const value_json = try allocator.alloc([]const u8, result.outputs.len);
        errdefer allocator.free(value_json);
        var initialized: usize = 0;
        errdefer for (value_json[0..initialized]) |json| allocator.free(json);
        for (result.outputs, 0..) |output, index| {
            value_json[index] = try output.value.canonicalJsonAlloc(allocator);
            initialized += 1;
            outputs[index] = .{ .name = output.name, .value_json = value_json[index] };
        }
        return .{
            .allocator = allocator,
            .wire = .{
                .physical_id = result.physical_id,
                .observed_inputs_json = observed_inputs_json,
                .outputs = outputs,
                .operation_handle = result.operation_handle,
                .completed = result.completed,
            },
            .value_json = value_json,
        };
    }

    fn deinit(self: *EncodedResult) void {
        self.allocator.free(self.wire.observed_inputs_json);
        for (self.value_json) |json| self.allocator.free(json);
        self.allocator.free(self.value_json);
        self.allocator.free(self.wire.outputs);
        self.* = undefined;
    }
};

const RequestEncoding = struct {
    allocator: std.mem.Allocator,
    wire: WireRequest,
    inputs_json: []const u8,
    state_json: ?[]const u8,
    observed: ?EncodedResult,

    fn init(allocator: std.mem.Allocator, id: u64, method: Method, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: ?*const provider_mod.ResourceResult, physical_id: ?[]const u8) !RequestEncoding {
        const inputs_json = try node.inputs.canonicalJsonAlloc(allocator);
        errdefer allocator.free(inputs_json);
        const state_json = if (context.state) |store| try local_state.resourcesJsonAlloc(allocator, "rpc", "session", store) else null;
        errdefer if (state_json) |json| allocator.free(json);
        var encoded_observed = if (observed) |result| try EncodedResult.init(allocator, result.*) else null;
        errdefer if (encoded_observed) |*result| result.deinit();
        return .{
            .allocator = allocator,
            .wire = .{
                .schema = schema,
                .id = id,
                .method = method,
                .node = .{
                    .id = node.id,
                    .provider = node.provider,
                    .type_name = node.type_name,
                    .schema_version = node.schema_version,
                    .logical_id = node.logical_id,
                    .inputs_json = inputs_json,
                    .lifecycle = .{
                        .protect = node.lifecycle.protect,
                        .retain_on_delete = node.lifecycle.retain_on_delete,
                        .replace_before_delete = node.lifecycle.replace_before_delete,
                        .ignore_changes = node.lifecycle.ignore_changes,
                        .operation_timeout_millis = node.lifecycle.operation_timeout_millis,
                    },
                },
                .context = .{
                    .deadline_millis = context.deadline_millis,
                    .physical_id = context.physical_id,
                    .operation_handle = context.operation_handle,
                    .destructive_confirmation = context.destructive_confirmation,
                    .state_json = state_json,
                },
                .observed = if (encoded_observed) |result| result.wire else null,
                .physical_id = physical_id,
            },
            .inputs_json = inputs_json,
            .state_json = state_json,
            .observed = encoded_observed,
        };
    }

    fn deinit(self: *RequestEncoding) void {
        self.allocator.free(self.inputs_json);
        if (self.state_json) |json| self.allocator.free(json);
        if (self.observed) |*result| result.deinit();
        self.* = undefined;
    }
};

const DecodedContext = struct {
    context: provider_mod.OperationContext,
    loaded: ?local_state.LoadedResources = null,

    fn init(allocator: std.mem.Allocator, wire: WireContext) !DecodedContext {
        var result = DecodedContext{ .context = provider_mod.OperationContext.init(allocator) };
        result.context.deadline_millis = wire.deadline_millis;
        result.context.physical_id = wire.physical_id;
        result.context.operation_handle = wire.operation_handle;
        result.context.destructive_confirmation = wire.destructive_confirmation;
        if (wire.state_json) |json| {
            result.loaded = try local_state.parseResources(allocator, json, "rpc", "session");
        }
        return result;
    }

    fn deinit(self: *DecodedContext) void {
        if (self.loaded) |*loaded| loaded.deinit();
        self.* = undefined;
    }
};

fn decodeNode(allocator: std.mem.Allocator, wire: WireNode) !resource.ResourceNode {
    var inputs = try value.Value.parseJsonAlloc(allocator, wire.inputs_json);
    defer inputs.deinit(allocator);
    return resource.ResourceNode.initOwned(allocator, .{
        .id = wire.id,
        .provider = wire.provider,
        .type_name = wire.type_name,
        .schema_version = wire.schema_version,
        .logical_id = wire.logical_id,
        .inputs = inputs,
        .lifecycle = .{
            .protect = wire.lifecycle.protect,
            .retain_on_delete = wire.lifecycle.retain_on_delete,
            .replace_before_delete = wire.lifecycle.replace_before_delete,
            .ignore_changes = wire.lifecycle.ignore_changes,
            .operation_timeout_millis = wire.lifecycle.operation_timeout_millis,
        },
    });
}

fn decodeResourceResult(allocator: std.mem.Allocator, wire: WireResourceResult) !provider_mod.ResourceResult {
    var observed_inputs = try value.Value.parseJsonAlloc(allocator, wire.observed_inputs_json);
    defer observed_inputs.deinit(allocator);
    const outputs = try allocator.alloc(state.StateOutput, wire.outputs.len);
    defer allocator.free(outputs);
    var initialized: usize = 0;
    defer for (outputs[0..initialized]) |*output| output.value.deinit(allocator);
    for (wire.outputs, 0..) |output, index| {
        outputs[index] = .{ .name = output.name, .value = try value.Value.parseJsonAlloc(allocator, output.value_json) };
        initialized += 1;
    }
    var result = try provider_mod.ResourceResult.init(allocator, wire.physical_id, observed_inputs, outputs, wire.operation_handle);
    result.completed = wire.completed;
    return result;
}

fn successResponseAlloc(allocator: std.mem.Allocator, id: u64) ![]u8 {
    return stringifyBounded(allocator, WireResponse{ .schema = schema, .id = id, .ok = true });
}

fn readResponseAlloc(allocator: std.mem.Allocator, id: u64, result: provider_mod.ReadResult) ![]u8 {
    return switch (result) {
        .absent => stringifyBounded(allocator, WireResponse{ .schema = schema, .id = id, .ok = true, .read = .{ .absent = true } }),
        .present => |present| blk: {
            var encoded = try EncodedResult.init(allocator, present);
            defer encoded.deinit();
            break :blk try stringifyBounded(allocator, WireResponse{ .schema = schema, .id = id, .ok = true, .read = .{ .absent = false, .resource = encoded.wire } });
        },
    };
}

fn diffResponseAlloc(allocator: std.mem.Allocator, id: u64, result: provider_mod.DiffResult) ![]u8 {
    return stringifyBounded(allocator, WireResponse{ .schema = schema, .id = id, .ok = true, .diff = .{ .kind = result.kind, .reasons = result.reasons } });
}

fn resourceResponseAlloc(allocator: std.mem.Allocator, id: u64, result: provider_mod.ResourceResult) ![]u8 {
    var encoded = try EncodedResult.init(allocator, result);
    defer encoded.deinit();
    return stringifyBounded(allocator, WireResponse{ .schema = schema, .id = id, .ok = true, .resource = encoded.wire });
}

fn failureFromRecorderAlloc(allocator: std.mem.Allocator, id: u64, err: provider_mod.ProviderError, recorder: *provider_error.DiagnosticRecorder) ![]u8 {
    var diagnostic = try recorder.snapshotAlloc(allocator);
    defer if (diagnostic) |*owned| owned.deinit();
    return failureResponseAlloc(allocator, id, err, if (diagnostic) |owned| .{
        .category = owned.category,
        .service = owned.service,
        .status = owned.status,
        .google_status = owned.google_status,
        .request_id = owned.request_id,
        .message = owned.message,
        .retry_after_millis = owned.retry_after_millis,
        .quota_metric = owned.quota_metric,
        .quota_limit = owned.quota_limit,
        .quota_subject = owned.quota_subject,
    } else null);
}

fn failureResponseAlloc(allocator: std.mem.Allocator, id: u64, err: provider_mod.ProviderError, diagnostic: ?provider_error.DiagnosticSource) ![]u8 {
    return stringifyBounded(allocator, WireResponse{ .schema = schema, .id = id, .ok = false, .failure = .{ .tag = @errorName(err), .diagnostic = diagnostic } });
}

fn stringifyBounded(allocator: std.mem.Allocator, input: anytype) ![]u8 {
    const bytes = try std.json.Stringify.valueAlloc(allocator, input, .{});
    if (bytes.len > max_frame_bytes) {
        allocator.free(bytes);
        return error.FrameTooLarge;
    }
    return bytes;
}

fn mapClientError(err: anyerror) provider_mod.ProviderError {
    return switch (err) {
        error.AuthenticationFailed => error.AuthenticationFailed,
        error.AuthorizationFailed => error.AuthorizationFailed,
        error.InvalidConfiguration => error.InvalidConfiguration,
        error.Conflict => error.Conflict,
        error.NotFound => error.NotFound,
        error.QuotaExceeded => error.QuotaExceeded,
        error.RateLimited => error.RateLimited,
        error.TransientFailure => error.TransientFailure,
        error.ProviderTimeout => error.ProviderTimeout,
        error.ProviderCancelled => error.ProviderCancelled,
        error.RemoteOperationFailed => error.RemoteOperationFailed,
        error.DestructiveConfirmationRequired => error.DestructiveConfirmationRequired,
        error.ResourceNotEmpty => error.ResourceNotEmpty,
        error.OutOfMemory => error.OutOfMemory,
        error.ProviderBug, error.InvalidFrame, error.FrameTooLarge, error.UnsupportedProtocol, error.HandshakeRequired, error.HandshakeAlreadyCompleted, error.ProviderIdentityMismatch, error.RequestIdMismatch, error.InvalidResponse => error.ProviderBug,
        else => error.TransientFailure,
    };
}

fn providerErrorFromName(name: []const u8) ?provider_mod.ProviderError {
    inline for (.{
        error.AuthenticationFailed,
        error.AuthorizationFailed,
        error.InvalidConfiguration,
        error.Conflict,
        error.NotFound,
        error.QuotaExceeded,
        error.RateLimited,
        error.TransientFailure,
        error.ProviderTimeout,
        error.ProviderCancelled,
        error.RemoteOperationFailed,
        error.DestructiveConfirmationRequired,
        error.ResourceNotEmpty,
        error.ProviderBug,
        error.OutOfMemory,
    }) |candidate| if (std.mem.eql(u8, name, @errorName(candidate))) return candidate;
    return null;
}

fn cloneStrings(allocator: std.mem.Allocator, source: []const []const u8) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, source.len);
    errdefer allocator.free(result);
    var initialized: usize = 0;
    errdefer for (result[0..initialized]) |text| allocator.free(text);
    for (source, 0..) |text, index| {
        result[index] = try allocator.dupe(u8, text);
        initialized += 1;
    }
    return result;
}

fn freeStrings(allocator: std.mem.Allocator, source: []const []const u8) void {
    for (source) |text| allocator.free(text);
    allocator.free(source);
}
