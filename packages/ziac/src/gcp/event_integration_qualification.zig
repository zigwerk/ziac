const std = @import("std");
const cost = @import("../cost.zig");
const intelligence = @import("intelligence.zig");
const plan = @import("../plan.zig");
const resource = @import("../resource.zig");
const visual_artifact = @import("../visual_artifact.zig");

pub const schema = "ziac.gcp.event-integration-qualification.v1";
pub const Evidence = struct {
    created: usize,
    imported: usize,
    no_op: usize,
    retained: usize,
    resumable_operations: usize,
    supported_asset_identities: usize,
    governed_action_boundaries: usize,
    estimates_requiring_usage: usize,
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
    cost_confidence: cost.Confidence = .unavailable,
    estimated_cost_micros: ?i64 = null,
    limitations: []const []const u8 = &.{
        "not_authenticated",
        "authenticated_event_integration_mutation_not_exercised",
        "event_delivery_not_exercised",
        "connector_runtime_not_exercised",
        "billing_usage_not_observed",
    },
};

pub fn serializeLocalAlloc(allocator: std.mem.Allocator, graph: *const resource.ResourceGraph, evidence: Evidence) !SerializedReceipt {
    try graph.validateAcyclic();
    var retained: usize = 0;
    var resumable: usize = 0;
    var estimates: usize = 0;
    var eventarc_count: usize = 0;
    var connectors_count: usize = 0;
    for (graph.resources.items) |node| {
        if (node.lifecycle.retain_on_delete) retained += 1;
        if (isResumable(node.type_name)) resumable += 1;
        if (requiresUsage(node.type_name)) estimates += 1;
        if (std.mem.startsWith(u8, node.type_name, "gcp.eventarc.") and std.mem.indexOf(u8, node.type_name, "IamMember") == null) eventarc_count += 1;
        if (std.mem.startsWith(u8, node.type_name, "gcp.connectors.") and std.mem.indexOf(u8, node.type_name, "IamMember") == null) connectors_count += 1;
    }
    if (eventarc_count == 0 or connectors_count == 0 or
        evidence.created != graph.resources.items.len or evidence.imported != graph.resources.items.len or
        evidence.no_op != graph.resources.items.len or evidence.retained != retained or
        evidence.resumable_operations != resumable or evidence.supported_asset_identities != 9 or
        evidence.governed_action_boundaries != intelligence.eventIntegrationActionUsages().len or
        evidence.estimates_requiring_usage != estimates)
        return error.InvalidQualificationEvidence;
    const graph_digest = try plan.desiredGraphDigestAlloc(allocator, graph);
    const graph_hex = std.fmt.bytesToHex(graph_digest, .lower);
    var artifact = try visual_artifact.serializeAlloc(allocator, graph, null, .{ .stack = "event-integration", .stage = "local-qualification", .created_at_millis = 0 });
    defer artifact.deinit();
    const artifact_hex = std.fmt.bytesToHex(artifact.digest, .lower);
    var permissions = try intelligence.synthesizePermissionPlan(allocator, graph);
    defer permissions.deinit(allocator);
    if (permissions.deployer_permissions.len == 0 or permissions.runtime_permissions.len == 0) return error.InvalidQualificationEvidence;
    const bytes = try std.json.Stringify.valueAlloc(allocator, Receipt{
        .graph_digest = graph_hex[0..],
        .visual_artifact_digest = artifact_hex[0..],
        .resource_count = graph.resources.items.len,
        .dependency_count = graph.dependencies.items.len,
        .deployer_permission_count = permissions.deployer_permissions.len,
        .runtime_permission_count = permissions.runtime_permissions.len,
        .evidence = evidence,
    }, .{});
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return .{ .allocator = allocator, .bytes = bytes, .digest = digest };
}
fn isResumable(type_name: []const u8) bool {
    if (std.mem.indexOf(u8, type_name, "IamMember") != null) return false;
    return std.mem.startsWith(u8, type_name, "gcp.eventarc.") or std.mem.startsWith(u8, type_name, "gcp.connectors.");
}
fn requiresUsage(type_name: []const u8) bool {
    return std.mem.eql(u8, type_name, "gcp.eventarc.MessageBus") or
        std.mem.eql(u8, type_name, "gcp.eventarc.Pipeline") or
        std.mem.eql(u8, type_name, "gcp.eventarc.Enrollment") or
        std.mem.eql(u8, type_name, "gcp.eventarc.GoogleApiSource") or
        std.mem.eql(u8, type_name, "gcp.connectors.Connection") or
        std.mem.eql(u8, type_name, "gcp.connectors.EventSubscription");
}
