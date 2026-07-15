const std = @import("std");
const cost = @import("../cost.zig");
const discovery_contract = @import("discovery_contract.zig");
const intelligence = @import("intelligence.zig");
const plan = @import("../plan.zig");
const resource = @import("../resource.zig");
const visual_artifact = @import("../visual_artifact.zig");

pub const schema = "ziac.gcp.vertex-ai-qualification.v1";

pub const Evidence = struct {
    created: usize,
    imported: usize,
    no_op: usize,
    retained: usize,
    resumable_operations: usize,
    hardened_resource_types: usize,
    supported_asset_identities: usize,
    governed_action_boundaries: usize,
    high_level_components: usize,
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
    provider_contract_id: []const u8,
    provider_contract_revision: []const u8,
    provider_contract_sha256: []const u8,
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
        "authenticated_vertex_ai_mutation_not_exercised",
        "online_prediction_not_exercised",
        "vector_query_not_exercised",
        "feature_sync_not_exercised",
        "pipeline_execution_not_exercised",
        "billing_usage_not_observed",
    },
};

pub fn serializeLocalAlloc(allocator: std.mem.Allocator, graph: *const resource.ResourceGraph, evidence: Evidence) !SerializedReceipt {
    try graph.validateAcyclic();
    var retained: usize = 0;
    var base_resources: usize = 0;
    var iam_resources: usize = 0;
    var model_count: usize = 0;
    var endpoint_count: usize = 0;
    var index_count: usize = 0;
    var index_endpoint_count: usize = 0;
    var group_count: usize = 0;
    var feature_count: usize = 0;
    var store_count: usize = 0;
    var view_count: usize = 0;
    for (graph.resources.items) |node| {
        if (node.lifecycle.retain_on_delete) retained += 1;
        if (!std.mem.startsWith(u8, node.type_name, "gcp.vertex.")) continue;
        if (std.mem.indexOf(u8, node.type_name, "IamMember") != null) {
            iam_resources += 1;
            continue;
        }
        base_resources += 1;
        if (std.mem.eql(u8, node.type_name, "gcp.vertex.Model")) model_count += 1;
        if (std.mem.eql(u8, node.type_name, "gcp.vertex.Endpoint")) endpoint_count += 1;
        if (std.mem.eql(u8, node.type_name, "gcp.vertex.Index")) index_count += 1;
        if (std.mem.eql(u8, node.type_name, "gcp.vertex.IndexEndpoint")) index_endpoint_count += 1;
        if (std.mem.eql(u8, node.type_name, "gcp.vertex.FeatureGroup")) group_count += 1;
        if (std.mem.eql(u8, node.type_name, "gcp.vertex.Feature")) feature_count += 1;
        if (std.mem.eql(u8, node.type_name, "gcp.vertex.FeatureOnlineStore")) store_count += 1;
        if (std.mem.eql(u8, node.type_name, "gcp.vertex.FeatureView")) view_count += 1;
    }
    if (model_count != 1 or endpoint_count != 1 or index_count != 1 or index_endpoint_count != 1 or
        group_count != 1 or feature_count == 0 or store_count != 1 or view_count != 1 or iam_resources < 2 or
        evidence.created != graph.resources.items.len or evidence.imported != graph.resources.items.len or
        evidence.no_op != graph.resources.items.len or evidence.retained != retained or
        evidence.resumable_operations != base_resources or evidence.hardened_resource_types != 16 or
        evidence.supported_asset_identities != 9 or
        evidence.governed_action_boundaries != intelligence.vertexAiActionUsages().len or
        evidence.high_level_components != 3 or evidence.estimates_requiring_usage != base_resources)
        return error.InvalidQualificationEvidence;

    const contract = vertexContract();
    const graph_digest = try plan.desiredGraphDigestAlloc(allocator, graph);
    const graph_hex = std.fmt.bytesToHex(graph_digest, .lower);
    var artifact = try visual_artifact.serializeAlloc(allocator, graph, null, .{
        .stack = "vertex-ai",
        .stage = "local-qualification",
        .created_at_millis = 0,
    });
    defer artifact.deinit();
    const artifact_hex = std.fmt.bytesToHex(artifact.digest, .lower);
    var permission_plan = try intelligence.synthesizePermissionPlan(allocator, graph);
    defer permission_plan.deinit(allocator);
    if (permission_plan.deployer_permissions.len == 0 or permission_plan.runtime_permissions.len < 2)
        return error.InvalidQualificationEvidence;

    const bytes = try std.json.Stringify.valueAlloc(allocator, Receipt{
        .provider_contract_id = contract.id,
        .provider_contract_revision = contract.revision,
        .provider_contract_sha256 = contract.document_sha256,
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

fn vertexContract() discovery_contract.Source {
    for (discovery_contract.sources) |source| {
        if (std.mem.eql(u8, source.id, "aiplatform:v1")) return source;
    }
    unreachable;
}
