const std = @import("std");

pub const default_cloud_builder = "gcr.io/cloud-builders/docker@sha256:6c9b879570fe1c63a78af0b575ca5ac52f6c2c7e25f76f91ae1f2d6cb2a872ee";
pub const default_build_image = "docker.io/library/debian:bookworm-slim@sha256:60eac759739651111db372c07be67863818726f754804b8707c90979bda511df";
pub const default_final_image = "gcr.io/distroless/static-debian12:nonroot@sha256:b7bb25d9f7c31d2bdd1982feb4dafcaf137703c7075dbe2febb41c24212b946f";
pub const default_zig_version = "0.16.0";
pub const default_zig_x86_64_sha256 = "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00";
pub const default_zig_aarch64_sha256 = "ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17";

pub const Error = std.mem.Allocator.Error || error{
    InvalidChecksum,
    InvalidDigest,
    InvalidIdentifier,
    InvalidPort,
    InvalidVersion,
    UnpinnedImage,
};

pub const Config = struct {
    artifact_name: []const u8,
    build_step: []const u8 = "install",
    port: u16 = 8080,
    zig_version: []const u8 = default_zig_version,
    zig_x86_64_sha256: []const u8 = default_zig_x86_64_sha256,
    zig_aarch64_sha256: []const u8 = default_zig_aarch64_sha256,
    build_image: []const u8 = default_build_image,
    final_image: []const u8 = default_final_image,
};

pub fn dockerfileAlloc(allocator: std.mem.Allocator, config: Config) Error![]u8 {
    try validate(config);
    var output = try std.Io.Writer.Allocating.initCapacity(allocator, 3072);
    defer output.deinit();
    output.writer.print(
        "FROM {s} AS build\nARG TARGETARCH\nARG ZIG_VERSION={s}\nARG ZIG_X86_64_SHA256={s}\nARG ZIG_AARCH64_SHA256={s}\n",
        .{ config.build_image, config.zig_version, config.zig_x86_64_sha256, config.zig_aarch64_sha256 },
    ) catch return error.OutOfMemory;
    output.writer.writeAll(
        "RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl xz-utils && rm -rf /var/lib/apt/lists/*\n" ++
            "RUN set -eu; \\\n" ++
            "    TARGETARCH=\"${TARGETARCH:-amd64}\"; \\\n" ++
            "    case \"$TARGETARCH\" in \\\n" ++
            "      amd64) ZIG_ARCH=x86_64; ZIG_TARGET=x86_64-linux-musl; ZIG_SHA256=\"$ZIG_X86_64_SHA256\" ;; \\\n" ++
            "      arm64) ZIG_ARCH=aarch64; ZIG_TARGET=aarch64-linux-musl; ZIG_SHA256=\"$ZIG_AARCH64_SHA256\" ;; \\\n" ++
            "      *) echo \"unsupported target architecture: $TARGETARCH\" >&2; exit 64 ;; \\\n" ++
            "    esac; \\\n" ++
            "    curl --fail --location --proto '=https' --tlsv1.2 --output /tmp/zig.tar.xz \"https://ziglang.org/download/$ZIG_VERSION/zig-$ZIG_ARCH-linux-$ZIG_VERSION.tar.xz\"; \\\n" ++
            "    echo \"$ZIG_SHA256  /tmp/zig.tar.xz\" | sha256sum -c -; \\\n" ++
            "    tar -xJf /tmp/zig.tar.xz -C /opt; \\\n" ++
            "    mv \"/opt/zig-$ZIG_ARCH-linux-$ZIG_VERSION\" /opt/zig; \\\n" ++
            "    rm /tmp/zig.tar.xz\n" ++
            "WORKDIR /src\nCOPY . .\n",
    ) catch return error.OutOfMemory;
    output.writer.print(
        "RUN set -eu; \\\n" ++
            "    TARGETARCH=\"${{TARGETARCH:-amd64}}\"; \\\n" ++
            "    case \"$TARGETARCH\" in \\\n" ++
            "      amd64) ZIG_TARGET=x86_64-linux-musl ;; \\\n" ++
            "      arm64) ZIG_TARGET=aarch64-linux-musl ;; \\\n" ++
            "      *) echo \"unsupported target architecture: $TARGETARCH\" >&2; exit 64 ;; \\\n" ++
            "    esac; \\\n" ++
            "    /opt/zig/zig build {s} -Doptimize=ReleaseSafe -Dtarget=\"$ZIG_TARGET\" --prefix /out\n" ++
            "FROM {s}\nCOPY --from=build --chown=65532:65532 /out/bin/{s} /app/{s}\nUSER nonroot:nonroot\nENV PORT={d}\nEXPOSE {d}\nENTRYPOINT [\"/app/{s}\"]\n",
        .{
            config.build_step,
            config.final_image,
            config.artifact_name,
            config.artifact_name,
            config.port,
            config.port,
            config.artifact_name,
        },
    ) catch return error.OutOfMemory;
    return output.toOwnedSlice();
}

pub fn buildDigest(
    source_digest: []const u8,
    dockerfile: []const u8,
    cloud_builder: []const u8,
) Error![64]u8 {
    if (!isDigest(source_digest) or dockerfile.len == 0) return error.InvalidDigest;
    if (!isPinnedImage(cloud_builder)) return error.UnpinnedImage;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("ziac-zig-build-v1\x00");
    hasher.update(source_digest);
    hasher.update("\x00");
    hasher.update(dockerfile);
    hasher.update("\x00");
    hasher.update(cloud_builder);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn validate(config: Config) Error!void {
    if (!isIdentifier(config.artifact_name) or !isIdentifier(config.build_step)) return error.InvalidIdentifier;
    if (config.port == 0) return error.InvalidPort;
    if (!isVersion(config.zig_version)) return error.InvalidVersion;
    if (!isDigest(config.zig_x86_64_sha256) or !isDigest(config.zig_aarch64_sha256)) return error.InvalidChecksum;
    if (!isPinnedImage(config.build_image) or !isPinnedImage(config.final_image)) return error.UnpinnedImage;
}

fn isIdentifier(identifier: []const u8) bool {
    if (identifier.len == 0 or identifier.len > 64 or !std.ascii.isAlphanumeric(identifier[0])) return false;
    for (identifier) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '-' and character != '_' and character != '.') return false;
    }
    return true;
}

fn isVersion(version: []const u8) bool {
    if (version.len == 0 or version.len > 64 or !std.ascii.isDigit(version[0])) return false;
    for (version) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '.' and character != '-' and character != '+') return false;
    }
    return true;
}

fn isDigest(digest: []const u8) bool {
    if (digest.len != 64) return false;
    for (digest) |character| {
        if (!(std.ascii.isDigit(character) or character >= 'a' and character <= 'f')) return false;
    }
    return true;
}

fn isPinnedImage(image: []const u8) bool {
    const marker = "@sha256:";
    const start = std.mem.lastIndexOf(u8, image, marker) orelse return false;
    return start > 0 and start + marker.len + 64 == image.len and isDigest(image[start + marker.len ..]);
}
