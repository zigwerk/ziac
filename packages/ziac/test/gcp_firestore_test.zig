const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
};

test "Firestore primitives compile a retained document platform graph" {
    var database = try ziac.gcp.firestore.Database.build(std.testing.allocator, provider, .{
        .database_id = "global-app",
        .location = "eur3",
        .database_type = .firestore_native,
        .edition = .standard,
        .point_in_time_recovery = true,
        .delete_protection = true,
        .kms_key_name = "projects/ziac-dev/locations/eur3/keyRings/data/cryptoKeys/firestore",
    });
    defer database.deinit(std.testing.allocator);

    var index = try ziac.gcp.firestore.Index.build(std.testing.allocator, provider, .{
        .database = database.name,
        .database_id = "global-app",
        .collection_group = "matches",
        .query_scope = .collection_group,
        .fields = &.{
            .{ .field_path = "status", .mode = .ascending },
            .{ .field_path = "played_at", .mode = .descending },
        },
    });
    defer index.deinit(std.testing.allocator);

    var vector_index = try ziac.gcp.firestore.Index.build(std.testing.allocator, provider, .{
        .name = "match-embeddings",
        .database = database.name,
        .database_id = "global-app",
        .collection_group = "matches",
        .query_scope = .collection_group,
        .fields = &.{.{ .field_path = "embedding", .mode = .{ .vector = 768 } }},
    });
    defer vector_index.deinit(std.testing.allocator);

    var field = try ziac.gcp.firestore.Field.build(std.testing.allocator, provider, .{
        .database = database.name,
        .database_id = "global-app",
        .collection_group = "sessions",
        .field_path = "expires_at",
        .ttl_enabled = true,
        .index_modes = &.{ .ascending, .descending },
    });
    defer field.deinit(std.testing.allocator);

    var backup = try ziac.gcp.firestore.BackupSchedule.build(std.testing.allocator, provider, .{
        .name = "daily",
        .database = database.name,
        .database_id = "global-app",
        .recurrence = .daily,
        .retention_seconds = 8 * 7 * 24 * 60 * 60,
    });
    defer backup.deinit(std.testing.allocator);

    var reader = try ziac.gcp.firestore.DatabaseIamMember.build(std.testing.allocator, provider, .{
        .name = "application-reader",
        .database = database.name,
        .database_id = "global-app",
        .role = "roles/datastore.viewer",
        .member = "serviceAccount:api@ziac-dev.iam.gserviceaccount.com",
    });
    defer reader.deinit(std.testing.allocator);

    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    for ([_]ziac.ResourceNode{
        database.node,
        index.node,
        vector_index.node,
        field.node,
        backup.node,
        reader.node,
    }) |node| try graph.addResource(node);

    try graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 6), graph.resources.items.len);
    for ([_][]const u8{ index.node.id, vector_index.node.id, field.node.id, backup.node.id, reader.node.id }) |child| {
        try std.testing.expect(hasDependency(&graph, child, database.node.id));
    }
    try std.testing.expect(database.node.lifecycle.protect);
    try std.testing.expect(database.node.lifecycle.retain_on_delete);
    try std.testing.expectEqualStrings("member", stringField(reader.node.inputs, "ownership_mode"));
}

test "Firestore declarations reject unsafe database index field and backup configuration" {
    try std.testing.expectError(error.InvalidDatabase, ziac.gcp.firestore.Database.build(std.testing.allocator, provider, .{
        .database_id = "(default)",
        .location = "eur3",
        .edition = .enterprise,
    }));

    const database = ziac.PublicOutput([]const u8).known("projects/ziac-dev/databases/global-app");
    try std.testing.expectError(error.InvalidIndex, ziac.gcp.firestore.Index.build(std.testing.allocator, provider, .{
        .database = database,
        .database_id = "global-app",
        .collection_group = "matches",
        .fields = &.{.{ .field_path = "embedding", .mode = .{ .vector = 0 } }},
    }));
    try std.testing.expectError(error.DuplicateField, ziac.gcp.firestore.Index.build(std.testing.allocator, provider, .{
        .database = database,
        .database_id = "global-app",
        .collection_group = "matches",
        .fields = &.{
            .{ .field_path = "status", .mode = .ascending },
            .{ .field_path = "status", .mode = .descending },
        },
    }));
    try std.testing.expectError(error.InvalidField, ziac.gcp.firestore.Field.build(std.testing.allocator, provider, .{
        .database = database,
        .database_id = "global-app",
        .collection_group = "sessions",
        .field_path = "profile/name",
    }));
    try std.testing.expectError(error.InvalidBackupSchedule, ziac.gcp.firestore.BackupSchedule.build(std.testing.allocator, provider, .{
        .name = "too-long",
        .database = database,
        .database_id = "global-app",
        .recurrence = .{ .weekly = .monday },
        .retention_seconds = 15 * 7 * 24 * 60 * 60,
    }));
}

fn hasDependency(graph: *const ziac.ResourceGraph, from: []const u8, to: []const u8) bool {
    for (graph.dependencies.items) |edge| {
        if (std.mem.eql(u8, edge.from, from) and std.mem.eql(u8, edge.to, to)) return true;
    }
    return false;
}

fn stringField(input: ziac.value.Value, name: []const u8) []const u8 {
    for (input.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value.string;
    unreachable;
}
