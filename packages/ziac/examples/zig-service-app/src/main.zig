const std = @import("std");
const builtin = @import("builtin");

const ok = "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 15\r\nconnection: close\r\n\r\n{\"status\":\"ok\"}";
const not_found = "HTTP/1.1 404 Not Found\r\ncontent-type: application/json\r\ncontent-length: 21\r\nconnection: close\r\n\r\n{\"error\":\"not found\"}";

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
        defer stream.close(io);
        var read_buffer: [4096]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        var request: [4096]u8 = undefined;
        const length = reader.interface.readSliceShort(&request) catch continue;
        const response = responseFor(request[0..length]);
        var write_buffer: [4096]u8 = undefined;
        var writer = stream.writer(io, &write_buffer);
        writer.interface.writeAll(response) catch continue;
        writer.interface.flush() catch continue;
    }
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
    return if (std.mem.startsWith(u8, request, "GET /health/startup ") or
        std.mem.startsWith(u8, request, "GET /health/live ") or
        std.mem.startsWith(u8, request, "GET / ")) ok else not_found;
}

fn writeAllLegacy(file_descriptor: anytype, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        offset += try std.posix.write(file_descriptor, bytes[offset..]);
    }
}

test "sample HTTP responses have exact content lengths" {
    try expectContentLength(ok);
    try expectContentLength(not_found);
}

fn expectContentLength(response: []const u8) !void {
    const separator = "\r\n\r\n";
    const split = std.mem.indexOf(u8, response, separator) orelse return error.InvalidResponse;
    const marker = "content-length: ";
    const start = (std.mem.indexOf(u8, response[0..split], marker) orelse return error.InvalidResponse) + marker.len;
    const end = std.mem.indexOfPos(u8, response, start, "\r\n") orelse return error.InvalidResponse;
    const declared = try std.fmt.parseInt(usize, response[start..end], 10);
    try std.testing.expectEqual(declared, response[split + separator.len ..].len);
}
