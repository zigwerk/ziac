const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;

test "GCP Secret Manager access source resolves typed versions into secure payloads" {
    const responses = [_]zstd.Http.Response{.{
        .status = 200,
        .body = "{\"name\":\"projects/ziac-dev/secrets/database-url/versions/7\",\"payload\":{\"data\":\"cG9zdGdyZXNxbDovL2FwcF91c2VyOnAlNDBzc0BkYi5leGFtcGxlOjI2MjU3L2FwcD9zc2xtb2RlPXZlcmlmeS1mdWxs\"}}",
    }};
    var token_source = FixedTokenSource{};
    var cache = auth.TokenCache.init(token_source.tokenSource(), 300);
    defer cache.deinit(std.testing.allocator);
    var transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, &responses);
    defer transport.deinit();
    var client = gclient.Client.init(transport.client(), &cache, .{
        .secret_manager = "https://secretmanager.example.test",
    });
    var access = ziac.gcp.secret_access.SecretManagerSource.init(&client);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var payload = try access.secretSource().resolve(&context, std.testing.allocator, .{
        .provider = "gcp-secret-manager",
        .resource = "projects/ziac-dev/secrets/database-url",
        .version = "7",
    });
    defer payload.deinit();

    try std.testing.expectEqualStrings(
        "postgresql://app_user:p%40ss@db.example:26257/app?sslmode=verify-full",
        payload.bytes,
    );
    try std.testing.expectEqualStrings(
        "https://secretmanager.example.test/v1/projects/ziac-dev/secrets/database-url/versions/7:access",
        transport.requests.items[0].url,
    );
}

test "GCP Secret Manager access source rejects unversioned and foreign references" {
    var token_source = FixedTokenSource{};
    var cache = auth.TokenCache.init(token_source.tokenSource(), 300);
    defer cache.deinit(std.testing.allocator);
    const responses = [_]zstd.Http.Response{};
    var transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, &responses);
    defer transport.deinit();
    var client = gclient.Client.init(transport.client(), &cache, .{});
    var access = ziac.gcp.secret_access.SecretManagerSource.init(&client);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    try std.testing.expectError(error.InvalidConfiguration, access.secretSource().resolve(&context, std.testing.allocator, .{
        .provider = "gcp-secret-manager",
        .resource = "projects/ziac-dev/secrets/database-url",
    }));
    try std.testing.expectError(error.NotFound, access.secretSource().resolve(&context, std.testing.allocator, .{
        .provider = "other",
        .resource = "projects/ziac-dev/secrets/database-url",
        .version = "7",
    }));
}

const FixedTokenSource = struct {
    fn tokenSource(self: *FixedTokenSource) auth.TokenSource {
        return .{ .ptr = self, .fetchFn = fetch };
    }

    fn fetch(_: *anyopaque, allocator: std.mem.Allocator, now_seconds: u64) auth.AuthError!auth.AccessToken {
        return auth.AccessToken.initOwned(allocator, .{
            .access_token = "dummy-google-token",
            .token_type = "Bearer",
            .expires_at_seconds = now_seconds + 3_600,
        });
    }
};
