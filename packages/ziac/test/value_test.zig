const std = @import("std");
const ziac = @import("ziac");

test "canonical values sort object fields and encode nested values" {
    var value = try ziac.value.Value.initOwned(std.testing.allocator, .{
        .object = &.{
            .{ .name = "zeta", .value = .{ .boolean = true } },
            .{ .name = "alpha", .value = .{ .string = "hello\nworld" } },
            .{ .name = "items", .value = .{ .list = &.{
                .{ .integer = 42 },
                .{ .string = "last" },
            } } },
        },
    });
    defer value.deinit(std.testing.allocator);

    const json = try value.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expectEqualStrings(
        "{\"alpha\":\"hello\\nworld\",\"items\":[42,\"last\"],\"zeta\":true}",
        json,
    );
}

test "canonical value hashes ignore source object field order" {
    var left = try ziac.value.Value.initOwned(std.testing.allocator, .{
        .object = &.{
            .{ .name = "name", .value = .{ .string = "api" } },
            .{ .name = "port", .value = .{ .integer = 8080 } },
        },
    });
    defer left.deinit(std.testing.allocator);

    var right = try ziac.value.Value.initOwned(std.testing.allocator, .{
        .object = &.{
            .{ .name = "port", .value = .{ .integer = 8080 } },
            .{ .name = "name", .value = .{ .string = "api" } },
        },
    });
    defer right.deinit(std.testing.allocator);

    try std.testing.expectEqual(try left.sha256(std.testing.allocator), try right.sha256(std.testing.allocator));
}

test "canonical values reject duplicate object fields" {
    try std.testing.expectError(error.DuplicateField, ziac.value.Value.initOwned(std.testing.allocator, .{
        .object = &.{
            .{ .name = "region", .value = .{ .string = "europe-west1" } },
            .{ .name = "region", .value = .{ .string = "us-central1" } },
        },
    }));
}

test "canonical values encode empty objects and lists" {
    var object = try ziac.value.Value.initOwned(std.testing.allocator, .{ .object = &.{} });
    defer object.deinit(std.testing.allocator);
    const object_json = try object.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(object_json);
    try std.testing.expectEqualStrings("{}", object_json);

    var list = try ziac.value.Value.initOwned(std.testing.allocator, .{ .list = &.{} });
    defer list.deinit(std.testing.allocator);
    const list_json = try list.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(list_json);
    try std.testing.expectEqualStrings("[]", list_json);
}

test "secret references serialize metadata without secret plaintext" {
    var value = try ziac.value.Value.initOwned(std.testing.allocator, .{
        .secret_ref = .{
            .provider = "gcp",
            .resource = "projects/example/secrets/database-url",
            .version = "7",
            .field = "value",
        },
    });
    defer value.deinit(std.testing.allocator);

    const json = try value.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expectEqualStrings(
        "{\"$secret\":{\"field\":\"value\",\"provider\":\"gcp\",\"resource\":\"projects/example/secrets/database-url\",\"version\":\"7\"}}",
        json,
    );
    try std.testing.expect(std.mem.indexOf(u8, json, "sentinel-secret-for-tests") == null);
}

test "canonical values clone owned trees independently" {
    var original = try ziac.value.Value.initOwned(std.testing.allocator, .{
        .object = &.{
            .{ .name = "status", .value = .{ .string = "ready" } },
            .{ .name = "unknown", .value = .{ .unknown_reason = "provider apply pending" } },
        },
    });
    defer original.deinit(std.testing.allocator);

    var cloned = try original.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    const original_json = try original.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(original_json);
    const cloned_json = try cloned.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(cloned_json);

    try std.testing.expectEqualStrings(original_json, cloned_json);
}

test "canonical values parse their public secret and unknown JSON forms" {
    const inputs = [_][]const u8{
        "{\"enabled\":true,\"items\":[1,\"two\"]}",
        "{\"$secret\":{\"provider\":\"gcp\",\"resource\":\"projects/p/secrets/s\",\"version\":\"1\"}}",
        "{\"$unknown\":\"apply pending\"}",
    };

    for (inputs) |input| {
        var value = try ziac.value.Value.parseJsonAlloc(std.testing.allocator, input);
        defer value.deinit(std.testing.allocator);
        const encoded = try value.canonicalJsonAlloc(std.testing.allocator);
        defer std.testing.allocator.free(encoded);
        try std.testing.expectEqualStrings(input, encoded);
    }
}

test "provider output references are canonical resource input values" {
    var reference = try ziac.value.Value.initOwned(std.testing.allocator, .{ .output_ref = .{
        .resource_id = "gcp.compute.GlobalAddress.api-ip",
        .field = "address",
    } });
    defer reference.deinit(std.testing.allocator);
    const json = try reference.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        "{\"$output\":{\"field\":\"address\",\"resource\":\"gcp.compute.GlobalAddress.api-ip\"}}",
        json,
    );

    var parsed = try ziac.value.Value.parseJsonAlloc(std.testing.allocator, json);
    defer parsed.deinit(std.testing.allocator);
    try std.testing.expect(parsed == .output_ref);
    try std.testing.expectEqualStrings("gcp.compute.GlobalAddress.api-ip", parsed.output_ref.resource_id);
    try std.testing.expectEqualStrings("address", parsed.output_ref.field);
}
