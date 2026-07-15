const std = @import("std");
const cost = @import("../cost.zig");
const intelligence = @import("intelligence.zig");
const plan = @import("../plan.zig");
const resource = @import("../resource.zig");
const visual_artifact = @import("../visual_artifact.zig");

pub const schema = "ziac.gcp.data-engineering-qualification.v1";

pub const Evidence = struct {
    created: usize,
    imported: usize,
    no_op: usize,
    retained: usize,
    resumable_operations: usize,
    supported_asset_identities: usize,
    governed_action_boundaries: usize,
    runtime_estimates_requiring_usage: usize,
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
    runtime_cost_origin: cost.Origin = .configuration_estimate,
    runtime_cost_confidence: cost.Confidence = .unavailable,
    estimated_runtime_cost_micros: ?i64 = null,
    dataform_service_cost_micros: i64 = 0,
    limitations: []const []const u8 = &.{
        "not_authenticated",
        "authenticated_data_engineering_mutation_not_exercised",
        "dataflow_job_execution_not_exercised",
        "dataproc_cluster_runtime_not_exercised",
        "dataform_workflow_invocation_not_exercised",
        "billing_usage_not_observed",
    },
};

pub fn serializeLocalAlloc(allocator: std.mem.Allocator, graph: *const resource.ResourceGraph, evidence: Evidence) !SerializedReceipt {
    try graph.validateAcyclic();
    var retained: usize = 0;
    var pipelines: usize = 0;
    var dataproc_clusters: usize = 0;
    var dataproc_policies: usize = 0;
    var dataproc_workflows: usize = 0;
    var dataform_repositories: usize = 0;
    var dataform_workspaces: usize = 0;
    var dataform_releases: usize = 0;
    var dataform_workflows: usize = 0;
    for (graph.resources.items) |node| {
        if (node.lifecycle.retain_on_delete) retained += 1;
        if (std.mem.eql(u8, node.type_name, "gcp.datapipelines.Pipeline")) pipelines += 1;
        if (std.mem.eql(u8, node.type_name, "gcp.dataproc.Cluster")) dataproc_clusters += 1;
        if (std.mem.eql(u8, node.type_name, "gcp.dataproc.AutoscalingPolicy")) dataproc_policies += 1;
        if (std.mem.eql(u8, node.type_name, "gcp.dataproc.WorkflowTemplate")) dataproc_workflows += 1;
        if (std.mem.eql(u8, node.type_name, "gcp.dataform.Repository")) dataform_repositories += 1;
        if (std.mem.eql(u8, node.type_name, "gcp.dataform.Workspace")) dataform_workspaces += 1;
        if (std.mem.eql(u8, node.type_name, "gcp.dataform.ReleaseConfig")) dataform_releases += 1;
        if (std.mem.eql(u8, node.type_name, "gcp.dataform.WorkflowConfig")) dataform_workflows += 1;
    }
    const runtime_estimates = pipelines + dataproc_clusters + dataproc_policies + dataproc_workflows;
    const action_count = intelligence.dataEngineeringActionUsages().len;
    if (evidence.created != graph.resources.items.len or evidence.imported != graph.resources.items.len or
        evidence.no_op != graph.resources.items.len or evidence.retained != retained or
        evidence.resumable_operations != dataproc_clusters or evidence.supported_asset_identities != 7 or
        evidence.governed_action_boundaries != action_count or evidence.runtime_estimates_requiring_usage != runtime_estimates or
        pipelines != 1 or dataproc_clusters != 1 or dataproc_policies != 1 or dataproc_workflows != 1 or
        dataform_repositories != 1 or dataform_workspaces != 1 or dataform_releases != 1 or dataform_workflows != 1)
        return error.InvalidQualificationEvidence;

    const graph_digest = try plan.desiredGraphDigestAlloc(allocator, graph);
    const graph_hex = std.fmt.bytesToHex(graph_digest, .lower);
    var artifact = try visual_artifact.serializeAlloc(allocator, graph, null, .{
        .stack = "data-engineering",
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
