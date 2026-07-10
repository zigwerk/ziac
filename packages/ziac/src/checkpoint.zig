const std = @import("std");
const fx = @import("zigeffect_std").fx;
const local_state = @import("local_state.zig");
const state_mod = @import("state.zig");

pub const CheckpointError = error{
    CheckpointFailed,
    OutOfMemory,
};

pub const Checkpoint = struct {
    ptr: *anyopaque,
    saveFn: *const fn (*anyopaque, *state_mod.InMemoryStateStore) CheckpointError!void,
    mutex: ?*fx.SpinLock = null,

    pub fn save(self: Checkpoint, store: *state_mod.InMemoryStateStore) CheckpointError!void {
        if (self.mutex) |mutex| {
            mutex.lock();
            defer mutex.unlock();
        }
        try self.saveFn(self.ptr, store);
    }

    pub fn serialized(self: Checkpoint, mutex: *fx.SpinLock) Checkpoint {
        var result = self;
        result.mutex = mutex;
        return result;
    }
};

pub const LocalResources = struct {
    store: local_state.Store,
    stack: []const u8,
    stage: []const u8,

    pub fn checkpoint(self: *LocalResources) Checkpoint {
        return .{ .ptr = self, .saveFn = save };
    }

    fn save(raw: *anyopaque, state: *state_mod.InMemoryStateStore) CheckpointError!void {
        const self: *LocalResources = @ptrCast(@alignCast(raw));
        self.store.saveResources(self.stack, self.stage, state) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.CheckpointFailed,
        };
    }
};
