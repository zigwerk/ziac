const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const generation = args.next() orelse return error.MissingGeneration;
    const port_text = args.next() orelse return error.MissingPort;
    const port = try std.fmt.parseInt(u16, port_text, 10);

    var address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var server = try address.listen(init.io, .{ .reuse_address = true });
    defer server.deinit(init.io);
    while (true) {
        const stream = server.accept(init.io) catch continue;
        defer stream.close(init.io);
        var read_buffer: [16 * 1024]u8 = undefined;
        var write_buffer: [16 * 1024]u8 = undefined;
        var reader = stream.reader(init.io, &read_buffer);
        var writer = stream.writer(init.io, &write_buffer);
        var http_server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = http_server.receiveHead() catch continue;
        try request.respond(generation, .{
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain" },
            },
        });
    }
}
