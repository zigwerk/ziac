const std = @import("std");
const client_mod = @import("client.zig");
const provider = @import("../provider.zig");
const secret = @import("../secret.zig");
const value = @import("../value.zig");

pub const SecretManagerSource = struct {
    client: *client_mod.Client,

    pub fn init(client: *client_mod.Client) SecretManagerSource {
        return .{ .client = client };
    }

    pub fn secretSource(self: *SecretManagerSource) secret.SecretSource {
        return .{ .ptr = self, .resolveFn = resolve };
    }

    fn resolve(
        raw: *anyopaque,
        context: *provider.OperationContext,
        allocator: std.mem.Allocator,
        reference: value.SecretReference,
    ) provider.ProviderError!secret.SecretPayload {
        const self: *SecretManagerSource = @ptrCast(@alignCast(raw));
        if (!std.mem.eql(u8, reference.provider, "gcp-secret-manager")) return error.NotFound;
        if (!isValidResource(reference.resource) or reference.field != null) return error.InvalidConfiguration;
        const version = reference.version orelse return error.InvalidConfiguration;
        if (!isNumeric(version)) return error.InvalidConfiguration;
        const path = std.fmt.allocPrint(
            allocator,
            "/v1/{s}/versions/{s}:access",
            .{ reference.resource, version },
        ) catch return error.OutOfMemory;
        defer allocator.free(path);
        var diagnostic = client_mod.Diagnostic.init(allocator);
        defer diagnostic.deinit();
        var response = try self.client.requestJsonAlloc(context, .{
            .api = .secret_manager,
            .method = "GET",
            .path = path,
        }, &diagnostic);
        defer response.deinit(allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |object| object,
            else => return error.ProviderBug,
        };
        const payload_value = root.get("payload") orelse return error.ProviderBug;
        const payload = switch (payload_value) {
            .object => |object| object,
            else => return error.ProviderBug,
        };
        const data_value = payload.get("data") orelse return error.ProviderBug;
        const encoded = switch (data_value) {
            .string => |text| text,
            else => return error.ProviderBug,
        };
        const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.ProviderBug;
        const decoded = allocator.alloc(u8, decoded_size) catch return error.OutOfMemory;
        errdefer {
            std.crypto.secureZero(u8, decoded);
            allocator.free(decoded);
        }
        std.base64.standard.Decoder.decode(decoded, encoded) catch return error.ProviderBug;
        return .{ .allocator = allocator, .bytes = decoded };
    }
};

fn isValidResource(resource: []const u8) bool {
    var parts = std.mem.splitScalar(u8, resource, '/');
    if (!std.mem.eql(u8, parts.next() orelse return false, "projects")) return false;
    if (!isIdentifier(parts.next() orelse return false)) return false;
    if (!std.mem.eql(u8, parts.next() orelse return false, "secrets")) return false;
    if (!isIdentifier(parts.next() orelse return false)) return false;
    return parts.next() == null;
}

fn isIdentifier(identifier: []const u8) bool {
    if (identifier.len == 0) return false;
    for (identifier) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '-' and character != '_') return false;
    }
    return true;
}

fn isNumeric(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |character| if (!std.ascii.isDigit(character)) return false;
    return true;
}
