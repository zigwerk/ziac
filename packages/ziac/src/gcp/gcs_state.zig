const std = @import("std");
const client_mod = @import("client.zig");
const provider = @import("../provider.zig");
const state_backend = @import("../state_backend.zig");

pub const Store = struct {
    client: *client_mod.Client,
    context: *provider.OperationContext,
    bucket: []const u8,
    max_object_bytes: usize,

    pub const Options = struct {
        max_object_bytes: usize = 64 * 1024 * 1024,
    };

    pub fn init(
        client: *client_mod.Client,
        context: *provider.OperationContext,
        bucket: []const u8,
    ) !Store {
        return initWithOptions(client, context, bucket, .{});
    }

    pub fn initWithOptions(
        client: *client_mod.Client,
        context: *provider.OperationContext,
        bucket: []const u8,
        options: Options,
    ) !Store {
        try validateBucket(bucket);
        if (options.max_object_bytes == 0) return error.InvalidObjectLimit;
        return .{
            .client = client,
            .context = context,
            .bucket = bucket,
            .max_object_bytes = options.max_object_bytes,
        };
    }

    pub fn objectStore(self: *Store) state_backend.ObjectStore {
        return .{ .ptr = self, .getFn = get, .putFn = put, .deleteFn = delete };
    }

    fn get(raw: *anyopaque, key: []const u8) anyerror!state_backend.Object {
        const self: *Store = @ptrCast(@alignCast(raw));
        try validateObjectKey(key);
        const allocator = self.context.allocator;
        const encoded_bucket = try percentEncodeAlloc(allocator, self.bucket);
        defer allocator.free(encoded_bucket);
        const encoded_key = try percentEncodeAlloc(allocator, key);
        defer allocator.free(encoded_key);
        const metadata_path = try std.fmt.allocPrint(
            allocator,
            "/storage/v1/b/{s}/o/{s}?fields=generation",
            .{ encoded_bucket, encoded_key },
        );
        defer allocator.free(metadata_path);
        var metadata = try self.request(.{ .api = .storage, .method = "GET", .path = metadata_path });
        defer metadata.deinit(allocator);
        const generation = try generationFromJsonAlloc(allocator, metadata.body);
        errdefer allocator.free(generation);

        const media_path = try std.fmt.allocPrint(
            allocator,
            "/storage/v1/b/{s}/o/{s}?alt=media&generation={s}",
            .{ encoded_bucket, encoded_key, generation },
        );
        defer allocator.free(media_path);
        var media = try self.request(.{
            .api = .storage,
            .method = "GET",
            .path = media_path,
            .accept = "application/octet-stream",
            .response_body_limit = self.max_object_bytes,
        });
        defer media.deinit(allocator);
        return .{
            .allocator = allocator,
            .bytes = try allocator.dupe(u8, media.body),
            .generation = generation,
        };
    }

    fn put(
        raw: *anyopaque,
        key: []const u8,
        bytes: []const u8,
        precondition: state_backend.Precondition,
    ) anyerror!state_backend.PutResult {
        const self: *Store = @ptrCast(@alignCast(raw));
        try validateObjectKey(key);
        if (bytes.len > self.max_object_bytes) return error.ObjectTooLarge;
        const expected = switch (precondition) {
            .absent => "0",
            .generation => |generation| blk: {
                try validateGeneration(generation);
                break :blk generation;
            },
        };
        const allocator = self.context.allocator;
        const encoded_bucket = try percentEncodeAlloc(allocator, self.bucket);
        defer allocator.free(encoded_bucket);
        const encoded_key = try percentEncodeAlloc(allocator, key);
        defer allocator.free(encoded_key);
        const path = try std.fmt.allocPrint(
            allocator,
            "/upload/storage/v1/b/{s}/o?uploadType=media&name={s}&ifGenerationMatch={s}",
            .{ encoded_bucket, encoded_key, expected },
        );
        defer allocator.free(path);
        var response = try self.request(.{
            .api = .storage,
            .method = "POST",
            .path = path,
            .body = bytes,
            .content_type = "application/json",
        });
        defer response.deinit(allocator);
        return .{
            .allocator = allocator,
            .generation = try generationFromJsonAlloc(allocator, response.body),
        };
    }

    fn delete(raw: *anyopaque, key: []const u8, generation: []const u8) anyerror!void {
        const self: *Store = @ptrCast(@alignCast(raw));
        try validateObjectKey(key);
        try validateGeneration(generation);
        const allocator = self.context.allocator;
        const encoded_bucket = try percentEncodeAlloc(allocator, self.bucket);
        defer allocator.free(encoded_bucket);
        const encoded_key = try percentEncodeAlloc(allocator, key);
        defer allocator.free(encoded_key);
        const path = try std.fmt.allocPrint(
            allocator,
            "/storage/v1/b/{s}/o/{s}?ifGenerationMatch={s}",
            .{ encoded_bucket, encoded_key, generation },
        );
        defer allocator.free(path);
        var response = try self.request(.{ .api = .storage, .method = "DELETE", .path = path });
        response.deinit(allocator);
    }

    fn request(self: *Store, request_value: client_mod.Request) provider.ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(self.context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(self.context, request_value, &diagnostic);
    }
};

fn generationFromJsonAlloc(allocator: std.mem.Allocator, json: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return error.InvalidRemoteState;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidRemoteState,
    };
    const generation = switch (root.get("generation") orelse return error.InvalidRemoteState) {
        .string => |value| value,
        else => return error.InvalidRemoteState,
    };
    try validateGeneration(generation);
    return allocator.dupe(u8, generation);
}

fn validateBucket(bucket: []const u8) !void {
    if (bucket.len < 3 or bucket.len > 63 or !std.ascii.isAlphanumeric(bucket[0]) or
        !std.ascii.isAlphanumeric(bucket[bucket.len - 1])) return error.InvalidBucket;
    for (bucket) |character| {
        if (!(std.ascii.isDigit(character) or std.ascii.isLower(character) or
            character == '-' or character == '_' or character == '.')) return error.InvalidBucket;
    }
}

fn validateObjectKey(key: []const u8) !void {
    if (key.len == 0 or key.len > 1024 or key[0] == '/') return error.InvalidObjectKey;
    var parts = std.mem.splitScalar(u8, key, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) {
            return error.InvalidObjectKey;
        }
        for (part) |character| if (character < 0x20 or character == 0x7f or character == '\\') {
            return error.InvalidObjectKey;
        };
    }
}

fn validateGeneration(generation: []const u8) !void {
    if (generation.len == 0 or generation.len > 32) return error.InvalidGeneration;
    for (generation) |character| if (!std.ascii.isDigit(character)) return error.InvalidGeneration;
}

fn percentEncodeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const hex = "0123456789ABCDEF";
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    for (input) |character| {
        if (std.ascii.isAlphanumeric(character) or character == '-' or character == '_' or character == '.' or character == '~') {
            try output.append(allocator, character);
        } else {
            try output.appendSlice(allocator, &.{ '%', hex[character >> 4], hex[character & 0x0f] });
        }
    }
    return output.toOwnedSlice(allocator);
}
