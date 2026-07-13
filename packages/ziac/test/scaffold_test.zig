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
    try std.testing.expect(rendered.file(".agents/skills/gcp-developer-research/SKILL.md") != null);
    try std.testing.expect(rendered.file(".claude/skills/gcp-developer-research/SKILL.md") != null);
    try std.testing.expect(rendered.file(".gemini/skills/gcp-developer-research/SKILL.md") != null);
    try std.testing.expect(rendered.file(".codex/agents/gcp-developer-researcher.toml") != null);
    try std.testing.expect(rendered.file(".claude/agents/gcp-developer-researcher.md") != null);
    try std.testing.expect(rendered.file(".gemini/agents/gcp-developer-researcher.md") != null);
    try std.testing.expect(rendered.file(".env.example") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, codex_skill, "merged canvas") != null);
    try std.testing.expect(std.mem.indexOf(u8, codex_skill, "smallest project that owns") != null);
    try std.testing.expect(std.mem.indexOf(u8, codex_skill, "gcp-developer-researcher") != null);
    try std.testing.expect(std.mem.indexOf(u8, codex_skill, "build.zig.zon") != null);
    try std.testing.expect(std.mem.indexOf(u8, codex_skill, "docs/agent-development-kit.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, codex_skill, "docs/gcp-provider-coverage.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, codex_skill, "ziac provider resources --json") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"dashboard\": { \"stack\": \"global-api\", \"stage\": \"dev\" }") != null);
    try std.testing.expectEqualStrings(codex_skill, rendered.file(".claude/skills/ziac/SKILL.md").?);
    try std.testing.expectEqualStrings(codex_skill, rendered.file(".gemini/skills/ziac/SKILL.md").?);

    const research_skill = rendered.file(".agents/skills/gcp-developer-research/SKILL.md").?;
    try std.testing.expect(std.mem.startsWith(u8, research_skill, "---\nname: gcp-developer-research\n"));
    try std.testing.expect(std.mem.indexOf(u8, research_skill, "search_documents") != null);
    try std.testing.expect(std.mem.indexOf(u8, research_skill, "get_documents") != null);
    try std.testing.expect(std.mem.indexOf(u8, research_skill, "Finding") != null);
    try std.testing.expect(std.mem.indexOf(u8, research_skill, "Recommended Ziac implication") != null);
    try std.testing.expect(std.mem.indexOf(u8, research_skill, "exact API or reference") != null);
    try std.testing.expect(std.mem.indexOf(u8, research_skill, "Never mutate") != null);
    try std.testing.expect(std.mem.indexOf(u8, research_skill, "docs/gcp-specialization.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, research_skill, "current GCP behavior") != null);
    try std.testing.expectEqualStrings(research_skill, rendered.file(".claude/skills/gcp-developer-research/SKILL.md").?);
    try std.testing.expectEqualStrings(research_skill, rendered.file(".gemini/skills/gcp-developer-research/SKILL.md").?);

    const codex_agent = rendered.file(".codex/agents/gcp-developer-researcher.toml").?;
    const claude_agent = rendered.file(".claude/agents/gcp-developer-researcher.md").?;
    const gemini_agent = rendered.file(".gemini/agents/gcp-developer-researcher.md").?;
    try std.testing.expect(std.mem.indexOf(u8, codex_agent, "sandbox_mode = \"read-only\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, claude_agent, "permissionMode: plan") != null);
    try std.testing.expect(std.mem.indexOf(u8, claude_agent, "disallowedTools: Write, Edit") != null);
    try std.testing.expect(std.mem.indexOf(u8, gemini_agent, "gcp-developer-research") != null);

    const mcp = rendered.file(".mcp.json").?;
    const codex = rendered.file(".codex/config.toml").?;
    const gemini = rendered.file(".gemini/settings.json").?;
    inline for (.{ mcp, codex, gemini }) |config| {
        try std.testing.expect(std.mem.indexOf(u8, config, "https://developerknowledge.googleapis.com/mcp") != null);
        try std.testing.expect(std.mem.indexOf(u8, config, "DEVELOPERKNOWLEDGE_API_KEY") != null);
    }
    inline for (.{ codex, gemini }) |config| {
        try std.testing.expect(std.mem.indexOf(u8, config, "search_documents") != null);
        try std.testing.expect(std.mem.indexOf(u8, config, "get_documents") != null);
    }
    try std.testing.expectEqualStrings("DEVELOPERKNOWLEDGE_API_KEY=", rendered.file(".env.example").?);
    try std.testing.expect(std.mem.indexOf(u8, mcp, "AIza") == null);
}

test "workspace agent files install a root-safe GCP researcher without a child MCP path" {
    var rendered = try ziac.scaffold.renderAlloc(std.testing.allocator, .{
        .project_name = "global-api",
        .ziac_path = "../../opt/ziac",
    });
    defer rendered.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try ziac.scaffold.writeWorkspaceAgentFiles(tmp.dir, std.testing.io, rendered);

    const root_mcp = try tmp.dir.readFileAlloc(std.testing.io, ".mcp.json", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(root_mcp);
    try std.testing.expect(std.mem.indexOf(u8, root_mcp, "google-developer-knowledge") != null);
    try std.testing.expect(std.mem.indexOf(u8, root_mcp, "ziac.project.json") == null);
    const root_codex = try tmp.dir.readFileAlloc(std.testing.io, ".codex/config.toml", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(root_codex);
    try std.testing.expect(std.mem.indexOf(u8, root_codex, "gcp_developer_researcher") != null);
    try std.testing.expect(std.mem.indexOf(u8, root_codex, "ziac.project.json") == null);
    const root_agent = try tmp.dir.readFileAlloc(std.testing.io, ".claude/agents/gcp-developer-researcher.md", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(root_agent);
    try std.testing.expect(std.mem.indexOf(u8, root_agent, "permissionMode: plan") != null);
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
