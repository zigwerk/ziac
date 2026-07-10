const std = @import("std");
const ziac = @import("ziac");

const cluster_mod = ziac.cockroach.cluster;

test "managed Cockroach Basic cluster is protected and order stable" {
    var first = try cluster_mod.Cluster.build(std.testing.allocator, .{}, .{
        .name = "ziac-prod",
        .plan = .{ .basic = .{
            .regions = &.{
                .{ .name = "us-central1" },
                .{ .name = "europe-west1", .primary = true },
            },
            .request_unit_limit = 10_000_000,
            .storage_mib_limit = 10_240,
        } },
    });
    defer first.deinit(std.testing.allocator);
    var reordered = try cluster_mod.Cluster.build(std.testing.allocator, .{}, .{
        .name = "ziac-prod",
        .plan = .{ .basic = .{
            .regions = &.{
                .{ .name = "europe-west1", .primary = true },
                .{ .name = "us-central1" },
            },
            .request_unit_limit = 10_000_000,
            .storage_mib_limit = 10_240,
        } },
    });
    defer reordered.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("cockroach.Cluster.ziac-prod", first.node.id);
    try std.testing.expectEqualStrings("cockroach.Cluster", first.node.type_name);
    try std.testing.expect(first.node.lifecycle.protect);
    try std.testing.expectEqual(@as(u64, 2 * 60 * 60 * 1000), first.node.lifecycle.operation_timeout_millis);
    try std.testing.expectEqual(first.node.inputs_hash, reordered.node.inputs_hash);
    try std.testing.expect(first.cluster_id == .resource_ref);
    try std.testing.expectEqualStrings("primary_private_endpoint_dns", first.primary_private_endpoint_dns.resource_ref.field);
    try std.testing.expectEqualStrings("delete_protection", first.delete_protection.resource_ref.field);

    const inputs = try first.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(inputs);
    try std.testing.expectEqualStrings(
        "{\"cloud_provider\":\"GCP\",\"name\":\"ziac-prod\",\"plan\":\"BASIC\",\"primary_region\":\"europe-west1\",\"protect\":true,\"regions\":[{\"name\":\"europe-west1\",\"node_count\":0,\"primary\":true},{\"name\":\"us-central1\",\"node_count\":0,\"primary\":false}],\"request_unit_limit\":10000000,\"storage_mib_limit\":10240}",
        inputs,
    );
}

test "managed Cockroach Standard and Advanced clusters encode plan-specific sizing" {
    var standard = try cluster_mod.Cluster.build(std.testing.allocator, .{}, .{
        .name = "ziac-std",
        .protect = false,
        .plan = .{ .standard = .{
            .regions = &.{.{ .name = "europe-west1" }},
            .provisioned_virtual_cpus = 4,
        } },
    });
    defer standard.deinit(std.testing.allocator);
    try std.testing.expect(!standard.node.lifecycle.protect);
    const standard_inputs = try standard.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(standard_inputs);
    try std.testing.expectEqualStrings(
        "{\"cloud_provider\":\"GCP\",\"name\":\"ziac-std\",\"plan\":\"STANDARD\",\"primary_region\":\"europe-west1\",\"protect\":false,\"provisioned_virtual_cpus\":4,\"regions\":[{\"name\":\"europe-west1\",\"node_count\":0,\"primary\":true}]}",
        standard_inputs,
    );

    var advanced = try cluster_mod.Cluster.build(std.testing.allocator, .{}, .{
        .name = "ziac-adv",
        .plan = .{ .advanced = .{
            .regions = &.{
                .{ .name = "us-central1", .node_count = 3 },
                .{ .name = "europe-west1", .node_count = 3 },
            },
            .num_virtual_cpus = 4,
            .storage_gib = 500,
            .cockroach_version = "v26.1",
            .private_network_visibility = true,
            .cidr_range = "172.28.0.0/14",
        } },
    });
    defer advanced.deinit(std.testing.allocator);
    const advanced_inputs = try advanced.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(advanced_inputs);
    try std.testing.expectEqualStrings(
        "{\"cidr_range\":\"172.28.0.0/14\",\"cloud_provider\":\"GCP\",\"cockroach_version\":\"v26.1\",\"name\":\"ziac-adv\",\"num_virtual_cpus\":4,\"plan\":\"ADVANCED\",\"private_network_visibility\":true,\"protect\":true,\"regions\":[{\"name\":\"europe-west1\",\"node_count\":3,\"primary\":false},{\"name\":\"us-central1\",\"node_count\":3,\"primary\":false}],\"storage_gib\":500}",
        advanced_inputs,
    );
}

test "managed Cockroach clusters reject invalid names topology and sizing" {
    try std.testing.expectError(error.InvalidClusterName, cluster_mod.Cluster.build(std.testing.allocator, .{}, .{
        .name = "Bad",
        .plan = .{ .basic = .{ .regions = &.{.{ .name = "europe-west1" }} } },
    }));
    try std.testing.expectError(error.MissingPrimaryRegion, cluster_mod.Cluster.build(std.testing.allocator, .{}, .{
        .name = "ziac-prod",
        .plan = .{ .basic = .{ .regions = &.{
            .{ .name = "europe-west1" },
            .{ .name = "us-central1" },
        } } },
    }));
    try std.testing.expectError(error.DuplicatePrimaryRegion, cluster_mod.Cluster.build(std.testing.allocator, .{}, .{
        .name = "ziac-prod",
        .plan = .{ .standard = .{
            .regions = &.{
                .{ .name = "europe-west1", .primary = true },
                .{ .name = "us-central1", .primary = true },
            },
            .provisioned_virtual_cpus = 2,
        } },
    }));
    try std.testing.expectError(error.InvalidSizing, cluster_mod.Cluster.build(std.testing.allocator, .{}, .{
        .name = "ziac-prod",
        .plan = .{ .standard = .{
            .regions = &.{.{ .name = "europe-west1" }},
            .provisioned_virtual_cpus = 0,
        } },
    }));
    try std.testing.expectError(error.InvalidSizing, cluster_mod.Cluster.build(std.testing.allocator, .{}, .{
        .name = "ziac-prod",
        .plan = .{ .advanced = .{
            .regions = &.{.{ .name = "europe-west1", .node_count = 0 }},
            .num_virtual_cpus = 4,
        } },
    }));
    try std.testing.expectError(error.InvalidCidrRange, cluster_mod.Cluster.build(std.testing.allocator, .{}, .{
        .name = "ziac-prod",
        .plan = .{ .advanced = .{
            .regions = &.{.{ .name = "europe-west1", .node_count = 3 }},
            .num_virtual_cpus = 4,
            .cidr_range = "172.28.0.0/20",
        } },
    }));
}

test "managed Cockroach cluster must be deployed unprotected before destroy planning" {
    var protected = try cluster_mod.Cluster.build(std.testing.allocator, .{}, .{
        .name = "ziac-prod",
        .plan = .{ .standard = .{
            .regions = &.{.{ .name = "europe-west1" }},
            .provisioned_virtual_cpus = 4,
        } },
    });
    defer protected.deinit(std.testing.allocator);
    var unprotected = try cluster_mod.Cluster.build(std.testing.allocator, .{}, .{
        .name = "ziac-prod",
        .protect = false,
        .plan = .{ .standard = .{
            .regions = &.{.{ .name = "europe-west1" }},
            .provisioned_virtual_cpus = 4,
        } },
    });
    defer unprotected.deinit(std.testing.allocator);
    var protected_graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer protected_graph.deinit();
    try protected_graph.addResource(protected.node);
    var unprotected_graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer unprotected_graph.deinit();
    try unprotected_graph.addResource(unprotected.node);
    var store = ziac.InMemoryStateStore.init(std.testing.allocator);
    defer store.deinit();
    var fake = ziac.provider.FakeProvider.init(std.testing.allocator);
    defer fake.deinit();
    var providers = ziac.provider.ProviderRegistry{};
    providers.register(.cockroach, fake.provider());

    var create_plan = try ziac.plan.buildPlan(std.testing.allocator, &protected_graph, &store);
    defer create_plan.deinit();
    try ziac.executor.executePlan(std.testing.allocator, &create_plan, &store, providers, .{});
    try std.testing.expect(store.get(protected.node.id).?.protect);
    try std.testing.expectError(error.ProtectedResource, ziac.plan.buildDestroyPlan(std.testing.allocator, &store));

    var unprotect_plan = try ziac.plan.buildPlan(std.testing.allocator, &unprotected_graph, &store);
    defer unprotect_plan.deinit();
    try std.testing.expectEqual(ziac.plan.OperationKind.update, unprotect_plan.operations[0].kind);
    try ziac.executor.executePlan(std.testing.allocator, &unprotect_plan, &store, providers, .{});
    try std.testing.expect(!store.get(unprotected.node.id).?.protect);

    var destroy_plan = try ziac.plan.buildDestroyPlan(std.testing.allocator, &store);
    defer destroy_plan.deinit();
    try std.testing.expectEqual(ziac.plan.OperationKind.delete, destroy_plan.operations[0].kind);
}
