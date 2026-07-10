const std = @import("std");

pub const ValidationError = error{
    MissingName,
    MissingClusterId,
    InvalidClusterId,
    MissingRegion,
    DuplicateRegion,
    InvalidUsername,
};

pub const RegionCompatibility = struct {
    allocator: std.mem.Allocator,
    missing: []const []const u8,
    unexpected: []const []const u8,

    pub fn compatible(self: RegionCompatibility) bool {
        return self.missing.len == 0 and self.unexpected.len == 0;
    }

    pub fn messageAlloc(self: RegionCompatibility, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        const missing = try joinAlloc(allocator, self.missing);
        defer allocator.free(missing);
        const unexpected = try joinAlloc(allocator, self.unexpected);
        defer allocator.free(unexpected);
        return std.fmt.allocPrint(
            allocator,
            "CockroachDB GCP regions incompatible: missing [{s}]; unexpected [{s}]",
            .{ missing, unexpected },
        );
    }

    pub fn reasonAlloc(self: RegionCompatibility, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        const missing = try joinAlloc(allocator, self.missing);
        defer allocator.free(missing);
        const unexpected = try joinAlloc(allocator, self.unexpected);
        defer allocator.free(unexpected);
        return std.fmt.allocPrint(
            allocator,
            "regions: missing [{s}]; unexpected [{s}]",
            .{ missing, unexpected },
        );
    }

    pub fn deinit(self: *RegionCompatibility) void {
        freeStrings(self.allocator, self.missing);
        freeStrings(self.allocator, self.unexpected);
        self.* = undefined;
    }
};

pub fn validateRegions(regions: []const []const u8) ValidationError!void {
    if (regions.len == 0) return error.MissingRegion;
    for (regions, 0..) |region, index| {
        if (region.len == 0) return error.MissingRegion;
        for (regions[index + 1 ..]) |other| {
            if (std.mem.eql(u8, region, other)) return error.DuplicateRegion;
        }
    }
}

pub fn validateClusterId(cluster_id: []const u8) ValidationError!void {
    if (cluster_id.len == 0) return error.MissingClusterId;
    for (cluster_id) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '-') return error.InvalidClusterId;
    }
}

pub fn validateUsername(username: []const u8) ValidationError!void {
    if (username.len == 0 or username.len > 63) return error.InvalidUsername;
    if (!std.ascii.isLower(username[0]) and username[0] != '_') return error.InvalidUsername;
    for (username[1..]) |character| {
        if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '_') {
            return error.InvalidUsername;
        }
    }
}

pub fn sortedRegionsAlloc(
    allocator: std.mem.Allocator,
    regions: []const []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    const sorted = try allocator.alloc([]const u8, regions.len);
    @memcpy(sorted, regions);
    std.mem.sort([]const u8, sorted, {}, lessThanString);
    return sorted;
}

pub fn regionCompatibilityAlloc(
    allocator: std.mem.Allocator,
    expected: []const []const u8,
    observed: []const []const u8,
) std.mem.Allocator.Error!RegionCompatibility {
    var missing = std.ArrayList([]const u8).empty;
    errdefer missing.deinit(allocator);
    var unexpected = std.ArrayList([]const u8).empty;
    errdefer unexpected.deinit(allocator);

    for (expected) |region| {
        if (!contains(observed, region)) try appendOwnedString(allocator, &missing, region);
    }
    errdefer for (missing.items) |region| allocator.free(region);
    for (observed) |region| {
        if (!contains(expected, region)) try appendOwnedString(allocator, &unexpected, region);
    }
    errdefer for (unexpected.items) |region| allocator.free(region);
    std.mem.sort([]const u8, missing.items, {}, lessThanString);
    std.mem.sort([]const u8, unexpected.items, {}, lessThanString);
    const owned_missing = try missing.toOwnedSlice(allocator);
    errdefer freeStrings(allocator, owned_missing);
    const owned_unexpected = try unexpected.toOwnedSlice(allocator);
    return .{
        .allocator = allocator,
        .missing = owned_missing,
        .unexpected = owned_unexpected,
    };
}

fn appendOwnedString(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    source: []const u8,
) std.mem.Allocator.Error!void {
    const owned = try allocator.dupe(u8, source);
    list.append(allocator, owned) catch |err| {
        allocator.free(owned);
        return err;
    };
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| if (std.mem.eql(u8, item, needle)) return true;
    return false;
}

fn joinAlloc(allocator: std.mem.Allocator, values: []const []const u8) std.mem.Allocator.Error![]const u8 {
    return std.mem.join(allocator, ", ", values);
}

fn freeStrings(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |item| allocator.free(item);
    allocator.free(values);
}

fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
