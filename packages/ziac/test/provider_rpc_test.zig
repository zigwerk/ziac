const std = @import("std");
const ziac = @import("ziac");

const descriptor = ziac.provider_rpc.Descriptor{
    .package_name = "ziac/provider-fixture",
    .package_version = "1.2.3",
    .provider = .gcp,
    .resource_type_prefixes = &.{"gcp.fixture."},
    .capabilities = .all,
    .max_inflight = 1,
};

fn fixtureNode(image: []const u8) !ziac.ResourceNode {
    return ziac.ResourceNode.initOwned(std.testing.allocator, .{
        .id = "gcp.fixture.Service.europe-west1.api",
        .provider = .gcp,
        .type_name = "gcp.fixture.Service",
        .schema_version = 7,
        .logical_id = "api",
        .inputs = .{ .object = &.{
            .{ .name = "image", .value = .{ .string = image } },
            .{ .name = "secret", .value = .{ .secret_ref = .{ .provider = "gcp", .resource = "api-key", .version = "latest" } } },
        } },
        .lifecycle = .{
            .protect = true,
            .retain_on_delete = true,
            .replace_before_delete = true,
            .ignore_changes = &.{"labels.generated"},
            .operation_timeout_millis = 42_000,
        },
    });
}

test "provider RPC v1 negotiates identity and implements the complete provider vtable" {
    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    fake.result_operation_handle = "operations/create-api";
    fake.result_completed = false;

    var session = ziac.provider_rpc.ServerSession.init(std.testing.allocator, descriptor, fake.provider());
    var loopback = ziac.provider_rpc.LoopbackTransport.init(&session);
    defer loopback.deinit();
    var client = try ziac.provider_rpc.Client.init(std.testing.allocator, loopback.transport(), .{
        .package_name = descriptor.package_name,
        .package_version = descriptor.package_version,
        .provider = descriptor.provider,
    });
    defer client.deinit();
    const rpc_provider = client.provider();

    try std.testing.expectEqual(@as(u16, 1), client.negotiated.protocol_major);
    try std.testing.expectEqual(@as(u16, 0), client.negotiated.protocol_minor);
    try std.testing.expectEqual(@as(u16, 1), client.negotiated.max_inflight);
    try std.testing.expect(client.negotiated.capabilities.create);

    var node = try fixtureNode("example/api:v1");
    defer node.deinit(std.testing.allocator);
    var before = try rpc_provider.read(std.testing.allocator, node);
    defer before.deinit();
    try std.testing.expect(before == .absent);

    var created = try rpc_provider.create(std.testing.allocator, node);
    defer created.deinit();
    try std.testing.expectEqualStrings("fake/gcp.fixture.Service.europe-west1.api", created.physical_id);
    try std.testing.expectEqualStrings("operations/create-api", created.operation_handle.?);
    try std.testing.expect(!created.completed);
    try std.testing.expectEqualStrings("api-key", created.observed_inputs.object[1].value.secret_ref.resource);

    fake.result_operation_handle = null;
    fake.result_completed = true;
    var after = try rpc_provider.read(std.testing.allocator, node);
    defer after.deinit();
    try std.testing.expect(after == .present);
    var no_change = try rpc_provider.diff(std.testing.allocator, node, &after.present);
    defer no_change.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.noop, no_change.kind);

    var changed = try fixtureNode("example/api:v2");
    defer changed.deinit(std.testing.allocator);
    var changed_diff = try rpc_provider.diff(std.testing.allocator, changed, &after.present);
    defer changed_diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, changed_diff.kind);
    try std.testing.expectEqualStrings("desired inputs changed", changed_diff.reasons[0]);

    var updated = try rpc_provider.update(std.testing.allocator, changed, &after.present);
    defer updated.deinit();
    try std.testing.expectEqual(changed.inputs_hash, updated.observed_hash);

    var delete_context = ziac.provider.OperationContext.init(std.testing.allocator);
    delete_context.destructive_confirmation = true;
    try rpc_provider.deleteWithContext(&delete_context, changed, updated.physical_id);

    var imported = try rpc_provider.importResource(std.testing.allocator, changed, "projects/example/fixtures/api");
    defer imported.deinit();
    try std.testing.expectEqualStrings("projects/example/fixtures/api", imported.physical_id);

    try rpc_provider.deleteWithContext(&delete_context, changed, imported.physical_id);
    try std.testing.expect(fake.last_delete_destructive_confirmation);
}

test "provider RPC v1 transfers state references and bounded diagnostics without secret material" {
    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    var session = ziac.provider_rpc.ServerSession.init(std.testing.allocator, descriptor, fake.provider());
    var loopback = ziac.provider_rpc.LoopbackTransport.init(&session);
    defer loopback.deinit();
    var client = try ziac.provider_rpc.Client.init(std.testing.allocator, loopback.transport(), .{
        .package_name = descriptor.package_name,
        .package_version = descriptor.package_version,
        .provider = descriptor.provider,
    });
    defer client.deinit();

    var store = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer store.deinit();
    try store.put(.{
        .resource_id = "gcp.fixture.SecretVersion.api-key",
        .provider = .gcp,
        .type_name = "gcp.fixture.SecretVersion",
        .logical_id = "api-key",
        .desired_hash = "desired",
        .outputs = &.{
            .{ .name = "name", .value = .{ .string = "projects/example/secrets/api-key/versions/1" } },
            .{ .name = "secret", .value = .{ .secret_ref = .{ .provider = "gcp", .resource = "api-key", .version = "1" } } },
        },
        .status = .created,
    });

    var node = try fixtureNode("example/api:v1");
    defer node.deinit(std.testing.allocator);
    fake.fail_next = error.QuotaExceeded;
    fake.diagnostic_next = .{
        .category = .quota,
        .service = "fixture.googleapis.com",
        .request_id = "rpc-request-42",
        .message = "quota exhausted",
        .quota_metric = "fixture.googleapis.com/resources",
    };
    var recorder = ziac.provider_error.DiagnosticRecorder.init(std.testing.allocator);
    defer recorder.deinit();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    context.state = &store;
    context.deadline_millis = std.math.maxInt(u64);
    context.physical_id = "existing/api";
    context.operation_handle = "operations/repair-api";
    context.diagnostics = &recorder;

    try std.testing.expectError(error.QuotaExceeded, client.provider().readWithContext(&context, node));
    var diagnostic = (try recorder.snapshotAlloc(std.testing.allocator)).?;
    defer diagnostic.deinit();
    try std.testing.expectEqual(ziac.provider_error.Category.quota, diagnostic.category);
    try std.testing.expectEqualStrings("rpc-request-42", diagnostic.request_id.?);
    try std.testing.expectEqualStrings("fixture.googleapis.com/resources", diagnostic.quota_metric.?);
    try std.testing.expect(std.mem.indexOf(u8, loopback.last_request, "projects/example/secrets/api-key/versions/1") != null);
    try std.testing.expect(std.mem.indexOf(u8, loopback.last_request, "secret plaintext sentinel") == null);
}

test "provider RPC v1 rejects unhandshaken calls identity mismatches and unauthorized resource types" {
    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    var session = ziac.provider_rpc.ServerSession.init(std.testing.allocator, descriptor, fake.provider());

    try std.testing.expectError(error.HandshakeRequired, session.handleAlloc(
        std.testing.allocator,
        "{\"schema\":\"ziac.provider.rpc.v1\",\"id\":1,\"method\":\"read\"}",
    ));

    var mismatch_session = ziac.provider_rpc.ServerSession.init(std.testing.allocator, descriptor, fake.provider());
    var mismatch_transport = ziac.provider_rpc.LoopbackTransport.init(&mismatch_session);
    defer mismatch_transport.deinit();
    try std.testing.expectError(error.ProviderIdentityMismatch, ziac.provider_rpc.Client.init(std.testing.allocator, mismatch_transport.transport(), .{
        .package_name = descriptor.package_name,
        .package_version = "9.9.9",
        .provider = descriptor.provider,
    }));

    var loopback = ziac.provider_rpc.LoopbackTransport.init(&session);
    defer loopback.deinit();
    var client = try ziac.provider_rpc.Client.init(std.testing.allocator, loopback.transport(), .{
        .package_name = descriptor.package_name,
        .package_version = descriptor.package_version,
        .provider = descriptor.provider,
    });
    defer client.deinit();
    var unauthorized = try ziac.ResourceNode.initOwned(std.testing.allocator, .{
        .id = "gcp.compute.Instance.api",
        .provider = .gcp,
        .type_name = "gcp.compute.Instance",
        .logical_id = "api",
    });
    defer unauthorized.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidConfiguration, client.provider().read(std.testing.allocator, unauthorized));
}
