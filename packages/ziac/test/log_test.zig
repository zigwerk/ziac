const std = @import("std");
const ziac = @import("ziac");

test "log store orders deduplicates bounds and redacts causal events" {
    var store = ziac.log.Store.init(std.testing.allocator, .{ .max_events = 2, .max_message_bytes = 32 });
    defer store.deinit();
    try store.append(.{
        .event_id = "build-1",
        .timestamp_millis = 10,
        .source = .compiler,
        .stream = .stderr,
        .severity = .info,
        .message = "compiled generation one",
        .session_id = "dev-42",
    });
    try store.append(.{
        .event_id = "run-1",
        .parent_event_id = "build-1",
        .timestamp_millis = 20,
        .source = .process,
        .stream = .stdout,
        .severity = .info,
        .message = "database connected",
        .session_id = "dev-42",
        .fields = &.{.{ .name = "DATABASE_URL", .value = "postgres://user:sentinel-secret@db/app", .secret = true }},
    });
    try store.append(.{
        .event_id = "run-1",
        .timestamp_millis = 21,
        .source = .process,
        .stream = .stdout,
        .severity = .info,
        .message = "duplicate",
    });
    try store.append(.{
        .event_id = "health-1",
        .parent_event_id = "run-1",
        .timestamp_millis = 30,
        .source = .health,
        .stream = .system,
        .severity = .warn,
        .message = "readiness failed after a deliberately very long diagnostic message",
        .resource_id = "gcp.run.Service.europe-west1.api",
        .region = "europe-west1",
    });

    try std.testing.expectEqual(@as(usize, 2), store.events.items.len);
    try std.testing.expectEqual(@as(u64, 1), store.dropped_count);
    try std.testing.expectEqual(@as(u64, 1), store.suppressed_count);
    try std.testing.expect(store.events.items[1].truncated);
    const jsonl = try store.jsonLinesAlloc(std.testing.allocator, .{});
    defer std.testing.allocator.free(jsonl);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "ziac.log.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "sentinel-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "[REDACTED]") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"sequence\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "\"sequence\":3") != null);
}

test "log messages redact credential assignments without hiding binding diagnostics" {
    var store = ziac.log.Store.init(std.testing.allocator, .{});
    defer store.deinit();
    try store.append(.{ .event_id = "credential", .timestamp_millis = 1, .source = .process, .stream = .stderr, .severity = .warn, .message = "authorization=Bearer sentinel-secret" });
    try store.append(.{ .event_id = "binding", .timestamp_millis = 2, .source = .process, .stream = .stderr, .severity = .err, .message = "DATABASE_URL binding failed" });
    const jsonl = try store.jsonLinesAlloc(std.testing.allocator, .{});
    defer std.testing.allocator.free(jsonl);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "sentinel-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "[REDACTED]") != null);
    try std.testing.expect(std.mem.indexOf(u8, jsonl, "DATABASE_URL binding failed") != null);
}

test "log filters and explanations use shared causal identities" {
    var store = ziac.log.Store.init(std.testing.allocator, .{});
    defer store.deinit();
    try store.append(.{ .event_id = "rpc", .timestamp_millis = 1, .source = .provider, .stream = .system, .severity = .info, .message = "CreateService", .trace_id = "trace-7" });
    try store.append(.{ .event_id = "lro", .parent_event_id = "rpc", .timestamp_millis = 2, .source = .cloud_run, .stream = .system, .severity = .info, .message = "operation running", .trace_id = "trace-7", .resource_id = "service-api" });
    try store.append(.{ .event_id = "condition", .parent_event_id = "lro", .timestamp_millis = 3, .source = .cloud_run, .stream = .system, .severity = .err, .message = "Ready=False", .trace_id = "trace-7", .resource_id = "service-api" });

    const filtered = try store.jsonLinesAlloc(std.testing.allocator, .{ .resource_id = "service-api", .minimum_severity = .err });
    defer std.testing.allocator.free(filtered);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "Ready=False") != null);
    try std.testing.expect(std.mem.indexOf(u8, filtered, "operation running") == null);

    const explanation = try store.explainJsonAlloc(std.testing.allocator, "condition");
    defer std.testing.allocator.free(explanation);
    try std.testing.expect(std.mem.indexOf(u8, explanation, "CreateService") != null);
    try std.testing.expect(std.mem.indexOf(u8, explanation, "operation running") != null);
    try std.testing.expect(std.mem.indexOf(u8, explanation, "Ready=False") != null);
    try std.testing.expect(std.mem.indexOf(u8, explanation, "\"complete\":true") != null);
}

test "cloud logging entries normalize into the same event schema and cursor" {
    const response =
        \\{"entries":[{"insertId":"cloud-1","timestamp":"2026-07-11T12:00:00Z","severity":"ERROR","textPayload":"revision failed","resource":{"labels":{"location":"us-central1","service_name":"api"}},"trace":"projects/p/traces/trace-9"}],"nextPageToken":"cursor-2"}
    ;
    var batch = try ziac.log.parseCloudLoggingResponseAlloc(std.testing.allocator, response, "cloud-session");
    defer batch.deinit();
    try std.testing.expectEqualStrings("cursor-2", batch.next_cursor.?);
    try std.testing.expectEqual(@as(usize, 1), batch.events.len);
    try std.testing.expectEqual(ziac.log.Source.cloud_run, batch.events[0].source);
    try std.testing.expectEqual(ziac.log.Severity.err, batch.events[0].severity);
    try std.testing.expectEqualStrings("us-central1", batch.events[0].region.?);
    try std.testing.expectEqualStrings("trace-9", batch.events[0].trace_id.?);
}

test "log sessions persist and Cloud Logging polling requests are deterministic" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    var events = ziac.log.Store.init(std.testing.allocator, .{});
    defer events.deinit();
    try events.append(.{ .event_id = "persisted", .timestamp_millis = 42, .source = .agent, .stream = .system, .severity = .info, .message = "saved evidence", .session_id = "session-42" });
    const sessions = ziac.log.SessionStore.init(std.testing.allocator, ziac.local_state.memoryFiles(&fs), .{});
    try sessions.save("hello-global", "dev", &events);
    var loaded = try sessions.load("hello-global", "dev");
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.events.items.len);
    try std.testing.expectEqualStrings("saved evidence", loaded.events.items[0].message);

    const request = try ziac.log.cloudLoggingListRequestJsonAlloc(std.testing.allocator, "project-42", "resource.type=\"cloud_run_revision\"", "cursor-1");
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.indexOf(u8, request, "projects/project-42") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "timestamp asc") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "cursor-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "entries.tail") == null);
}

test "Cloud Logging poller owns and advances the page cursor" {
    var client = ziac.log.ScriptedCloudLoggingClient.init(
        "{\"entries\":[{\"insertId\":\"cloud-1\",\"severity\":\"INFO\",\"textPayload\":\"ready\"}],\"nextPageToken\":\"cursor-2\"}",
    );
    var poller = ziac.log.CloudLoggingPoller.init(std.testing.allocator, client.client(), .{
        .project_id = "project-dev",
        .filter = "resource.type=\"cloud_run_revision\"",
        .session_id = "session-dev",
    });
    defer poller.deinit();
    var batch = try poller.pollAlloc();
    defer batch.deinit();
    try std.testing.expectEqual(@as(usize, 1), client.call_count);
    try std.testing.expectEqualStrings("cursor-2", poller.cursor.?);
    try std.testing.expectEqualStrings("session-dev", batch.events[0].session_id.?);
    try std.testing.expect(std.mem.indexOf(u8, client.last_request.?, "entries.tail") == null);
}
