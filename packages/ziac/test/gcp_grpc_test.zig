const std = @import("std");
const ziac = @import("ziac");

test "gRPC unary codec enforces framing, compression, and message bounds" {
    const grpc = ziac.gcp.grpc;
    const frame = try grpc.frameUnaryAlloc(std.testing.allocator, "hello", .{ .max_message_bytes = 16 });
    defer std.testing.allocator.free(frame);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 5 }, frame[0..5]);
    try std.testing.expectEqualStrings("hello", try grpc.unframeUnary(frame, .{ .max_message_bytes = 16 }));
    try std.testing.expectError(error.MessageTooLarge, grpc.unframeUnary(frame, .{ .max_message_bytes = 4 }));
    const compressed = try std.testing.allocator.dupe(u8, frame);
    defer std.testing.allocator.free(compressed);
    compressed[0] = 1;
    try std.testing.expectError(error.UnsupportedCompression, grpc.unframeUnary(compressed, .{}));
}

test "gRPC capability audit blocks unqualified HTTP2 adapters and parses trailers" {
    const grpc = ziac.gcp.grpc;
    try std.testing.expectError(error.TransportNotQualified, grpc.requireQualified(.{
        .http2 = true,
        .tls = true,
        .trailers = true,
        .deadlines = true,
        .cancellation = true,
        .multiplexing = true,
        .connection_reuse = true,
        .flow_control = false,
        .bounded_messages = true,
        .redacted_diagnostics = true,
    }));
    const status = try grpc.parseTrailers(&.{
        .{ .name = "grpc-status", .value = "8" },
        .{ .name = "grpc-message", .value = "quota%20exceeded" },
    });
    try std.testing.expectEqual(grpc.Code.resource_exhausted, status.code);
    try std.testing.expectEqualStrings("quota%20exceeded", status.message);
}
