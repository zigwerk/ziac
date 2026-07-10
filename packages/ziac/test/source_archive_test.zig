const std = @import("std");
const ziac = @import("ziac");

const source_archive = ziac.build.source_archive;

test "source archive is byte-stable with sorted paths and normalized metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "src");
    try writeFile(tmp.dir, "z.txt", "last\n");
    try writeFile(tmp.dir, "src/b.zig", "pub const b = 2;\n");
    try writeFile(tmp.dir, "src/a.zig", "pub const a = 1;\n");
    const generated = [_]source_archive.GeneratedFile{.{
        .path = "Dockerfile.ziac",
        .contents = "FROM scratch\n",
        .executable = true,
    }};

    var first = try source_archive.createAlloc(std.testing.allocator, std.testing.io, tmp.dir, .{
        .generated_files = &generated,
    });
    defer first.deinit();
    try writeFile(tmp.dir, "src/a.zig", "pub const a = 1;\n");
    var second = try source_archive.createAlloc(std.testing.allocator, std.testing.io, tmp.dir, .{
        .generated_files = &generated,
    });
    defer second.deinit();

    try std.testing.expectEqualSlices(u8, first.bytes, second.bytes);
    try std.testing.expectEqualStrings(&first.digest, &second.digest);
    try expectManifest(&first, &.{ "Dockerfile.ziac", "src/a.zig", "src/b.zig", "z.txt" });
    try expectTarEntries(&first, &.{
        .{ .path = "Dockerfile.ziac", .mode = 0o755 },
        .{ .path = "src/a.zig", .mode = 0o644 },
        .{ .path = "src/b.zig", .mode = 0o644 },
        .{ .path = "z.txt", .mode = 0o644 },
    });
}

test "source archive applies mandatory and ziacignore exclusions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ ".git", ".zig-cache", "zig-out", ".ziac/state", "secrets", "nested/.secrets", "cache" }) |path| {
        try tmp.dir.createDirPath(std.testing.io, path);
    }
    try tmp.dir.createDirPath(std.testing.io, "src");
    try writeFile(tmp.dir, ".ziacignore", "ignored.log\ncache/**\n**/*.tmp\n");
    try writeFile(tmp.dir, ".git/config", "secret\n");
    try writeFile(tmp.dir, ".zig-cache/hash", "cache\n");
    try writeFile(tmp.dir, "zig-out/app", "binary\n");
    try writeFile(tmp.dir, ".ziac/state/prod.json", "state\n");
    try writeFile(tmp.dir, ".env", "TOKEN=secret\n");
    try writeFile(tmp.dir, ".env.production", "TOKEN=secret\n");
    try writeFile(tmp.dir, "private.pem", "secret\n");
    try writeFile(tmp.dir, "private.key", "secret\n");
    try writeFile(tmp.dir, "gha-creds-fixture.json", "temporary external account credential\n");
    try writeFile(tmp.dir, "secrets/token", "secret\n");
    try writeFile(tmp.dir, "nested/.secrets/token", "secret\n");
    try writeFile(tmp.dir, "ignored.log", "ignored\n");
    try writeFile(tmp.dir, "cache/generated", "ignored\n");
    try writeFile(tmp.dir, "root.tmp", "ignored\n");
    try writeFile(tmp.dir, "src/generated.tmp", "ignored\n");
    try writeFile(tmp.dir, "build.zig", "pub fn build() void {}\n");
    try writeFile(tmp.dir, "src/main.zig", "pub fn main() void {}\n");

    var archive = try source_archive.createAlloc(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer archive.deinit();
    try expectManifest(&archive, &.{ ".ziacignore", "build.zig", "src/main.zig" });

    const before = archive.digest;
    try writeFile(tmp.dir, "ignored.log", "changed but still ignored\n");
    var unchanged = try source_archive.createAlloc(std.testing.allocator, std.testing.io, tmp.dir, .{});
    defer unchanged.deinit();
    try std.testing.expectEqualStrings(&before, &unchanged.digest);
}

test "source and generated build inputs independently change the archive digest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "main.zig", "pub fn main() void {}\n");
    const recipe_a = [_]source_archive.GeneratedFile{.{ .path = "Dockerfile.ziac", .contents = "FROM scratch\n" }};
    const recipe_b = [_]source_archive.GeneratedFile{.{ .path = "Dockerfile.ziac", .contents = "FROM scratch\nUSER 65532\n" }};

    var original = try source_archive.createAlloc(std.testing.allocator, std.testing.io, tmp.dir, .{ .generated_files = &recipe_a });
    defer original.deinit();
    var recipe_changed = try source_archive.createAlloc(std.testing.allocator, std.testing.io, tmp.dir, .{ .generated_files = &recipe_b });
    defer recipe_changed.deinit();
    try std.testing.expect(!std.mem.eql(u8, &original.digest, &recipe_changed.digest));

    try writeFile(tmp.dir, "main.zig", "pub fn main() void { @panic(\"changed\"); }\n");
    var source_changed = try source_archive.createAlloc(std.testing.allocator, std.testing.io, tmp.dir, .{ .generated_files = &recipe_a });
    defer source_changed.deinit();
    try std.testing.expect(!std.mem.eql(u8, &original.digest, &source_changed.digest));
}

test "source archive rejects symlinks by default and can exclude them" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "main.zig", "pub fn main() void {}\n");
    try tmp.dir.symLink(std.testing.io, "main.zig", "linked.zig", .{});

    try std.testing.expectError(
        error.SymlinkNotAllowed,
        source_archive.createAlloc(std.testing.allocator, std.testing.io, tmp.dir, .{}),
    );
    var archive = try source_archive.createAlloc(std.testing.allocator, std.testing.io, tmp.dir, .{
        .symlink_policy = .exclude,
    });
    defer archive.deinit();
    try expectManifest(&archive, &.{"main.zig"});
}

test "source archive validates ziacignore without following a symlink" {
    var invalid = std.testing.tmpDir(.{});
    defer invalid.cleanup();
    try writeFile(invalid.dir, ".ziacignore", "!main.zig\n");
    try writeFile(invalid.dir, "main.zig", "pub fn main() void {}\n");
    try std.testing.expectError(
        error.InvalidIgnoreRule,
        source_archive.createAlloc(std.testing.allocator, std.testing.io, invalid.dir, .{}),
    );

    var linked = std.testing.tmpDir(.{});
    defer linked.cleanup();
    try writeFile(linked.dir, "rules.txt", "!unsafe\n");
    try writeFile(linked.dir, "main.zig", "pub fn main() void {}\n");
    try linked.dir.symLink(std.testing.io, "rules.txt", ".ziacignore", .{});
    try std.testing.expectError(
        error.SymlinkNotAllowed,
        source_archive.createAlloc(std.testing.allocator, std.testing.io, linked.dir, .{}),
    );
}

test "source archive rejects unbounded ignore patterns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var oversized: [258]u8 = undefined;
    @memset(oversized[0..257], 'a');
    oversized[257] = '\n';
    try writeFile(tmp.dir, ".ziacignore", &oversized);
    try writeFile(tmp.dir, "main.zig", "pub fn main() void {}\n");
    try std.testing.expectError(
        error.InvalidIgnoreRule,
        source_archive.createAlloc(std.testing.allocator, std.testing.io, tmp.dir, .{}),
    );
}

test "source archive rejects unsafe generated paths collisions and limits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "main.zig", "12345");
    const traversal = [_]source_archive.GeneratedFile{.{ .path = "../Dockerfile", .contents = "unsafe" }};
    try std.testing.expectError(
        error.InvalidPath,
        source_archive.createAlloc(std.testing.allocator, std.testing.io, tmp.dir, .{ .generated_files = &traversal }),
    );
    const collision = [_]source_archive.GeneratedFile{.{ .path = "main.zig", .contents = "duplicate" }};
    try std.testing.expectError(
        error.DuplicatePath,
        source_archive.createAlloc(std.testing.allocator, std.testing.io, tmp.dir, .{ .generated_files = &collision }),
    );
    try std.testing.expectError(
        error.FileTooLarge,
        source_archive.createAlloc(std.testing.allocator, std.testing.io, tmp.dir, .{ .max_file_bytes = 4 }),
    );
}

test "source archive can transfer payload ownership without retaining bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "main.zig", "pub fn main() void {}\n");
    var archive = try source_archive.createAlloc(std.testing.allocator, std.testing.io, tmp.dir, .{});
    const expected = archive.digest;
    const bytes = archive.takeBytes();
    defer std.testing.allocator.free(bytes);
    archive.deinit();

    var digest_bytes: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest_bytes, .{});
    const digest = std.fmt.bytesToHex(digest_bytes, .lower);
    try std.testing.expectEqualStrings(&expected, &digest);
}

const ExpectedTarEntry = struct {
    path: []const u8,
    mode: u32,
};

fn expectTarEntries(archive: *const source_archive.Archive, expected: []const ExpectedTarEntry) !void {
    var compressed_reader: std.Io.Reader = .fixed(archive.bytes);
    var decompression_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor: std.compress.flate.Decompress = .init(&compressed_reader, .gzip, &decompression_buffer);
    var name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var link_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var iterator: std.tar.Iterator = .init(&decompressor.reader, .{
        .file_name_buffer = &name_buffer,
        .link_name_buffer = &link_buffer,
    });
    var index: usize = 0;
    while (try iterator.next()) |entry| : (index += 1) {
        try std.testing.expect(index < expected.len);
        try std.testing.expectEqualStrings(expected[index].path, entry.name);
        try std.testing.expectEqual(expected[index].mode, entry.mode);
        try std.testing.expectEqual(std.tar.FileKind.file, entry.kind);
    }
    try std.testing.expectEqual(expected.len, index);
}

fn expectManifest(archive: *const source_archive.Archive, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, archive.entries.len);
    for (archive.entries, expected) |actual, path| try std.testing.expectEqualStrings(path, actual.path);
}

fn writeFile(dir: std.Io.Dir, path: []const u8, contents: []const u8) !void {
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = contents });
}
