const std = @import("std");

const max_ignore_rules = 1024;
const max_ignore_pattern_bytes = 256;

pub const SymlinkPolicy = enum {
    reject,
    exclude,
};

pub const GeneratedFile = struct {
    path: []const u8,
    contents: []const u8,
    executable: bool = false,
};

pub const Options = struct {
    ignore_file_name: ?[]const u8 = ".ziacignore",
    symlink_policy: SymlinkPolicy = .reject,
    generated_files: []const GeneratedFile = &.{},
    max_ignore_file_bytes: usize = 256 * 1024,
    max_file_bytes: usize = 64 * 1024 * 1024,
    max_source_bytes: usize = 256 * 1024 * 1024,
    max_archive_bytes: usize = 256 * 1024 * 1024,
};

pub const Entry = struct {
    path: []const u8,
    size: usize,
    executable: bool,
    generated: bool,
};

pub const Archive = struct {
    allocator: std.mem.Allocator,
    bytes: []const u8,
    digest: [64]u8,
    entries: []const Entry,

    pub fn deinit(self: *Archive) void {
        self.allocator.free(self.bytes);
        for (self.entries) |entry| self.allocator.free(entry.path);
        self.allocator.free(self.entries);
        self.* = undefined;
    }
};

const Rule = struct {
    pattern: []const u8,
    directory_tree: bool,
    basename_only: bool,

    fn deinit(self: *Rule, allocator: std.mem.Allocator) void {
        allocator.free(self.pattern);
        self.* = undefined;
    }
};

const PendingEntry = struct {
    path: []const u8,
    generated_contents: ?[]const u8 = null,
    generated_executable: bool = false,
};

const LoadedFile = struct {
    allocator: std.mem.Allocator,
    contents: []const u8,
    executable: bool,

    fn deinit(self: *LoadedFile) void {
        self.allocator.free(self.contents);
        self.* = undefined;
    }
};

pub fn createAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    options: Options,
) !Archive {
    if (options.max_file_bytes == 0 or options.max_source_bytes == 0 or options.max_archive_bytes == 0) {
        return error.InvalidLimit;
    }
    var rules = try loadRulesAlloc(allocator, io, root, options);
    defer {
        for (rules.items) |*rule| rule.deinit(allocator);
        rules.deinit(allocator);
    }

    var pending = std.ArrayList(PendingEntry).empty;
    defer {
        for (pending.items) |entry| allocator.free(entry.path);
        pending.deinit(allocator);
    }
    var walker = try root.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |walked| {
        const normalized = try normalizeWalkedPathAlloc(allocator, walked.path);
        if (isMandatoryExcluded(normalized) or matchesRules(rules.items, normalized)) {
            allocator.free(normalized);
            continue;
        }
        switch (walked.kind) {
            .directory => allocator.free(normalized),
            .sym_link => {
                allocator.free(normalized);
                if (options.symlink_policy == .reject) return error.SymlinkNotAllowed;
            },
            .file => pending.append(allocator, .{ .path = normalized }) catch |err| {
                allocator.free(normalized);
                return err;
            },
            else => {
                allocator.free(normalized);
                return error.UnsupportedFileType;
            },
        }
    }
    for (options.generated_files) |generated| {
        try validateRelativePath(generated.path);
        if (isMandatoryExcluded(generated.path) or matchesRules(rules.items, generated.path)) return error.InvalidPath;
        if (generated.contents.len > options.max_file_bytes) return error.FileTooLarge;
        const path = try allocator.dupe(u8, generated.path);
        pending.append(allocator, .{
            .path = path,
            .generated_contents = generated.contents,
            .generated_executable = generated.executable,
        }) catch |err| {
            allocator.free(path);
            return err;
        };
    }
    std.mem.sort(PendingEntry, pending.items, {}, lessThanPendingPath);
    for (pending.items[1..], 1..) |entry, index| {
        if (std.mem.eql(u8, pending.items[index - 1].path, entry.path)) return error.DuplicatePath;
    }

    const entries = try allocator.alloc(Entry, pending.items.len);
    errdefer allocator.free(entries);
    var initialized_entries: usize = 0;
    errdefer for (entries[0..initialized_entries]) |entry| allocator.free(entry.path);

    var output = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    defer output.deinit();
    var compression_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(
        &output.writer,
        &compression_buffer,
        .gzip,
        .default,
    );
    var tar_writer: std.tar.Writer = .{ .underlying_writer = &compressor.writer };
    var total_source_bytes: usize = 0;
    for (pending.items, 0..) |item, index| {
        const generated = item.generated_contents != null;
        var loaded = if (generated) null else try readSourceFileAlloc(
            allocator,
            io,
            root,
            item.path,
            options.max_file_bytes,
        );
        defer if (loaded) |*source| source.deinit();
        const contents = item.generated_contents orelse loaded.?.contents;
        if (contents.len > options.max_file_bytes) return error.FileTooLarge;
        total_source_bytes = std.math.add(usize, total_source_bytes, contents.len) catch return error.SourceTooLarge;
        if (total_source_bytes > options.max_source_bytes) return error.SourceTooLarge;

        const executable = if (generated)
            item.generated_executable
        else
            loaded.?.executable;
        try tar_writer.writeFileBytes(item.path, contents, .{
            .mode = if (executable) 0o755 else 0o644,
            .mtime = 0,
        });
        entries[index] = .{
            .path = try allocator.dupe(u8, item.path),
            .size = contents.len,
            .executable = executable,
            .generated = generated,
        };
        initialized_entries += 1;
    }
    try tar_writer.finishPedantically();
    try compressor.finish();
    const bytes = try output.toOwnedSlice();
    errdefer allocator.free(bytes);
    if (bytes.len > options.max_archive_bytes) return error.ArchiveTooLarge;
    var digest_bytes: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest_bytes, .{});
    return .{
        .allocator = allocator,
        .bytes = bytes,
        .digest = std.fmt.bytesToHex(digest_bytes, .lower),
        .entries = entries,
    };
}

fn loadRulesAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    options: Options,
) !std.ArrayList(Rule) {
    var rules = std.ArrayList(Rule).empty;
    errdefer {
        for (rules.items) |*rule| rule.deinit(allocator);
        rules.deinit(allocator);
    }
    const ignore_name = options.ignore_file_name orelse return rules;
    try validateRelativePath(ignore_name);
    var loaded = readSourceFileAlloc(
        allocator,
        io,
        root,
        ignore_name,
        options.max_ignore_file_bytes,
    ) catch |err| switch (err) {
        error.FileNotFound => return rules,
        error.FileTooLarge => return error.IgnoreFileTooLarge,
        else => |other| return other,
    };
    defer loaded.deinit();
    var lines = std.mem.splitScalar(u8, loaded.contents, '\n');
    while (lines.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '!') return error.InvalidIgnoreRule;
        if (line[0] == '/') line = line[1..];
        const directory_tree = line.len > 0 and line[line.len - 1] == '/';
        if (directory_tree) line = line[0 .. line.len - 1];
        if (line.len > max_ignore_pattern_bytes or rules.items.len >= max_ignore_rules) {
            return error.InvalidIgnoreRule;
        }
        try validatePattern(line);
        try rules.append(allocator, .{
            .pattern = try allocator.dupe(u8, line),
            .directory_tree = directory_tree,
            .basename_only = std.mem.indexOfScalar(u8, line, '/') == null,
        });
    }
    return rules;
}

fn matchesRules(rules: []const Rule, path: []const u8) bool {
    for (rules) |rule| if (ruleMatches(rule, path)) return true;
    return false;
}

fn ruleMatches(rule: Rule, path: []const u8) bool {
    if (rule.basename_only) {
        var components = std.mem.splitScalar(u8, path, '/');
        while (components.next()) |component| {
            if (globMatches(rule.pattern, component)) return true;
        }
        return false;
    }
    if (globMatches(rule.pattern, path)) return true;
    if (!rule.directory_tree) return false;
    var split = std.mem.splitBackwardsScalar(u8, path, '/');
    _ = split.next();
    var end = path.len;
    while (std.mem.lastIndexOfScalar(u8, path[0..end], '/')) |slash| {
        if (globMatches(rule.pattern, path[0..slash])) return true;
        end = slash;
    }
    return false;
}

fn globMatches(pattern: []const u8, text: []const u8) bool {
    if (pattern.len > max_ignore_pattern_bytes) return false;
    var states = [_]bool{false} ** (max_ignore_pattern_bytes + 1);
    states[0] = true;
    applyGlobEpsilon(pattern, &states);
    for (text) |character| {
        var next = [_]bool{false} ** (max_ignore_pattern_bytes + 1);
        for (pattern, 0..) |token, index| {
            if (!states[index]) continue;
            if (token == '*') {
                const double = index + 1 < pattern.len and pattern[index + 1] == '*';
                if (double or character != '/') next[index] = true;
            } else if ((token == '?' and character != '/') or token == character) {
                next[index + 1] = true;
            }
        }
        states = next;
        applyGlobEpsilon(pattern, &states);
    }
    return states[pattern.len];
}

fn applyGlobEpsilon(
    pattern: []const u8,
    states: *[max_ignore_pattern_bytes + 1]bool,
) void {
    var changed = true;
    while (changed) {
        changed = false;
        for (pattern, 0..) |token, index| {
            if (!states[index] or token != '*') continue;
            const double = index + 1 < pattern.len and pattern[index + 1] == '*';
            const after_star = index + if (double) @as(usize, 2) else 1;
            if (!states[after_star]) {
                states[after_star] = true;
                changed = true;
            }
            if (double and after_star < pattern.len and pattern[after_star] == '/' and !states[after_star + 1]) {
                states[after_star + 1] = true;
                changed = true;
            }
        }
    }
}

fn isMandatoryExcluded(path: []const u8) bool {
    var components = std.mem.splitScalar(u8, path, '/');
    var basename: []const u8 = path;
    while (components.next()) |component| {
        basename = component;
        for ([_][]const u8{ ".git", ".zig-cache", "zig-out", ".ziac", "secrets", ".secrets" }) |directory| {
            if (std.mem.eql(u8, component, directory)) return true;
        }
    }
    if (std.mem.eql(u8, basename, ".env") or std.mem.startsWith(u8, basename, ".env.")) return true;
    return std.mem.endsWith(u8, basename, ".pem") or std.mem.endsWith(u8, basename, ".key");
}

fn normalizeWalkedPathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const normalized = try allocator.dupe(u8, path);
    if (std.fs.path.sep != '/') std.mem.replaceScalar(u8, normalized, std.fs.path.sep, '/');
    try validateRelativePath(normalized);
    return normalized;
}

fn validateRelativePath(path: []const u8) !void {
    if (path.len == 0 or path[0] == '/' or path[path.len - 1] == '/' or
        std.mem.indexOfScalar(u8, path, 0) != null or std.mem.indexOfScalar(u8, path, '\\') != null)
    {
        return error.InvalidPath;
    }
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
            return error.InvalidPath;
        }
    }
}

fn validatePattern(pattern: []const u8) !void {
    if (pattern.len == 0 or pattern[0] == '/' or std.mem.indexOfScalar(u8, pattern, 0) != null or
        std.mem.indexOfScalar(u8, pattern, '\\') != null)
    {
        return error.InvalidIgnoreRule;
    }
    var components = std.mem.splitScalar(u8, pattern, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
            return error.InvalidIgnoreRule;
        }
    }
}

fn readSourceFileAlloc(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    path: []const u8,
    max_file_bytes: usize,
) !LoadedFile {
    const file = root.openFile(io, path, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.SymLinkLoop, error.AccessDenied => return error.SymlinkNotAllowed,
        else => |other| return other,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.UnsupportedFileType;
    if (stat.size > max_file_bytes) return error.FileTooLarge;
    var reader = file.reader(io, &.{});
    const contents = reader.interface.allocRemaining(
        allocator,
        .limited(max_file_bytes +| 1),
    ) catch |err| switch (err) {
        error.StreamTooLong => return error.FileTooLarge,
        else => |other| return other,
    };
    errdefer allocator.free(contents);
    if (contents.len > max_file_bytes) return error.FileTooLarge;
    const executable = if (std.Io.File.Permissions.has_executable_bit)
        stat.permissions.toMode() & 0o111 != 0
    else
        false;
    return .{ .allocator = allocator, .contents = contents, .executable = executable };
}

fn lessThanPendingPath(_: void, left: PendingEntry, right: PendingEntry) bool {
    return std.mem.order(u8, left.path, right.path) == .lt;
}
