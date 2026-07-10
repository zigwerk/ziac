const std = @import("std");
const ziac = @import("ziac");

test "public and secret outputs are distinct inspectable types" {
    const Public = ziac.Output([]const u8, .public);
    const Secret = ziac.Output([]const u8, .secret);
    try std.testing.expect(Public != Secret);
    try std.testing.expect(Public.ValueType == []const u8);
    try std.testing.expectEqual(ziac.output.Secrecy.public, Public.secrecy);
    try std.testing.expectEqual(ziac.output.Secrecy.secret, Secret.secrecy);
}

test "known and unknown planning values remain typed" {
    const Public = ziac.Output([]const u8, .public);
    const known = Public.known("https://example.com");
    try std.testing.expect(known == .value);
    try std.testing.expectEqualStrings("https://example.com", known.value);

    const unknown = Public.unknown("known after provider create");
    try std.testing.expect(unknown == .unknown_reason);
    try std.testing.expectEqualStrings("known after provider create", unknown.unknown_reason);
}

test "resource output identifies resource field type and secrecy" {
    const Url = ziac.output.Descriptor("url", []const u8, .public);
    const output = Url.fromResource("gcp.run.Service.api");
    try std.testing.expectEqualStrings("url", Url.field_name);
    try std.testing.expect(Url.ValueType == []const u8);
    try std.testing.expectEqual(ziac.output.Secrecy.public, Url.secrecy);
    try std.testing.expectEqualStrings("gcp.run.Service.api", output.resource_ref.resource_id);
    try std.testing.expectEqualStrings("url", output.resource_ref.field);
}

test "typed output resolves provider state values" {
    var state = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer state.deinit();
    try state.put(.{
        .resource_id = "service",
        .type_name = "test.Service",
        .logical_id = "service",
        .desired_hash = "hash",
        .outputs = &.{
            .{ .name = "url", .value = .{ .string = "https://service.example" } },
            .{ .name = "database", .value = .{ .secret_ref = .{
                .provider = "gcp",
                .resource = "projects/example/secrets/database",
                .version = "latest",
            } } },
        },
        .status = .created,
    });

    const url = ziac.Output([]const u8, .public).fromResource("service", "url");
    try std.testing.expectEqualStrings("https://service.example", try url.resolve(&state));
    const database = ziac.Output(ziac.value.SecretReference, .secret).fromResource("service", "database");
    const reference = try database.resolve(&state);
    try std.testing.expectEqualStrings("projects/example/secrets/database", reference.resource);
}

test "secret ref is never a plain string output" {
    const secret = ziac.SecretRef.named("database-url");
    try std.testing.expectEqualStrings("database-url", secret.name);
}
