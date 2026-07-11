const std = @import("std");
const ziac = @import("ziac");

const base_digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const base_config = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const base_layer = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";

test "OCI planner deterministically layers a Zig binary over a pinned base" {
    const base_layers = [_]ziac.oci.Descriptor{.{
        .media_type = ziac.oci.layer_media_type,
        .digest = base_layer,
        .size = 1234,
    }};
    const input = ziac.oci.PlanInput{
        .repository = "europe-west1-docker.pkg.dev/project/apps/api",
        .base_manifest_digest = base_digest,
        .base_config_digest = base_config,
        .base_layers = &base_layers,
        .base_diff_ids = &.{base_layer},
        .binary_tar = "deterministic tar bytes for /app/api",
        .architecture = "amd64",
        .entrypoint = "/app/api",
    };
    var first = try ziac.oci.planAlloc(std.testing.allocator, input);
    defer first.deinit();
    var second = try ziac.oci.planAlloc(std.testing.allocator, input);
    defer second.deinit();
    try std.testing.expectEqualStrings(&first.layer_digest, &second.layer_digest);
    try std.testing.expectEqualStrings(&first.config_digest, &second.config_digest);
    try std.testing.expectEqualStrings(&first.manifest_digest, &second.manifest_digest);
    try std.testing.expectEqualSlices(u8, first.manifest_blob, second.manifest_blob);
    try std.testing.expect(std.mem.startsWith(u8, first.image_ref, input.repository));
    try std.testing.expect(std.mem.indexOf(u8, first.image_ref, "@sha256:") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.manifest_blob, base_layer) != null);
    try std.testing.expect(std.mem.indexOf(u8, first.manifest_blob, &first.layer_digest) != null);

    var changed = try ziac.oci.planAlloc(std.testing.allocator, .{
        .repository = input.repository,
        .base_manifest_digest = base_digest,
        .base_config_digest = base_config,
        .base_layers = &base_layers,
        .base_diff_ids = &.{base_layer},
        .binary_tar = "changed deterministic tar bytes",
        .architecture = "amd64",
        .entrypoint = "/app/api",
    });
    defer changed.deinit();
    try std.testing.expect(!std.mem.eql(u8, &first.manifest_digest, &changed.manifest_digest));
}

test "OCI push uploads only missing content addressed blobs" {
    var plan = try ziac.oci.planAlloc(std.testing.allocator, .{
        .repository = "registry.example/project/api",
        .base_manifest_digest = base_digest,
        .base_config_digest = base_config,
        .base_layers = &.{},
        .base_diff_ids = &.{},
        .binary_tar = "binary layer",
        .architecture = "arm64",
        .entrypoint = "/app/api",
    });
    defer plan.deinit();
    var registry = ziac.oci.ScriptedRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const first = try ziac.oci.push(&plan, registry.registry());
    try std.testing.expectEqual(@as(usize, 3), first.uploaded_blobs);
    try std.testing.expectEqual(@as(usize, 0), first.reused_blobs);
    const second = try ziac.oci.push(&plan, registry.registry());
    try std.testing.expectEqual(@as(usize, 0), second.uploaded_blobs);
    try std.testing.expectEqual(@as(usize, 3), second.reused_blobs);
    try std.testing.expectEqual(@as(usize, 3), registry.upload_count);
}

test "OCI planner rejects mutable or malformed base contracts" {
    try std.testing.expectError(error.UnpinnedBaseManifest, ziac.oci.planAlloc(std.testing.allocator, .{
        .repository = "registry.example/project/api",
        .base_manifest_digest = "latest",
        .base_config_digest = base_config,
        .binary_tar = "binary",
        .entrypoint = "/app/api",
    }));
}

test "OCI cache stores blobs by digest and locks the exact base manifest" {
    var fs = ziac.zstd.FileSystem.MemoryFileSystem.init(std.testing.allocator);
    defer fs.deinit();
    const cache = ziac.oci.Cache.init(std.testing.allocator, ziac.local_state.memoryFiles(&fs));
    try cache.putBlob(base_layer, "cached layer");
    try std.testing.expect(try cache.hasBlob(base_layer));
    const loaded = try cache.getBlobAlloc(base_layer);
    defer std.testing.allocator.free(loaded);
    try std.testing.expectEqualStrings("cached layer", loaded);

    try cache.lockBase("europe-west1-docker.pkg.dev/project/apps/api", base_digest);
    try cache.requireBase("europe-west1-docker.pkg.dev/project/apps/api", base_digest);
    try std.testing.expectError(error.BaseManifestLockMismatch, cache.requireBase(
        "europe-west1-docker.pkg.dev/project/apps/api",
        "sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
    ));
}
