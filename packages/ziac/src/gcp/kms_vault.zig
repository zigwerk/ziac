const std = @import("std");
const client_mod = @import("client.zig");
const provider = @import("../provider.zig");
const estate_service = @import("../estate_service.zig");

pub const CiphertextStore = struct {
    ptr: *anyopaque,
    persist_fn: *const fn (*anyopaque, []const u8, []const u8, []const u8, [32]u8) anyerror!void,
};

pub const Vault = struct {
    allocator: std.mem.Allocator,
    client: *client_mod.Client,
    context: *provider.OperationContext,
    key_name: []u8,
    store: CiphertextStore,

    pub fn init(
        allocator: std.mem.Allocator,
        client: *client_mod.Client,
        context: *provider.OperationContext,
        key_name: []const u8,
        store: CiphertextStore,
    ) !Vault {
        if (!validKeyName(key_name)) return error.InvalidKmsKeyName;
        return .{
            .allocator = allocator,
            .client = client,
            .context = context,
            .key_name = try allocator.dupe(u8, key_name),
            .store = store,
        };
    }

    pub fn deinit(self: *Vault) void {
        self.allocator.free(self.key_name);
        self.* = undefined;
    }

    pub fn credentialVault(self: *Vault) estate_service.CredentialVault {
        return .{ .ptr = self, .seal_fn = seal };
    }

    fn seal(raw: *anyopaque, subject: []const u8, plaintext: []const u8) !void {
        const self: *Vault = @ptrCast(@alignCast(raw));
        if (!validSubject(subject) or plaintext.len < 8 or plaintext.len > 16 * 1024 or
            std.mem.indexOfAny(u8, plaintext, "\x00\r\n") != null) return error.InvalidCredential;
        const encoded_size = std.base64.standard.Encoder.calcSize(plaintext.len);
        const encoded = try self.allocator.alloc(u8, encoded_size);
        defer {
            std.crypto.secureZero(u8, encoded);
            self.allocator.free(encoded);
        }
        _ = std.base64.standard.Encoder.encode(encoded, plaintext);
        const body = try std.json.Stringify.valueAlloc(self.allocator, .{ .plaintext = encoded }, .{});
        defer {
            std.crypto.secureZero(u8, body);
            self.allocator.free(body);
        }
        const path = try std.fmt.allocPrint(self.allocator, "/v1/{s}:encrypt", .{self.key_name});
        defer self.allocator.free(path);
        var diagnostic = client_mod.Diagnostic.init(self.allocator);
        defer diagnostic.deinit();
        var response = try self.client.requestJsonAlloc(self.context, .{
            .api = .cloud_kms,
            .method = "POST",
            .path = path,
            .body = body,
        }, &diagnostic);
        defer response.deinit(self.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response.body, .{}) catch return error.InvalidKmsResponse;
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |value| value,
            else => return error.InvalidKmsResponse,
        };
        const key_version = jsonString(object.get("name")) orelse return error.InvalidKmsResponse;
        const ciphertext = jsonString(object.get("ciphertext")) orelse return error.InvalidKmsResponse;
        const verified = jsonBool(object.get("verifiedPlaintextCrc32c")) orelse return error.InvalidKmsResponse;
        if (!verified or !std.mem.startsWith(u8, key_version, self.key_name) or ciphertext.len == 0 or ciphertext.len > 64 * 1024) {
            return error.InvalidKmsResponse;
        }
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(plaintext, &digest, .{});
        defer std.crypto.secureZero(u8, &digest);
        try self.store.persist_fn(self.store.ptr, subject, ciphertext, key_version, digest);
    }
};

fn validKeyName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "projects/") or name.len > 1024 or std.mem.indexOfAny(u8, name, "\x00\r\n") != null) return false;
    return std.mem.indexOf(u8, name, "/locations/") != null and std.mem.indexOf(u8, name, "/keyRings/") != null and
        std.mem.indexOf(u8, name, "/cryptoKeys/") != null and !std.mem.endsWith(u8, name, "/");
}

fn validSubject(subject: []const u8) bool {
    return subject.len >= 3 and subject.len <= 512 and std.mem.indexOfAny(u8, subject, "\x00\r\n") == null;
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const present = value orelse return null;
    return switch (present) {
        .string => |text| text,
        else => null,
    };
}

fn jsonBool(value: ?std.json.Value) ?bool {
    const present = value orelse return null;
    return switch (present) {
        .bool => |boolean| boolean,
        else => null,
    };
}
