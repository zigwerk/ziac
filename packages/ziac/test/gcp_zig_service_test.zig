const std = @import("std");
const ziac = @import("ziac");

const regions = [_][]const u8{ "europe-west1", "us-central1" };
const Providers = ziac.stack.ProviderSet(.{ziac.resource.ProviderId.gcp});

const App = struct {
    pub const Env = struct {
        release: ziac.binding.Value([]const u8),
        database_url: ziac.binding.Secret([]const u8),
    };
};

const Bindings = struct {
    release: ziac.PublicOutput([]const u8),
    database_url: ziac.Output(ziac.value.SecretReference, .secret),
};

test "global ZigService composes source build bindings identities and global routing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSource(tmp.dir, "src/main.zig", "pub fn main() void {}\n");
    try writeSource(tmp.dir, "build.zig", "pub fn build() void {}\n");
    var version = try ziac.gcp.secret_manager.SecretVersion.build(std.testing.allocator, provider(), .{
        .name = "initial",
        .secret_id = "database-url",
        .source = .{ .provider = "fixture", .resource = "database-url" },
    });
    defer version.deinit(std.testing.allocator);
    var base = ziac.ResourceGraph.init(std.testing.allocator);
    defer base.deinit();
    try base.addResource(version.node);
    const Service = ziac.gcp.global.ZigService(App, Bindings, Providers);
    var component = try Service.build(std.testing.allocator, provider(), .{
        .base_graph = &base,
        .source = .{ .io = std.testing.io, .root = tmp.dir },
        .name = "api",
        .artifact_name = "sample-api",
        .regions = &regions,
        .domain = "api.example.com",
        .dns_zone = "example-com",
        .bindings = .{
            .release = .{ .value = "test" },
            .database_url = version.version,
        },
    });
    defer component.deinit();

    try std.testing.expectEqualStrings("https://api.example.com", component.url.value);
    try std.testing.expect(component.image_ref == .resource_ref);
    try std.testing.expect(component.image_digest == .resource_ref);
    try std.testing.expect(component.repository_url == .resource_ref);
    try std.testing.expect(std.mem.indexOf(u8, component.dockerfile(), "ENTRYPOINT [\"/app/sample-api\"]") != null);
    try std.testing.expectEqual(@as(usize, 1), countType(&component.graph, "gcp.storage.BuildBucket"));
    try std.testing.expectEqual(@as(usize, 1), countType(&component.graph, "gcp.storage.SourceObject"));
    try std.testing.expectEqual(@as(usize, 1), countType(&component.graph, "gcp.cloudbuild.ZigImage"));
    try std.testing.expectEqual(ziac.gcp.global.Realization.native_multi_region, component.realization);
    try std.testing.expectEqual(@as(usize, 1), countType(&component.graph, "gcp.run.Service"));
    try std.testing.expectEqual(@as(usize, 2), countType(&component.graph, "gcp.iam.ServiceAccount"));
    try std.testing.expectEqual(@as(usize, 3), countType(&component.graph, "gcp.iam.ProjectMember"));
    try std.testing.expectEqual(@as(usize, 1), countType(&component.graph, "gcp.secret.SecretIamMember"));
    try std.testing.expect(countType(&component.graph, "gcp.project.Service") >= 9);

    const image = findType(&component.graph, "gcp.cloudbuild.ZigImage");
    const source = findType(&component.graph, "gcp.storage.SourceObject");
    try std.testing.expectEqualStrings(component.source_path, inputValue(source, "source_path").string);
    try std.testing.expectEqualStrings(&component.source_digest, inputValue(source, "source_digest").string);
    try std.testing.expectEqualStrings(&component.build_digest, inputValue(image, "build_digest").string);
    try std.testing.expect(std.mem.startsWith(u8, inputValue(image, "service_account").string, "projects/ziac-dev/serviceAccounts/api-build"));

    for (component.graph.resources.items) |node| {
        if (!std.mem.eql(u8, node.type_name, "gcp.run.Service")) continue;
        const image_input = inputValue(node, "image");
        try std.testing.expect(image_input == .output_ref);
        try std.testing.expectEqualStrings(image.id, image_input.output_ref.resource_id);
        const env = inputValue(node, "env").list;
        try std.testing.expectEqual(@as(usize, 2), env.len);
        try std.testing.expectEqualStrings("RELEASE", objectValue(env[0].object, "name").string);
        try std.testing.expectEqualStrings("DATABASE_URL", objectValue(env[1].object, "name").string);
        try std.testing.expect(objectValue(env[1].object, "value") == .output_ref);
        try std.testing.expectEqualStrings(version.node.id, objectValue(env[1].object, "value").output_ref.resource_id);
        try std.testing.expectEqualStrings("/health/startup", objectValue(inputValue(node, "startup_probe").object, "path").string);
        try std.testing.expectEqualStrings("/health/live", objectValue(inputValue(node, "liveness_probe").object, "path").string);
    }
    try component.graph.validateAcyclic();

    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var payload = try component.payloadSource().resolve(&context, std.testing.allocator, component.source_path);
    defer payload.deinit();
    const integrity = ziac.gcp.storage.integrity(payload.bytes);
    try std.testing.expectEqualStrings(&component.source_digest, &integrity.sha256);
    try std.testing.expectEqual(@as(u64, @intCast(inputValue(source, "size").integer)), integrity.size);
    try std.testing.expectEqualStrings(inputValue(source, "crc32c").string, &integrity.crc32c);
}

test "global ZigService ignores excluded noise and changes identity for source edits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSource(tmp.dir, ".ziacignore", "ignored.txt\n");
    try writeSource(tmp.dir, "ignored.txt", "first\n");
    try writeSource(tmp.dir, "src/main.zig", "pub fn main() void {}\n");
    try writeSource(tmp.dir, "build.zig", "pub fn build() void {}\n");
    const EmptyApp = struct {
        pub const Env = struct {};
    };
    const EmptyBindings = struct {};
    const Service = ziac.gcp.global.ZigService(EmptyApp, EmptyBindings, Providers);
    const args = Service.Args{
        .source = .{ .io = std.testing.io, .root = tmp.dir },
        .name = "api",
        .artifact_name = "sample-api",
        .regions = &regions,
        .domain = "api.example.com",
        .bindings = .{},
        .manage_apis = false,
    };
    var original = try Service.build(std.testing.allocator, provider(), args);
    defer original.deinit();

    try writeSource(tmp.dir, "ignored.txt", "changed but ignored\n");
    var noise_changed = try Service.build(std.testing.allocator, provider(), args);
    defer noise_changed.deinit();
    try std.testing.expectEqualStrings(&original.source_digest, &noise_changed.source_digest);
    try std.testing.expectEqualStrings(&original.build_digest, &noise_changed.build_digest);

    try writeSource(tmp.dir, "src/main.zig", "pub fn main() void { @panic(\"changed\"); }\n");
    var source_changed = try Service.build(std.testing.allocator, provider(), args);
    defer source_changed.deinit();
    try std.testing.expect(!std.mem.eql(u8, &original.source_digest, &source_changed.source_digest));
    try std.testing.expect(!std.mem.eql(u8, &original.build_digest, &source_changed.build_digest));

    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var stale_payload = try original.payloadSource().resolve(&context, std.testing.allocator, original.source_path);
    defer stale_payload.deinit();
    try std.testing.expect(!std.mem.eql(u8, &ziac.gcp.storage.integrity(stale_payload.bytes).sha256, &original.source_digest));
}

test "global ZigService rejects a conflicting project API in a base graph" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSource(tmp.dir, "src/main.zig", "pub fn main() void {}\n");
    try writeSource(tmp.dir, "build.zig", "pub fn build() void {}\n");
    var conflicting_provider = provider();
    conflicting_provider.project_id = "another-project";
    var api = try ziac.gcp.project_service.Service.build(std.testing.allocator, conflicting_provider, .{
        .service = "run.googleapis.com",
    });
    defer api.deinit(std.testing.allocator);
    var base = ziac.ResourceGraph.init(std.testing.allocator);
    defer base.deinit();
    try base.addResource(api.node);
    const EmptyApp = struct {
        pub const Env = struct {};
    };
    const EmptyBindings = struct {};
    const Service = ziac.gcp.global.ZigService(EmptyApp, EmptyBindings, Providers);

    try std.testing.expectError(error.DuplicateResource, Service.build(std.testing.allocator, provider(), .{
        .base_graph = &base,
        .source = .{ .io = std.testing.io, .root = tmp.dir },
        .name = "api",
        .artifact_name = "sample-api",
        .regions = &regions,
        .domain = "api.example.com",
        .bindings = .{},
    }));
}

test "global ZigService rejects non-GCP and cross-project secret references" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSource(tmp.dir, "src/main.zig", "pub fn main() void {}\n");
    try writeSource(tmp.dir, "build.zig", "pub fn build() void {}\n");
    const Service = ziac.gcp.global.ZigService(App, Bindings, Providers);
    const common = Service.Args{
        .source = .{ .io = std.testing.io, .root = tmp.dir },
        .name = "api",
        .artifact_name = "sample-api",
        .regions = &regions,
        .domain = "api.example.com",
        .bindings = .{
            .release = .{ .value = "test" },
            .database_url = .{ .value = .{
                .provider = "not-secret-manager",
                .resource = "database-url",
            } },
        },
        .manage_apis = false,
    };
    try std.testing.expectError(error.InvalidSecretBinding, Service.build(std.testing.allocator, provider(), common));

    var cross_project = common;
    cross_project.bindings.database_url = .{ .value = .{
        .provider = "gcp-secret-manager",
        .resource = "projects/other-project/secrets/database-url",
        .version = "1",
    } };
    try std.testing.expectError(error.InvalidSecretBinding, Service.build(std.testing.allocator, provider(), cross_project));
}

fn provider() ziac.gcp.config.ProviderConfig {
    return .{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
        .service_regions = &regions,
        .network_tier = .premium,
    };
}

fn countType(graph: *const ziac.ResourceGraph, type_name: []const u8) usize {
    var count: usize = 0;
    for (graph.resources.items) |node| {
        if (std.mem.eql(u8, node.type_name, type_name)) count += 1;
    }
    return count;
}

fn findType(graph: *const ziac.ResourceGraph, type_name: []const u8) ziac.ResourceNode {
    for (graph.resources.items) |node| if (std.mem.eql(u8, node.type_name, type_name)) return node;
    unreachable;
}

fn inputValue(node: ziac.ResourceNode, name: []const u8) ziac.value.Value {
    return objectValue(node.inputs.object, name);
}

fn objectValue(fields: []const ziac.value.Field, name: []const u8) ziac.value.Value {
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    unreachable;
}

fn writeSource(dir: std.Io.Dir, path: []const u8, contents: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(std.testing.io, parent);
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = contents });
}
