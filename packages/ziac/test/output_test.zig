const std = @import("std");
const ziac = @import("ziac");

test "known output stores a value" {
    const value = ziac.Output([]const u8).known("https://example.com");
    try std.testing.expect(value == .value);
    try std.testing.expectEqualStrings("https://example.com", value.value);
}

test "resource output stores resource and field reference" {
    const value = ziac.Output([]const u8).fromResource("gcp.run.Service.api", "url");
    try std.testing.expect(value == .resource_ref);
    try std.testing.expectEqualStrings("gcp.run.Service.api", value.resource_ref.resource_id);
    try std.testing.expectEqualStrings("url", value.resource_ref.field);
}

test "secret ref is never a plain string output" {
    const secret = ziac.SecretRef.named("database-url");
    try std.testing.expectEqualStrings("database-url", secret.name);
}
