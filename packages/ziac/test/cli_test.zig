const std = @import("std");
const ziac = @import("ziac");

fn testEnv(
    fs: *ziac.zstd.FileSystem.MemoryFileSystem,
    console: *ziac.zstd.Console.CapturedConsole,
) ziac.cli.Env {
    return .{
        .console = console,
        .registry = ziac.stack_registry.fixtureRegistry(),
        .state = ziac.local_state.Store.init(std.testing.allocator, ziac.local_state.memoryFiles(fs)),
    };
}

test "cli plan prints deterministic create summary without writing state" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();

    var env = testEnv(&fs, &console);
    const code = try ziac.cli.run(std.testing.allocator, &.{ "plan", "--stack", "hello-global", "--stage", "dev" }, &env);

    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "Plan: 2 create, 0 update, 0 delete, 0 noop") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "+ gcp.artifact.Repository hello-global") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "+ gcp.run.Service api") != null);
    try std.testing.expect(!fs.exists(".ziac/state/hello-global/dev/resources.json"));
}

test "cli deploy persists state and redacted outputs" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();

    var env = testEnv(&fs, &console);
    const code = try ziac.cli.run(std.testing.allocator, &.{ "deploy", "--stack", "hello-global", "--stage", "dev" }, &env);

    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(fs.exists(".ziac/state/hello-global/dev/resources.json"));
    try std.testing.expect(fs.exists(".ziac/state/hello-global/dev/outputs.json"));
    const outputs = fs.readFile(".ziac/state/hello-global/dev/outputs.json").?;
    try std.testing.expect(std.mem.indexOf(u8, outputs, "sentinel-secret-for-tests") == null);
}

test "cli outputs prints redacted secret values" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var env = testEnv(&fs, &console);

    _ = try ziac.cli.run(std.testing.allocator, &.{ "deploy", "--stack", "hello-global", "--stage", "dev" }, &env);
    console.stdout.clearRetainingCapacity();
    const code = try ziac.cli.run(std.testing.allocator, &.{ "outputs", "--stack", "hello-global", "--stage", "dev" }, &env);

    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "service_url=https://api-europe-west1-ziac-dev.run.app") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "repository_url=europe-west1-docker.pkg.dev/ziac-dev/hello-global") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "database_url=[REDACTED]") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "sentinel-secret-for-tests") == null);
}

test "cli destroy marks resource deleted" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var env = testEnv(&fs, &console);

    _ = try ziac.cli.run(std.testing.allocator, &.{ "deploy", "--stack", "hello-global", "--stage", "dev" }, &env);
    console.stdout.clearRetainingCapacity();
    const code = try ziac.cli.run(std.testing.allocator, &.{ "destroy", "--stack", "hello-global", "--stage", "dev" }, &env);

    try std.testing.expectEqual(@as(u8, 0), code);
    const resources = fs.readFile(".ziac/state/hello-global/dev/resources.json").?;
    try std.testing.expect(std.mem.indexOf(u8, resources, "\"status\":\"deleted\"") != null);
}

test "cli state prints persisted resource status" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var console = ziac.zstd.Console.CapturedConsole.init(std.testing.allocator);
    defer console.deinit();
    var env = testEnv(&fs, &console);

    _ = try ziac.cli.run(std.testing.allocator, &.{ "deploy", "--stack", "hello-global", "--stage", "dev" }, &env);
    console.stdout.clearRetainingCapacity();
    const code = try ziac.cli.run(std.testing.allocator, &.{ "state", "--stack", "hello-global", "--stage", "dev" }, &env);

    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "gcp.artifact.Repository.europe-west1.hello-global created") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.stdoutText(), "gcp.run.Service.europe-west1.api created") != null);
}
