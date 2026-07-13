const std = @import("std");
const plan_mod = @import("plan.zig");
const resource = @import("resource.zig");
const value_mod = @import("value.zig");

pub const schema = "ziac.visual.v1";
pub const format_version: u32 = 1;

pub const Target = struct {
    stack: []const u8,
    stage: []const u8,
    created_at_millis: u64,
};

pub const SerializedArtifact = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    digest: [32]u8,

    pub fn deinit(self: *SerializedArtifact) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

const VisualResource = struct {
    node: resource.ResourceNode,
    operation: ?plan_mod.OperationKind,
    dependencies: []const []const u8,
    reasons: []const []const u8,
};

const VisualEdge = struct {
    from: []const u8,
    to: []const u8,
};

pub fn serializeAlloc(
    allocator: std.mem.Allocator,
    graph: *const resource.ResourceGraph,
    planned: ?*const plan_mod.Plan,
    target: Target,
) !SerializedArtifact {
    try validateTarget(target.stack);
    try validateTarget(target.stage);
    try graph.validateAcyclic();

    const resources = try visualResourcesAlloc(allocator, graph, planned);
    defer allocator.free(resources);
    const edges = try visualEdgesAlloc(allocator, graph, planned);
    defer allocator.free(edges);
    var regions = try usedRegionsAlloc(allocator, resources);
    defer regions.deinit(allocator);
    const graph_digest = if (planned) |present|
        present.preconditions.desired_graph_digest
    else
        try plan_mod.desiredGraphDigestAlloc(allocator, graph);
    const state_serial = if (planned) |present| present.preconditions.state_serial else 0;

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.append(allocator, '{');
    try appendNamedString(&output, allocator, "schema", schema, false);
    try appendNamedUnsigned(&output, allocator, "format_version", format_version, true);
    try appendNamedString(&output, allocator, "truth_mode", if (planned == null) "desired" else "plan", true);
    try appendNamedUnsigned(&output, allocator, "created_at_millis", target.created_at_millis, true);
    try appendNamedString(&output, allocator, "stack", target.stack, true);
    try appendNamedString(&output, allocator, "stage", target.stage, true);
    try appendNamedHash(&output, allocator, "graph_digest", graph_digest, true);
    try appendNamedUnsigned(&output, allocator, "state_serial", state_serial, true);
    try output.appendSlice(allocator, ",\"summary\":{");
    try appendNamedUnsigned(&output, allocator, "resources", resources.len, false);
    try appendNamedUnsigned(&output, allocator, "edges", edges.len, true);
    try appendNamedUnsigned(&output, allocator, "regions", regions.items.len, true);
    try output.append(allocator, '}');
    try output.appendSlice(allocator, ",\"regions\":");
    try appendStringArray(&output, allocator, regions.items);
    try output.appendSlice(allocator, ",\"resources\":[");
    for (resources, 0..) |item, index| {
        if (index != 0) try output.append(allocator, ',');
        try appendResource(&output, allocator, item, target.created_at_millis);
    }
    try output.appendSlice(allocator, "],\"edges\":[");
    for (edges, 0..) |edge, index| {
        if (index != 0) try output.append(allocator, ',');
        try appendEdge(&output, allocator, resources, edge);
    }
    try output.appendSlice(allocator, "],\"routes\":[");
    try appendGlobalRoutes(&output, allocator, resources);
    try output.appendSlice(allocator, "],\"observations\":[],\"diagnostics\":[]}");

    const bytes = try output.toOwnedSlice(allocator);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return .{ .allocator = allocator, .bytes = bytes, .digest = digest };
}

fn visualResourcesAlloc(
    allocator: std.mem.Allocator,
    graph: *const resource.ResourceGraph,
    planned: ?*const plan_mod.Plan,
) ![]VisualResource {
    if (planned) |present| {
        const items = try allocator.alloc(VisualResource, present.operations.len);
        for (present.operations, 0..) |operation, index| items[index] = .{
            .node = operation.resource,
            .operation = operation.kind,
            .dependencies = operation.dependencies,
            .reasons = operation.reasons,
        };
        std.mem.sort(VisualResource, items, {}, lessThanVisualResource);
        return items;
    }

    const items = try allocator.alloc(VisualResource, graph.resources.items.len);
    for (graph.resources.items, 0..) |node, index| items[index] = .{
        .node = node,
        .operation = null,
        .dependencies = &.{},
        .reasons = &.{},
    };
    std.mem.sort(VisualResource, items, {}, lessThanVisualResource);
    return items;
}

fn visualEdgesAlloc(
    allocator: std.mem.Allocator,
    graph: *const resource.ResourceGraph,
    planned: ?*const plan_mod.Plan,
) ![]VisualEdge {
    var edges = std.ArrayList(VisualEdge).empty;
    errdefer edges.deinit(allocator);
    if (planned) |present| {
        for (present.operations) |operation| for (operation.dependencies) |dependency| {
            try edges.append(allocator, .{ .from = operation.resource.id, .to = dependency });
        };
    } else {
        for (graph.dependencies.items) |edge| {
            try edges.append(allocator, .{ .from = edge.from, .to = edge.to });
        }
    }
    const owned = try edges.toOwnedSlice(allocator);
    std.mem.sort(VisualEdge, owned, {}, lessThanVisualEdge);
    return owned;
}

fn usedRegionsAlloc(allocator: std.mem.Allocator, resources: []const VisualResource) !std.ArrayList([]const u8) {
    var regions = std.ArrayList([]const u8).empty;
    errdefer regions.deinit(allocator);
    for (resources) |item| {
        var node_regions = std.ArrayList([]const u8).empty;
        defer node_regions.deinit(allocator);
        try appendNodeRegions(allocator, &node_regions, item.node);
        for (node_regions.items) |region| try appendUniqueString(allocator, &regions, region);
    }
    std.mem.sort([]const u8, regions.items, {}, lessThanString);
    return regions;
}

fn appendResource(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    item: VisualResource,
    observed_at_millis: u64,
) !void {
    var regions = std.ArrayList([]const u8).empty;
    defer regions.deinit(allocator);
    try appendNodeRegions(allocator, &regions, item.node);
    std.mem.sort([]const u8, regions.items, {}, lessThanString);
    const scope = resourceScope(item.node, regions.items);

    try output.append(allocator, '{');
    try appendNamedString(output, allocator, "id", item.node.id, false);
    try appendNamedString(output, allocator, "provider", @tagName(item.node.provider), true);
    try appendNamedString(output, allocator, "type", item.node.type_name, true);
    try appendNamedString(output, allocator, "logical_id", item.node.logical_id, true);
    try appendNamedString(output, allocator, "scope", scope, true);
    if (regions.items.len == 1) try appendNamedString(output, allocator, "region", regions.items[0], true);
    try output.appendSlice(allocator, ",\"regions\":");
    try appendStringArray(output, allocator, regions.items);
    try appendNamedString(output, allocator, "operation", if (item.operation) |kind| @tagName(kind) else "none", true);
    try appendNamedString(output, allocator, "health", "unknown", true);
    try appendStorageDetails(output, allocator, item.node);
    try appendPubsubDetails(output, allocator, item.node);
    try appendAsyncDeliveryDetails(output, allocator, item.node);
    try appendRunWorkloadDetails(output, allocator, item.node);
    try appendIamDetails(output, allocator, item.node);
    try appendConfigurationCost(output, allocator, observed_at_millis);
    try output.appendSlice(allocator, ",\"inputs\":");
    try appendSafeValue(output, allocator, item.node.inputs, null);
    try output.appendSlice(allocator, ",\"lifecycle\":{");
    try appendNamedBool(output, allocator, "protect", item.node.lifecycle.protect, false);
    try appendNamedBool(output, allocator, "retain_on_delete", item.node.lifecycle.retain_on_delete, true);
    try appendNamedBool(output, allocator, "replace_before_delete", item.node.lifecycle.replace_before_delete, true);
    try output.append(allocator, '}');
    try output.appendSlice(allocator, ",\"reasons\":");
    try appendStringArray(output, allocator, item.reasons);
    try output.append(allocator, '}');
}

fn appendConfigurationCost(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    observed_at_millis: u64,
) !void {
    try output.appendSlice(allocator, ",\"cost\":{");
    try appendNamedString(output, allocator, "schema", "ziac.resource-cost.v1", false);
    try appendNamedString(output, allocator, "origin", "configuration_estimate", true);
    try appendNamedString(output, allocator, "currency", "USD", true);
    try output.appendSlice(allocator, ",\"amount_micros\":null");
    try appendNamedString(output, allocator, "confidence", "explicit_usage", true);
    try appendNamedUnsigned(output, allocator, "observed_at_millis", observed_at_millis, true);
    try appendNamedBool(output, allocator, "is_billing_export", false, true);
    try output.append(allocator, '}');
}

fn appendEdge(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    resources: []const VisualResource,
    edge: VisualEdge,
) !void {
    const from_resource = findResource(resources, edge.from);
    const from_type = if (from_resource) |item| item.node.type_name else "unknown";
    const to_type = findResourceType(resources, edge.to) orelse "unknown";
    const kind = edgeKind(if (from_resource) |item| item.node else null, edge.to, from_type, to_type);
    const id = try std.fmt.allocPrint(allocator, "{s}->{s}", .{ edge.from, edge.to });
    defer allocator.free(id);
    try output.append(allocator, '{');
    try appendNamedString(output, allocator, "id", id, false);
    try appendNamedString(output, allocator, "from", edge.from, true);
    try appendNamedString(output, allocator, "to", edge.to, true);
    try appendNamedString(output, allocator, "kind", kind, true);
    if (std.mem.eql(u8, kind, "iam")) if (from_resource) |item| {
        if (objectString(item.node, "role")) |role| if (iamEdgeDetails(role)) |details| {
            try appendNamedString(output, allocator, "access", details.access, true);
            try output.appendSlice(allocator, ",\"permissions\":[");
            try appendJsonString(output, allocator, details.permission);
            try output.append(allocator, ']');
        };
    };
    try output.append(allocator, '}');
}

const IamEdgeDetails = struct {
    access: []const u8,
    permission: []const u8,
};

fn iamEdgeDetails(role: []const u8) ?IamEdgeDetails {
    const mappings = [_]struct { role: []const u8, access: []const u8, permission: []const u8 }{
        .{ .role = "roles/artifactregistry.reader", .access = "read", .permission = "artifactregistry.repositories.downloadArtifacts" },
        .{ .role = "roles/cloudtasks.enqueuer", .access = "write", .permission = "cloudtasks.tasks.create" },
        .{ .role = "roles/iam.workloadIdentityUser", .access = "invoke", .permission = "iam.serviceAccounts.getAccessToken" },
        .{ .role = "roles/pubsub.publisher", .access = "write", .permission = "pubsub.topics.publish" },
        .{ .role = "roles/pubsub.subscriber", .access = "read", .permission = "pubsub.subscriptions.consume" },
        .{ .role = "roles/run.invoker", .access = "invoke", .permission = "run.routes.invoke" },
        .{ .role = "roles/secretmanager.secretAccessor", .access = "read", .permission = "secretmanager.versions.access" },
        .{ .role = "roles/storage.objectUser", .access = "read_write", .permission = "storage.objects.create" },
        .{ .role = "roles/storage.objectViewer", .access = "read", .permission = "storage.objects.get" },
    };
    for (mappings) |mapping| if (std.mem.eql(u8, role, mapping.role)) return .{
        .access = mapping.access,
        .permission = mapping.permission,
    };
    return null;
}

fn appendGlobalRoutes(output: *std.ArrayList(u8), allocator: std.mem.Allocator, resources: []const VisualResource) !void {
    var front_door: ?[]const u8 = null;
    for (resources) |item| {
        if (std.mem.eql(u8, item.node.type_name, "gcp.compute.GlobalForwardingRule")) {
            front_door = item.node.id;
            const port = objectField(item.node.inputs, "port") orelse continue;
            if (port == .integer and port.integer == 443) break;
        }
    }
    const source = front_door orelse return;
    var wrote = false;
    for (resources) |item| {
        if (!std.mem.eql(u8, item.node.type_name, "gcp.run.Service")) continue;
        const region = directRegion(item.node) orelse continue;
        if (wrote) try output.append(allocator, ',');
        wrote = true;
        const id = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ source, region });
        defer allocator.free(id);
        try output.append(allocator, '{');
        try appendNamedString(output, allocator, "id", id, false);
        try appendNamedString(output, allocator, "from_resource", source, true);
        try appendNamedString(output, allocator, "to_resource", item.node.id, true);
        try appendNamedString(output, allocator, "to_region", region, true);
        try appendNamedString(output, allocator, "provenance", "inferred", true);
        try output.append(allocator, '}');
    }
}

fn appendNodeRegions(
    allocator: std.mem.Allocator,
    regions: *std.ArrayList([]const u8),
    node: resource.ResourceNode,
) !void {
    if (directRegion(node)) |region| try appendUniqueString(allocator, regions, region);
    if (objectField(node.inputs, "regions")) |region_value| if (region_value == .list) {
        for (region_value.list) |entry| switch (entry) {
            .string => |region| try appendUniqueString(allocator, regions, region),
            .object => |fields| if (objectFieldFromFields(fields, "name")) |name| {
                if (name == .string) try appendUniqueString(allocator, regions, name.string);
            },
            else => {},
        };
    };
    if (objectField(node.inputs, "allowed_persistence_regions")) |region_value| if (region_value == .list) {
        for (region_value.list) |entry| if (entry == .string) try appendUniqueString(allocator, regions, entry.string);
    };
}

fn directRegion(node: resource.ResourceNode) ?[]const u8 {
    if (objectField(node.inputs, "region")) |region| {
        if (region == .string) return region.string;
    }
    if (std.mem.eql(u8, node.type_name, "gcp.storage.Bucket") or
        std.mem.startsWith(u8, node.type_name, "gcp.tasks.") or
        std.mem.startsWith(u8, node.type_name, "gcp.eventarc."))
    {
        const location = objectField(node.inputs, "location") orelse return null;
        return if (location == .string) location.string else null;
    }
    return null;
}

fn appendStorageDetails(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
) !void {
    if (!std.mem.startsWith(u8, node.type_name, "gcp.storage.")) return;
    try output.appendSlice(allocator, ",\"storage\":{");
    if (std.mem.eql(u8, node.type_name, "gcp.storage.Bucket")) {
        try appendNamedString(output, allocator, "kind", "bucket", false);
        try appendOptionalStorageString(output, allocator, node, "location", "location");
        try appendOptionalStorageString(output, allocator, node, "storage_class", "storage_class");
        try appendOptionalStorageInteger(output, allocator, node, "retention_period_seconds", "retention_period_seconds");
        try appendOptionalStorageInteger(output, allocator, node, "soft_delete_retention_seconds", "soft_delete_retention_seconds");
        try appendOptionalStorageString(output, allocator, node, "public_access_prevention", "public_access_prevention");
        try appendOptionalStorageBool(output, allocator, node, "uniform_bucket_level_access", "uniform_bucket_level_access");
        try appendOptionalStorageBool(output, allocator, node, "versioning", "versioning");
        try appendStorageListCount(output, allocator, node, "lifecycle_rules", "lifecycle_rule_count");
        try appendStorageListCount(output, allocator, node, "cors", "cors_rule_count");
    } else if (std.mem.eql(u8, node.type_name, "gcp.storage.BucketIamMember")) {
        try appendNamedString(output, allocator, "kind", "iam_member", false);
        try appendOptionalStorageString(output, allocator, node, "role", "iam_role");
        try appendOptionalStorageString(output, allocator, node, "member", "iam_member");
        try appendOptionalStorageString(output, allocator, node, "condition_title", "iam_condition_title");
    } else {
        try appendNamedString(output, allocator, "kind", "object", false);
        try appendOptionalStorageString(output, allocator, node, "object_name", "object_name");
        try appendOptionalStorageString(output, allocator, node, "content_type", "content_type");
        try appendOptionalStorageInteger(output, allocator, node, "size", "size_bytes");
    }
    try output.append(allocator, '}');
}

fn appendPubsubDetails(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
) !void {
    if (!std.mem.startsWith(u8, node.type_name, "gcp.pubsub.")) return;
    try output.appendSlice(allocator, ",\"pubsub\":{");
    if (std.mem.eql(u8, node.type_name, "gcp.pubsub.Topic")) {
        try appendNamedString(output, allocator, "kind", "topic", false);
        try appendOptionalStorageInteger(output, allocator, node, "message_retention_seconds", "message_retention_seconds");
        try appendOptionalStorageString(output, allocator, node, "kms_key_name", "kms_key_name");
        try appendStorageListCount(output, allocator, node, "allowed_persistence_regions", "persistence_region_count");
    } else if (std.mem.eql(u8, node.type_name, "gcp.pubsub.Subscription")) {
        try appendNamedString(output, allocator, "kind", "subscription", false);
        try appendOptionalStorageString(output, allocator, node, "delivery_kind", "delivery_kind");
        try appendOptionalStorageInteger(output, allocator, node, "ack_deadline_seconds", "ack_deadline_seconds");
        try appendOptionalStorageInteger(output, allocator, node, "message_retention_seconds", "message_retention_seconds");
        try appendOptionalStorageInteger(output, allocator, node, "max_delivery_attempts", "max_delivery_attempts");
    } else if (std.mem.eql(u8, node.type_name, "gcp.pubsub.Schema")) {
        try appendNamedString(output, allocator, "kind", "schema", false);
        try appendOptionalStorageString(output, allocator, node, "schema_type", "schema_type");
    } else if (std.mem.eql(u8, node.type_name, "gcp.pubsub.Snapshot")) {
        try appendNamedString(output, allocator, "kind", "snapshot", false);
    } else {
        try appendNamedString(output, allocator, "kind", "iam_member", false);
        try appendOptionalStorageString(output, allocator, node, "role", "iam_role");
    }
    try output.append(allocator, '}');
}

fn appendAsyncDeliveryDetails(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
) !void {
    if (!std.mem.startsWith(u8, node.type_name, "gcp.tasks.") and
        !std.mem.startsWith(u8, node.type_name, "gcp.eventarc.")) return;
    try output.appendSlice(allocator, ",\"async_delivery\":{");
    if (std.mem.eql(u8, node.type_name, "gcp.tasks.Queue")) {
        try appendNamedString(output, allocator, "kind", "queue", false);
        try appendOptionalStorageString(output, allocator, node, "max_dispatches_per_second", "max_dispatches_per_second");
        try appendOptionalStorageInteger(output, allocator, node, "max_concurrent_dispatches", "max_concurrent_dispatches");
        try appendOptionalStorageInteger(output, allocator, node, "max_attempts", "max_attempts");
        try appendOptionalStorageString(output, allocator, node, "authorization_kind", "authorization_kind");
    } else if (std.mem.eql(u8, node.type_name, "gcp.tasks.QueueIamMember")) {
        try appendNamedString(output, allocator, "kind", "queue_iam_member", false);
        try appendOptionalStorageString(output, allocator, node, "role", "iam_role");
        try appendOptionalStorageString(output, allocator, node, "member", "iam_member");
    } else {
        try appendNamedString(output, allocator, "kind", "trigger", false);
        try appendStorageListCount(output, allocator, node, "event_filters", "event_filter_count");
        try appendOptionalStorageString(output, allocator, node, "destination_kind", "destination_kind");
        try appendOptionalStorageString(output, allocator, node, "channel", "channel");
    }
    try output.append(allocator, '}');
}

fn appendRunWorkloadDetails(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
) !void {
    if (!std.mem.eql(u8, node.type_name, "gcp.run.Job") and
        !std.mem.eql(u8, node.type_name, "gcp.run.JobIamMember") and
        !std.mem.eql(u8, node.type_name, "gcp.run.WorkerPool")) return;
    try output.appendSlice(allocator, ",\"run_workload\":{");
    if (std.mem.eql(u8, node.type_name, "gcp.run.Job")) {
        try appendNamedString(output, allocator, "kind", "job", false);
        try appendStorageListCount(output, allocator, node, "containers", "container_count");
        try appendOptionalStorageInteger(output, allocator, node, "task_count", "task_count");
        try appendOptionalStorageInteger(output, allocator, node, "parallelism", "parallelism");
        try appendOptionalStorageInteger(output, allocator, node, "max_retries", "max_retries");
        try appendOptionalStorageInteger(output, allocator, node, "timeout_seconds", "timeout_seconds");
        try appendOptionalStorageString(output, allocator, node, "service_account", "service_account");
    } else if (std.mem.eql(u8, node.type_name, "gcp.run.WorkerPool")) {
        try appendNamedString(output, allocator, "kind", "worker_pool", false);
        try appendStorageListCount(output, allocator, node, "containers", "container_count");
        try appendOptionalStorageInteger(output, allocator, node, "manual_instance_count", "manual_instance_count");
        try appendStorageListCount(output, allocator, node, "instance_splits", "instance_split_count");
        try appendOptionalStorageString(output, allocator, node, "service_account", "service_account");
    } else {
        try appendNamedString(output, allocator, "kind", "job_iam_member", false);
        try appendOptionalStorageString(output, allocator, node, "role", "iam_role");
        try appendOptionalStorageString(output, allocator, node, "member", "iam_member");
    }
    try output.append(allocator, '}');
}

fn appendIamDetails(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
) !void {
    const ownership_value = objectField(node.inputs, "ownership_mode") orelse return;
    if (ownership_value != .string) return;
    try output.appendSlice(allocator, ",\"iam\":{");
    try appendNamedString(output, allocator, "ownership", ownership_value.string, false);
    try appendOptionalStorageString(output, allocator, node, "resource_name", "target");
    try appendOptionalStorageString(output, allocator, node, "role", "role");
    try appendOptionalStorageString(output, allocator, node, "condition_title", "condition_title");
    try appendNamedUnsigned(output, allocator, "principal_count", try iamPrincipalCount(allocator, node), true);
    try output.append(allocator, '}');
}

fn iamPrincipalCount(allocator: std.mem.Allocator, node: resource.ResourceNode) !usize {
    const ownership = objectField(node.inputs, "ownership_mode") orelse return 0;
    if (ownership != .string) return 0;
    if (std.mem.eql(u8, ownership.string, "member")) return 1;
    if (std.mem.eql(u8, ownership.string, "binding")) {
        const members = objectField(node.inputs, "members") orelse return 0;
        return if (members == .list) members.list.len else 0;
    }
    const bindings_json = objectField(node.inputs, "bindings_json") orelse return 0;
    if (bindings_json != .string) return 0;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bindings_json.string, .{}) catch return 0;
    defer parsed.deinit();
    const bindings = switch (parsed.value) {
        .array => |array| array.items,
        else => return 0,
    };
    var count: usize = 0;
    for (bindings) |binding_value| {
        const binding = switch (binding_value) {
            .object => |object| object,
            else => continue,
        };
        const members_value = binding.get("members") orelse continue;
        if (members_value == .array) count += members_value.array.items.len;
    }
    return count;
}

fn appendOptionalStorageString(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    input_name: []const u8,
    output_name: []const u8,
) !void {
    const input = objectField(node.inputs, input_name) orelse return;
    if (input == .string) try appendNamedString(output, allocator, output_name, input.string, true);
}

fn appendOptionalStorageInteger(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    input_name: []const u8,
    output_name: []const u8,
) !void {
    const input = objectField(node.inputs, input_name) orelse return;
    if (input == .integer) try appendNamedUnsigned(output, allocator, output_name, input.integer, true);
}

fn appendOptionalStorageBool(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    input_name: []const u8,
    output_name: []const u8,
) !void {
    const input = objectField(node.inputs, input_name) orelse return;
    if (input == .boolean) try appendNamedBool(output, allocator, output_name, input.boolean, true);
}

fn appendStorageListCount(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    input_name: []const u8,
    output_name: []const u8,
) !void {
    const input = objectField(node.inputs, input_name) orelse return;
    if (input == .list) try appendNamedUnsigned(output, allocator, output_name, input.list.len, true);
}

fn resourceScope(node: resource.ResourceNode, regions: []const []const u8) []const u8 {
    if (isGlobalType(node.type_name)) return "global";
    if (regions.len > 1) return "multi_region";
    if (regions.len == 1) return "regional";
    if (node.provider == .local) return "local";
    return "project";
}

fn isGlobalType(type_name: []const u8) bool {
    return std.mem.indexOf(u8, type_name, "Global") != null or
        std.mem.eql(u8, type_name, "gcp.compute.BackendService") or
        std.mem.eql(u8, type_name, "gcp.compute.UrlMap") or
        std.mem.eql(u8, type_name, "gcp.compute.HttpRedirectUrlMap") or
        std.mem.eql(u8, type_name, "gcp.compute.TargetHttpsProxy") or
        std.mem.eql(u8, type_name, "gcp.compute.TargetHttpProxy") or
        std.mem.eql(u8, type_name, "gcp.compute.ManagedSslCertificate");
}

fn edgeKind(from_node: ?resource.ResourceNode, to_id: []const u8, from_type: []const u8, to_type: []const u8) []const u8 {
    if (std.mem.eql(u8, from_type, "gcp.pubsub.Subscription") and std.mem.eql(u8, to_type, "gcp.pubsub.Topic")) return "event";
    if (std.mem.eql(u8, from_type, "gcp.eventarc.Trigger") and
        (std.mem.eql(u8, to_type, "gcp.pubsub.Topic") or std.mem.eql(u8, to_type, "gcp.run.Service"))) return "event";
    if (std.mem.startsWith(u8, from_type, "gcp.tasks.Queue") and std.mem.eql(u8, to_type, "gcp.run.Service")) return "event";
    if (std.mem.indexOf(u8, from_type, "IamMember") != null or
        std.mem.indexOf(u8, from_type, "IamBinding") != null or
        std.mem.indexOf(u8, from_type, "IamPolicy") != null or
        std.mem.startsWith(u8, from_type, "gcp.iam.")) return "iam";
    if (from_node) |node| if (containsOutputReference(node.inputs, to_id)) return "output";
    if (isTrafficPair(from_type, to_type)) return "traffic";
    if (std.mem.startsWith(u8, from_type, "cockroach.") != std.mem.startsWith(u8, to_type, "cockroach.")) {
        return "connectivity";
    }
    return "dependency";
}

fn isTrafficPair(from_type: []const u8, to_type: []const u8) bool {
    return (std.mem.eql(u8, from_type, "gcp.compute.GlobalForwardingRule") and
        (std.mem.eql(u8, to_type, "gcp.compute.TargetHttpsProxy") or std.mem.eql(u8, to_type, "gcp.compute.TargetHttpProxy"))) or
        ((std.mem.eql(u8, from_type, "gcp.compute.TargetHttpsProxy") or std.mem.eql(u8, from_type, "gcp.compute.TargetHttpProxy")) and
            (std.mem.eql(u8, to_type, "gcp.compute.UrlMap") or std.mem.eql(u8, to_type, "gcp.compute.HttpRedirectUrlMap"))) or
        (std.mem.eql(u8, from_type, "gcp.compute.UrlMap") and std.mem.eql(u8, to_type, "gcp.compute.BackendService")) or
        (std.mem.eql(u8, from_type, "gcp.compute.BackendService") and std.mem.eql(u8, to_type, "gcp.compute.RegionServerlessNeg")) or
        (std.mem.eql(u8, from_type, "gcp.compute.RegionServerlessNeg") and
            std.mem.eql(u8, to_type, "gcp.run.Service"));
}

fn containsOutputReference(value: value_mod.Value, resource_id: []const u8) bool {
    return switch (value) {
        .output_ref => |reference| std.mem.eql(u8, reference.resource_id, resource_id),
        .list => |items| for (items) |item| {
            if (containsOutputReference(item, resource_id)) break true;
        } else false,
        .object => |fields| for (fields) |field| {
            if (containsOutputReference(field.value, resource_id)) break true;
        } else false,
        .string, .integer, .boolean, .secret_ref, .unknown_reason => false,
    };
}

fn appendSafeValue(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    value: value_mod.Value,
    field_name: ?[]const u8,
) !void {
    if (field_name) |name| if (isSecretField(name)) {
        try output.appendSlice(allocator, "{\"$secret\":\"redacted\"}");
        return;
    };
    switch (value) {
        .string => |inner| try appendJsonString(output, allocator, inner),
        .integer => |inner| try output.print(allocator, "{d}", .{inner}),
        .boolean => |inner| try output.appendSlice(allocator, if (inner) "true" else "false"),
        .list => |items| {
            try output.append(allocator, '[');
            for (items, 0..) |item, index| {
                if (index != 0) try output.append(allocator, ',');
                try appendSafeValue(output, allocator, item, null);
            }
            try output.append(allocator, ']');
        },
        .object => |fields| {
            try output.append(allocator, '{');
            for (fields, 0..) |field, index| {
                if (index != 0) try output.append(allocator, ',');
                try appendJsonString(output, allocator, field.name);
                try output.append(allocator, ':');
                try appendSafeValue(output, allocator, field.value, field.name);
            }
            try output.append(allocator, '}');
        },
        .secret_ref => try output.appendSlice(allocator, "{\"$secret\":\"redacted\"}"),
        .output_ref => |reference| {
            try output.appendSlice(allocator, "{\"$output\":{");
            try appendNamedString(output, allocator, "resource", reference.resource_id, false);
            try appendNamedString(output, allocator, "field", reference.field, true);
            try output.appendSlice(allocator, "}}");
        },
        .unknown_reason => |reason| {
            try output.appendSlice(allocator, "{\"$unknown\":");
            try appendJsonString(output, allocator, reason);
            try output.append(allocator, '}');
        },
    }
}

fn isSecretField(name: []const u8) bool {
    const needles = [_][]const u8{ "secret", "password", "token", "credential", "private_key", "database_url", "connection_string" };
    for (needles) |needle| if (indexOfIgnoreCase(name, needle) != null) return true;
    return false;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        var matches = true;
        for (haystack[index .. index + needle.len], needle) |left, right| {
            if (std.ascii.toLower(left) != std.ascii.toLower(right)) {
                matches = false;
                break;
            }
        }
        if (matches) return index;
    }
    return null;
}

fn objectField(node_inputs: value_mod.Value, name: []const u8) ?value_mod.Value {
    return switch (node_inputs) {
        .object => |fields| objectFieldFromFields(fields, name),
        else => null,
    };
}

fn objectString(node: resource.ResourceNode, name: []const u8) ?[]const u8 {
    const field = objectField(node.inputs, name) orelse return null;
    return switch (field) {
        .string => |text| text,
        else => null,
    };
}

fn objectFieldFromFields(fields: []const value_mod.Field, name: []const u8) ?value_mod.Value {
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return null;
}

fn findResourceType(resources: []const VisualResource, id: []const u8) ?[]const u8 {
    const item = findResource(resources, id) orelse return null;
    return item.node.type_name;
}

fn findResource(resources: []const VisualResource, id: []const u8) ?VisualResource {
    for (resources) |item| if (std.mem.eql(u8, item.node.id, id)) return item;
    return null;
}

fn appendUniqueString(allocator: std.mem.Allocator, values: *std.ArrayList([]const u8), value: []const u8) !void {
    for (values.items) |existing| if (std.mem.eql(u8, existing, value)) return;
    try values.append(allocator, value);
}

fn appendStringArray(output: *std.ArrayList(u8), allocator: std.mem.Allocator, values: []const []const u8) !void {
    try output.append(allocator, '[');
    for (values, 0..) |value, index| {
        if (index != 0) try output.append(allocator, ',');
        try appendJsonString(output, allocator, value);
    }
    try output.append(allocator, ']');
}

fn appendNamedString(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    value: []const u8,
    comma: bool,
) !void {
    if (comma) try output.append(allocator, ',');
    try appendJsonString(output, allocator, name);
    try output.append(allocator, ':');
    try appendJsonString(output, allocator, value);
}

fn appendNamedUnsigned(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    value: anytype,
    comma: bool,
) !void {
    if (comma) try output.append(allocator, ',');
    try appendJsonString(output, allocator, name);
    try output.print(allocator, ":{d}", .{value});
}

fn appendNamedBool(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    value: bool,
    comma: bool,
) !void {
    if (comma) try output.append(allocator, ',');
    try appendJsonString(output, allocator, name);
    try output.appendSlice(allocator, if (value) ":true" else ":false");
}

fn appendNamedHash(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    hash: [32]u8,
    comma: bool,
) !void {
    const encoded = std.fmt.bytesToHex(hash, .lower);
    try appendNamedString(output, allocator, name, &encoded, comma);
}

fn appendJsonString(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(encoded);
    try output.appendSlice(allocator, encoded);
}

fn validateTarget(value: []const u8) !void {
    if (value.len == 0 or value.len > 128 or std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) {
        return error.InvalidVisualTarget;
    }
    for (value) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '-' and character != '_') {
            return error.InvalidVisualTarget;
        }
    }
}

fn lessThanVisualResource(_: void, left: VisualResource, right: VisualResource) bool {
    return std.mem.lessThan(u8, left.node.id, right.node.id);
}

fn lessThanVisualEdge(_: void, left: VisualEdge, right: VisualEdge) bool {
    const from_order = std.mem.order(u8, left.from, right.from);
    if (from_order != .eq) return from_order == .lt;
    return std.mem.lessThan(u8, left.to, right.to);
}

fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}
