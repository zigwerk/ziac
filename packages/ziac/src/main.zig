const std = @import("std");
const ziac = @import("ziac");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var console = ziac.zstd.Console.CapturedConsole.init(allocator);
    defer console.deinit();

    var args = std.ArrayList([]const u8).empty;
    defer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }

    var iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer iterator.deinit();
    _ = iterator.skip();
    while (iterator.next()) |arg| {
        try args.append(allocator, try allocator.dupe(u8, arg));
    }

    var cwd = std.Io.Dir.cwd();
    var local_fs = ziac.zstd.FileSystem.LocalFileSystem.init(&cwd, io);
    var env = ziac.cli.Env{
        .console = &console,
        .registry = ziac.stack_registry.fixtureRegistry(),
        .state = ziac.local_state.Store.init(allocator, ziac.local_state.localFiles.store(&local_fs)),
    };

    const code = try ziac.cli.run(allocator, args.items, &env);
    if (console.stdoutText().len > 0) {
        try std.Io.File.stdout().writeStreamingAll(io, console.stdoutText());
    }
    if (console.stderrText().len > 0) {
        try std.Io.File.stderr().writeStreamingAll(io, console.stderrText());
    }
    std.process.exit(code);
}
