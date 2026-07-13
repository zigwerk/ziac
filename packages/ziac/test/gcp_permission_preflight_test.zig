const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;

test "live permission preflight uses testIamPermissions and preserves missing proof" {
    const responses = [_]zstd.Http.Response{.{
        .status = 200,
        .body = "{\"permissions\":[\"resourcemanager.projects.getIamPolicy\"]}",
    }};
    var token_source = FixedTokenSource{};
    var cache = auth.TokenCache.init(token_source.tokenSource(), 300);
    defer cache.deinit(std.testing.allocator);
    var transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, &responses);
    defer transport.deinit();
    var client = gclient.Client.init(transport.client(), &cache, .{
        .resource_manager = "https://resourcemanager.example.test",
    });
    var preflight = ziac.gcp.permission_preflight.LivePermissionPreflight.init(&client);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var report = try preflight.testResource(&context, .forProject("ziac-dev"), &.{
        "resourcemanager.projects.setIamPolicy",
        "resourcemanager.projects.getIamPolicy",
    });
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.hasGranted("resourcemanager.projects.getIamPolicy"));
    try std.testing.expect(report.hasMissing("resourcemanager.projects.setIamPolicy"));
    try std.testing.expectEqualStrings(
        "https://resourcemanager.example.test/v3/projects/ziac-dev:testIamPermissions",
        transport.requests.items[0].url,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        transport.requests.items[0].body,
        "[\"resourcemanager.projects.getIamPolicy\",\"resourcemanager.projects.setIamPolicy\"]",
    ) != null);
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
