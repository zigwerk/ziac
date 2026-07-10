const std = @import("std");
const ziac = @import("ziac");

test "saved plan round trips full operations and content identity" {
    var fixture = try PlanFixture.init();
    defer fixture.deinit();
    var encoded = try ziac.plan_format.serializeAlloc(std.testing.allocator, &fixture.planned, .{
        .stack = "api",
        .stage = "prod",
        .created_at_millis = 1_725_000_000_000,
    });
    defer encoded.deinit();

    try std.testing.expect(encoded.approval_required);
    try std.testing.expect(std.mem.indexOf(u8, encoded.bytes, "sentinel-secret-plaintext") == null);
    try std.testing.expect(std.mem.indexOf(u8, encoded.bytes, "\"$secret\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded.bytes, "\"$output\"") != null);

    var loaded = try ziac.plan_format.parseAlloc(std.testing.allocator, encoded.bytes);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("api", loaded.stack);
    try std.testing.expectEqualStrings("prod", loaded.stage);
    try std.testing.expectEqual(@as(u64, 1_725_000_000_000), loaded.created_at_millis);
    try std.testing.expectEqualSlices(u8, &encoded.digest, &loaded.digest);
    try std.testing.expect(loaded.approval_required);
    try std.testing.expectEqual(fixture.planned.operations.len, loaded.plan.operations.len);
    try std.testing.expectEqualSlices(
        u8,
        &fixture.planned.preconditions.desired_graph_digest,
        &loaded.plan.preconditions.desired_graph_digest,
    );
    try std.testing.expectEqualSlices(
        u8,
        &fixture.planned.preconditions.operations_digest,
        &loaded.plan.preconditions.operations_digest,
    );
    const loaded_digest = try ziac.plan.operationsDigestAlloc(std.testing.allocator, loaded.plan.operations);
    try std.testing.expectEqualSlices(u8, &fixture.planned.preconditions.operations_digest, &loaded_digest);

    const service = findOperation(loaded.plan.operations, "gcp.run.Service.api");
    try std.testing.expectEqual(ziac.plan.OperationKind.create, service.kind);
    try std.testing.expectEqual(@as(usize, 1), service.dependencies.len);
    try std.testing.expectEqualStrings("gcp.artifact.Repository.images", service.dependencies[0]);
    try std.testing.expectEqual(@as(u64, 600_000), service.resource.lifecycle.operation_timeout_millis);
    try std.testing.expectEqual(@as(usize, 2), service.resource.lifecycle.ignore_changes.len);
}

test "saved plan parser rejects input operation envelope and approval tampering" {
    var fixture = try PlanFixture.init();
    defer fixture.deinit();
    var encoded = try ziac.plan_format.serializeAlloc(std.testing.allocator, &fixture.planned, .{
        .stack = "api",
        .stage = "prod",
        .created_at_millis = 1,
    });
    defer encoded.deinit();

    const input_tamper = try replaceOnce(encoded.bytes, "example/api:v1", "example/api:v2");
    defer std.testing.allocator.free(input_tamper);
    try std.testing.expectError(error.PlanIntegrityMismatch, ziac.plan_format.parseAlloc(std.testing.allocator, input_tamper));

    const operation_tamper = try replaceOnce(encoded.bytes, "resource is not in state", "resource was not in state");
    defer std.testing.allocator.free(operation_tamper);
    try std.testing.expectError(error.PlanIntegrityMismatch, ziac.plan_format.parseAlloc(std.testing.allocator, operation_tamper));

    const envelope_tamper = try replaceHexDigitAfter(encoded.bytes, "\"plan_digest\":\"");
    defer std.testing.allocator.free(envelope_tamper);
    try std.testing.expectError(error.PlanIntegrityMismatch, ziac.plan_format.parseAlloc(std.testing.allocator, envelope_tamper));

    const approval_tamper = try replaceOnce(encoded.bytes, "\"approval_required\":true", "\"approval_required\":false");
    defer std.testing.allocator.free(approval_tamper);
    try std.testing.expectError(error.PlanIntegrityMismatch, ziac.plan_format.parseAlloc(std.testing.allocator, approval_tamper));
}

test "saved plan parser rejects unknown versions malformed hashes and targets" {
    var fixture = try PlanFixture.init();
    defer fixture.deinit();
    var encoded = try ziac.plan_format.serializeAlloc(std.testing.allocator, &fixture.planned, .{
        .stack = "api",
        .stage = "prod",
        .created_at_millis = 1,
    });
    defer encoded.deinit();

    const future = try replaceOnce(encoded.bytes, "\"format_version\":1", "\"format_version\":2");
    defer std.testing.allocator.free(future);
    try std.testing.expectError(error.UnsupportedPlanVersion, ziac.plan_format.parseAlloc(std.testing.allocator, future));

    const malformed_hash = try replaceOnce(encoded.bytes, "\"lineage_hash\":\"", "\"lineage_hash\":\"z");
    defer std.testing.allocator.free(malformed_hash);
    try std.testing.expectError(error.InvalidPlanFile, ziac.plan_format.parseAlloc(std.testing.allocator, malformed_hash));

    try std.testing.expectError(error.InvalidPlanTarget, ziac.plan_format.serializeAlloc(std.testing.allocator, &fixture.planned, .{
        .stack = "../api",
        .stage = "prod",
        .created_at_millis = 1,
    }));
}

test "saved plan files are create exclusive and bounded on load" {
    var fixture = try PlanFixture.init();
    defer fixture.deinit();
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    const files = ziac.local_state.memoryFiles(&fs);

    const metadata = try ziac.plan_format.save(files, std.testing.allocator, "review/api.plan.json", &fixture.planned, .{
        .stack = "api",
        .stage = "prod",
        .created_at_millis = 1,
    });
    try std.testing.expect(metadata.approval_required);
    try std.testing.expectError(error.PlanAlreadyExists, ziac.plan_format.save(files, std.testing.allocator, "review/api.plan.json", &fixture.planned, .{
        .stack = "api",
        .stage = "prod",
        .created_at_millis = 2,
    }));

    var loaded = try ziac.plan_format.load(files, std.testing.allocator, "review/api.plan.json", .{});
    defer loaded.deinit();
    try std.testing.expectEqualSlices(u8, &metadata.digest, &loaded.digest);
    try std.testing.expectError(error.PlanTooLarge, ziac.plan_format.load(files, std.testing.allocator, "review/api.plan.json", .{
        .max_bytes = 8,
    }));
}

const PlanFixture = struct {
    graph: ziac.ResourceGraph,
    state: ziac.InMemoryStateStore,
    planned: ziac.plan.Plan,

    fn init() !PlanFixture {
        var graph = ziac.ResourceGraph.init(std.testing.allocator);
        errdefer graph.deinit();
        try graph.addResource(.{
            .id = "gcp.artifact.Repository.images",
            .provider = .gcp,
            .type_name = "gcp.artifact.Repository",
            .logical_id = "images",
            .inputs = .{ .object = &.{.{ .name = "location", .value = .{ .string = "europe-west1" } }} },
        });
        try graph.addResource(.{
            .id = "gcp.run.Service.api",
            .provider = .gcp,
            .type_name = "gcp.run.Service",
            .logical_id = "api",
            .inputs = .{ .object = &.{
                .{ .name = "database_url", .value = .{ .secret_ref = .{
                    .provider = "gcp-secret-manager",
                    .resource = "projects/ziac-prod/secrets/database-url",
                    .version = "latest",
                } } },
                .{ .name = "image", .value = .{ .string = "example/api:v1" } },
                .{ .name = "repository", .value = .{ .output_ref = .{
                    .resource_id = "gcp.artifact.Repository.images",
                    .field = "url",
                } } },
            } },
            .lifecycle = .{
                .ignore_changes = &.{ "labels", "annotations" },
                .operation_timeout_millis = 600_000,
            },
        });
        var state = ziac.InMemoryStateStore.init(std.testing.allocator);
        errdefer state.deinit();
        state.setLineage("api/prod");
        try state.put(.{
            .resource_id = "gcp.run.Service.old",
            .provider = .gcp,
            .type_name = "gcp.run.Service",
            .logical_id = "old",
            .desired_hash = "old",
            .status = .created,
        });
        return .{
            .graph = graph,
            .state = state,
            .planned = try ziac.plan.buildPlan(std.testing.allocator, &graph, &state),
        };
    }

    fn deinit(self: *PlanFixture) void {
        self.planned.deinit();
        self.state.deinit();
        self.graph.deinit();
    }
};

fn findOperation(operations: []const ziac.plan.PlanOperation, id: []const u8) ziac.plan.PlanOperation {
    for (operations) |operation| if (std.mem.eql(u8, operation.resource.id, id)) return operation;
    unreachable;
}

fn replaceOnce(input: []const u8, needle: []const u8, replacement: []const u8) ![]u8 {
    const index = std.mem.indexOf(u8, input, needle) orelse return error.TestNeedleMissing;
    const size = input.len - needle.len + replacement.len;
    const output = try std.testing.allocator.alloc(u8, size);
    @memcpy(output[0..index], input[0..index]);
    @memcpy(output[index .. index + replacement.len], replacement);
    @memcpy(output[index + replacement.len ..], input[index + needle.len ..]);
    return output;
}

fn replaceHexDigitAfter(input: []const u8, marker: []const u8) ![]u8 {
    const output = try std.testing.allocator.dupe(u8, input);
    const marker_index = std.mem.indexOf(u8, output, marker) orelse return error.TestNeedleMissing;
    const index = marker_index + marker.len;
    output[index] = if (output[index] == '0') '1' else '0';
    return output;
}
