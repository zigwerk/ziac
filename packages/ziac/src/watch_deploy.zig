const std = @import("std");
const contract = @import("agent_contract.zig");

pub const ActiveResult = enum { complete, cancelled, failed };

pub const Controller = struct {
    allocator: std.mem.Allocator,
    pending: ?[]const u8 = null,
    active: ?[]const u8 = null,
    cancel_requested: bool = false,
    superseded_count: u64 = 0,
    cancelled_count: u64 = 0,
    completed_count: u64 = 0,
    failed_count: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Controller {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Controller) void {
        if (self.pending) |value| self.allocator.free(value);
        if (self.active) |value| self.allocator.free(value);
        self.* = undefined;
    }

    pub fn submit(self: *Controller, digest: []const u8) std.mem.Allocator.Error!void {
        if (self.pending) |current| {
            if (std.mem.eql(u8, current, digest)) return;
            const replacement = try self.allocator.dupe(u8, digest);
            self.allocator.free(current);
            self.pending = replacement;
            self.superseded_count += 1;
        } else {
            self.pending = try self.allocator.dupe(u8, digest);
        }
        if (self.active != null) self.cancel_requested = true;
    }

    pub fn startNext(self: *Controller) error{ActiveDeployment}!?[]const u8 {
        if (self.active != null) return error.ActiveDeployment;
        const next = self.pending orelse return null;
        self.pending = null;
        self.active = next;
        self.cancel_requested = false;
        return next;
    }

    pub fn finishActive(self: *Controller, result: ActiveResult) error{NoActiveDeployment}!void {
        const active = self.active orelse return error.NoActiveDeployment;
        self.allocator.free(active);
        self.active = null;
        self.cancel_requested = false;
        switch (result) {
            .complete => self.completed_count += 1,
            .cancelled => self.cancelled_count += 1,
            .failed => self.failed_count += 1,
        }
    }

    pub fn cancelRequested(self: *const Controller) bool {
        return self.cancel_requested;
    }

    pub fn pendingDigest(self: *const Controller) ?[]const u8 {
        return self.pending;
    }

    pub fn activeDigest(self: *const Controller) ?[]const u8 {
        return self.active;
    }
};

pub const Runtime = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        push_image: *const fn (*anyopaque, []const u8) anyerror!void,
        create_revision: *const fn (*anyopaque, []const u8, bool) anyerror!void,
        wait_ready: *const fn (*anyopaque, []const u8) anyerror!bool,
        promote_traffic: *const fn (*anyopaque, []const u8) anyerror!void,
        now_millis: *const fn (*anyopaque) u64,
    };

    pub fn pushImage(self: Runtime, image_ref: []const u8) !void {
        try self.vtable.push_image(self.ptr, image_ref);
    }

    pub fn createRevision(self: Runtime, image_ref: []const u8, no_traffic: bool) !void {
        try self.vtable.create_revision(self.ptr, image_ref, no_traffic);
    }

    pub fn waitReady(self: Runtime, image_ref: []const u8) !bool {
        return self.vtable.wait_ready(self.ptr, image_ref);
    }

    pub fn promoteTraffic(self: Runtime, image_ref: []const u8) !void {
        try self.vtable.promote_traffic(self.ptr, image_ref);
    }

    pub fn nowMillis(self: Runtime) u64 {
        return self.vtable.now_millis(self.ptr);
    }
};

pub const ExecuteInput = struct {
    now_millis: u64,
    started_at_millis: u64 = 0,
    stage: []const u8,
    project: []const u8,
    plan_digest: []const u8,
    image_ref: []const u8,
    regions: usize,
    monthly_cost_minor: u64 = 0,
    destructive: bool = false,
    slo_target_millis: u64 = 15_000,
};

pub const Status = enum {
    complete,
    push_failed,
    revision_failed,
    readiness_failed,
    traffic_failed,
};

pub const Receipt = struct {
    schema: []const u8 = "ziac.watch-deploy.v1",
    status: Status,
    image_ref: []const u8,
    no_traffic_verified: bool,
    traffic_promoted: bool,
    timings: Timings,
    slo_target_millis: u64,
    slo_miss: bool,
};

pub const Timings = struct {
    total_millis: u64,
    push_millis: u64,
    revision_millis: u64,
    readiness_millis: u64,
    traffic_millis: u64,
};

pub fn execute(runtime: Runtime, envelope: contract.CapabilityEnvelope, input: ExecuteInput) !Receipt {
    if (!isDevelopmentStage(input.stage)) return error.WatchProductionForbidden;
    if (input.destructive) return error.WatchDestructiveChange;
    if (!isImmutableImage(input.image_ref)) return error.MutableWatchImage;
    try envelope.require(.{
        .now_millis = input.now_millis,
        .started_at_millis = input.started_at_millis,
        .stage = input.stage,
        .project = input.project,
        .provider = .gcp,
        .action = .apply,
        .updates = 1,
        .regions = input.regions,
        .monthly_cost_minor = input.monthly_cost_minor,
        .plan_digest = input.plan_digest,
    });
    const started = runtime.nowMillis();
    runtime.pushImage(input.image_ref) catch {
        const ended = runtime.nowMillis();
        return receipt(input, .push_failed, false, false, timings(started, ended, ended, ended, ended));
    };
    const pushed = runtime.nowMillis();
    runtime.createRevision(input.image_ref, true) catch {
        const ended = runtime.nowMillis();
        return receipt(input, .revision_failed, false, false, timings(started, pushed, ended, ended, ended));
    };
    const revisioned = runtime.nowMillis();
    const ready = runtime.waitReady(input.image_ref) catch false;
    const readied = runtime.nowMillis();
    if (!ready) return receipt(input, .readiness_failed, true, false, timings(started, pushed, revisioned, readied, readied));
    runtime.promoteTraffic(input.image_ref) catch {
        const ended = runtime.nowMillis();
        return receipt(input, .traffic_failed, true, false, timings(started, pushed, revisioned, readied, ended));
    };
    const promoted = runtime.nowMillis();
    return receipt(input, .complete, true, true, timings(started, pushed, revisioned, readied, promoted));
}

pub const ScriptedRuntime = struct {
    push_error: ?anyerror = null,
    revision_error: ?anyerror = null,
    readiness_error: ?anyerror = null,
    traffic_error: ?anyerror = null,
    ready: bool = true,
    push_count: usize = 0,
    revision_count: usize = 0,
    readiness_count: usize = 0,
    traffic_count: usize = 0,
    now_millis: u64 = 0,
    push_millis: u64 = 0,
    revision_millis: u64 = 0,
    readiness_millis: u64 = 0,
    traffic_millis: u64 = 0,

    pub fn init() ScriptedRuntime {
        return .{};
    }

    pub fn runtime(self: *ScriptedRuntime) Runtime {
        return .{ .ptr = self, .vtable = &scripted_vtable };
    }

    fn pushImage(raw: *anyopaque, _: []const u8) !void {
        const self: *ScriptedRuntime = @ptrCast(@alignCast(raw));
        self.push_count += 1;
        self.now_millis +|= self.push_millis;
        if (self.push_error) |err| return err;
    }

    fn createRevision(raw: *anyopaque, _: []const u8, no_traffic: bool) !void {
        const self: *ScriptedRuntime = @ptrCast(@alignCast(raw));
        if (!no_traffic) return error.TrafficMustRemainZero;
        self.revision_count += 1;
        self.now_millis +|= self.revision_millis;
        if (self.revision_error) |err| return err;
    }

    fn waitReady(raw: *anyopaque, _: []const u8) !bool {
        const self: *ScriptedRuntime = @ptrCast(@alignCast(raw));
        self.readiness_count += 1;
        self.now_millis +|= self.readiness_millis;
        if (self.readiness_error) |err| return err;
        return self.ready;
    }

    fn promoteTraffic(raw: *anyopaque, _: []const u8) !void {
        const self: *ScriptedRuntime = @ptrCast(@alignCast(raw));
        if (self.traffic_error) |err| return err;
        self.traffic_count += 1;
        self.now_millis +|= self.traffic_millis;
    }

    fn nowMillis(raw: *anyopaque) u64 {
        const self: *ScriptedRuntime = @ptrCast(@alignCast(raw));
        return self.now_millis;
    }
};

const scripted_vtable: Runtime.VTable = .{
    .push_image = ScriptedRuntime.pushImage,
    .create_revision = ScriptedRuntime.createRevision,
    .wait_ready = ScriptedRuntime.waitReady,
    .promote_traffic = ScriptedRuntime.promoteTraffic,
    .now_millis = ScriptedRuntime.nowMillis,
};

fn receipt(
    input: ExecuteInput,
    status: Status,
    no_traffic_verified: bool,
    traffic_promoted: bool,
    phase_timings: Timings,
) Receipt {
    return .{
        .status = status,
        .image_ref = input.image_ref,
        .no_traffic_verified = no_traffic_verified,
        .traffic_promoted = traffic_promoted,
        .timings = phase_timings,
        .slo_target_millis = input.slo_target_millis,
        .slo_miss = phase_timings.total_millis > input.slo_target_millis,
    };
}

pub fn eventStreamJsonAlloc(allocator: std.mem.Allocator, deployment: Receipt) std.mem.Allocator.Error![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    const phases = [_]struct { name: []const u8, duration: u64 }{
        .{ .name = "push", .duration = deployment.timings.push_millis },
        .{ .name = "revision", .duration = deployment.timings.revision_millis },
        .{ .name = "readiness", .duration = deployment.timings.readiness_millis },
        .{ .name = "traffic", .duration = deployment.timings.traffic_millis },
    };
    for (phases) |phase| {
        const line = std.json.Stringify.valueAlloc(allocator, .{
            .schema = "ziac.watch-deploy-event.v1",
            .phase = phase.name,
            .duration_millis = phase.duration,
            .image_ref = deployment.image_ref,
        }, .{}) catch return error.OutOfMemory;
        defer allocator.free(line);
        try output.appendSlice(allocator, line);
        try output.append(allocator, '\n');
    }
    const receipt_json = std.json.Stringify.valueAlloc(allocator, deployment, .{}) catch return error.OutOfMemory;
    defer allocator.free(receipt_json);
    try output.appendSlice(allocator, receipt_json);
    try output.append(allocator, '\n');
    return output.toOwnedSlice(allocator);
}

fn timings(started: u64, pushed: u64, revisioned: u64, readied: u64, ended: u64) Timings {
    return .{
        .total_millis = ended -| started,
        .push_millis = pushed -| started,
        .revision_millis = revisioned -| pushed,
        .readiness_millis = readied -| revisioned,
        .traffic_millis = ended -| readied,
    };
}

fn isDevelopmentStage(stage: []const u8) bool {
    return std.mem.eql(u8, stage, "dev") or std.mem.startsWith(u8, stage, "dev_") or
        std.mem.startsWith(u8, stage, "dev-") or std.mem.startsWith(u8, stage, "pr-");
}

fn isImmutableImage(image: []const u8) bool {
    const marker = "@sha256:";
    const index = std.mem.lastIndexOf(u8, image, marker) orelse return false;
    if (index == 0 or image.len != index + marker.len + 64) return false;
    for (image[index + marker.len ..]) |character| if (!std.ascii.isHex(character)) return false;
    return true;
}
