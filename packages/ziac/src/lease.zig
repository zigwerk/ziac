const std = @import("std");
const ci = @import("ci.zig");

pub const Status = enum { active, expired, cleaning, clean, failed };

pub const Input = struct {
    id: []const u8,
    owner: []const u8,
    repository: []const u8,
    change_number: u64,
    created_at_millis: u64,
    expires_at_millis: u64,
    project: []const u8,
    state_prefix: []const u8,
    max_resources: usize,
    max_monthly_cost_minor: u64,
};

pub const Lease = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    owner: []const u8,
    repository: []const u8,
    stage: []const u8,
    project: []const u8,
    state_prefix: []const u8,
    created_at_millis: u64,
    expires_at_millis: u64,
    last_heartbeat_millis: u64,
    max_resources: usize,
    max_monthly_cost_minor: u64,
    status: Status = .active,
    cleaned: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator, input: Input) !Lease {
        if (input.id.len == 0 or input.owner.len == 0 or input.repository.len == 0 or input.change_number == 0 or
            input.expires_at_millis <= input.created_at_millis or input.max_resources == 0 or input.max_monthly_cost_minor == 0) return error.InvalidLease;
        const id = try allocator.dupe(u8, input.id);
        errdefer allocator.free(id);
        const owner = try allocator.dupe(u8, input.owner);
        errdefer allocator.free(owner);
        const repository = try allocator.dupe(u8, input.repository);
        errdefer allocator.free(repository);
        const stage = try ci.previewStageAlloc(allocator, .{ .repository = input.repository, .change_number = input.change_number });
        errdefer allocator.free(stage);
        const project = try allocator.dupe(u8, input.project);
        errdefer allocator.free(project);
        const state_prefix = try allocator.dupe(u8, input.state_prefix);
        errdefer allocator.free(state_prefix);
        return .{
            .allocator = allocator,
            .id = id,
            .owner = owner,
            .repository = repository,
            .stage = stage,
            .project = project,
            .state_prefix = state_prefix,
            .created_at_millis = input.created_at_millis,
            .expires_at_millis = input.expires_at_millis,
            .last_heartbeat_millis = input.created_at_millis,
            .max_resources = input.max_resources,
            .max_monthly_cost_minor = input.max_monthly_cost_minor,
            .cleaned = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *Lease) void {
        self.allocator.free(self.id);
        self.allocator.free(self.owner);
        self.allocator.free(self.repository);
        self.allocator.free(self.stage);
        self.allocator.free(self.project);
        self.allocator.free(self.state_prefix);
        var iterator = self.cleaned.keyIterator();
        while (iterator.next()) |key| self.allocator.free(key.*);
        self.cleaned.deinit();
        self.* = undefined;
    }

    pub fn authorizeMutation(self: *Lease, now_millis: u64, resources: usize, monthly_cost_minor: u64) !void {
        try self.requireActive(now_millis);
        if (resources > self.max_resources or monthly_cost_minor > self.max_monthly_cost_minor) return error.LeaseBudgetExceeded;
    }

    pub fn heartbeat(self: *Lease, now_millis: u64) !void {
        try self.requireActive(now_millis);
        if (now_millis < self.last_heartbeat_millis) return error.InvalidHeartbeat;
        self.last_heartbeat_millis = now_millis;
    }

    pub fn jsonAlloc(self: *Lease, allocator: std.mem.Allocator, now_millis: u64) std.mem.Allocator.Error![]u8 {
        const status = self.effectiveStatus(now_millis);
        const state_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.state_prefix, self.stage });
        defer allocator.free(state_path);
        const wif_subject = try std.fmt.allocPrint(allocator, "repo:{s}:pull_request:{s}", .{ self.repository, self.stage });
        defer allocator.free(wif_subject);
        return std.json.Stringify.valueAlloc(allocator, .{
            .schema = "ziac.ephemeral-lease.v1",
            .id = self.id,
            .owner = self.owner,
            .repository = self.repository,
            .stage = self.stage,
            .project = self.project,
            .state_path = state_path,
            .wif_subject = wif_subject,
            .created_at_millis = self.created_at_millis,
            .expires_at_millis = self.expires_at_millis,
            .last_heartbeat_millis = self.last_heartbeat_millis,
            .max_resources = self.max_resources,
            .max_monthly_cost_minor = self.max_monthly_cost_minor,
            .status = status,
            .cleaned_resources = self.cleaned.count(),
        }, .{}) catch return error.OutOfMemory;
    }

    pub fn cleanup(self: *Lease, provider: CleanupProvider, now_millis: u64, resources: []const []const u8) !CleanupReceipt {
        if (now_millis < self.expires_at_millis) return error.LeaseNotExpired;
        if (!std.mem.startsWith(u8, self.stage, "pr-")) return error.UnsafeCleanupStage;
        if (self.status == .clean) return .{ .stage = self.stage, .deleted = 0, .already_clean = true };
        self.status = .cleaning;
        var deleted: usize = 0;
        for (resources) |resource_id| {
            if (self.cleaned.contains(resource_id)) continue;
            provider.delete(resource_id) catch |err| {
                self.status = .failed;
                return err;
            };
            const owned = try self.allocator.dupe(u8, resource_id);
            errdefer self.allocator.free(owned);
            try self.cleaned.put(owned, {});
            deleted += 1;
        }
        self.status = .clean;
        return .{ .stage = self.stage, .deleted = deleted, .already_clean = false };
    }

    fn requireActive(self: *Lease, now_millis: u64) !void {
        if (now_millis >= self.expires_at_millis) {
            if (self.status == .active) self.status = .expired;
            return error.LeaseExpired;
        }
        if (self.status != .active) return error.LeaseInactive;
    }

    fn effectiveStatus(self: *Lease, now_millis: u64) Status {
        if (self.status == .active and now_millis >= self.expires_at_millis) self.status = .expired;
        return self.status;
    }
};

pub const CleanupReceipt = struct {
    schema: []const u8 = "ziac.lease-cleanup.v1",
    stage: []const u8,
    deleted: usize,
    already_clean: bool,
};

pub const CleanupProvider = struct {
    ptr: *anyopaque,
    delete_fn: *const fn (*anyopaque, []const u8) anyerror!void,

    pub fn delete(self: CleanupProvider, resource_id: []const u8) !void {
        try self.delete_fn(self.ptr, resource_id);
    }
};

pub const ScriptedCleanup = struct {
    allocator: std.mem.Allocator,
    deleted: std.StringHashMap(void),
    delete_count: usize = 0,
    failure: ?anyerror = null,

    pub fn init(allocator: std.mem.Allocator) ScriptedCleanup {
        return .{ .allocator = allocator, .deleted = std.StringHashMap(void).init(allocator) };
    }

    pub fn deinit(self: *ScriptedCleanup) void {
        var iterator = self.deleted.keyIterator();
        while (iterator.next()) |key| self.allocator.free(key.*);
        self.deleted.deinit();
        self.* = undefined;
    }

    pub fn provider(self: *ScriptedCleanup) CleanupProvider {
        return .{ .ptr = self, .delete_fn = delete };
    }

    fn delete(raw: *anyopaque, resource_id: []const u8) !void {
        const self: *ScriptedCleanup = @ptrCast(@alignCast(raw));
        if (self.failure) |err| return err;
        if (self.deleted.contains(resource_id)) return;
        const owned = try self.allocator.dupe(u8, resource_id);
        errdefer self.allocator.free(owned);
        try self.deleted.put(owned, {});
        self.delete_count += 1;
    }
};
