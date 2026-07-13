const std = @import("std");
const ziac = @import("ziac");

fn build(allocator: std.mem.Allocator) !ziac.gcp.DocumentStore {
    return ziac.gcp.DocumentStore.build(allocator, .{
        .project_id = "example-project",
        .primary_region = "europe-west1",
    }, .{
        .name = "documents",
        .database_id = "documents",
        .location = "eur3",
        .point_in_time_recovery = true,
        .delete_protection = true,
        .indexes = &.{.{
            .name = "matches-by-status",
            .collection_group = "matches",
            .fields = &.{
                .{ .field_path = "status", .mode = .ascending },
                .{ .field_path = "played_at", .mode = .descending },
            },
        }},
        .fields = &.{.{
            .collection_group = "sessions",
            .field_path = "expires_at",
            .ttl_enabled = true,
        }},
        .backup_schedules = &.{.{
            .name = "daily",
            .recurrence = .daily,
            .retention_seconds = 8 * 7 * 24 * 60 * 60,
        }},
        .readers = &.{"group:analytics@example.com"},
        .writers = &.{"serviceAccount:api@example-project.iam.gserviceaccount.com"},
    });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var store = try build(allocator);
    defer store.deinit();
    var requirements = try ziac.gcp.intelligence.synthesizeGraph(allocator, &store.graph);
    defer requirements.deinit(allocator);
    std.debug.print("document store: {d} resources, {d} APIs\n", .{
        store.graph.resources.items.len,
        requirements.apis.len,
    });
}

test "document store example compiles a protected regional database" {
    var store = try build(std.testing.allocator);
    defer store.deinit();
    try store.graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 6), store.graph.resources.items.len);
}
