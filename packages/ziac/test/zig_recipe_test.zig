const std = @import("std");
const ziac = @import("ziac");

const recipe = ziac.build.zig_recipe;

test "generated Zig container recipe pins every toolchain and runtime input" {
    const dockerfile = try recipe.dockerfileAlloc(std.testing.allocator, .{
        .artifact_name = "sample-api",
        .port = 8080,
    });
    defer std.testing.allocator.free(dockerfile);

    for ([_][]const u8{
        "FROM docker.io/library/debian:bookworm-slim@sha256:60eac759739651111db372c07be67863818726f754804b8707c90979bda511df AS build",
        "ARG ZIG_VERSION=0.16.0",
        "ARG ZIG_X86_64_SHA256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00",
        "ARG ZIG_AARCH64_SHA256=ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17",
        "sha256sum -c -",
        "/opt/zig/zig build install -Doptimize=ReleaseSafe -Dtarget=\"$ZIG_TARGET\" --prefix /out",
        "FROM gcr.io/distroless/static-debian12:nonroot@sha256:b7bb25d9f7c31d2bdd1982feb4dafcaf137703c7075dbe2febb41c24212b946f",
        "COPY --from=build --chown=65532:65532 /out/bin/sample-api /app/sample-api",
        "USER nonroot:nonroot",
        "ENTRYPOINT [\"/app/sample-api\"]",
    }) |expected| try std.testing.expect(std.mem.indexOf(u8, dockerfile, expected) != null);
    try std.testing.expect(std.mem.indexOf(u8, dockerfile, "ZIG_TARGET=x86_64-linux-musl") != null);
    try std.testing.expect(std.mem.indexOf(u8, dockerfile, "ZIG_TARGET=aarch64-linux-musl") != null);
    try std.testing.expect(std.mem.indexOf(u8, dockerfile, "FROM debian:bookworm-slim\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, dockerfile, "# syntax=") == null);
}

test "generated recipe matches the runnable sample fixture" {
    const dockerfile = try recipe.dockerfileAlloc(std.testing.allocator, .{
        .artifact_name = "ziac-sample-api",
        .port = 8080,
    });
    defer std.testing.allocator.free(dockerfile);
    const fixture = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "test/fixtures/zig-service/Dockerfile.ziac",
        std.testing.allocator,
        std.Io.Limit.limited(16 * 1024),
    );
    defer std.testing.allocator.free(fixture);

    try std.testing.expectEqualStrings(fixture, dockerfile);
}

test "Zig recipe digest is deterministic and includes source builder and recipe" {
    const dockerfile = try recipe.dockerfileAlloc(std.testing.allocator, .{ .artifact_name = "api" });
    defer std.testing.allocator.free(dockerfile);
    const source_a = "1111111111111111111111111111111111111111111111111111111111111111";
    const source_b = "2222222222222222222222222222222222222222222222222222222222222222";
    const first = try recipe.buildDigest(source_a, dockerfile, recipe.default_cloud_builder);
    const repeated = try recipe.buildDigest(source_a, dockerfile, recipe.default_cloud_builder);
    const source_changed = try recipe.buildDigest(source_b, dockerfile, recipe.default_cloud_builder);
    const builder_changed = try recipe.buildDigest(source_a, dockerfile, "builder.example/docker@sha256:" ++ source_b);

    try std.testing.expectEqualStrings(&first, &repeated);
    try std.testing.expect(!std.mem.eql(u8, &first, &source_changed));
    try std.testing.expect(!std.mem.eql(u8, &first, &builder_changed));
}

test "Zig recipe rejects shell fragments mutable images and invalid checksums" {
    try std.testing.expectError(error.InvalidIdentifier, recipe.dockerfileAlloc(std.testing.allocator, .{
        .artifact_name = "api; touch /tmp/owned",
    }));
    try std.testing.expectError(error.UnpinnedImage, recipe.dockerfileAlloc(std.testing.allocator, .{
        .artifact_name = "api",
        .final_image = "gcr.io/distroless/static-debian12:nonroot",
    }));
    try std.testing.expectError(error.InvalidChecksum, recipe.dockerfileAlloc(std.testing.allocator, .{
        .artifact_name = "api",
        .zig_x86_64_sha256 = "not-a-checksum",
    }));
    try std.testing.expectError(error.InvalidDigest, recipe.buildDigest(
        "short",
        "FROM scratch\n",
        recipe.default_cloud_builder,
    ));
}
