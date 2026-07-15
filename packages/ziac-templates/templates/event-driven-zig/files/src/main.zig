const std = @import("std");

pub const Env = struct {};

pub fn main() void {}

test "event envelope validation is deterministic" {
    try std.testing.expect(validEvent("order.created"));
    try std.testing.expect(!validEvent(""));
}

fn validEvent(name: []const u8) bool {
    return name.len > 0 and std.mem.indexOfAny(u8, name, "\r\n") == null;
}
