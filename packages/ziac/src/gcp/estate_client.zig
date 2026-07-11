const std = @import("std");
const zstd = @import("zigeffect_std");
const estate = @import("../estate.zig");
const provider = @import("../provider.zig");
const gcp_client = @import("client.zig");

pub const Adapter = struct {
    gcp_client: *gcp_client.Client,
    context: *provider.OperationContext,
    diagnostic: gcp_client.Diagnostic,

    pub fn init(api_client: *gcp_client.Client, context: *provider.OperationContext) Adapter {
        return .{
            .gcp_client = api_client,
            .context = context,
            .diagnostic = gcp_client.Diagnostic.init(context.allocator),
        };
    }

    pub fn deinit(self: *Adapter) void {
        self.diagnostic.deinit();
        self.* = undefined;
    }

    pub fn client(self: *Adapter) estate.Client {
        return .{ .ptr = self, .search_alloc = searchAlloc };
    }

    fn searchAlloc(
        raw: *anyopaque,
        allocator: std.mem.Allocator,
        request: estate.SearchRequest,
    ) ![]u8 {
        const self: *Adapter = @ptrCast(@alignCast(raw));
        const path = try searchPathAlloc(self.context.allocator, request);
        defer self.context.allocator.free(path);
        var response = try self.gcp_client.requestJsonAlloc(self.context, .{
            .api = .cloud_asset,
            .method = "GET",
            .path = path,
            .response_body_limit = 16 * 1024 * 1024,
        }, &self.diagnostic);
        defer response.deinit(self.context.allocator);
        return allocator.dupe(u8, response.body);
    }
};

fn searchPathAlloc(allocator: std.mem.Allocator, request: estate.SearchRequest) ![]u8 {
    if (!validProjectId(request.project_id) or request.page_size == 0 or request.page_size > 500) {
        return error.InvalidScanRequest;
    }
    if (request.page_token) |token| {
        if (token.len == 0 or token.len > 16 * 1024 or std.mem.indexOfScalar(u8, token, 0) != null) {
            return error.InvalidScanRequest;
        }
        const encoded = try queryEncodeAlloc(allocator, token);
        defer allocator.free(encoded);
        return std.fmt.allocPrint(
            allocator,
            "/v1/projects/{s}:searchAllResources?pageSize={d}&pageToken={s}",
            .{ request.project_id, request.page_size, encoded },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "/v1/projects/{s}:searchAllResources?pageSize={d}",
        .{ request.project_id, request.page_size },
    );
}

fn queryEncodeAlloc(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (input) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try result.append(allocator, byte);
        } else {
            try result.appendSlice(allocator, &.{ '%', hex[byte >> 4], hex[byte & 0x0f] });
        }
    }
    return result.toOwnedSlice(allocator);
}

fn validProjectId(value: []const u8) bool {
    if (value.len < 6 or value.len > 63 or !std.ascii.isLower(value[0])) return false;
    if (value[value.len - 1] == '-') return false;
    for (value) |byte| {
        if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '-')) return false;
    }
    return !zstd.Secrets.containsSecret(value);
}
