const std = @import("std");
const ziac = @import("ziac");

const config = ziac.gcp.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
};

test "Cloud Tasks queue captures rate retry HTTP OIDC and exact IAM intent" {
    var queue = try ziac.gcp.tasks.Queue.build(std.testing.allocator, config, .{
        .name = "invoice-worker",
        .rate_limits = .{
            .max_dispatches_per_second = 12.5,
            .max_concurrent_dispatches = 24,
        },
        .retry_config = .{
            .max_attempts = 8,
            .max_retry_duration_seconds = 3_600,
            .min_backoff_seconds = 5,
            .max_backoff_seconds = 300,
            .max_doublings = 5,
        },
        .http_target = .{
            .uri_override = .{
                .scheme = .https,
                .host = "invoice-worker.example.run.app",
                .path = "/tasks/invoice",
                .enforce_mode = .always,
            },
            .method = .post,
            .headers = &.{.{ .key = "content-type", .value = "application/json" }},
            .authorization = .{ .oidc = .{
                .service_account_email = "invoice-tasks@ziac-dev.iam.gserviceaccount.com",
                .audience = "https://invoice-worker.example.run.app",
            } },
        },
        .logging_sample_ratio = 0.25,
        .retain_on_delete = false,
    });
    defer queue.deinit(std.testing.allocator);

    var enqueuer = try ziac.gcp.tasks.QueueIamMember.build(std.testing.allocator, config, .{
        .name = "api-enqueuer",
        .queue = queue.name,
        .role = "roles/cloudtasks.enqueuer",
        .member = "serviceAccount:api@ziac-dev.iam.gserviceaccount.com",
    });
    defer enqueuer.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.tasks.Queue.europe-west1.invoice-worker", queue.node.id);
    try std.testing.expect(!queue.node.lifecycle.retain_on_delete);
    const json = try queue.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"max_dispatches_per_second\":\"12.5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "invoice-worker.example.run.app") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"authorization_kind\":\"oidc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "content-type") != null);
    try std.testing.expect(ziac.gcp.live_provider.supports(queue.node));
    try std.testing.expect(ziac.gcp.live_provider.supports(enqueuer.node));
}

test "Cloud Tasks queue rejects unsafe targets and invalid retry limits" {
    try std.testing.expectError(error.InvalidRateLimits, ziac.gcp.tasks.Queue.build(std.testing.allocator, config, .{
        .name = "invoice-worker",
        .rate_limits = .{ .max_dispatches_per_second = 501 },
    }));
    try std.testing.expectError(error.InvalidRetryConfig, ziac.gcp.tasks.Queue.build(std.testing.allocator, config, .{
        .name = "invoice-worker",
        .retry_config = .{ .max_attempts = 0 },
    }));
    try std.testing.expectError(error.InvalidTarget, ziac.gcp.tasks.Queue.build(std.testing.allocator, config, .{
        .name = "invoice-worker",
        .http_target = .{
            .uri_override = .{ .scheme = .http, .host = "worker.internal" },
            .authorization = .{ .oidc = .{
                .service_account_email = "invoice-tasks@ziac-dev.iam.gserviceaccount.com",
                .audience = "http://worker.internal",
            } },
        },
    }));
}
