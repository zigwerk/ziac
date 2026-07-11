const std = @import("std");
const scenario = @import("scenario.zig");

pub const Evidence = struct {
    request_event_id: []const u8,
    revision: []const u8,
    deployment_digest: []const u8,
    env_field: []const u8,
    binding_resource: []const u8,
    secret_version: []const u8,
    runtime_identity: []const u8,
    required_permission: []const u8,
    granted_permissions: []const []const u8,
    network_path: []const u8,
    cockroach_locality: []const u8,
    provider_event_id: []const u8,
    secret_binding_ready: bool = false,
    database_ready: bool = false,
};

pub const RootCause = enum {
    missing_runtime_iam,
    secret_binding_not_ready,
    network_path_unhealthy,
    database_unavailable,
    none,
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    root_cause: RootCause,
    json: []const u8,

    pub fn deinit(self: *Result) void {
        self.allocator.free(self.json);
        self.* = undefined;
    }
};

pub fn analyzeAlloc(allocator: std.mem.Allocator, evidence: Evidence) !Result {
    try validate(evidence);
    const root_cause: RootCause = if (!contains(evidence.granted_permissions, evidence.required_permission))
        .missing_runtime_iam
    else if (!evidence.secret_binding_ready)
        .secret_binding_not_ready
    else if (!std.mem.eql(u8, evidence.network_path, "healthy"))
        .network_path_unhealthy
    else if (!evidence.database_ready)
        .database_unavailable
    else
        .none;
    const json = std.json.Stringify.valueAlloc(allocator, .{
        .schema = "ziac.diagnosis.v1",
        .root_cause = root_cause,
        .chain = .{
            .request_event_id = evidence.request_event_id,
            .revision = evidence.revision,
            .deployment_digest = evidence.deployment_digest,
            .env_field = evidence.env_field,
            .binding_resource = evidence.binding_resource,
            .secret_version = evidence.secret_version,
            .runtime_identity = evidence.runtime_identity,
            .required_permission = evidence.required_permission,
            .network_path = evidence.network_path,
            .cockroach_locality = evidence.cockroach_locality,
            .provider_event_id = evidence.provider_event_id,
        },
        .complete = root_cause != .none,
    }, .{}) catch return error.OutOfMemory;
    return .{ .allocator = allocator, .root_cause = root_cause, .json = json };
}

pub fn proposeRepairAlloc(allocator: std.mem.Allocator, evidence: Evidence, result: Result) !scenario.Proposal {
    if (result.root_cause != .missing_runtime_iam) return error.NoIamRepairRequired;
    const operation = try std.fmt.allocPrint(
        allocator,
        "grant roles/secretmanager.secretAccessor to {s} for {s}",
        .{ evidence.runtime_identity, evidence.binding_resource },
    );
    defer allocator.free(operation);
    return scenario.proposalAlloc(allocator, .{
        .scenario_id = "cloud-run-cockroach-missing-iam",
        .requirement = "global-api-healthy",
        .resource_id = evidence.binding_resource,
        .finding_id = evidence.provider_event_id,
        .operation = operation,
        .verification = &.{"check-global-api"},
    });
}

pub const Verification = struct {
    schema: []const u8 = "ziac.diagnosis-verification.v1",
    permission_present: bool,
    binding_ready: bool,
    network_ready: bool,
    database_ready: bool,
    complete: bool,
    requirement_satisfied: bool,
};

pub fn verify(evidence: Evidence) Verification {
    const permission = contains(evidence.granted_permissions, evidence.required_permission);
    const network = std.mem.eql(u8, evidence.network_path, "healthy");
    const complete = permission and evidence.secret_binding_ready and network and evidence.database_ready;
    return .{
        .permission_present = permission,
        .binding_ready = evidence.secret_binding_ready,
        .network_ready = network,
        .database_ready = evidence.database_ready,
        .complete = complete,
        .requirement_satisfied = complete,
    };
}

fn validate(evidence: Evidence) !void {
    if (evidence.request_event_id.len == 0 or evidence.revision.len == 0 or evidence.deployment_digest.len == 0 or
        evidence.env_field.len == 0 or evidence.binding_resource.len == 0 or evidence.runtime_identity.len == 0 or
        evidence.required_permission.len == 0 or evidence.provider_event_id.len == 0) return error.IncompleteDiagnosisEvidence;
}

fn contains(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, expected)) return true;
    return false;
}
