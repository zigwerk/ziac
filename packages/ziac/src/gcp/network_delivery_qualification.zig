const std = @import("std");
const cost = @import("../cost.zig");
const intelligence = @import("intelligence.zig");
const plan = @import("../plan.zig");
const resource = @import("../resource.zig");
const visual_artifact = @import("../visual_artifact.zig");

pub const schema = "ziac.gcp.network-delivery-qualification.v1";

pub const Evidence = struct {
    created: usize,
    imported: usize,
    no_op: usize,
    retained: usize,
    deleted: usize,
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

const Status = enum { passed };

const Receipt = struct {
    schema: []const u8 = schema,
    status: Status = .passed,
    authenticated: bool = false,
    graph_digest: []const u8,
    visual_artifact_digest: []const u8,
    resource_count: usize,
    dependency_count: usize,
    deployer_permission_count: usize,
    evidence: Evidence,
    cost_origin: cost.Origin = .configuration_estimate,
    limitations: []const []const u8 = &.{
        "not_authenticated",
        "private_connectivity_not_probed",
        "backend_health_not_observed",
        "costs_are_configuration_estimates",
    },
};

pub fn serializeLocalAlloc(allocator: std.mem.Allocator, graph: *const resource.ResourceGraph, evidence: Evidence) !SerializedReceipt {
    try graph.validateAcyclic();
    const resource_count = graph.resources.items.len;
    var retained_count: usize = 0;
    for (graph.resources.items) |node| retained_count += @intFromBool(node.lifecycle.retain_on_delete);
    if (evidence.created != resource_count or evidence.imported != resource_count or
        evidence.no_op != resource_count or evidence.retained != retained_count or
        evidence.deleted != resource_count - retained_count) return error.InvalidQualificationEvidence;

    const graph_digest = try plan.desiredGraphDigestAlloc(allocator, graph);
    const graph_hex = std.fmt.bytesToHex(graph_digest, .lower);
    var artifact = try visual_artifact.serializeAlloc(allocator, graph, null, .{
        .stack = "network-delivery",
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
        .resource_count = resource_count,
        .dependency_count = graph.dependencies.items.len,
        .deployer_permission_count = permission_plan.deployer_permissions.len,
        .evidence = evidence,
    }, .{});
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return .{ .allocator = allocator, .bytes = bytes, .digest = digest };
}
