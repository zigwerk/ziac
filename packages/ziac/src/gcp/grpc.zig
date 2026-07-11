const std = @import("std");

pub const Limits = struct {
    max_message_bytes: usize = 4 * 1024 * 1024,
};

pub const CodecError = std.mem.Allocator.Error || error{
    InvalidFrame,
    MessageTooLarge,
    UnsupportedCompression,
};

pub fn frameUnaryAlloc(allocator: std.mem.Allocator, message: []const u8, limits: Limits) CodecError![]u8 {
    if (message.len > limits.max_message_bytes or message.len > std.math.maxInt(u32)) return error.MessageTooLarge;
    const frame = try allocator.alloc(u8, message.len + 5);
    frame[0] = 0;
    std.mem.writeInt(u32, frame[1..5], @intCast(message.len), .big);
    @memcpy(frame[5..], message);
    return frame;
}

pub fn unframeUnary(frame: []const u8, limits: Limits) CodecError![]const u8 {
    if (frame.len < 5) return error.InvalidFrame;
    if (frame[0] != 0) return error.UnsupportedCompression;
    const length = std.mem.readInt(u32, frame[1..5], .big);
    if (length > limits.max_message_bytes) return error.MessageTooLarge;
    if (length != frame.len - 5) return error.InvalidFrame;
    return frame[5..];
}

pub const Capabilities = struct {
    http2: bool = false,
    tls: bool = false,
    trailers: bool = false,
    deadlines: bool = false,
    cancellation: bool = false,
    multiplexing: bool = false,
    connection_reuse: bool = false,
    flow_control: bool = false,
    bounded_messages: bool = false,
    redacted_diagnostics: bool = false,
};

pub fn requireQualified(capabilities: Capabilities) error{TransportNotQualified}!void {
    inline for (@typeInfo(Capabilities).@"struct".fields) |field| {
        if (!@field(capabilities, field.name)) return error.TransportNotQualified;
    }
}

pub const Header = struct { name: []const u8, value: []const u8 };
pub const Status = struct { code: u8, message: []const u8 };

pub fn parseTrailers(trailers: []const Header) error{InvalidTrailers}!Status {
    var code: ?u8 = null;
    var message: []const u8 = "";
    for (trailers) |trailer| {
        if (std.ascii.eqlIgnoreCase(trailer.name, "grpc-status")) {
            code = std.fmt.parseInt(u8, trailer.value, 10) catch return error.InvalidTrailers;
        } else if (std.ascii.eqlIgnoreCase(trailer.name, "grpc-message")) {
            message = trailer.value;
        }
    }
    return .{ .code = code orelse return error.InvalidTrailers, .message = message };
}

pub const UnaryRequest = struct {
    authority: []const u8,
    service: []const u8,
    method: []const u8,
    payload: []const u8,
    timeout_millis: u64,
};

pub const QualifiedTransport = struct {
    context: *anyopaque,
    capabilities: Capabilities,
    invoke_fn: *const fn (*anyopaque, std.mem.Allocator, UnaryRequest, Limits) anyerror![]u8,

    pub fn invoke(
        self: QualifiedTransport,
        allocator: std.mem.Allocator,
        request: UnaryRequest,
        limits: Limits,
    ) anyerror![]u8 {
        try requireQualified(self.capabilities);
        if (request.timeout_millis == 0) return error.InvalidDeadline;
        return self.invoke_fn(self.context, allocator, request, limits);
    }
};

pub const ParityObservation = struct {
    rest_canonical_json: []const u8,
    grpc_canonical_json: []const u8,
    rest_operation: ?[]const u8 = null,
    grpc_operation: ?[]const u8 = null,
};

pub fn requireParity(observation: ParityObservation) error{TransportParityMismatch}!void {
    if (!std.mem.eql(u8, observation.rest_canonical_json, observation.grpc_canonical_json)) {
        return error.TransportParityMismatch;
    }
    if ((observation.rest_operation == null) != (observation.grpc_operation == null)) {
        return error.TransportParityMismatch;
    }
    if (observation.rest_operation) |rest| {
        if (!std.mem.eql(u8, rest, observation.grpc_operation.?)) return error.TransportParityMismatch;
    }
}
