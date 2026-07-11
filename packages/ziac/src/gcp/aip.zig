const std = @import("std");
const proto = @import("proto_contract.zig");

pub const FieldBehavior = proto.Behavior;

pub const FieldChange = struct {
    path: []const u8,
    behavior: FieldBehavior,
    changed: bool,
};

pub const ChangeKind = enum { noop, update, replace };

pub const ChangePlan = struct {
    kind: ChangeKind,
    update_mask: []const u8,
    replacement_fields: []const []const u8,
    ignored_output_fields: []const []const u8,

    pub fn deinit(self: *ChangePlan, allocator: std.mem.Allocator) void {
        allocator.free(self.update_mask);
        freeStrings(allocator, self.replacement_fields);
        freeStrings(allocator, self.ignored_output_fields);
        self.* = undefined;
    }
};

pub fn planChanges(allocator: std.mem.Allocator, changes: []const FieldChange) std.mem.Allocator.Error!ChangePlan {
    var updates: std.ArrayList([]const u8) = .empty;
    defer updates.deinit(allocator);
    var replacements: std.ArrayList([]const u8) = .empty;
    errdefer deinitStringList(allocator, &replacements);
    var ignored: std.ArrayList([]const u8) = .empty;
    errdefer deinitStringList(allocator, &ignored);

    for (changes) |change| {
        if (!change.changed) continue;
        switch (change.behavior) {
            .output_only => try ignored.append(allocator, try allocator.dupe(u8, change.path)),
            .immutable, .identifier => try replacements.append(allocator, try allocator.dupe(u8, change.path)),
            else => try updates.append(allocator, change.path),
        }
    }
    std.mem.sort([]const u8, updates.items, {}, stringLessThan);
    const update_mask = try joinMaskAlloc(allocator, updates.items);
    errdefer allocator.free(update_mask);
    const replacement_slice = try replacements.toOwnedSlice(allocator);
    errdefer freeStrings(allocator, replacement_slice);
    const ignored_slice = try ignored.toOwnedSlice(allocator);
    return .{
        .kind = if (replacement_slice.len > 0) .replace else if (updates.items.len > 0) .update else .noop,
        .update_mask = update_mask,
        .replacement_fields = replacement_slice,
        .ignored_output_fields = ignored_slice,
    };
}

pub fn requestId(stack: []const u8, resource_id: []const u8, operation: []const u8, output: *[36]u8) void {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(stack);
    hasher.update(&.{0});
    hasher.update(resource_id);
    hasher.update(&.{0});
    hasher.update(operation);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    digest[6] = (digest[6] & 0x0f) | 0x40;
    digest[8] = (digest[8] & 0x3f) | 0x80;
    _ = std.fmt.bufPrint(output, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        digest[0],  digest[1],  digest[2],  digest[3],
        digest[4],  digest[5],  digest[6],  digest[7],
        digest[8],  digest[9],  digest[10], digest[11],
        digest[12], digest[13], digest[14], digest[15],
    }) catch unreachable;
}

pub const ListState = struct {
    next_page_token: []const u8 = "",
    @"unreachable": []const []const u8 = &.{},
};

pub fn requireCompleteList(state: ListState) error{PartialDiscovery}!void {
    if (state.next_page_token.len != 0 or state.@"unreachable".len != 0) return error.PartialDiscovery;
}

pub const ServiceObservation = struct {
    generation: i64,
    observed_generation: i64,
    reconciling: bool,
    terminal_state: []const u8,
    latest_created_revision: []const u8,
    latest_ready_revision: []const u8,
};

pub const Readiness = enum { reconciling, ready };

pub fn serviceReadiness(observation: ServiceObservation) error{ReconciliationFailed}!Readiness {
    if (std.mem.eql(u8, observation.terminal_state, "CONDITION_FAILED")) return error.ReconciliationFailed;
    if (observation.reconciling or observation.observed_generation < observation.generation) return .reconciling;
    if (!std.mem.eql(u8, observation.terminal_state, "CONDITION_SUCCEEDED")) return .reconciling;
    if (!std.mem.eql(u8, observation.latest_created_revision, observation.latest_ready_revision)) return .reconciling;
    return .ready;
}

pub const CauseKind = enum {
    invalid_argument,
    unauthenticated,
    permission_denied,
    not_found,
    conflict,
    quota_exhausted,
    precondition_failed,
    unavailable,
    deadline_exceeded,
    remote_failure,
};

pub const Cause = struct {
    code: i64,
    kind: CauseKind,
    message: []const u8,
    detail_type: ?[]const u8,

    pub fn deinit(self: Cause, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        if (self.detail_type) |detail| allocator.free(detail);
    }
};

pub fn parseStatusJson(allocator: std.mem.Allocator, json: []const u8) (std.mem.Allocator.Error || error{InvalidStatus})!Cause {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return error.InvalidStatus;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidStatus,
    };
    const code = switch (root.get("code") orelse return error.InvalidStatus) {
        .integer => |value| value,
        else => return error.InvalidStatus,
    };
    const message = switch (root.get("message") orelse return error.InvalidStatus) {
        .string => |value| value,
        else => return error.InvalidStatus,
    };
    var detail_type: ?[]const u8 = null;
    if (root.get("details")) |details_value| switch (details_value) {
        .array => |details| if (details.items.len > 0) switch (details.items[0]) {
            .object => |detail| if (detail.get("@type")) |type_value| switch (type_value) {
                .string => |qualified| {
                    const prefix = "type.googleapis.com/";
                    const short = if (std.mem.startsWith(u8, qualified, prefix)) qualified[prefix.len..] else qualified;
                    detail_type = try allocator.dupe(u8, short);
                },
                else => {},
            },
            else => {},
        },
        else => {},
    };
    errdefer if (detail_type) |detail| allocator.free(detail);
    return .{
        .code = code,
        .kind = causeKind(code, detail_type),
        .message = try allocator.dupe(u8, message),
        .detail_type = detail_type,
    };
}

fn causeKind(code: i64, detail_type: ?[]const u8) CauseKind {
    if (detail_type) |detail| {
        if (std.mem.eql(u8, detail, "google.rpc.QuotaFailure")) return .quota_exhausted;
        if (std.mem.eql(u8, detail, "google.rpc.PreconditionFailure")) return .precondition_failed;
    }
    return switch (code) {
        3 => .invalid_argument,
        4 => .deadline_exceeded,
        5 => .not_found,
        6, 10 => .conflict,
        7 => .permission_denied,
        8 => .quota_exhausted,
        9 => .precondition_failed,
        14 => .unavailable,
        16 => .unauthenticated,
        else => .remote_failure,
    };
}

fn joinMaskAlloc(allocator: std.mem.Allocator, fields: []const []const u8) std.mem.Allocator.Error![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    for (fields, 0..) |field, index| {
        if (index > 0) try bytes.append(allocator, ',');
        try bytes.appendSlice(allocator, field);
    }
    return bytes.toOwnedSlice(allocator);
}

fn stringLessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn deinitStringList(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |string| allocator.free(string);
    list.deinit(allocator);
}

fn freeStrings(allocator: std.mem.Allocator, strings: []const []const u8) void {
    for (strings) |string| allocator.free(string);
    allocator.free(strings);
}
