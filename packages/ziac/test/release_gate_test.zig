const std = @import("std");

const AutomatedGate = struct {
    command: []const u8,
    includes: []const []const u8,
};

const LiveTest = struct {
    id: []const u8,
    command: []const u8,
    authenticated: bool,
    required_environment: []const []const u8,
    safety_constraints: []const []const u8,
    evidence: []const []const u8,
};

const Manifest = struct {
    schema: []const u8,
    version: u32,
    automated_gate: AutomatedGate,
    live_tests: []const LiveTest,
};

test "release manifest declares deterministic and authenticated acceptance gates" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "release/live-tests.json",
        std.testing.allocator,
        .limited(256 * 1024),
    );
    defer std.testing.allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(Manifest, std.testing.allocator, bytes, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();
    const manifest = parsed.value;

    try std.testing.expectEqualStrings("ziac.release.live-tests.v1", manifest.schema);
    try std.testing.expectEqual(@as(u32, 1), manifest.version);
    try std.testing.expectEqualStrings("zig build release-gate --summary all", manifest.automated_gate.command);
    for ([_][]const u8{
        "formatting",
        "unit-and-compile-fail",
        "provider-contracts",
        "interruption-and-state-migration",
        "examples-and-cli",
        "native-container",
        "secret-scan",
    }) |required| try expectContains(manifest.automated_gate.includes, required);

    for (manifest.live_tests, 0..) |entry, index| {
        try std.testing.expect(entry.id.len > 0);
        try std.testing.expect(entry.command.len > 0);
        try std.testing.expect(entry.safety_constraints.len > 0);
        try std.testing.expect(entry.evidence.len > 0);
        if (entry.authenticated) try std.testing.expect(entry.required_environment.len > 0);
        for (manifest.live_tests[index + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, entry.id, other.id));
        }
    }

    try expectLiveTest(manifest.live_tests, "gcp-global-container", true);
    try expectLiveTest(manifest.live_tests, "cockroach-cloud-sql", true);
    try expectLiveTest(manifest.live_tests, "cockroach-local-verified-tls", false);
}

fn expectLiveTest(entries: []const LiveTest, id: []const u8, authenticated: bool) !void {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.id, id)) {
            try std.testing.expectEqual(authenticated, entry.authenticated);
            return;
        }
    }
    return error.MissingLiveTest;
}

fn expectContains(values: []const []const u8, expected: []const u8) !void {
    for (values) |value| if (std.mem.eql(u8, value, expected)) return;
    return error.MissingGateCapability;
}
