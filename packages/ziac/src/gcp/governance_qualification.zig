const std = @import("std");
const cost = @import("../cost.zig");
const intelligence = @import("intelligence.zig");
const plan = @import("../plan.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");
const visual_artifact = @import("../visual_artifact.zig");

pub const schema = "ziac.gcp.governance-boundary-qualification.v1";

pub const Evidence = struct {
    created: usize,
    imported: usize,
    no_op: usize,
    retained: usize,
    resumable_operations: usize,
    list_discoveries: usize,
    enforced_resources: usize,
    dry_run_resources: usize,
};

pub const SerializedReceipt = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    digest: [32]u8,

    pub fn deinit(self: *SerializedReceipt) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

const Receipt = struct {
    schema: []const u8 = schema,
    status: enum { passed } = .passed,
    authenticated: bool = false,
    graph_digest: []const u8,
    visual_artifact_digest: []const u8,
    resource_count: usize,
    dependency_count: usize,
    deployer_permission_count: usize,
    evidence: Evidence,
    cost_origin: cost.Origin = .configuration_estimate,
    estimated_management_cost_micros: i64 = 0,
    limitations: []const []const u8 = &.{
        "not_authenticated",
        "destructive_governance_actions_not_exercised",
        "organization_scope_not_mutated",
        "vpc_service_controls_enforcement_not_probed",
        "billing_and_workload_costs_excluded",
    },
};

pub fn serializeLocalAlloc(allocator: std.mem.Allocator, graph: *const resource.ResourceGraph, evidence: Evidence) !SerializedReceipt {
    try graph.validateAcyclic();
    var retained: usize = 0;
    var resumable: usize = 0;
    var list_discoveries: usize = 0;
    var enforced: usize = 0;
    var dry_run: usize = 0;
    for (graph.resources.items) |node| {
        if (node.lifecycle.retain_on_delete) retained += 1;
        if (isResumableGovernanceType(node.type_name)) resumable += 1;
        if (std.mem.eql(u8, node.type_name, "gcp.tags.TagBinding") or std.mem.eql(u8, node.type_name, "gcp.tags.TagHold")) list_discoveries += 1;
        if (std.mem.eql(u8, node.type_name, "gcp.orgpolicy.Policy") or std.mem.eql(u8, node.type_name, "gcp.accesscontextmanager.ServicePerimeter") or
            (std.mem.eql(u8, node.type_name, "gcp.accesscontextmanager.GcpUserAccessBinding") and hasNonEmptyInput(node.inputs, "access_level"))) enforced += 1;
        if ((std.mem.eql(u8, node.type_name, "gcp.orgpolicy.Policy") and booleanInput(node.inputs, "has_dry_run_spec")) or
            (std.mem.eql(u8, node.type_name, "gcp.accesscontextmanager.ServicePerimeter") and booleanInput(node.inputs, "has_dry_run")) or
            (std.mem.eql(u8, node.type_name, "gcp.accesscontextmanager.GcpUserAccessBinding") and hasNonEmptyInput(node.inputs, "dry_run_access_level"))) dry_run += 1;
    }
    if (evidence.created != graph.resources.items.len or evidence.imported != graph.resources.items.len or
        evidence.no_op != graph.resources.items.len or evidence.retained != retained or
        evidence.resumable_operations != resumable or evidence.list_discoveries != list_discoveries or
        evidence.enforced_resources != enforced or evidence.dry_run_resources != dry_run or
        enforced == 0 or dry_run == 0) return error.InvalidQualificationEvidence;

    const graph_digest = try plan.desiredGraphDigestAlloc(allocator, graph);
    const graph_hex = std.fmt.bytesToHex(graph_digest, .lower);
    var artifact = try visual_artifact.serializeAlloc(allocator, graph, null, .{
        .stack = "governance-boundary",
        .stage = "local-qualification",
        .created_at_millis = 0,
    });
    defer artifact.deinit();
    const artifact_hex = std.fmt.bytesToHex(artifact.digest, .lower);
    var permission_plan = try intelligence.synthesizePermissionPlan(allocator, graph);
    defer permission_plan.deinit(allocator);
    const bytes = try std.json.Stringify.valueAlloc(allocator, Receipt{
        .graph_digest = graph_hex[0..],
        .visual_artifact_digest = artifact_hex[0..],
        .resource_count = graph.resources.items.len,
        .dependency_count = graph.dependencies.items.len,
        .deployer_permission_count = permission_plan.deployer_permissions.len,
        .evidence = evidence,
    }, .{});
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return .{ .allocator = allocator, .bytes = bytes, .digest = digest };
}

fn isResumableGovernanceType(type_name: []const u8) bool {
    return std.mem.startsWith(u8, type_name, "gcp.tags.") or
        std.mem.startsWith(u8, type_name, "gcp.accesscontextmanager.");
}

fn objectField(selected: value.Value, name: []const u8) ?value.Value {
    if (selected != .object) return null;
    for (selected.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return null;
}

fn booleanInput(inputs: value.Value, name: []const u8) bool {
    const selected = objectField(inputs, name) orelse return false;
    return selected == .boolean and selected.boolean;
}

fn hasNonEmptyInput(inputs: value.Value, name: []const u8) bool {
    const selected = objectField(inputs, name) orelse return false;
    return switch (selected) {
        .string => |inner| inner.len != 0,
        .output_ref => true,
        else => false,
    };
}
