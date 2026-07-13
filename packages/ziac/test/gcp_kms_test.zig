const std = @import("std");
const ziac = @import("ziac");

test "Cloud KMS resources form an applyable retained bootstrap chain" {
    const provider = ziac.gcp.ProviderConfig{ .project_id = "ziac-cloud-prod", .primary_region = "europe-west1" };
    var ring = try ziac.gcp.kms.KeyRing.build(std.testing.allocator, provider, .{ .name = "ziac-cloud", .location = "europe-west1" });
    defer ring.deinit(std.testing.allocator);
    var key = try ziac.gcp.kms.CryptoKey.build(std.testing.allocator, provider, .{ .name = "connection-vault", .key_ring = ring.name });
    defer key.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("gcp.kms.KeyRing", ring.node.type_name);
    try std.testing.expectEqualStrings("gcp.kms.CryptoKey", key.node.type_name);
    try std.testing.expect(ring.node.lifecycle.retain_on_delete);
    try std.testing.expect(key.node.lifecycle.retain_on_delete);
    try std.testing.expect(ziac.gcp.live_provider.supports(ring.node));
    try std.testing.expect(ziac.gcp.live_provider.supports(key.node));
}
