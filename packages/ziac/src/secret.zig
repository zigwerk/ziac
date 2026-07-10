const std = @import("std");
const provider = @import("provider.zig");
const value = @import("value.zig");

pub const PayloadDeinitObserver = struct {
    ptr: *anyopaque,
    deinitFn: *const fn (*anyopaque) void,
};

pub const SecretPayload = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    observer: ?PayloadDeinitObserver = null,

    pub fn initOwned(
        allocator: std.mem.Allocator,
        bytes: []const u8,
        observer: ?PayloadDeinitObserver,
    ) provider.ProviderError!SecretPayload {
        return .{
            .allocator = allocator,
            .bytes = allocator.dupe(u8, bytes) catch return error.OutOfMemory,
            .observer = observer,
        };
    }

    pub fn deinit(self: *SecretPayload) void {
        std.crypto.secureZero(u8, self.bytes);
        self.allocator.free(self.bytes);
        if (self.observer) |observer| observer.deinitFn(observer.ptr);
        self.* = undefined;
    }
};

pub const SecretSource = struct {
    ptr: *anyopaque,
    resolveFn: *const fn (
        *anyopaque,
        *provider.OperationContext,
        std.mem.Allocator,
        value.SecretReference,
    ) provider.ProviderError!SecretPayload,

    pub fn resolve(
        self: SecretSource,
        context: *provider.OperationContext,
        allocator: std.mem.Allocator,
        reference: value.SecretReference,
    ) provider.ProviderError!SecretPayload {
        return self.resolveFn(self.ptr, context, allocator, reference);
    }
};
