const std = @import("std");

pub const current_version: u32 = 2;

pub fn lineageAlloc(
    allocator: std.mem.Allocator,
    stack: []const u8,
    stage: []const u8,
) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ stack, stage });
}
