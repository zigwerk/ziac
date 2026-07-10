const std = @import("std");
const ziac = @import("ziac");

test "fixture registry builds hello global stack graph and outputs" {
    var registry = ziac.stack_registry.fixtureRegistry();

    var program = try registry.build(std.testing.allocator, .{
        .stack = "hello-global",
        .stage = "dev",
    });
    defer program.deinit();

    try std.testing.expectEqual(@as(usize, 2), program.graph.resources.items.len);
    try std.testing.expectEqualStrings("gcp.artifact.Repository.europe-west1.hello-global", program.graph.resources.items[0].id);
    try std.testing.expectEqualStrings("gcp.run.Service.europe-west1.api", program.graph.resources.items[1].id);
    const service_inputs = try program.graph.resources.items[1].inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(service_inputs);
    try std.testing.expect(std.mem.indexOf(u8, service_inputs, "api:latest") != null);
    try std.testing.expect(std.mem.indexOf(u8, service_inputs, "sentinel-secret-for-tests") == null);
    try std.testing.expectEqual(@as(usize, 1), program.graph.dependencies.items.len);
    try std.testing.expectEqualStrings("gcp.run.Service.europe-west1.api", program.graph.dependencies.items[0].from);
    try std.testing.expectEqualStrings("gcp.artifact.Repository.europe-west1.hello-global", program.graph.dependencies.items[0].to);
    try std.testing.expectEqual(@as(usize, 6), program.outputs.items.len);
    try std.testing.expectEqualStrings("repository_url", program.outputs.items[0].name);
    try std.testing.expectEqualStrings("service_url", program.outputs.items[1].name);
    try std.testing.expectEqualStrings("service_name", program.outputs.items[2].name);
    try std.testing.expectEqualStrings("service_region", program.outputs.items[3].name);
    try std.testing.expectEqualStrings("service_account", program.outputs.items[4].name);
    try std.testing.expectEqualStrings("database_url", program.outputs.items[5].name);
    try std.testing.expect(program.outputs.items[5].secret);
    try std.testing.expect(program.outputs.items[0].source == .resource_ref);
    try std.testing.expectEqualStrings(
        "repository_url",
        program.outputs.items[0].source.resource_ref.field,
    );
    try std.testing.expect(program.outputs.items[1].source == .resource_ref);
    try std.testing.expectEqualStrings(
        "service_url",
        program.outputs.items[1].source.resource_ref.field,
    );
}

test "fixture registry rejects unknown stack names" {
    var registry = ziac.stack_registry.fixtureRegistry();

    try std.testing.expectError(error.UnknownStack, registry.build(std.testing.allocator, .{
        .stack = "missing",
        .stage = "dev",
    }));
}

test "fixture registry scopes preview repository service and generated image" {
    var registry = ziac.stack_registry.fixtureRegistry();
    var program = try registry.build(std.testing.allocator, .{
        .stack = "hello-global",
        .stage = "pr-42-9333e523",
    });
    defer program.deinit();

    try std.testing.expectEqualStrings(
        "gcp.artifact.Repository.europe-west1.hello-global-pr-42-9333e523",
        program.graph.resources.items[0].id,
    );
    try std.testing.expectEqualStrings(
        "gcp.run.Service.europe-west1.api-pr-42-9333e523",
        program.graph.resources.items[1].id,
    );
    const service_inputs = try program.graph.resources.items[1].inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(service_inputs);
    try std.testing.expect(std.mem.indexOf(u8, service_inputs, "/hello-global-pr-42-9333e523/api:latest") != null);
    try std.testing.expect(program.outputs.items[2].source == .literal);
    try std.testing.expectEqualStrings("api-pr-42-9333e523", program.outputs.items[2].source.literal);
}

test "configured registry builds the global ContainerService stack" {
    const regions = [_][]const u8{ "europe-west1", "us-central1" };
    var registry = ziac.stack_registry.configuredRegistry(.{
        .project_id = "test-ziac-disposable",
        .region = regions[0],
        .regions = &regions,
        .service_account = "api@test-ziac-disposable.iam.gserviceaccount.com",
        .image = "europe-west1-docker.pkg.dev/test-ziac-disposable/apps/api@sha256:abc",
        .domain = "api.example.com",
        .dns_zone = "example-com",
    });

    var program = try registry.build(std.testing.allocator, .{
        .stack = "global-container",
        .stage = "smoke",
    });
    defer program.deinit();

    try std.testing.expectEqual(@as(usize, 14), program.graph.resources.items.len);
    try std.testing.expectEqual(@as(usize, 14), program.graph.dependencies.items.len);
    try std.testing.expect(hasDependency(
        &program.graph,
        "gcp.run.Service.us-central1.api",
        "gcp.run.Service.europe-west1.api",
    ));
    try std.testing.expectEqual(@as(usize, 5), program.outputs.items.len);
    try std.testing.expectEqualStrings("url", program.outputs.items[0].name);
    try std.testing.expectEqualStrings("ip_address", program.outputs.items[1].name);
    try std.testing.expectEqualStrings("certificate_status", program.outputs.items[2].name);
    try std.testing.expectEqualStrings("service_url_europe-west1", program.outputs.items[3].name);
    try std.testing.expectEqualStrings("service_url_us-central1", program.outputs.items[4].name);
    try std.testing.expect(program.outputs.items[1].source == .resource_ref);
    try std.testing.expectEqualStrings("address", program.outputs.items[1].source.resource_ref.field);
}

fn hasDependency(graph: *const ziac.ResourceGraph, from: []const u8, to: []const u8) bool {
    for (graph.dependencies.items) |edge| {
        if (std.mem.eql(u8, edge.from, from) and std.mem.eql(u8, edge.to, to)) return true;
    }
    return false;
}

test "configured registry isolates global preview names and domains" {
    const regions = [_][]const u8{ "europe-west1", "us-central1" };
    var registry = ziac.stack_registry.configuredRegistry(.{
        .project_id = "test-ziac-disposable",
        .region = regions[0],
        .regions = &regions,
        .service_account = "api@test-ziac-disposable.iam.gserviceaccount.com",
        .image = "europe-west1-docker.pkg.dev/test-ziac-disposable/apps/api@sha256:abc",
        .domain = "api.example.com",
        .dns_zone = "example-com",
    });
    var first = try registry.build(std.testing.allocator, .{
        .stack = "global-container",
        .stage = "pr-42-9333e523",
    });
    defer first.deinit();
    var second = try registry.build(std.testing.allocator, .{
        .stack = "global-container",
        .stage = "pr-43-9333e523",
    });
    defer second.deinit();

    try std.testing.expectEqual(first.graph.resources.items.len, second.graph.resources.items.len);
    for (first.graph.resources.items, second.graph.resources.items) |left, right| {
        if (std.mem.eql(u8, left.type_name, "gcp.project.Service")) {
            try std.testing.expectEqualStrings(left.id, right.id);
            continue;
        }
        try std.testing.expect(!std.mem.eql(u8, left.id, right.id));
        try std.testing.expect(std.mem.indexOf(u8, left.id, "pr-42-9333e523") != null);
        try std.testing.expect(std.mem.indexOf(u8, right.id, "pr-43-9333e523") != null);
    }
    try std.testing.expect(first.outputs.items[0].source == .literal);
    try std.testing.expectEqualStrings(
        "https://pr-42-9333e523.api.example.com",
        first.outputs.items[0].source.literal,
    );
    try std.testing.expectEqualStrings(
        "https://pr-43-9333e523.api.example.com",
        second.outputs.items[0].source.literal,
    );
}

test "live region CSV parsing rejects empty entries" {
    const parsed = try ziac.stack_registry.regionsFromCsvAlloc(std.testing.allocator, "europe-west1,us-central1");
    defer std.testing.allocator.free(parsed);
    try std.testing.expectEqual(@as(usize, 2), parsed.len);
    try std.testing.expectEqualStrings("europe-west1", parsed[0]);
    try std.testing.expectEqualStrings("us-central1", parsed[1]);
    try std.testing.expectError(
        error.InvalidRegionList,
        ziac.stack_registry.regionsFromCsvAlloc(std.testing.allocator, "europe-west1,,us-central1"),
    );
}
