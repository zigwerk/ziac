const std = @import("std");
const ziac = @import("ziac");

test "program artifact round trips a user stack with outputs and dependencies" {
    const regions = [_][]const u8{ "europe-west1", "us-central1" };
    const registry = ziac.stack_registry.configuredRegistry(.{
        .project_id = "outside-app",
        .region = regions[0],
        .regions = &regions,
        .service_account = "api@outside-app.iam.gserviceaccount.com",
        .image = "europe-west1-docker.pkg.dev/outside-app/api/app@sha256:abcd",
        .domain = "example.com",
        .dns_zone = "example-zone",
    });
    var source = try registry.build(std.testing.allocator, .{
        .stack = "global-container",
        .stage = "dev",
    });
    defer source.deinit();

    const encoded = try ziac.program_format.encodeAlloc(std.testing.allocator, "global-container", "dev", &source);
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "ziac.program.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "sentinel-secret-for-tests") == null);

    var decoded = try ziac.program_format.decodeAlloc(std.testing.allocator, encoded, .{
        .stack = "global-container",
        .stage = "dev",
    });
    defer decoded.deinit();

    try std.testing.expectEqual(source.graph.resources.items.len, decoded.graph.resources.items.len);
    try std.testing.expectEqual(source.graph.dependencies.items.len, decoded.graph.dependencies.items.len);
    try std.testing.expectEqual(source.outputs.items.len, decoded.outputs.items.len);
    try std.testing.expectEqualStrings(source.graph.resources.items[1].id, decoded.graph.resources.items[1].id);
}

test "program artifact rejects tampering and the wrong invocation target" {
    const regions = [_][]const u8{ "europe-west1", "us-central1" };
    const registry = ziac.stack_registry.configuredRegistry(.{
        .project_id = "outside-app",
        .region = regions[0],
        .regions = &regions,
        .service_account = "api@outside-app.iam.gserviceaccount.com",
        .image = "europe-west1-docker.pkg.dev/outside-app/api/app@sha256:abcd",
        .domain = "example.com",
        .dns_zone = "example-zone",
    });
    var source = try registry.build(std.testing.allocator, .{
        .stack = "global-container",
        .stage = "dev",
    });
    defer source.deinit();
    const encoded = try ziac.program_format.encodeAlloc(std.testing.allocator, "global-container", "dev", &source);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectError(error.ProgramTargetMismatch, ziac.program_format.decodeAlloc(std.testing.allocator, encoded, .{
        .stack = "other",
        .stage = "dev",
    }));

    const tampered = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(tampered);
    const needle = "outside-app";
    const offset = std.mem.lastIndexOf(u8, tampered, needle).?;
    tampered[offset] = 'j';
    try std.testing.expectError(error.ProgramIntegrityMismatch, ziac.program_format.decodeAlloc(std.testing.allocator, tampered, .{
        .stack = "global-container",
        .stage = "dev",
    }));
}

test "project manifest validates a fixed argv program compiler" {
    const manifest =
        \\{"schema":"ziac.project.v1","project":"outside-app","source_roots":["src"],"program":{"argv":["zig","build","ziac-program","--"],"max_output_bytes":8388608},"components":[],"requirements":[],"acceptance_checks":[],"environments":[],"adaptations":[],"scenarios":[],"authority":{"read":true,"plan":true,"apply":false,"delete":false,"secret_read":false,"live_network":false}}
    ;
    var project = try ziac.agent_contract.Project.parseAlloc(std.testing.allocator, manifest);
    defer project.deinit();
    try std.testing.expectEqualStrings("zig", project.program.?.argv[0]);
    try std.testing.expectEqual(@as(usize, 8 * 1024 * 1024), project.program.?.max_output_bytes);

    const unsafe =
        \\{"schema":"ziac.project.v1","project":"outside-app","source_roots":["src"],"program":{"argv":["/bin/sh","-c"],"max_output_bytes":8388608},"components":[],"requirements":[],"acceptance_checks":[],"environments":[],"adaptations":[],"scenarios":[],"authority":{"read":true,"plan":true,"apply":false,"delete":false,"secret_read":false,"live_network":false}}
    ;
    try std.testing.expectError(error.InvalidProgramCompiler, ziac.agent_contract.Project.parseAlloc(std.testing.allocator, unsafe));
}

test "project compiler appends only the requested stack target and validates its artifact" {
    const regions = [_][]const u8{ "europe-west1", "us-central1" };
    const registry = ziac.stack_registry.configuredRegistry(.{
        .project_id = "outside-app",
        .region = regions[0],
        .regions = &regions,
        .service_account = "api@outside-app.iam.gserviceaccount.com",
        .image = "europe-west1-docker.pkg.dev/outside-app/api/app@sha256:abcd",
        .domain = "example.com",
        .dns_zone = "example-zone",
    });
    var source = try registry.build(std.testing.allocator, .{ .stack = "global-container", .stage = "dev" });
    defer source.deinit();
    const artifact = try ziac.program_format.encodeAlloc(std.testing.allocator, "global-container", "dev", &source);
    defer std.testing.allocator.free(artifact);

    var scripted = ziac.project_program.ScriptedRunner.init(artifact);
    var decoded = try ziac.project_program.loadAlloc(std.testing.allocator, .{
        .argv = &.{ "zig", "build", "ziac-program", "--" },
        .max_output_bytes = 8 * 1024 * 1024,
    }, scripted.runner(), .{ .stack = "global-container", .stage = "dev" });
    defer decoded.deinit();

    try std.testing.expectEqual(@as(usize, 1), scripted.call_count);
    try std.testing.expectEqualStrings("global-container", scripted.last_stack.?);
    try std.testing.expectEqualStrings("dev", scripted.last_stage.?);
}

test "project target extraction ignores commands without a complete graph target" {
    const target = ziac.project_program.targetFromArgs(&.{ "plan", "--stack", "api", "--stage", "dev" }).?;
    try std.testing.expectEqualStrings("api", target.stack);
    try std.testing.expectEqualStrings("dev", target.stage);
    try std.testing.expect(ziac.project_program.targetFromArgs(&.{"doctor"}) == null);
    try std.testing.expect(ziac.project_program.targetFromArgs(&.{ "plan", "--stack", "api" }) == null);
}
