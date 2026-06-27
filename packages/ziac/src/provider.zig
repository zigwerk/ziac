const std = @import("std");
const resource = @import("resource.zig");

pub const ProviderError = error{
    ProviderFailed,
    OutOfMemory,
};

pub const Provider = struct {
    ptr: *anyopaque,
    reconcileFn: *const fn (*anyopaque, resource.ResourceNode) ProviderError!void,
    deleteFn: *const fn (*anyopaque, resource.ResourceNode) ProviderError!void,

    pub fn reconcile(self: Provider, node: resource.ResourceNode) ProviderError!void {
        return self.reconcileFn(self.ptr, node);
    }

    pub fn delete(self: Provider, node: resource.ResourceNode) ProviderError!void {
        return self.deleteFn(self.ptr, node);
    }
};

pub const FakeProvider = struct {
    allocator: std.mem.Allocator,
    reconciled: std.ArrayList([]const u8),
    deleted: std.ArrayList([]const u8),
    fail_reconcile: bool = false,
    fail_delete: bool = false,

    pub fn init(allocator: std.mem.Allocator) FakeProvider {
        return .{
            .allocator = allocator,
            .reconciled = std.ArrayList([]const u8).empty,
            .deleted = std.ArrayList([]const u8).empty,
        };
    }

    pub fn deinit(self: *FakeProvider) void {
        self.reconciled.deinit(self.allocator);
        self.deleted.deinit(self.allocator);
    }

    pub fn provider(self: *FakeProvider) Provider {
        return .{
            .ptr = self,
            .reconcileFn = reconcile,
            .deleteFn = delete,
        };
    }

    fn reconcile(raw: *anyopaque, node: resource.ResourceNode) ProviderError!void {
        const self: *FakeProvider = @ptrCast(@alignCast(raw));
        if (self.fail_reconcile) return error.ProviderFailed;
        try self.reconciled.append(self.allocator, node.id);
    }

    fn delete(raw: *anyopaque, node: resource.ResourceNode) ProviderError!void {
        const self: *FakeProvider = @ptrCast(@alignCast(raw));
        if (self.fail_delete) return error.ProviderFailed;
        try self.deleted.append(self.allocator, node.id);
    }
};
