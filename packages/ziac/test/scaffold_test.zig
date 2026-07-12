const std = @import("std");
const ziac = @import("ziac");

test "scaffold renders a complete agent-first global Zig project" {
    var rendered = try ziac.scaffold.renderAlloc(std.testing.allocator, .{
        .project_name = "global-api",
        .ziac_path = "../../opt/ziac",
    });
    defer rendered.deinit();

    try std.testing.expect(rendered.file("build.zig") != null);
    try std.testing.expect(rendered.file("build.zig.zon") != null);
    try std.testing.expect(rendered.file("ziac.project.json") != null);
    try std.testing.expect(rendered.file("ziac.stack.zig") != null);
    try std.testing.expect(rendered.file("ziac_program.zig") != null);
    try std.testing.expect(rendered.file("src/main.zig") != null);
    try std.testing.expect(rendered.file(".agents/skills/ziac/SKILL.md") != null);
    try std.testing.expect(rendered.file(".claude/skills/ziac/SKILL.md") != null);
    try std.testing.expect(rendered.file(".gemini/skills/ziac/SKILL.md") != null);
    try std.testing.expect(rendered.file("GEMINI.md") != null);
    try std.testing.expect(rendered.file(".mcp.json") != null);
    try std.testing.expect(rendered.file(".codex/config.toml") != null);
    try std.testing.expect(rendered.file(".gemini/settings.json") != null);

    const manifest = rendered.file("ziac.project.json").?;
    var project = try ziac.agent_contract.Project.parseAlloc(std.testing.allocator, manifest);
    defer project.deinit();
    try std.testing.expectEqualStrings("global-api", project.id);
    try std.testing.expectEqualStrings("zig", project.program.?.argv[0]);
    try std.testing.expect(project.development != null);

    try std.testing.expect(std.mem.indexOf(u8, rendered.file("ziac.stack.zig").?, "gcp.global.ZigService") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.file("build.zig").?, "zigeffect_test_runner") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.file("build.zig.zon").?, "../../opt/ziac") != null);
    const codex_skill = rendered.file(".agents/skills/ziac/SKILL.md").?;
    try std.testing.expect(std.mem.startsWith(u8, codex_skill, "---\nname: ziac\n"));
    try std.testing.expect(std.mem.indexOf(u8, codex_skill, "ziac check --stack global-api --stage dev --json") != null);
    try std.testing.expect(std.mem.indexOf(u8, codex_skill, "integrity-checked saved plan") != null);
    try std.testing.expectEqualStrings(codex_skill, rendered.file(".claude/skills/ziac/SKILL.md").?);
    try std.testing.expectEqualStrings(codex_skill, rendered.file(".gemini/skills/ziac/SKILL.md").?);
}

test "scaffold rejects ambiguous names and unsafe dependency paths" {
    try std.testing.expectError(error.InvalidProjectName, ziac.scaffold.renderAlloc(std.testing.allocator, .{
        .project_name = "Not Safe",
        .ziac_path = "../../opt/ziac",
    }));
    try std.testing.expectError(error.InvalidZiacPath, ziac.scaffold.renderAlloc(std.testing.allocator, .{
        .project_name = "safe-name",
        .ziac_path = "/absolute/ziac",
    }));
}

test "scaffold derives a stable package name from a fresh Git directory" {
    const name = try ziac.scaffold.projectNameAlloc(std.testing.allocator, "My Fresh_API.project-73AB");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("my-fresh-api-project-73ab", name);
    try std.testing.expectError(error.InvalidProjectName, ziac.scaffold.projectNameAlloc(std.testing.allocator, "..."));
}

test "scaffold writes without overwriting an existing project" {
    var rendered = try ziac.scaffold.renderAlloc(std.testing.allocator, .{
        .project_name = "global-api",
        .ziac_path = "../../opt/ziac",
    });
    defer rendered.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try ziac.scaffold.write(tmp.dir, std.testing.io, rendered, false);
    const manifest = try tmp.dir.readFileAlloc(std.testing.io, "ziac.project.json", std.testing.allocator, .limited(1024 * 1024));
    defer std.testing.allocator.free(manifest);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "global-api") != null);
    try std.testing.expectError(error.ProjectFileExists, ziac.scaffold.write(tmp.dir, std.testing.io, rendered, false));
}
