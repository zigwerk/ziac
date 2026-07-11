const std = @import("std");

pub const Kind = enum {
    region_loss,
    quota_exhausted,
    iam_denied,
    stale_etag,
    interrupted_apply,
    lro_stalled,
    cockroach_gateway_loss,
    secret_rotation,
    reload_failed,
    rollback_failed,
    ttl_cleanup,
};

const all_kinds = [_]Kind{
    .region_loss,
    .quota_exhausted,
    .iam_denied,
    .stale_etag,
    .interrupted_apply,
    .lro_stalled,
    .cockroach_gateway_loss,
    .secret_rotation,
    .reload_failed,
    .rollback_failed,
    .ttl_cleanup,
};

pub fn catalog() []const Kind {
    return &all_kinds;
}

pub const Definition = struct {
    id: []const u8,
    kind: Kind,
    seed: u64,
    max_steps: usize,
    target_resource: []const u8,
    requirement: []const u8,
    acceptance_check: []const u8,
};

pub const FindingKind = enum {
    region_unavailable,
    quota_limit,
    missing_iam_permission,
    stale_precondition,
    resumable_operation,
    operation_timeout,
    database_gateway_unavailable,
    stale_secret_binding,
    unhealthy_generation,
    rollback_unavailable,
    expired_lease,
};

pub const Finding = struct {
    id: []const u8,
    kind: FindingKind,
    resource_id: []const u8,
    repair_hint: []const u8,
};

pub const Receipt = struct {
    allocator: std.mem.Allocator,
    replay_token: []const u8,
    findings: []const Finding,
    steps: usize,
    json: []const u8,

    pub fn deinit(self: *Receipt) void {
        self.allocator.free(self.replay_token);
        self.allocator.free(self.findings);
        self.allocator.free(self.json);
        self.* = undefined;
    }
};

pub fn runAlloc(allocator: std.mem.Allocator, definition: Definition) !Receipt {
    if (definition.id.len == 0 or definition.seed == 0 or definition.max_steps == 0 or definition.target_resource.len == 0) {
        return error.InvalidScenario;
    }
    const replay_token = try replayTokenAlloc(allocator, definition);
    errdefer allocator.free(replay_token);
    const findings = try allocator.alloc(Finding, 1);
    errdefer allocator.free(findings);
    findings[0] = findingFor(definition);
    const replay_command = try std.fmt.allocPrint(allocator, "ziac scenario replay --token {s} --json", .{replay_token});
    defer allocator.free(replay_command);
    const steps: usize = @min(definition.max_steps, 3);
    const json = std.json.Stringify.valueAlloc(allocator, .{
        .schema = "ziac.scenario-receipt.v1",
        .scenario = definition.id,
        .kind = definition.kind,
        .seed = definition.seed,
        .max_steps = definition.max_steps,
        .steps = steps,
        .target_resource = definition.target_resource,
        .requirement = definition.requirement,
        .acceptance_check = definition.acceptance_check,
        .replay_token = replay_token,
        .replay_command = replay_command,
        .findings = findings,
        .complete = true,
        .unsupported = false,
    }, .{}) catch return error.OutOfMemory;
    errdefer allocator.free(json);
    return .{
        .allocator = allocator,
        .replay_token = replay_token,
        .findings = findings,
        .steps = steps,
        .json = json,
    };
}

pub const ProposalInput = struct {
    scenario_id: []const u8,
    requirement: []const u8,
    resource_id: []const u8,
    finding_id: []const u8,
    operation: []const u8,
    verification: []const []const u8,
};

pub const Proposal = struct {
    allocator: std.mem.Allocator,
    digest: [64]u8,
    json: []const u8,

    pub fn deinit(self: *Proposal) void {
        self.allocator.free(self.json);
        self.* = undefined;
    }
};

pub fn proposalAlloc(allocator: std.mem.Allocator, input: ProposalInput) !Proposal {
    if (input.scenario_id.len == 0 or input.requirement.len == 0 or input.resource_id.len == 0 or
        input.finding_id.len == 0 or input.operation.len == 0 or input.verification.len == 0) return error.InvalidRepairProposal;
    const json = std.json.Stringify.valueAlloc(allocator, .{
        .schema = "ziac.repair-proposal.v1",
        .scenario = input.scenario_id,
        .requirement = input.requirement,
        .resource_id = input.resource_id,
        .finding_id = input.finding_id,
        .operation = input.operation,
        .verification = input.verification,
        .apply_authorized = false,
    }, .{}) catch return error.OutOfMemory;
    errdefer allocator.free(json);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(json, &hash, .{});
    return .{
        .allocator = allocator,
        .digest = std.fmt.bytesToHex(hash, .lower),
        .json = json,
    };
}

fn replayTokenAlloc(allocator: std.mem.Allocator, definition: Definition) std.mem.Allocator.Error![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("ziac-scenario-v1\x00");
    hasher.update(definition.id);
    hasher.update("\x00");
    hasher.update(@tagName(definition.kind));
    var integers: [24]u8 = undefined;
    std.mem.writeInt(u64, integers[0..8], definition.seed, .little);
    std.mem.writeInt(u64, integers[8..16], definition.max_steps, .little);
    std.mem.writeInt(u64, integers[16..24], definition.target_resource.len, .little);
    hasher.update(&integers);
    hasher.update(definition.target_resource);
    var hash: [32]u8 = undefined;
    hasher.final(&hash);
    const hex = std.fmt.bytesToHex(hash, .lower);
    return std.fmt.allocPrint(allocator, "v1-{s}", .{&hex});
}

fn findingFor(definition: Definition) Finding {
    const result: struct { id: []const u8, kind: FindingKind, hint: []const u8 } = switch (definition.kind) {
        .region_loss => .{ .id = "finding-region-loss", .kind = .region_unavailable, .hint = "route around the unavailable region and verify failover" },
        .quota_exhausted => .{ .id = "finding-quota", .kind = .quota_limit, .hint = "reduce the plan or request the exact quota increase" },
        .iam_denied => .{ .id = "finding-missing-iam", .kind = .missing_iam_permission, .hint = "grant the minimum permission to the declared runtime identity" },
        .stale_etag => .{ .id = "finding-stale-etag", .kind = .stale_precondition, .hint = "refresh observed state and replan against the current etag" },
        .interrupted_apply => .{ .id = "finding-interrupted-apply", .kind = .resumable_operation, .hint = "resume from the durable operation checkpoint" },
        .lro_stalled => .{ .id = "finding-lro-stalled", .kind = .operation_timeout, .hint = "inspect operation metadata before bounded retry" },
        .cockroach_gateway_loss => .{ .id = "finding-gateway-loss", .kind = .database_gateway_unavailable, .hint = "select a healthy locality-aware gateway" },
        .secret_rotation => .{ .id = "finding-secret-rotation", .kind = .stale_secret_binding, .hint = "roll a revision with the current secret version" },
        .reload_failed => .{ .id = "finding-reload", .kind = .unhealthy_generation, .hint = "retain the active generation and repair the candidate" },
        .rollback_failed => .{ .id = "finding-rollback", .kind = .rollback_unavailable, .hint = "restore the last verified immutable revision" },
        .ttl_cleanup => .{ .id = "finding-expired-lease", .kind = .expired_lease, .hint = "run idempotent cleanup with lease-scoped authority" },
    };
    return .{
        .id = result.id,
        .kind = result.kind,
        .resource_id = definition.target_resource,
        .repair_hint = result.hint,
    };
}
