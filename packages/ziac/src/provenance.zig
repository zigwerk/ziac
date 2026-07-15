const std = @import("std");

pub const Error = std.mem.Allocator.Error || error{InvalidComponentOrigin};

pub const Origin = struct {
    package: []const u8,
    name: []const u8,
    version: []const u8,
    instance: []const u8,
    source_digest: []const u8,

    pub fn validate(self: Origin) error{InvalidComponentOrigin}!void {
        if (!validPackageName(self.package) or !validToken(self.name, 128) or
            !validVersion(self.version) or !validToken(self.instance, 128) or
            !validDigest(self.source_digest)) return error.InvalidComponentOrigin;
    }

    pub fn initOwned(allocator: std.mem.Allocator, source: Origin) Error!Origin {
        try source.validate();
        return cloneOwned(allocator, source);
    }

    pub fn cloneOwned(allocator: std.mem.Allocator, source: Origin) std.mem.Allocator.Error!Origin {
        const package = try allocator.dupe(u8, source.package);
        errdefer allocator.free(package);
        const name = try allocator.dupe(u8, source.name);
        errdefer allocator.free(name);
        const version = try allocator.dupe(u8, source.version);
        errdefer allocator.free(version);
        const instance = try allocator.dupe(u8, source.instance);
        errdefer allocator.free(instance);
        return .{
            .package = package,
            .name = name,
            .version = version,
            .instance = instance,
            .source_digest = try allocator.dupe(u8, source.source_digest),
        };
    }

    pub fn deinit(self: *Origin, allocator: std.mem.Allocator) void {
        allocator.free(self.package);
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.instance);
        allocator.free(self.source_digest);
        self.* = undefined;
    }

    pub fn eql(self: Origin, other: Origin) bool {
        return std.mem.eql(u8, self.package, other.package) and
            std.mem.eql(u8, self.name, other.name) and
            std.mem.eql(u8, self.version, other.version) and
            std.mem.eql(u8, self.instance, other.instance) and
            std.mem.eql(u8, self.source_digest, other.source_digest);
    }
};

pub fn validPackageName(value: []const u8) bool {
    if (value.len == 0 or value.len > 128 or value[0] == '/' or value[value.len - 1] == '/') return false;
    var previous_separator = false;
    for (value) |char| {
        const separator = char == '/';
        if (!(std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or char == '.' or separator)) return false;
        if (separator and previous_separator) return false;
        previous_separator = separator;
    }
    return true;
}

pub fn validToken(value: []const u8, max_len: usize) bool {
    if (value.len == 0 or value.len > max_len) return false;
    for (value) |char| if (!(std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or char == '.')) return false;
    return true;
}

pub fn validVersion(value: []const u8) bool {
    if (value.len < 5 or value.len > 64) return false;
    var dots: usize = 0;
    for (value) |char| {
        if (char == '.') dots += 1 else if (!(std.ascii.isDigit(char) or std.ascii.isAlphabetic(char) or char == '-' or char == '+')) return false;
    }
    return dots >= 2;
}

pub fn validDigest(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |char| if (!(std.ascii.isDigit(char) or char >= 'a' and char <= 'f')) return false;
    return true;
}
