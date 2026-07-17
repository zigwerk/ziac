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
    try std.testing.expect(rendered.file("zigeffect.project.json") != null);
    try std.testing.expect(rendered.file(".zigeffect/compatibility.json") != null);
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
    inline for (.{ "ziac-provider-development", "ziac-provider-maintenance", "ziac-provider-qualification" }) |skill_name| {
        inline for (.{ ".agents/skills/", ".claude/skills/", ".gemini/skills/" }) |prefix| {
            const path = prefix ++ skill_name ++ "/SKILL.md";
            try std.testing.expect(rendered.file(path) != null);
        }
    }
    inline for (.{ "ziac-provider-creator", "ziac-provider-maintainer", "ziac-provider-qualifier" }) |agent_name| {
        try std.testing.expect(rendered.file(".codex/agents/" ++ agent_name ++ ".toml") != null);
        try std.testing.expect(rendered.file(".claude/agents/" ++ agent_name ++ ".md") != null);
        try std.testing.expect(rendered.file(".gemini/agents/" ++ agent_name ++ ".md") != null);
    }
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
    const effect_manifest = rendered.file("zigeffect.project.json").?;
    var parsed_effect = try ziac.zstd.Project.parseManifest(std.testing.allocator, effect_manifest);
    defer parsed_effect.deinit();
    try std.testing.expectEqualStrings("global-api", parsed_effect.value.name);
    try std.testing.expectEqualStrings("global-api", parsed_effect.value.components[0].id);

    try std.testing.expect(std.mem.indexOf(u8, rendered.file("ziac.stack.zig").?, "gcp.global.ZigService") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.file("build.zig").?, "zigeffect_test_runner") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.file("build.zig").?, "zigeffect_std") != null);
    const app_source = rendered.file("src/main.zig").?;
    try std.testing.expect(std.mem.indexOf(u8, app_source, "kernel.Service(") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_source, "zstd.ManagedRuntime") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_source, "TestContext") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_source, "mapCausalEventIds") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_source, "TestContext.initFromProject") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_source, "ProcessInputs") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_source, "Stateful(std.process.Init)") == null);
    try std.testing.expect(std.mem.indexOf(u8, app_source, "context.publish") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_source, "project_graph.recordJsonAlloc") != null);
    try std.testing.expect(std.mem.indexOf(u8, app_source, "tmp.dir, main_layer") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.file("build.zig.zon").?, "../../opt/ziac") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.file(".zigeffect/compatibility.json").?, "\"template_version\":15") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, codex_skill, "## Ecosystem layers") != null);
    try std.testing.expect(std.mem.indexOf(u8, codex_skill, "ziac registry search") != null);
    try std.testing.expect(std.mem.indexOf(u8, codex_skill, "ziac package verify") != null);
    for ([_][]const u8{
        "ziac_context",
        "zigeffect agent context",
        ".zigeffect/tests/process-receipts/",
        ".zigeffect/tests/raw-receipts/",
        ".zigeffect/handoffs/tests/",
        "zigeffect graph path",
        "work packet",
        "project-mounted graph",
        "Re-query",
    }) |contract| try std.testing.expect(std.mem.indexOf(u8, codex_skill, contract) != null);
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

    const provider_development = rendered.file(".agents/skills/ziac-provider-development/SKILL.md").?;
    try std.testing.expect(std.mem.startsWith(u8, provider_development, "---\nname: ziac-provider-development\n"));
    try std.testing.expect(std.mem.indexOf(u8, provider_development, "ziac.provider.rpc.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, provider_development, "first-party") != null);
    try std.testing.expect(std.mem.indexOf(u8, provider_development, "third-party") != null);
    try std.testing.expect(std.mem.indexOf(u8, provider_development, "gcp-developer-researcher") != null);
    try std.testing.expect(std.mem.indexOf(u8, provider_development, "zig build provider-rpc-test") != null);
    try std.testing.expect(std.mem.indexOf(u8, provider_development, "ziac package verify") != null);
    try std.testing.expect(std.mem.indexOf(u8, provider_development, "zigeffect agent context") != null);
    try std.testing.expect(std.mem.indexOf(u8, provider_development, ".zigeffect/handoffs/tests/") != null);
    try std.testing.expectEqualStrings(provider_development, rendered.file(".claude/skills/ziac-provider-development/SKILL.md").?);
    try std.testing.expectEqualStrings(provider_development, rendered.file(".gemini/skills/ziac-provider-development/SKILL.md").?);

    const provider_maintenance = rendered.file(".agents/skills/ziac-provider-maintenance/SKILL.md").?;
    try std.testing.expect(std.mem.startsWith(u8, provider_maintenance, "---\nname: ziac-provider-maintenance\n"));
    try std.testing.expect(std.mem.indexOf(u8, provider_maintenance, "semantic upgrade report") != null);
    try std.testing.expect(std.mem.indexOf(u8, provider_maintenance, "state migration") != null);
    try std.testing.expect(std.mem.indexOf(u8, provider_maintenance, "self-qualify") != null);
    try std.testing.expect(std.mem.indexOf(u8, provider_maintenance, "zigeffect agent context") != null);
    try std.testing.expect(std.mem.indexOf(u8, provider_maintenance, "proof handoff") != null);
    try std.testing.expectEqualStrings(provider_maintenance, rendered.file(".claude/skills/ziac-provider-maintenance/SKILL.md").?);
    try std.testing.expectEqualStrings(provider_maintenance, rendered.file(".gemini/skills/ziac-provider-maintenance/SKILL.md").?);

    const provider_qualification = rendered.file(".agents/skills/ziac-provider-qualification/SKILL.md").?;
    try std.testing.expect(std.mem.startsWith(u8, provider_qualification, "---\nname: ziac-provider-qualification\n"));
    try std.testing.expect(std.mem.indexOf(u8, provider_qualification, "immutable package digest") != null);
    try std.testing.expect(std.mem.indexOf(u8, provider_qualification, "Do not repair") != null);
    try std.testing.expect(std.mem.indexOf(u8, provider_qualification, "cloud_qualified") != null);
    try std.testing.expect(std.mem.indexOf(u8, provider_qualification, "source revision") != null);
    try std.testing.expect(std.mem.indexOf(u8, provider_qualification, "receipt digest") != null);
    try std.testing.expectEqualStrings(provider_qualification, rendered.file(".claude/skills/ziac-provider-qualification/SKILL.md").?);
    try std.testing.expectEqualStrings(provider_qualification, rendered.file(".gemini/skills/ziac-provider-qualification/SKILL.md").?);

    const provider_creator = rendered.file(".codex/agents/ziac-provider-creator.toml").?;
    const provider_maintainer = rendered.file(".codex/agents/ziac-provider-maintainer.toml").?;
    const provider_qualifier = rendered.file(".codex/agents/ziac-provider-qualifier.toml").?;
    try std.testing.expect(std.mem.indexOf(u8, provider_creator, "sandbox_mode = \"workspace-write\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, provider_creator, "Do not apply") != null);
    try std.testing.expect(std.mem.indexOf(u8, provider_creator, "proof-carrying") != null);
    try std.testing.expect(std.mem.indexOf(u8, provider_maintainer, "self-qualify") != null);
    try std.testing.expect(std.mem.indexOf(u8, provider_maintainer, "proof handoff") != null);
    try std.testing.expect(std.mem.indexOf(u8, provider_qualifier, "Do not edit candidate source") != null);
    try std.testing.expect(std.mem.indexOf(u8, provider_qualifier, "receipt digest") != null);

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
    try std.testing.expect(std.mem.indexOf(u8, codex, "agents.ziac_provider_creator") != null);
    try std.testing.expect(std.mem.indexOf(u8, codex, "agents.ziac_provider_maintainer") != null);
    try std.testing.expect(std.mem.indexOf(u8, codex, "agents.ziac_provider_qualifier") != null);
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
    const root_provider_agent = try tmp.dir.readFileAlloc(std.testing.io, ".claude/agents/ziac-provider-creator.md", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(root_provider_agent);
    try std.testing.expect(std.mem.indexOf(u8, root_provider_agent, "ziac-provider-development") != null);
    const root_provider_skill = try tmp.dir.readFileAlloc(std.testing.io, ".agents/skills/ziac-provider-qualification/SKILL.md", std.testing.allocator, .limited(64 * 1024));
    defer std.testing.allocator.free(root_provider_skill);
    try std.testing.expect(std.mem.indexOf(u8, root_provider_skill, "immutable package digest") != null);
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
