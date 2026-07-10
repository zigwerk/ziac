const std = @import("std");
const fx = @import("zigeffect_std").fx;
const state_backend = @import("state_backend.zig");
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

pub const Resources = struct {
    store: state_backend.Store,
    stack: []const u8,
    stage: []const u8,
    lock_owner_id: ?[]const u8 = null,
    now_millis: ?u64 = null,

    pub fn checkpoint(self: *Resources) Checkpoint {
        return .{ .ptr = self, .saveFn = save };
    }

    fn save(raw: *anyopaque, state: *state_mod.InMemoryStateStore) CheckpointError!void {
        const self: *Resources = @ptrCast(@alignCast(raw));
        if (self.lock_owner_id) |owner_id| {
            self.store.renewLock(self.stack, self.stage, owner_id, self.now_millis orelse nowMillis()) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.CheckpointFailed,
            };
        }
        self.store.saveResources(self.stack, self.stage, state) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.CheckpointFailed,
        };
    }
};

fn nowMillis() u64 {
    var clock = fx.Clock.system();
    return clock.nowMs();
}
