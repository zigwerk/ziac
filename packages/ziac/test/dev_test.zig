const std = @import("std");
const ziac = @import("ziac");

const project_fixture = @embedFile("fixtures/agent/ziac.project.json");

test "dev plan requires explicit adaptations and preserves remote-only evidence" {
    var project = try ziac.agent_contract.Project.parseAlloc(std.testing.allocator, project_fixture);
    defer project.deinit();
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try addNode(&graph, .gcp, "gcp.run.Service", "api");
    try addNode(&graph, .gcp, "gcp.compute.BackendService", "edge");
    try addNode(&graph, .cockroach, "cockroach.Cluster", "database");
    try addNode(&graph, .gcp, "gcp.psc.Endpoint", "database-private");

    const plan = try ziac.dev.planAdaptationsAlloc(std.testing.allocator, project, &graph);
    defer std.testing.allocator.free(plan);
    try std.testing.expectEqual(@as(usize, 4), plan.len);
    try std.testing.expectEqual(ziac.agent_contract.AdaptationStrategy.local_process, plan[0].strategy);
    try std.testing.expectEqual(ziac.agent_contract.AdaptationStrategy.local_proxy, plan[1].strategy);
    try std.testing.expectEqual(ziac.agent_contract.AdaptationStrategy.local_service, plan[2].strategy);
    try std.testing.expectEqual(ziac.agent_contract.AdaptationStrategy.remote_only, plan[3].strategy);

    try addNode(&graph, .gcp, "gcp.secret.Secret", "missing-adaptation");
    try std.testing.expectError(error.MissingDevAdaptation, ziac.dev.planAdaptationsAlloc(std.testing.allocator, project, &graph));
}

test "dev change classifier separates fast local and governed changes" {
    try std.testing.expectEqual(ziac.dev.ChangeKind.source_only, ziac.dev.classifyPath("src/main.zig"));
    try std.testing.expectEqual(ziac.dev.ChangeKind.image_only, ziac.dev.classifyPath("Dockerfile"));
    try std.testing.expectEqual(ziac.dev.ChangeKind.runtime_config, ziac.dev.classifyPath("config/dev.json"));
    try std.testing.expectEqual(ziac.dev.ChangeKind.secret_reference, ziac.dev.classifyPath("secrets/database.ref"));
    try std.testing.expectEqual(ziac.dev.ChangeKind.graph_topology, ziac.dev.classifyPath("ziac.project.json"));
    try std.testing.expectEqual(ziac.dev.ChangeKind.destructive, ziac.dev.classifyPath("migrations/001-drop-users.sql"));
}

test "dev affected subgraph includes transitive dependents in stable order" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    try addNode(&graph, .gcp, "gcp.secret.Secret", "secret");
    try addNode(&graph, .gcp, "gcp.run.Service", "api");
    try addNode(&graph, .gcp, "gcp.compute.BackendService", "edge");
    try graph.addDependency("gcp.run.Service.api", "gcp.secret.Secret.secret");
    try graph.addDependency("gcp.compute.BackendService.edge", "gcp.run.Service.api");

    const affected = try ziac.dev.affectedSubgraphAlloc(std.testing.allocator, &graph, &.{"gcp.secret.Secret.secret"});
    defer std.testing.allocator.free(affected);
    try std.testing.expectEqual(@as(usize, 3), affected.len);
    try std.testing.expectEqualStrings("gcp.compute.BackendService.edge", affected[0]);
    try std.testing.expectEqualStrings("gcp.run.Service.api", affected[1]);
    try std.testing.expectEqualStrings("gcp.secret.Secret.secret", affected[2]);
}

test "dev supervisor promotes only ready newest generations and retains healthy fallback" {
    var supervisor = ziac.dev.Supervisor.init(std.testing.allocator);
    defer supervisor.deinit();

    try supervisor.begin(.{ .id = 1, .digest = "sha256:first", .port = 4101 });
    try supervisor.markReady(1);
    try std.testing.expectEqual(@as(?u64, 1), supervisor.activeGeneration());

    try supervisor.begin(.{ .id = 2, .digest = "sha256:broken", .port = 4102 });
    try supervisor.markFailed(2, "readiness timeout");
    try std.testing.expectEqual(@as(?u64, 1), supervisor.activeGeneration());
    try std.testing.expectEqual(ziac.dev.GenerationStatus.failed, supervisor.generation(2).?.status);

    try supervisor.begin(.{ .id = 3, .digest = "sha256:healthy", .port = 4103 });
    try supervisor.markReady(3);
    try std.testing.expectEqual(@as(?u64, 3), supervisor.activeGeneration());
    try std.testing.expectEqual(ziac.dev.GenerationStatus.draining, supervisor.generation(1).?.status);
    try supervisor.completeDrain(1);
    try std.testing.expectEqual(ziac.dev.GenerationStatus.stopped, supervisor.generation(1).?.status);

    try supervisor.begin(.{ .id = 4, .digest = "sha256:stale", .port = 4104 });
    try supervisor.begin(.{ .id = 5, .digest = "sha256:newest", .port = 4105 });
    try std.testing.expectEqual(ziac.dev.GenerationStatus.superseded, supervisor.generation(4).?.status);
    try std.testing.expectEqual(@as(?u64, 5), supervisor.candidateGeneration());
}

test "dev bindings keep secret values out of artifacts" {
    const bindings = [_]ziac.dev.Binding{
        .{ .name = "PORT", .value = "8080" },
        .{ .name = "DATABASE_URL", .value = "postgres://user:sentinel-secret@db/app", .secret = true },
    };
    const artifact = try ziac.dev.bindingsJsonAlloc(std.testing.allocator, &bindings);
    defer std.testing.allocator.free(artifact);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "PORT") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "8080") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "DATABASE_URL") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "sentinel-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "[REDACTED]") != null);
}

test "dev reload boundary keeps serving on build and readiness failures" {
    var supervisor = ziac.dev.Supervisor.init(std.testing.allocator);
    defer supervisor.deinit();
    var scripted = ziac.dev.ScriptedRuntime.init();

    const first = try ziac.dev.reload(&supervisor, scripted.runtime(), .{ .id = 1, .digest = "first", .port = 4201 });
    try std.testing.expectEqual(ziac.dev.ReloadStatus.promoted, first.status);
    try std.testing.expectEqual(@as(?u64, 1), supervisor.activeGeneration());

    scripted.build_error = error.BuildFailed;
    const build_failed = try ziac.dev.reload(&supervisor, scripted.runtime(), .{ .id = 2, .digest = "broken-build", .port = 4202 });
    try std.testing.expectEqual(ziac.dev.ReloadStatus.build_failed, build_failed.status);
    try std.testing.expectEqual(@as(?u64, 1), supervisor.activeGeneration());

    scripted.build_error = null;
    scripted.ready = false;
    const readiness_failed = try ziac.dev.reload(&supervisor, scripted.runtime(), .{ .id = 3, .digest = "broken-ready", .port = 4203 });
    try std.testing.expectEqual(ziac.dev.ReloadStatus.readiness_failed, readiness_failed.status);
    try std.testing.expectEqual(@as(?u64, 1), supervisor.activeGeneration());
    try std.testing.expectEqual(@as(usize, 1), scripted.stop_count);

    scripted.ready = true;
    const promoted = try ziac.dev.reload(&supervisor, scripted.runtime(), .{ .id = 4, .digest = "newest", .port = 4204 });
    try std.testing.expectEqual(ziac.dev.ReloadStatus.promoted, promoted.status);
    try std.testing.expectEqual(@as(?u64, 4), supervisor.activeGeneration());
    try std.testing.expectEqual(@as(usize, 2), scripted.promote_count);
    try std.testing.expectEqual(@as(usize, 1), scripted.drain_count);
}

fn addNode(graph: *ziac.ResourceGraph, provider: ziac.resource.ProviderId, type_name: []const u8, logical_id: []const u8) !void {
    const id = try std.fmt.allocPrint(std.testing.allocator, "{s}.{s}", .{ type_name, logical_id });
    defer std.testing.allocator.free(id);
    var node = try ziac.ResourceNode.initOwned(std.testing.allocator, .{
        .id = id,
        .provider = provider,
        .type_name = type_name,
        .logical_id = logical_id,
        .inputs = .{ .object = &.{} },
    });
    defer node.deinit(std.testing.allocator);
    try graph.addResource(node);
}
