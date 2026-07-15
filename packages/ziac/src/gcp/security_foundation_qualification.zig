const std = @import("std");
const cost = @import("../cost.zig");
const intelligence = @import("intelligence.zig");
const plan = @import("../plan.zig");
const resource = @import("../resource.zig");
const visual_artifact = @import("../visual_artifact.zig");

pub const schema = "ziac.gcp.security-foundation-qualification.v1";

pub const Evidence = struct {
    created: usize,
    imported: usize,
    no_op: usize,
    retained: usize,
    resumable_operations: usize,
    finding_routes: usize,
    admission_policies: usize,
    private_trust_resources: usize,
    governed_action_boundaries: usize,
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
    runtime_permission_count: usize,
    evidence: Evidence,
    cost_origin: cost.Origin = .configuration_estimate,
    estimated_management_cost_micros: ?i64 = null,
    limitations: []const []const u8 = &.{
        "not_authenticated",
        "authenticated_security_mutation_not_exercised",
        "certificate_authority_state_transition_not_exercised",
        "certificate_revocation_not_exercised",
        "security_command_center_tier_not_queried",
        "private_ca_usage_and_billing_not_observed",
    },
};

pub fn serializeLocalAlloc(allocator: std.mem.Allocator, graph: *const resource.ResourceGraph, evidence: Evidence) !SerializedReceipt {
    try graph.validateAcyclic();
    var retained: usize = 0;
    var resumable: usize = 0;
    var finding_routes: usize = 0;
    var admission_policies: usize = 0;
    var private_trust: usize = 0;
    var governed_actions: usize = 0;
    for (graph.resources.items) |node| {
        if (node.lifecycle.retain_on_delete) retained += 1;
        if (isResumableType(node.type_name)) resumable += 1;
        if (std.mem.eql(u8, node.type_name, "gcp.securitycenter.NotificationConfig") or
            std.mem.eql(u8, node.type_name, "gcp.securitycenter.BigQueryExport")) finding_routes += 1;
        if (std.mem.eql(u8, node.type_name, "gcp.binaryauthorization.Policy")) admission_policies += 1;
        if (std.mem.startsWith(u8, node.type_name, "gcp.privateca.")) private_trust += 1;
        if (std.mem.eql(u8, node.type_name, "gcp.privateca.CertificateAuthority") or
            std.mem.eql(u8, node.type_name, "gcp.privateca.Certificate")) governed_actions += 1;
    }
    if (evidence.created != graph.resources.items.len or evidence.imported != graph.resources.items.len or
        evidence.no_op != graph.resources.items.len or evidence.retained != retained or
        evidence.resumable_operations != resumable or evidence.finding_routes != finding_routes or
        evidence.admission_policies != admission_policies or evidence.private_trust_resources != private_trust or
        evidence.governed_action_boundaries != governed_actions or finding_routes == 0 or
        admission_policies == 0 or private_trust == 0 or governed_actions == 0)
        return error.InvalidQualificationEvidence;

    const graph_digest = try plan.desiredGraphDigestAlloc(allocator, graph);
    const graph_hex = std.fmt.bytesToHex(graph_digest, .lower);
    var artifact = try visual_artifact.serializeAlloc(allocator, graph, null, .{
        .stack = "security-foundation",
        .stage = "local-qualification",
        .created_at_millis = 0,
    });
    defer artifact.deinit();
    const artifact_hex = std.fmt.bytesToHex(artifact.digest, .lower);
    var permission_plan = try intelligence.synthesizePermissionPlan(allocator, graph);
    defer permission_plan.deinit(allocator);
    if (permission_plan.deployer_permissions.len == 0 or permission_plan.runtime_permissions.len == 0)
        return error.InvalidQualificationEvidence;

    const bytes = try std.json.Stringify.valueAlloc(allocator, Receipt{
        .graph_digest = graph_hex[0..],
        .visual_artifact_digest = artifact_hex[0..],
        .resource_count = graph.resources.items.len,
        .dependency_count = graph.dependencies.items.len,
        .deployer_permission_count = permission_plan.deployer_permissions.len,
        .runtime_permission_count = permission_plan.runtime_permissions.len,
        .evidence = evidence,
    }, .{});
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return .{ .allocator = allocator, .bytes = bytes, .digest = digest };
}

fn isResumableType(type_name: []const u8) bool {
    return std.mem.eql(u8, type_name, "gcp.privateca.CaPool") or
        std.mem.eql(u8, type_name, "gcp.privateca.CertificateAuthority") or
        std.mem.eql(u8, type_name, "gcp.privateca.CertificateTemplate");
}
