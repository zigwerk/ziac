const std = @import("std");
const ziac = @import("ziac");

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const fixture_path = args.next() orelse return error.MissingFixturePath;

    var proxy = ziac.dev_native.StableProxy.init(init.gpa, init.io, 0);
    try proxy.start();
    defer proxy.deinit();

    var runtime = ziac.dev_native.NativeRuntime.init(init.gpa, init.io, &proxy, .{
        .build_argv = &.{ "/bin/sh", "-c", "true" },
        .process_argv = &.{fixture_path},
        .readiness_attempts = 80,
        .readiness_interval_millis = 10,
    });
    defer runtime.deinit();
    var supervisor = ziac.dev.Supervisor.init(init.gpa);
    defer supervisor.deinit();

    const watch_path = ".zig-cache/ziac-dev-watch-e2e";
    var cwd = std.Io.Dir.cwd();
    cwd.deleteTree(init.io, watch_path) catch {};
    defer cwd.deleteTree(init.io, watch_path) catch {};
    try cwd.createDirPath(init.io, watch_path);
    var watch_dir = try cwd.openDir(init.io, watch_path, .{ .iterate = true });
    defer watch_dir.close(init.io);
    try watch_dir.writeFile(init.io, .{ .sub_path = "version.txt", .data = "first" });
    var digest_source = ziac.dev_native.DirectoryDigestSource.init(init.io, watch_dir);
    var watcher = ziac.dev_native.WatchSession.init(
        init.gpa,
        &supervisor,
        runtime.runtime(),
        digest_source.source(),
        45210,
    );
    defer watcher.deinit();

    const first = try watcher.start();
    if (first.status != .promoted) return error.FirstGenerationNotPromoted;
    try expectGeneration(init, &proxy, "1");

    if (try watcher.pollOnce() != null) return error.UnchangedSourceReloaded;
    try watch_dir.writeFile(init.io, .{ .sub_path = "version.txt", .data = "second" });
    const second = (try watcher.pollOnce()) orelse return error.ChangedSourceNotReloaded;
    if (second.status != .promoted) return error.SecondGenerationNotPromoted;
    try expectGeneration(init, &proxy, "2");

    runtime.config.build_argv = &.{ "/bin/sh", "-c", "false" };
    try watch_dir.writeFile(init.io, .{ .sub_path = "version.txt", .data = "broken" });
    const failed = (try watcher.pollOnce()) orelse return error.BrokenSourceNotAttempted;
    if (failed.status != .build_failed) return error.BuildFailureNotRecorded;
    try expectGeneration(init, &proxy, "2");
}

fn expectGeneration(init: std.process.Init, proxy: *const ziac.dev_native.StableProxy, expected: []const u8) !void {
    const url = try proxy.urlAlloc(init.gpa, "/");
    defer init.gpa.free(url);
    var client = ziac.zstd.Http.LocalClient.init(init.gpa, init.io);
    defer client.deinit();
    var response = try client.sendAlloc(init.gpa, .{ .method = "GET", .url = url });
    defer response.deinit(init.gpa);
    if (!std.mem.eql(u8, response.body, expected)) return error.UnexpectedGeneration;
}
