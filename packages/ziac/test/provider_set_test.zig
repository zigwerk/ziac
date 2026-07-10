const std = @import("std");
const ziac = @import("ziac");

test "provider sets are duplicate-free and canonically stable" {
    const First = ziac.stack.ProviderSet(.{ ziac.resource.ProviderId.cockroach, ziac.resource.ProviderId.gcp });
    const Second = ziac.stack.ProviderSet(.{ ziac.resource.ProviderId.gcp, ziac.resource.ProviderId.cockroach });

    try std.testing.expectEqualSlices(ziac.resource.ProviderId, &First.ids, &Second.ids);
    try std.testing.expectEqualSlices(
        ziac.resource.ProviderId,
        &.{ .gcp, .cockroach },
        &First.ids,
    );
    try std.testing.expect(First.has(.gcp));
    try std.testing.expect(First.has(.cockroach));
    try std.testing.expect(!First.has(.local));
}

test "typed stack context exposes only declared provider namespaces" {
    const Providers = ziac.stack.ProviderSet(.{ ziac.resource.ProviderId.gcp, ziac.resource.ProviderId.cockroach });
    const Context = ziac.stack.Context(Providers);
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    var context = Context.init(std.testing.allocator, &graph);

    try std.testing.expect(@TypeOf(context.gcp()) == ziac.stack.GcpNamespace);
    try std.testing.expect(@TypeOf(context.cockroach()) == ziac.stack.CockroachNamespace);
}

test "runtime provider registry is derived from comptime provider set" {
    const Providers = ziac.stack.ProviderSet(.{ziac.resource.ProviderId.gcp});
    var fake_gcp = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake_gcp.deinit();
    var fake_cockroach = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake_cockroach.deinit();

    const registry = ziac.stack.runtimeRegistry(Providers, .{
        .gcp = fake_gcp.provider(),
        .cockroach = fake_cockroach.provider(),
    });

    _ = try registry.get(.gcp);
    try std.testing.expectError(error.InvalidConfiguration, registry.get(.cockroach));
}
