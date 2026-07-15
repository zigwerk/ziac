const std = @import("std");

pub const Env = struct {};
const ok = "{\"status\":\"ok\"}";

pub fn main() !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var address = try std.Io.net.IpAddress.parseIp4("0.0.0.0", 8080);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    while (true) {
        const stream = server.accept(io) catch continue;
        handle(io, stream) catch {};
    }
}

fn handle(io: std.Io, stream: std.Io.net.Stream) !void {
    defer stream.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    var request = try server.receiveHead();
    const found = routeFound(request.head.target);
    try request.respond(if (found) ok else "{\"error\":\"not found\"}", .{ .status = if (found) .ok else .not_found, .keep_alive = false, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
}

fn routeFound(target: []const u8) bool {
    return std.mem.eql(u8, target, "/") or std.mem.eql(u8, target, "/health/live") or std.mem.eql(u8, target, "/health/startup");
}

test "health endpoints are exact" {
    try std.testing.expect(routeFound("/health/live"));
    try std.testing.expect(!routeFound("/missing"));
}
