const std = @import("std");
const ziac = @import("ziac");
const stack = @import("stack");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip();
    var stack_name: ?[]const u8 = null;
    var stage: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--stack")) stack_name = args.next() orelse return error.MissingStack;
        if (std.mem.eql(u8, arg, "--stage")) stage = args.next() orelse return error.MissingStage;
    }
    const target = ziac.program_format.Target{
        .stack = stack_name orelse return error.MissingStack,
        .stage = stage orelse return error.MissingStage,
    };
    var program = try stack.build(init.gpa, init, .{ .stack = target.stack, .stage = target.stage });
    defer program.deinit();
    const artifact = try ziac.program_format.encodeAlloc(init.gpa, target.stack, target.stage, &program);
    defer init.gpa.free(artifact);
    try std.Io.File.stdout().writeStreamingAll(init.io, artifact);
}
