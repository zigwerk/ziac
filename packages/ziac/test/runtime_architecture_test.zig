const std = @import("std");

fn readSource(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(2 * 1024 * 1024));
}

test "every shipped Ziac process root declares injected process inputs and one owning runtime" {
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
        try std.testing.expect(std.mem.indexOf(u8, source, "ziac.process_runtime.ProcessInputs") != null);
        try std.testing.expect(std.mem.indexOf(u8, source, "MainProgram.fromFn") != null);
        try std.testing.expect(std.mem.indexOf(u8, source, ").Stateful(std.process.Init)") == null);
        try std.testing.expect(std.mem.indexOf(u8, source, "runtime_events") == null);
    }

    const runtime = try readSource("src/process_runtime.zig");
    defer std.testing.allocator.free(runtime);
    try std.testing.expect(std.mem.indexOf(u8, runtime, "const main_layer") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime, "zstd.ManagedRuntime") != null);
    try std.testing.expect(std.mem.indexOf(u8, runtime, "ProcessInputs") != null);
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
        "src/agent_tools.zig",
        "src/provider_rpc.zig",
    };
    for (paths) |path| {
        const source = try readSource(path);
        defer std.testing.allocator.free(source);
        try std.testing.expect(std.mem.indexOf(u8, source, "fx.Runtime(") == null);
        try std.testing.expect(std.mem.indexOf(u8, source, "fx.layerGraph") == null);
        try std.testing.expect(std.mem.indexOf(u8, source, "zstd.fx.layerGraph") == null);
        try std.testing.expect(std.mem.indexOf(u8, source, "ctx.runEffect") == null);
    }
}

test "application roots contain no causal plumbing" {
    const application_paths = [_][]const u8{
        "src/main.zig",
        "src/application.zig",
        "src/mcp_server_main.zig",
        "src/dashboard_host_main.zig",
        "src/provider_gcp_main.zig",
        "src/provider_cockroach_main.zig",
        "src/estate_control_plane_main.zig",
        "src/billing_worker_main.zig",
        "src/agent_tools.zig",
        "src/provider_rpc.zig",
    };
    inline for (application_paths) |path| {
        const source = try readSource(path);
        defer std.testing.allocator.free(source);
        inline for (.{ "recordCausal", "causalRecorder()", ".causal_store =", "CausalStore.init", "CausalJournalStore" }) |plumbing| {
            try std.testing.expect(std.mem.indexOf(u8, source, plumbing) == null);
        }
    }

    const executor = try readSource("src/executor.zig");
    defer std.testing.allocator.free(executor);
    try std.testing.expect(std.mem.indexOf(u8, executor, "causal_store:") == null);

    const workflow = try readSource("src/watch_deploy.zig");
    defer std.testing.allocator.free(workflow);
    const runtime_start = std.mem.indexOf(u8, workflow, "pub const WorkflowRuntime = struct") orelse return error.MissingWorkflowRuntime;
    const runtime_end = std.mem.indexOfPos(u8, workflow, runtime_start, "};") orelse return error.MissingWorkflowRuntime;
    try std.testing.expect(std.mem.indexOf(u8, workflow[runtime_start..runtime_end], "causal_") == null);
}

test "generated Ziac applications leave causal integration to the runtime and framework" {
    inline for (.{ "global-zig-api", "event-driven-zig" }) |template| {
        const source_path = "../ziac-templates/templates/" ++ template ++ "/files/src/main.zig";
        const source = try readSource(source_path);
        defer std.testing.allocator.free(source);
        const application_source = source[0 .. std.mem.indexOf(u8, source, "test \"") orelse source.len];
        inline for (.{ "recordCausal", "causalRecorder()", ".causal_store =", "CausalStore.init", "CausalJournalStore" }) |plumbing| {
            try std.testing.expect(std.mem.indexOf(u8, application_source, plumbing) == null);
        }
    }

    const workflow = try readSource("../ziac-templates/templates/event-driven-zig/files/src/event_workflow.zig");
    defer std.testing.allocator.free(workflow);
    inline for (.{ "causalRecorder()", "CausalJournalStore", "recordDecisionCausal" }) |plumbing| {
        try std.testing.expect(std.mem.indexOf(u8, workflow, plumbing) == null);
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
        try std.testing.expect(std.mem.indexOf(u8, source, "ProcessInputs") != null);
        try std.testing.expect(std.mem.indexOf(u8, source, "Stateful(std.process.Init)") == null);
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
        try std.testing.expect(std.mem.indexOf(u8, compatibility, "\"template_version\":16") != null);
    }
}

test "event driven projects scaffold typed durable workflow control" {
    const workflow = try readSource("../ziac-templates/templates/event-driven-zig/files/src/event_workflow.zig");
    defer std.testing.allocator.free(workflow);
    inline for (.{
        "fx.statechart.Definition(",
        "fx.workflow.WorkflowContext",
        "fx.workflow.Activity(",
        "zstd.Workflow.execution",
        "execution.decision",
        "registerDefinitionAtomic",
    }) |contract| try std.testing.expect(std.mem.indexOf(u8, workflow, contract) != null);

    const main = try readSource("../ziac-templates/templates/event-driven-zig/files/src/main.zig");
    defer std.testing.allocator.free(main);
    try std.testing.expect(std.mem.indexOf(u8, main, "FileJournalStore.open") != null);
    try std.testing.expect(std.mem.indexOf(u8, main, "EventWorkflow") != null);
    try std.testing.expect(std.mem.indexOf(u8, main, "ProcessInputs") != null);

    const manifest = try readSource("../ziac-templates/templates/event-driven-zig/files/zigeffect.project.json");
    defer std.testing.allocator.free(manifest);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "event-workflow-replay") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"statechart\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "\"workflow\"") != null);
}
