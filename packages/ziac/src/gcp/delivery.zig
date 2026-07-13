const std = @import("std");

pub const Outcome = enum {
    success,
    retryable,
    permanent_failure,
};

pub const Attempt = struct {
    delivery_id: []const u8,
    attempt: u32,
    outcome: Outcome,
    already_completed: bool = false,
    cancelled: bool = false,
};

pub const Decision = union(enum) {
    acknowledge,
    retry_after_seconds: u32,
    dead_letter,
    suppress_duplicate,
    cancel,
};

pub const Policy = struct {
    max_attempts: u32,
    min_backoff_seconds: u32,
    max_backoff_seconds: u32,
    max_doublings: u8,

    pub fn decide(self: Policy, attempt: Attempt) Decision {
        if (attempt.cancelled) return .cancel;
        if (attempt.already_completed) return .suppress_duplicate;
        if (attempt.outcome == .success) return .acknowledge;
        if (attempt.outcome == .permanent_failure or attempt.attempt >= self.max_attempts) return .dead_letter;
        const retry_index = attempt.attempt -| 2;
        const exponent: u5 = @intCast(@min(@min(retry_index, self.max_doublings), 31));
        const multiplier = @as(u32, 1) << exponent;
        return .{ .retry_after_seconds = @min(self.max_backoff_seconds, self.min_backoff_seconds *| multiplier) };
    }
};
