const std = @import("std");
const log = @import("../log.zig");
const provider = @import("../provider.zig");
const gcp_client = @import("client.zig");

pub const Adapter = struct {
    allocator: std.mem.Allocator,
    api: *gcp_client.Client,
    context: *provider.OperationContext,
    diagnostic: gcp_client.Diagnostic,
    response: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, api: *gcp_client.Client, context: *provider.OperationContext) Adapter {
        return .{
            .allocator = allocator,
            .api = api,
            .context = context,
            .diagnostic = gcp_client.Diagnostic.init(allocator),
        };
    }

    pub fn deinit(self: *Adapter) void {
        if (self.response) |bytes| self.allocator.free(bytes);
        self.diagnostic.deinit();
        self.* = undefined;
    }

    pub fn client(self: *Adapter) log.CloudLoggingClient {
        return .{ .ptr = self, .list_fn = list };
    }

    fn list(raw: *anyopaque, request_json: []const u8) ![]const u8 {
        const self: *Adapter = @ptrCast(@alignCast(raw));
        if (request_json.len == 0 or request_json.len > 1024 * 1024) return error.InvalidCloudLoggingRequest;
        var response = try self.api.requestJsonAlloc(self.context, .{
            .api = .logging,
            .method = "POST",
            .path = "/v2/entries:list",
            .body = request_json,
            .response_body_limit = 8 * 1024 * 1024,
        }, &self.diagnostic);
        defer response.deinit(self.context.allocator);
        const owned = try self.allocator.dupe(u8, response.body);
        if (self.response) |previous| self.allocator.free(previous);
        self.response = owned;
        return owned;
    }
};
