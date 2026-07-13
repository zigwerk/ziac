const std = @import("std");
const builtin = @import("builtin");

const ok = "{\"status\":\"ok\"}";
const not_found = "{\"error\":\"not found\"}";

pub fn main() !void {
    if (comptime builtin.zig_version.minor >= 16) {
        return mainCurrent();
    }
    return mainLegacy();
}

fn mainCurrent() !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    var address = try std.Io.net.IpAddress.parseIp4("0.0.0.0", 8080);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    while (true) {
        const stream = server.accept(io) catch continue;
        handleCurrent(io, stream) catch {};
    }
}

fn handleCurrent(io: std.Io, stream: std.Io.net.Stream) !void {
    defer stream.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var write_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    var request = try server.receiveHead();
    const found = routeFound(request.head.target);
    try request.respond(if (found) ok else not_found, .{
        .status = if (found) .ok else .not_found,
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

fn mainLegacy() !void {
    const address = try std.net.Address.parseIp4("0.0.0.0", 8080);
    var server = try address.listen(.{ .reuse_address = true });
    defer server.deinit();

    while (true) {
        const connection = server.accept() catch continue;
        handleLegacy(connection.stream);
    }
}

fn handleLegacy(stream: anytype) void {
    defer stream.close();
    var request: [4096]u8 = undefined;
    const length = std.posix.read(stream.handle, &request) catch return;
    writeAllLegacy(stream.handle, responseFor(request[0..length])) catch {};
}

fn responseFor(request: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, request, "GET ") and routeFound(request[4 .. std.mem.indexOfScalarPos(u8, request, 4, ' ') orelse request.len])) ok else not_found;
}

fn routeFound(target: []const u8) bool {
    return std.mem.eql(u8, target, "/health/startup") or
        std.mem.eql(u8, target, "/health/live") or
        std.mem.eql(u8, target, "/");
}

fn writeAllLegacy(file_descriptor: anytype, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        offset += try std.posix.write(file_descriptor, bytes[offset..]);
    }
}

test "sample HTTP routing is exact" {
    try std.testing.expectEqualStrings(ok, responseFor("GET /health/live HTTP/1.1\r\n"));
    try std.testing.expectEqualStrings(not_found, responseFor("GET /missing HTTP/1.1\r\n"));
}
