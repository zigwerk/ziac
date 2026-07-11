const std = @import("std");
const proto = @import("proto_contract.zig");

pub fn main(init: std.process.Init) !void {
    try proto.verifyEmbeddedLock();
    const snapshot = try proto.snapshotJsonAlloc(init.gpa, proto.embedded_descriptor);
    defer init.gpa.free(snapshot);
    try std.Io.File.stdout().writeStreamingAll(init.io, snapshot);
}
