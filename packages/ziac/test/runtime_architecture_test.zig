const std = @import("std");

fn readSource(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(2 * 1024 * 1024));
}

test "every shipped Ziac process root is owned by the canonical managed runtime" {
    const roots = [_][]const u8{
        "src/main.zig",
        "src/mcp_server_main.zig",
        "src/dashboard_host_main.zig",
        "src/provider_gcp_main.zig",
        "src/provider_cockroach_main.zig",
        "src/estate_control_plane_main.zig",
        "src/billing_worker_main.zig",
    };
    for (roots) |path| {
        const source = try readSource(path);
        defer std.testing.allocator.free(source);
        try std.testing.expect(std.mem.indexOf(u8, source, "ziac.process_runtime.run") != null);
    }
}

test "Ziac production roots do not create legacy or nested runtimes" {
    const paths = [_][]const u8{
        "src/main.zig",
        "src/application.zig",
        "src/executor.zig",
        "src/mcp_server_main.zig",
        "src/dashboard_host_main.zig",
        "src/provider_gcp_main.zig",
        "src/provider_cockroach_main.zig",
        "src/estate_control_plane_main.zig",
        "src/billing_worker_main.zig",
    };
    for (paths) |path| {
        const source = try readSource(path);
        defer std.testing.allocator.free(source);
        try std.testing.expect(std.mem.indexOf(u8, source, "fx.Runtime(") == null);
        try std.testing.expect(std.mem.indexOf(u8, source, "fx.layerGraph") == null);
        try std.testing.expect(std.mem.indexOf(u8, source, "zstd.fx.layerGraph") == null);
    }
}

test "provider and MCP protocol requests execute as child effects" {
    inline for (.{ "src/provider_gcp_main.zig", "src/provider_cockroach_main.zig" }) |path| {
        const source = try readSource(path);
        defer std.testing.allocator.free(source);
        try std.testing.expect(std.mem.indexOf(u8, source, "serveStdioEffectful") != null);
    }
    const mcp = try readSource("src/mcp_server_main.zig");
    defer std.testing.allocator.free(mcp);
    try std.testing.expect(std.mem.indexOf(u8, mcp, "ctx.runtime()") != null);
    try std.testing.expect(std.mem.indexOf(u8, mcp, ".named(\"mcp.request\")") != null);
    const dashboard = try readSource("src/dashboard_host_main.zig");
    defer std.testing.allocator.free(dashboard);
    try std.testing.expect(std.mem.indexOf(u8, dashboard, "dashboard_runtime = ctx.runtime()") != null);
    try std.testing.expect(std.mem.indexOf(u8, dashboard, "callbackEffect") != null);
}

test "Ziac exposes stable external capability tags rather than a planner service" {
    const source = try readSource("src/application.zig");
    defer std.testing.allocator.free(source);
    inline for (.{
        "ziac/ProjectCompiler",
        "ziac/StateStore",
        "ziac/ProviderRegistry",
        "ziac/ProcessSpawner",
    }) |service_key| {
        try std.testing.expect(std.mem.indexOf(u8, source, service_key) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, source, "pub const Planner = struct") == null);
}

test "Ziac owns both executable infrastructure and ZigEffect project intent" {
    const ziac_manifest = try readSource("ziac.project.json");
    defer std.testing.allocator.free(ziac_manifest);
    try std.testing.expect(std.mem.indexOf(u8, ziac_manifest, "\"program\"") != null);
    const effect_manifest = try readSource("zigeffect.project.json");
    defer std.testing.allocator.free(effect_manifest);
    try std.testing.expect(std.mem.indexOf(u8, effect_manifest, "effect-native-plan-execute") != null);
}

test "registry templates preserve the effectful application and pure compiler boundary" {
    inline for (.{ "global-zig-api", "event-driven-zig" }) |template| {
        const source_path = "../ziac-templates/templates/" ++ template ++ "/files/src/main.zig";
        const source = try readSource(source_path);
        defer std.testing.allocator.free(source);
        try std.testing.expect(std.mem.indexOf(u8, source, "kernel.Service(") != null);
        try std.testing.expect(std.mem.indexOf(u8, source, "zstd.ManagedRuntime") != null);
        try std.testing.expect(std.mem.indexOf(u8, source, "TestContext") != null);
    }
    const hermes = try readSource("../ziac-templates/templates/hermes-desktop/files/ziac.stack.zig");
    defer std.testing.allocator.free(hermes);
    try std.testing.expect(std.mem.indexOf(u8, hermes, "TestContext") != null);
    try std.testing.expect(std.mem.indexOf(u8, hermes, "ManagedRuntime") == null);

    inline for (.{ "global-zig-api", "event-driven-zig", "hermes-desktop" }) |template| {
        const manifest_path = "../ziac-templates/templates/" ++ template ++ "/files/zigeffect.project.json";
        const compatibility_path = "../ziac-templates/templates/" ++ template ++ "/files/.zigeffect/compatibility.json";
        const manifest = try readSource(manifest_path);
        defer std.testing.allocator.free(manifest);
        const compatibility = try readSource(compatibility_path);
        defer std.testing.allocator.free(compatibility);
        try std.testing.expect(std.mem.indexOf(u8, manifest, "{{project_name}}") != null);
        try std.testing.expect(std.mem.indexOf(u8, compatibility, "\"template_version\":11") != null);
    }
}

test "event driven projects scaffold typed durable workflow control" {
    const workflow = try readSource("../ziac-templates/templates/event-driven-zig/files/src/event_workflow.zig");
    defer std.testing.allocator.free(workflow);
    inline for (.{
        "fx.statechart.Definition(",
        "fx.workflow.WorkflowContext",
        "fx.workflow.Activity(",
        "recordDecisionCausal",
        "registerDefinitionAtomic",
    }) |contract| try std.testing.expect(std.mem.indexOf(u8, workflow, contract) != null);

    const main = try readSource("../ziac-templates/templates/event-driven-zig/files/src/main.zig");
    defer std.testing.allocator.free(main);
    try std.testing.expect(std.mem.indexOf(u8, main, "FileJournalStore.open") != null);
    try std.testing.expect(std.mem.indexOf(u8, main, "EventWorkflow") != null);

    const manifest = try readSource("../ziac-templates/templates/event-driven-zig/files/zigeffect.project.json");
    defer std.testing.allocator.free(manifest);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "event-workflow-replay") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"statechart\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"workflow\"") != null);
}
