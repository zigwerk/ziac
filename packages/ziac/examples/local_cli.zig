const std = @import("std");
const ziac = @import("ziac");

pub fn runLocalCliExample(allocator: std.mem.Allocator) ![]const u8 {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(allocator);
    defer console.deinit();
    var local = ziac.state_backend.Local.init(ziac.local_state.Store.init(
        allocator,
        ziac.local_state.memoryFiles(&fs),
    ));

    var env = ziac.cli.Env{
        .console = &console,
        .registry = ziac.stack_registry.fixtureRegistry(),
        .state = local.store(),
    };

    _ = try ziac.cli.run(allocator, &.{ "plan", "--stack", "hello-global", "--stage", "dev" }, &env);
    _ = try ziac.cli.run(allocator, &.{ "deploy", "--stack", "hello-global", "--stage", "dev" }, &env);
    _ = try ziac.cli.run(allocator, &.{ "outputs", "--stack", "hello-global", "--stage", "dev" }, &env);

    return allocator.dupe(u8, console.stdoutText());
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const output = try runLocalCliExample(allocator);
    defer allocator.free(output);
    std.debug.print("{s}", .{output});
}

test "local CLI example plans deploys and prints redacted outputs" {
    const output = try runLocalCliExample(std.testing.allocator);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "Plan: 2 create") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Deploy complete") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "repository_url=europe-west1-docker.pkg.dev/ziac-dev/hello-global") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "database_url=[REDACTED]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "sentinel-secret-for-tests") == null);
}
