const std = @import("std");

pub const CoreError = error{
    EmptyName,
    InvalidName,
    OutOfMemory,
};

pub const PhysicalNameInput = struct {
    stack: []const u8,
    stage: []const u8,
    logical_id: []const u8,
};

pub const Diagnostic = struct {
    code: []const u8,
    message: []const u8,
    subject: []const u8,

    pub fn format(self: Diagnostic, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        return std.fmt.allocPrint(
            allocator,
            "{s}: {s} ({s})",
            .{ self.code, self.message, self.subject },
        );
    }
};

pub fn validateLogicalId(value: []const u8) CoreError!void {
    if (value.len == 0) return error.EmptyName;
    for (value) |char| {
        const ok =
            (char >= 'a' and char <= 'z') or
            (char >= 'A' and char <= 'Z') or
            (char >= '0' and char <= '9') or
            char == '-' or
            char == '_';
        if (!ok) return error.InvalidName;
    }
}

pub fn physicalName(
    allocator: std.mem.Allocator,
    input: PhysicalNameInput,
) CoreError![]const u8 {
    try validateLogicalId(input.stack);
    try validateLogicalId(input.stage);
    try validateLogicalId(input.logical_id);
    return std.fmt.allocPrint(
        allocator,
        "{s}-{s}-{s}",
        .{ input.stack, input.stage, input.logical_id },
    );
}
