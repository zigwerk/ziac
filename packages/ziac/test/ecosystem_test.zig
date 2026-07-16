const std = @import("std");
const ziac = @import("ziac");

const component_manifest =
    \\{
    \\  "schema": "ziac.package.v1",
    \\  "name": "ziac-gcpx/asset-bucket",
    \\  "version": "0.1.0",
    \\  "kind": "component",
    \\  "summary": "A governed asset bucket",
    \\  "license": "Apache-2.0",
    \\  "source": "https://github.com/ziac-run/ziac-gcpx",
    \\  "entry": "src/asset_bucket.zig",
    \\  "compatibility": { "ziac": ">=0.1.0 <0.2.0", "zig": ">=0.16.0 <0.17.0" },
    \\  "providers": ["gcp"],
    \\  "resource_types": ["gcp.storage.BucketIamMember", "gcp.storage.Bucket"],
    \\  "maturity": "preview"
    \\}
;

const component_manifest_reordered =
    \\{"maturity":"preview","resource_types":["gcp.storage.Bucket","gcp.storage.BucketIamMember"],"providers":["gcp"],"entry":"src/asset_bucket.zig","source":"https://github.com/ziac-run/ziac-gcpx","license":"Apache-2.0","summary":"A governed asset bucket","kind":"component","version":"0.1.0","name":"ziac-gcpx/asset-bucket","compatibility":{"zig":">=0.16.0 <0.17.0","ziac":">=0.1.0 <0.2.0"},"schema":"ziac.package.v1"}
;

const component_manifest_tampered =
    \\{"schema":"ziac.package.v1","name":"ziac-gcpx/asset-bucket","version":"0.1.0","kind":"component","summary":"A tampered asset bucket","license":"Apache-2.0","source":"https://github.com/ziac-run/ziac-gcpx","entry":"src/asset_bucket.zig","compatibility":{"ziac":">=0.1.0 <0.2.0","zig":">=0.16.0 <0.17.0"},"providers":["gcp"],"resource_types":["gcp.storage.Bucket","gcp.storage.BucketIamMember"],"maturity":"preview"}
;

const provider_manifest =
    \\{
    \\  "schema": "ziac.package.v1",
    \\  "name": "ziac-provider/cockroach",
    \\  "version": "0.1.0",
    \\  "kind": "provider",
    \\  "summary": "CockroachDB Cloud resources for Ziac",
    \\  "license": "Apache-2.0",
    \\  "source": "https://github.com/ziac-run/ziac",
    \\  "entry": "ziac-provider-cockroach",
    \\  "compatibility": { "ziac": ">=0.1.0 <0.2.0", "zig": ">=0.16.0 <0.17.0" },
    \\  "providers": ["cockroach"],
    \\  "resource_types": ["cockroach.cluster.Cluster", "cockroach.sql.Database"],
    \\  "maturity": "preview",
    \\  "provider_rpc": { "protocol": "ziac.provider.rpc.v1", "provider": "cockroach", "executable": "ziac-provider-cockroach", "max_inflight": 1 }
    \\}
;

test "package manifests are canonical and independent of JSON field ordering" {
    var first = try ziac.ecosystem.Manifest.parseAlloc(std.testing.allocator, component_manifest);
    defer first.deinit();
    var second = try ziac.ecosystem.Manifest.parseAlloc(std.testing.allocator, component_manifest_reordered);
    defer second.deinit();

    try std.testing.expectEqual(ziac.ecosystem.Kind.component, first.kind);
    try std.testing.expectEqualStrings("ziac-gcpx/asset-bucket", first.name);
    try std.testing.expectEqualStrings("gcp.storage.Bucket", first.resource_types[0]);
    try std.testing.expectEqual(first.digest(), second.digest());

    const canonical = try first.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(canonical);
    try std.testing.expectEqualStrings(
        "{\"schema\":\"ziac.package.v1\",\"name\":\"ziac-gcpx/asset-bucket\",\"version\":\"0.1.0\",\"kind\":\"component\",\"summary\":\"A governed asset bucket\",\"license\":\"Apache-2.0\",\"source\":\"https://github.com/ziac-run/ziac-gcpx\",\"entry\":\"src/asset_bucket.zig\",\"compatibility\":{\"ziac\":\">=0.1.0 <0.2.0\",\"zig\":\">=0.16.0 <0.17.0\"},\"providers\":[\"gcp\"],\"resource_types\":[\"gcp.storage.Bucket\",\"gcp.storage.BucketIamMember\"],\"maturity\":\"preview\"}",
        canonical,
    );
}

test "package manifests reject executable hooks traversal duplicates and secret-shaped fields" {
    const traversal = replaceManifestEntry("../escape");
    try std.testing.expectError(error.InvalidPackageEntry, ziac.ecosystem.Manifest.parseAlloc(std.testing.allocator, traversal));

    const duplicate =
        \\{"schema":"ziac.package.v1","name":"ziac/example","version":"0.1.0","kind":"component","summary":"Example","license":"Apache-2.0","source":"https://example.invalid/source","entry":"src/root.zig","compatibility":{"ziac":">=0.1.0 <0.2.0","zig":">=0.16.0 <0.17.0"},"providers":["gcp","gcp"],"resource_types":["gcp.storage.Bucket"],"maturity":"preview"}
    ;
    try std.testing.expectError(error.DuplicatePackageValue, ziac.ecosystem.Manifest.parseAlloc(std.testing.allocator, duplicate));

    const hook =
        \\{"schema":"ziac.package.v1","name":"ziac/example","version":"0.1.0","kind":"template","summary":"Example","license":"Apache-2.0","source":"https://example.invalid/source","entry":"files","compatibility":{"ziac":">=0.1.0 <0.2.0","zig":">=0.16.0 <0.17.0"},"providers":["gcp"],"resource_types":["gcp.storage.Bucket"],"maturity":"preview","post_install":"sh setup.sh"}
    ;
    try std.testing.expectError(error.ExecutablePackageHook, ziac.ecosystem.Manifest.parseAlloc(std.testing.allocator, hook));

    const invalid_template_entry =
        \\{"schema":"ziac.package.v1","name":"ziac/example","version":"0.1.0","kind":"template","summary":"Example","license":"Apache-2.0","source":"https://example.invalid/source","entry":"src","compatibility":{"ziac":">=0.1.0 <0.2.0","zig":">=0.16.0 <0.17.0"},"providers":["gcp"],"resource_types":["gcp.storage.Bucket"],"maturity":"preview"}
    ;
    try std.testing.expectError(error.InvalidPackageEntry, ziac.ecosystem.Manifest.parseAlloc(std.testing.allocator, invalid_template_entry));

    const secret =
        \\{"schema":"ziac.package.v1","name":"ziac/example","version":"0.1.0","kind":"template","summary":"Example","license":"Apache-2.0","source":"https://example.invalid/source","entry":"files","compatibility":{"ziac":">=0.1.0 <0.2.0","zig":">=0.16.0 <0.17.0"},"providers":["gcp"],"resource_types":["gcp.storage.Bucket"],"maturity":"preview","api_token":"sentinel"}
    ;
    try std.testing.expectError(error.SecretMaterialDetected, ziac.ecosystem.Manifest.parseAlloc(std.testing.allocator, secret));
}

test "provider manifests declare RPC identity without granting install or execution hooks" {
    var manifest = try ziac.ecosystem.Manifest.parseAlloc(std.testing.allocator, provider_manifest);
    defer manifest.deinit();
    try std.testing.expectEqual(ziac.ecosystem.Kind.provider, manifest.kind);
    try std.testing.expectEqualStrings("ziac.provider.rpc.v1", manifest.provider_rpc.?.protocol);
    try std.testing.expectEqualStrings("cockroach", manifest.provider_rpc.?.provider);
    try std.testing.expectEqualStrings("ziac-provider-cockroach", manifest.provider_rpc.?.executable);
    try std.testing.expectEqual(@as(u16, 1), manifest.provider_rpc.?.max_inflight);

    const canonical = try manifest.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(canonical);
    try std.testing.expect(std.mem.indexOf(u8, canonical, "\"provider_rpc\":{\"protocol\":\"ziac.provider.rpc.v1\"") != null);

    const missing_rpc =
        \\{"schema":"ziac.package.v1","name":"ziac-provider/example","version":"0.1.0","kind":"provider","summary":"Example provider","license":"Apache-2.0","source":"https://example.invalid/source","entry":"ziac-provider-example","compatibility":{"ziac":">=0.1.0 <0.2.0","zig":">=0.16.0 <0.17.0"},"providers":["gcp"],"resource_types":["gcp.example.Resource"],"maturity":"preview"}
    ;
    try std.testing.expectError(error.MissingProviderRpc, ziac.ecosystem.Manifest.parseAlloc(std.testing.allocator, missing_rpc));

    const rpc_on_component =
        \\{"schema":"ziac.package.v1","name":"ziac/example","version":"0.1.0","kind":"component","summary":"Example","license":"Apache-2.0","source":"https://example.invalid/source","entry":"src/root.zig","compatibility":{"ziac":">=0.1.0 <0.2.0","zig":">=0.16.0 <0.17.0"},"providers":["gcp"],"resource_types":["gcp.example.Resource"],"maturity":"preview","provider_rpc":{"protocol":"ziac.provider.rpc.v1","provider":"gcp","executable":"ziac-provider-gcp","max_inflight":1}}
    ;
    try std.testing.expectError(error.UnexpectedProviderRpc, ziac.ecosystem.Manifest.parseAlloc(std.testing.allocator, rpc_on_component));

    const mismatched_provider =
        \\{"schema":"ziac.package.v1","name":"ziac-provider/example","version":"0.1.0","kind":"provider","summary":"Example provider","license":"Apache-2.0","source":"https://example.invalid/source","entry":"ziac-provider-example","compatibility":{"ziac":">=0.1.0 <0.2.0","zig":">=0.16.0 <0.17.0"},"providers":["gcp"],"resource_types":["gcp.example.Resource"],"maturity":"preview","provider_rpc":{"protocol":"ziac.provider.rpc.v1","provider":"cockroach","executable":"ziac-provider-example","max_inflight":1}}
    ;
    try std.testing.expectError(error.InvalidProviderRpc, ziac.ecosystem.Manifest.parseAlloc(std.testing.allocator, mismatched_provider));
}

test "registry validates exact manifest digests and returns bounded deterministic search" {
    var manifest = try ziac.ecosystem.Manifest.parseAlloc(std.testing.allocator, component_manifest);
    defer manifest.deinit();
    const digest = std.fmt.bytesToHex(manifest.digest(), .lower);
    const index_bytes = try std.fmt.allocPrint(std.testing.allocator,
        \\{{"schema":"ziac.registry.v1","packages":[{{"name":"ziac-gcpx/asset-bucket","version":"0.1.0","kind":"component","summary":"A governed asset bucket","path":"components/asset-bucket","manifest_sha256":"{s}","qualification":"official"}},{{"name":"ziac/hermes-desktop","version":"0.1.0","kind":"template","summary":"Hermes Desktop on Compute Engine","path":"templates/hermes-desktop","manifest_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","qualification":"verified"}}]}}
    , .{digest});
    defer std.testing.allocator.free(index_bytes);

    var registry = try ziac.ecosystem.Registry.parseAlloc(std.testing.allocator, index_bytes);
    defer registry.deinit();
    try registry.verifyManifest(registry.entries[0], component_manifest_reordered);
    try std.testing.expectError(error.PackageDigestMismatch, registry.verifyManifest(registry.entries[0], component_manifest_tampered));

    const matches = try registry.searchAlloc(std.testing.allocator, .{ .query = "HERMES", .kind = .template, .limit = 10 });
    defer std.testing.allocator.free(matches);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("ziac/hermes-desktop", registry.entries[matches[0]].name);
}

test "template rendering is token-only bounded and never executes hooks" {
    var source_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer source_tmp.cleanup();
    var target_tmp = std.testing.tmpDir(.{});
    defer target_tmp.cleanup();
    try source_tmp.dir.createDirPath(std.testing.io, "files/src");
    try source_tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "files/build.zig.zon",
        .data = ".{ .name = .{{zig_package_name}}, .fingerprint = 0x{{package_fingerprint}}, .dependencies = .{ .ziac = .{ .path = {{ziac_path}} }, .ziac_gcpx = .{ .path = {{ziac_gcpx_path}} } } }\n",
    });
    try source_tmp.dir.writeFile(std.testing.io, .{ .sub_path = "files/src/main.zig", .data = "pub const project = \"{{project_name}}\";\n" });

    try ziac.ecosystem.renderTemplate(std.testing.allocator, std.testing.io, source_tmp.dir, target_tmp.dir, .{
        .project_name = "team-agent",
        .zig_package_name = "team_agent",
        .package_fingerprint = "1234abcd",
        .ziac_path_json = "\"../ziac\"",
        .ziac_gcpx_path_json = "\"../ziac-gcpx\"",
        .zigeffect_path_json = "\"../zigeffect\"",
        .zigeffect_std_path_json = "\"../zigeffect-std\"",
    }, false);
    const source = try target_tmp.dir.readFileAlloc(std.testing.io, "src/main.zig", std.testing.allocator, .limited(1024));
    defer std.testing.allocator.free(source);
    try std.testing.expectEqualStrings("pub const project = \"team-agent\";\n", source);

    var unknown_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer unknown_tmp.cleanup();
    try unknown_tmp.dir.createDirPath(std.testing.io, "files");
    try unknown_tmp.dir.writeFile(std.testing.io, .{ .sub_path = "files/unsafe", .data = "{{shell_command}}" });
    try std.testing.expectError(error.UnknownTemplateToken, ziac.ecosystem.renderTemplate(std.testing.allocator, std.testing.io, unknown_tmp.dir, target_tmp.dir, .{
        .project_name = "team-agent",
        .zig_package_name = "team_agent",
        .package_fingerprint = "1234abcd",
        .ziac_path_json = "\"../ziac\"",
        .ziac_gcpx_path_json = "\"../ziac-gcpx\"",
        .zigeffect_path_json = "\"../zigeffect\"",
        .zigeffect_std_path_json = "\"../zigeffect-std\"",
    }, true));
}

fn replaceManifestEntry(comptime entry: []const u8) []const u8 {
    return std.fmt.comptimePrint(
        \\{{"schema":"ziac.package.v1","name":"ziac/example","version":"0.1.0","kind":"component","summary":"Example","license":"Apache-2.0","source":"https://example.invalid/source","entry":"{s}","compatibility":{{"ziac":">=0.1.0 <0.2.0","zig":">=0.16.0 <0.17.0"}},"providers":["gcp"],"resource_types":["gcp.storage.Bucket"],"maturity":"preview"}}
    , .{entry});
}
