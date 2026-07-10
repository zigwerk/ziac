const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

test "Cockroach provider API key is an environment-backed secret input" {
    const config = ziac.cockroach.config.ProviderConfig{
        .api_key = ziac.cockroach.config.environmentApiKey("ZIAC_TEST_COCKROACH_API_KEY"),
    };
    try config.validate();

    const input = config.apiKeyInput();
    try std.testing.expect(input == .secret_ref);
    try std.testing.expectEqualStrings("env", input.secret_ref.provider);
    try std.testing.expectEqualStrings("ZIAC_TEST_COCKROACH_API_KEY", input.secret_ref.resource);

    const canonical = try input.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(canonical);
    try std.testing.expectEqualStrings(
        "{\"$secret\":{\"provider\":\"env\",\"resource\":\"ZIAC_TEST_COCKROACH_API_KEY\"}}",
        canonical,
    );

    var env = zstd.Env.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("ZIAC_TEST_COCKROACH_API_KEY", "sentinel-cockroach-key");
    var api_key = try config.loadApiKeyAlloc(std.testing.allocator, env);
    defer api_key.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("sentinel-cockroach-key", api_key.value);
    try std.testing.expect(std.mem.indexOf(u8, canonical, "sentinel-cockroach-key") == null);
}

test "Cockroach provider rejects literal and malformed API key references" {
    try std.testing.expectError(error.UnsupportedSecretProvider, (ziac.cockroach.config.ProviderConfig{
        .api_key = .{ .provider = "literal", .resource = "do-not-store-me" },
    }).validate());
    try std.testing.expectError(error.MissingApiKeyReference, (ziac.cockroach.config.ProviderConfig{
        .api_key = ziac.cockroach.config.environmentApiKey(""),
    }).validate());
}

test "Cockroach GCP region compatibility diagnostics are deterministic" {
    var diagnostic = try ziac.cockroach.validation.regionCompatibilityAlloc(
        std.testing.allocator,
        &.{ "us-central1", "europe-west1", "asia-northeast1" },
        &.{ "asia-southeast1", "asia-northeast1" },
    );
    defer diagnostic.deinit();

    try std.testing.expect(!diagnostic.compatible());
    try std.testing.expectEqual(@as(usize, 2), diagnostic.missing.len);
    try std.testing.expectEqualStrings("europe-west1", diagnostic.missing[0]);
    try std.testing.expectEqualStrings("us-central1", diagnostic.missing[1]);
    try std.testing.expectEqual(@as(usize, 1), diagnostic.unexpected.len);
    try std.testing.expectEqualStrings("asia-southeast1", diagnostic.unexpected[0]);
    const message = try diagnostic.messageAlloc(std.testing.allocator);
    defer std.testing.allocator.free(message);
    try std.testing.expectEqualStrings(
        "CockroachDB GCP regions incompatible: missing [europe-west1, us-central1]; unexpected [asia-southeast1]",
        message,
    );
}
