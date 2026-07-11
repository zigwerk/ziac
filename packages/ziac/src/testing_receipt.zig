const std = @import("std");
const zstd = @import("zigeffect_std");

pub const schema = "zigeffect.test-suite-receipt.v2";
pub const schema_version: u32 = 2;

pub const Status = enum { passed, skipped, failed, pending };

pub const TestResult = struct {
    index: u32,
    id: []const u8,
    status: Status,
    error_name: ?[]const u8 = null,
    log_error_count: u32 = 0,
    leak_count: u32 = 0,
    duration_ms: u64 = 0,
};

pub const Counts = struct {
    discovered: u32,
    executed: u32,
    passed: u32,
    skipped: u32,
    failed: u32,
    pending: u32,
    log_errors: u32,
    leaks: u32,
};

pub const Execution = struct {
    zig_version: []const u8,
    target: []const u8,
    optimize: []const u8,
    seed: u32,
    runner_version: []const u8,
    replay_command: []const u8,
};

pub const Receipt = struct {
    schema: []const u8,
    schema_version: u32,
    suite: []const u8,
    status: Status,
    complete: bool,
    started_ms: i64,
    ended_ms: i64,
    duration_ms: u64,
    execution: Execution,
    counts: Counts,
    tests: []const TestResult,
    limitations: []const []const u8 = &.{},

    pub fn validate(self: Receipt) !void {
        if (!std.mem.eql(u8, self.schema, schema) or self.schema_version != schema_version) {
            return error.UnsupportedSchema;
        }
        if (self.suite.len == 0 or self.ended_ms < self.started_ms) return error.InvalidReceipt;
        if (self.execution.zig_version.len == 0 or self.execution.target.len == 0 or
            self.execution.optimize.len == 0 or self.execution.runner_version.len == 0 or
            self.execution.replay_command.len == 0)
        {
            return error.InvalidExecution;
        }
        if (self.counts.discovered != self.tests.len) return error.InvalidCounts;

        var computed = Counts{
            .discovered = @intCast(self.tests.len),
            .executed = 0,
            .passed = 0,
            .skipped = 0,
            .failed = 0,
            .pending = 0,
            .log_errors = 0,
            .leaks = 0,
        };
        for (self.tests, 0..) |result, index| {
            if (result.index != index or result.id.len == 0) return error.InvalidTest;
            for (self.tests[0..index]) |prior| {
                if (std.mem.eql(u8, prior.id, result.id)) return error.DuplicateTestId;
            }
            switch (result.status) {
                .passed => computed.passed += 1,
                .skipped => computed.skipped += 1,
                .failed => computed.failed += 1,
                .pending => computed.pending += 1,
            }
            if (result.status != .pending) computed.executed += 1;
            computed.log_errors +|= result.log_error_count;
            computed.leaks +|= result.leak_count;
        }
        if (!std.meta.eql(computed, self.counts)) return error.InvalidCounts;

        const complete = computed.executed == computed.discovered and computed.pending == 0;
        const passed = complete and computed.failed == 0 and computed.log_errors == 0 and computed.leaks == 0;
        if (self.complete != complete or (self.status == .passed) != passed) return error.InvalidVerdict;
    }
};

pub const ParsedReceipt = std.json.Parsed(Receipt);

pub fn parse(allocator: std.mem.Allocator, input: []const u8) !ParsedReceipt {
    if (zstd.Secrets.containsSecret(input)) return error.SecretMaterialRejected;
    var parsed = try std.json.parseFromSlice(
        Receipt,
        allocator,
        input,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    );
    errdefer parsed.deinit();
    try parsed.value.validate();
    return parsed;
}
