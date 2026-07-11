const std = @import("std");
const ziac = @import("ziac");

const fixture = @embedFile("fixtures/agent/ziac.project.json");

test "agent session validates transitions and emits status next query and handoff" {
    var project = try ziac.agent_contract.Project.parseAlloc(std.testing.allocator, fixture);
    defer project.deinit();
    var graph = try fixtureGraph(std.testing.allocator);
    defer graph.deinit();
    var session = try ziac.agent.Session.init(std.testing.allocator, .{
        .id = "session-42",
        .objective = "restore global API connectivity",
        .stack = "global-api",
        .stage = "dev_sean",
    });
    defer session.deinit();

    try session.transition(.planning, .{ .event_id = "event-plan", .evidence_id = "plan-1" });
    try session.transition(.preflighting, .{ .event_id = "event-preflight" });
    try session.transition(.simulating, .{ .event_id = "event-simulate" });
    try session.transition(.diagnosing, .{ .event_id = "event-diagnose", .resource_id = "gcp.run.Service.global.api" });
    try std.testing.expectError(error.InvalidSessionTransition, session.transition(.applying, .{ .event_id = "event-invalid" }));
    try session.transition(.proposing_repair, .{ .event_id = "event-proposal", .evidence_id = "repair-plan" });

    const status = try ziac.agent.statusJsonAlloc(std.testing.allocator, project, session, &graph);
    defer std.testing.allocator.free(status);
    try std.testing.expect(std.mem.indexOf(u8, status, "ziac.agent-status.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "proposing_repair") != null);

    const next = try ziac.agent.nextJsonAlloc(std.testing.allocator, project, session);
    defer std.testing.allocator.free(next);
    try std.testing.expect(std.mem.indexOf(u8, next, "agent propose") != null);
    try std.testing.expect(std.mem.indexOf(u8, next, "global-api-healthy") != null);

    const query = try ziac.agent.queryResourceJsonAlloc(std.testing.allocator, &graph, "gcp.run.Service.global.api");
    defer std.testing.allocator.free(query);
    try std.testing.expect(std.mem.indexOf(u8, query, "gcp.secret.Secret.database-url") != null);

    const handoff = try ziac.agent.handoffJsonAlloc(std.testing.allocator, project, session, .{
        .root_cause = "runtime service account lacks secret accessor",
        .plan_digest = "repair-plan",
        .verification = &.{"check-global-api"},
        .blocked_by = &.{"apply capability"},
    });
    defer std.testing.allocator.free(handoff);
    try std.testing.expect(std.mem.indexOf(u8, handoff, "ziac.handoff.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, handoff, "sentinel-secret") == null);
}

test "agent explain follows event parents without cycles" {
    var session = try ziac.agent.Session.init(std.testing.allocator, .{
        .id = "session-explain",
        .objective = "explain failure",
        .stack = "global-api",
        .stage = "dev_sean",
    });
    defer session.deinit();
    try session.record(.{ .event_id = "root", .summary = "deployment started" });
    try session.record(.{ .event_id = "child", .parent_event_id = "root", .summary = "revision failed", .resource_id = "gcp.run.Service.global.api" });
    const explanation = try ziac.agent.explainJsonAlloc(std.testing.allocator, session, "child");
    defer std.testing.allocator.free(explanation);
    try std.testing.expect(std.mem.indexOf(u8, explanation, "revision failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, explanation, "deployment started") != null);
}

test "agent transition is atomic and causal cycles remain explicit" {
    var session = try ziac.agent.Session.init(std.testing.allocator, .{
        .id = "session-atomic",
        .objective = "preserve truthful state",
        .stack = "global-api",
        .stage = "dev_sean",
    });
    defer session.deinit();

    try session.transition(.planning, .{ .event_id = "event-plan" });
    try std.testing.expectError(error.DuplicateEvent, session.transition(.preflighting, .{ .event_id = "event-plan" }));
    try std.testing.expectEqual(ziac.agent.State.planning, session.state);

    try session.record(.{ .event_id = "cycle-a", .parent_event_id = "cycle-b" });
    try session.record(.{ .event_id = "cycle-b", .parent_event_id = "cycle-a" });
    const explanation = try ziac.agent.explainJsonAlloc(std.testing.allocator, session, "cycle-a");
    defer std.testing.allocator.free(explanation);
    try std.testing.expect(std.mem.indexOf(u8, explanation, "\"complete\": false") != null);
}

test "agent session snapshot round trips durable state and evidence" {
    var session = try ziac.agent.Session.init(std.testing.allocator, .{
        .id = "session-round-trip",
        .objective = "repair the global API",
        .stack = "global-api",
        .stage = "dev_sean",
    });
    defer session.deinit();
    try session.transition(.planning, .{
        .event_id = "event-plan",
        .evidence_id = "plan-42",
        .resource_id = "gcp.run.Service.global.api",
        .summary = "planned exact update",
    });

    const snapshot = try session.jsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    var restored = try ziac.agent.Session.parseAlloc(std.testing.allocator, snapshot);
    defer restored.deinit();

    try std.testing.expectEqual(ziac.agent.State.planning, restored.state);
    try std.testing.expectEqualStrings(session.id, restored.id);
    try std.testing.expectEqual(@as(usize, 1), restored.events.items.len);
    try std.testing.expectEqualStrings("plan-42", restored.events.items[0].evidence_id.?);
    try std.testing.expectEqualStrings("planned exact update", restored.events.items[0].summary);
}

test "agent session store persists atomically by stack and stage" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    const store = ziac.agent.SessionStore.init(std.testing.allocator, ziac.local_state.memoryFiles(&fs));
    var session = try ziac.agent.Session.init(std.testing.allocator, .{
        .id = "session-store",
        .objective = "persist agent evidence",
        .stack = "global-api",
        .stage = "dev_sean",
    });
    defer session.deinit();
    try session.transition(.planning, .{ .event_id = "event-plan", .summary = "ready to plan" });
    try store.save(session);

    var loaded = try store.load("global-api", "dev_sean");
    defer loaded.deinit();
    try std.testing.expectEqual(ziac.agent.State.planning, loaded.state);
    try std.testing.expectEqualStrings("ready to plan", loaded.events.items[0].summary);
    try std.testing.expect(fs.exists(".ziac/agent/global-api/dev_sean/session.json"));
}

fn fixtureGraph(allocator: std.mem.Allocator) !ziac.ResourceGraph {
    var graph = ziac.ResourceGraph.init(allocator);
    errdefer graph.deinit();
    var secret = try ziac.ResourceNode.initOwned(allocator, .{
        .id = "gcp.secret.Secret.database-url",
        .provider = .gcp,
        .type_name = "gcp.secret.Secret",
        .logical_id = "database-url",
        .inputs = .{ .object = &.{} },
    });
    defer secret.deinit(allocator);
    var service = try ziac.ResourceNode.initOwned(allocator, .{
        .id = "gcp.run.Service.global.api",
        .provider = .gcp,
        .type_name = "gcp.run.Service",
        .logical_id = "api",
        .inputs = .{ .object = &.{} },
    });
    defer service.deinit(allocator);
    try graph.addResource(secret);
    try graph.addResource(service);
    try graph.addDependency(service.id, secret.id);
    return graph;
}
