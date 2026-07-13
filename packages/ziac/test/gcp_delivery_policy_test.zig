const std = @import("std");
const ziac = @import("ziac");

test "delivery policy deterministically retries dead letters suppresses duplicates and cancels" {
    const policy = ziac.gcp.delivery.Policy{
        .max_attempts = 4,
        .min_backoff_seconds = 5,
        .max_backoff_seconds = 60,
        .max_doublings = 3,
    };
    try std.testing.expectEqualDeep(
        ziac.gcp.delivery.Decision{ .retry_after_seconds = 10 },
        policy.decide(.{ .delivery_id = "evt-1", .attempt = 3, .outcome = .retryable }),
    );
    try std.testing.expectEqualDeep(
        ziac.gcp.delivery.Decision.dead_letter,
        policy.decide(.{ .delivery_id = "evt-1", .attempt = 4, .outcome = .retryable }),
    );
    try std.testing.expectEqualDeep(
        ziac.gcp.delivery.Decision.suppress_duplicate,
        policy.decide(.{ .delivery_id = "evt-1", .attempt = 2, .outcome = .success, .already_completed = true }),
    );
    try std.testing.expectEqualDeep(
        ziac.gcp.delivery.Decision.cancel,
        policy.decide(.{ .delivery_id = "evt-1", .attempt = 2, .outcome = .retryable, .cancelled = true }),
    );
}
