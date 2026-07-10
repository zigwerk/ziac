const std = @import("std");

pub const Error = std.mem.Allocator.Error || error{
    InvalidRepository,
    InvalidChangeNumber,
    InvalidPreviewStage,
    ProductionPreviewCleanupForbidden,
    InvalidNameLimit,
    InvalidResourceName,
    ResourceNameTooLong,
    InvalidDomain,
};

pub const PreviewStageArgs = struct {
    repository: []const u8,
    change_number: u64,
};

pub fn previewStageAlloc(
    allocator: std.mem.Allocator,
    args: PreviewStageArgs,
) Error![]u8 {
    try validateRepository(args.repository);
    if (args.change_number == 0) return error.InvalidChangeNumber;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (args.repository) |character| {
        const normalized = std.ascii.toLower(character);
        hasher.update(&.{normalized});
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const encoded = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "pr-{d}-{s}", .{ args.change_number, encoded[0..8] });
}

pub fn isPreviewStage(stage: []const u8) bool {
    var parts = std.mem.splitScalar(u8, stage, '-');
    const prefix = parts.next() orelse return false;
    const number = parts.next() orelse return false;
    const repository_hash = parts.next() orelse return false;
    if (parts.next() != null or !std.mem.eql(u8, prefix, "pr")) return false;
    if (number.len == 0 or (number.len > 1 and number[0] == '0')) return false;
    const parsed = std.fmt.parseInt(u64, number, 10) catch return false;
    if (parsed == 0 or repository_hash.len != 8) return false;
    for (repository_hash) |character| {
        if (!std.ascii.isDigit(character) and !(character >= 'a' and character <= 'f')) return false;
    }
    return true;
}

pub fn isProductionStage(stage: []const u8) bool {
    return std.mem.eql(u8, stage, "prod") or std.mem.eql(u8, stage, "production");
}

pub fn validatePreviewCleanup(stage: []const u8) Error!void {
    if (isProductionStage(stage)) return error.ProductionPreviewCleanupForbidden;
    if (!isPreviewStage(stage)) return error.InvalidPreviewStage;
}

pub fn scopedResourceNameAlloc(
    allocator: std.mem.Allocator,
    base: []const u8,
    stage: []const u8,
    max_len: usize,
) Error![]u8 {
    try validateProviderName(base);
    if (max_len == 0) return error.InvalidNameLimit;
    try validatePreviewPrefix(stage);
    if (!isPreviewStage(stage)) {
        if (base.len > max_len) return error.ResourceNameTooLong;
        return allocator.dupe(u8, base);
    }

    const candidate_len = base.len + 1 + stage.len;
    if (candidate_len <= max_len) return std.fmt.allocPrint(allocator, "{s}-{s}", .{ base, stage });

    const fixed_len = 1 + 8 + 1 + stage.len;
    if (max_len <= fixed_len) return error.ResourceNameTooLong;
    var prefix_len = max_len - fixed_len;
    prefix_len = @min(prefix_len, base.len);
    while (prefix_len > 1 and base[prefix_len - 1] == '-') prefix_len -= 1;
    const digest = shortDigest(base);
    return std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{
        base[0..prefix_len],
        digest[0..8],
        stage,
    });
}

pub fn previewDomainAlloc(
    allocator: std.mem.Allocator,
    base_domain: []const u8,
    stage: []const u8,
) Error![]u8 {
    try validateDomain(base_domain);
    try validatePreviewPrefix(stage);
    if (!isPreviewStage(stage)) return allocator.dupe(u8, base_domain);
    if (stage.len > 63 or stage.len + 1 + base_domain.len > 253) return error.InvalidDomain;
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ stage, base_domain });
}

fn validateRepository(repository: []const u8) Error!void {
    if (repository.len == 0 or repository.len > 201) return error.InvalidRepository;
    const slash = std.mem.indexOfScalar(u8, repository, '/') orelse return error.InvalidRepository;
    if (slash == 0 or slash == repository.len - 1 or std.mem.indexOfScalarPos(u8, repository, slash + 1, '/') != null) {
        return error.InvalidRepository;
    }
    for (repository) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '-' and character != '_' and character != '.' and character != '/') {
            return error.InvalidRepository;
        }
    }
}

fn validateProviderName(name: []const u8) Error!void {
    if (name.len == 0 or !std.ascii.isLower(name[0]) or !std.ascii.isAlphanumeric(name[name.len - 1])) {
        return error.InvalidResourceName;
    }
    for (name) |character| {
        if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') {
            return error.InvalidResourceName;
        }
    }
}

fn validatePreviewPrefix(stage: []const u8) Error!void {
    if (std.mem.startsWith(u8, stage, "pr-") and !isPreviewStage(stage)) return error.InvalidPreviewStage;
}

fn validateDomain(domain: []const u8) Error!void {
    if (domain.len == 0 or domain.len > 253 or domain[0] == '.' or domain[domain.len - 1] == '.') return error.InvalidDomain;
    var labels = std.mem.splitScalar(u8, domain, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63 or !std.ascii.isLower(label[0]) or
            !std.ascii.isAlphanumeric(label[label.len - 1])) return error.InvalidDomain;
        for (label) |character| {
            if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') {
                return error.InvalidDomain;
            }
        }
    }
}

fn shortDigest(value: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}
