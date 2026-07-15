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
    try appendComputeWorkloadDetails(output, allocator, item.node);
    try appendNetworkDeliveryDetails(output, allocator, item.node);
    try appendEdgeSecurityDetails(output, allocator, item.node);
    try appendConnectivityDetails(output, allocator, item.node);
    try appendContainerPlatformDetails(output, allocator, item.node);
    try appendMonitoringDetails(output, allocator, item.node);
    try appendLoggingDetails(output, allocator, item.node);
    try appendBuildDeliveryDetails(output, allocator, item.node);
    try appendCloudDeployDetails(output, allocator, item.node);
    try appendGovernanceDetails(output, allocator, item.node);
    try appendSecurityFoundationDetails(output, allocator, item.node);
    try appendDataEngineeringDetails(output, allocator, item.node);
    try appendEventIntegrationDetails(output, allocator, item.node);
    try appendVertexAiDetails(output, allocator, item.node);
    try appendOrganizationFoundationDetails(output, allocator, item.node);
    try appendKmsSecretDetails(output, allocator, item.node);
    try appendBigqueryDetails(output, allocator, item.node);
    try appendFirestoreDetails(output, allocator, item.node);
    try appendCloudSqlDetails(output, allocator, item.node);
    try appendSpannerDetails(output, allocator, item.node);
    try appendMemorystoreDetails(output, allocator, item.node);
    try appendApplicationServicesDetails(output, allocator, item.node);
    try appendPrivateConnectivityDetails(output, allocator, item.node);
    try appendIamDetails(output, allocator, item.node);
    try appendConfigurationCost(output, allocator, item.node, observed_at_millis);
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
    node: resource.ResourceNode,
    observed_at_millis: u64,
) !void {
    try output.appendSlice(allocator, ",\"cost\":{");
    try appendNamedString(output, allocator, "schema", "ziac.resource-cost.v1", false);
    try appendNamedString(output, allocator, "origin", "configuration_estimate", true);
    try appendNamedString(output, allocator, "currency", "USD", true);
    const no_charge = isNoChargeFoundationType(node.type_name) or std.mem.startsWith(u8, node.type_name, "gcp.dataform.");
    if (no_charge)
        try output.appendSlice(allocator, ",\"amount_micros\":0")
    else
        try output.appendSlice(allocator, ",\"amount_micros\":null");
    try appendNamedString(output, allocator, "confidence", if (no_charge) "explicit_usage" else "unavailable", true);
    try appendNamedString(output, allocator, "basis", if (std.mem.startsWith(u8, node.type_name, "gcp.dataform.")) "service_no_charge" else if (no_charge) "documented_no_charge" else "usage_assumptions_required", true);
    try appendNamedUnsigned(output, allocator, "observed_at_millis", observed_at_millis, true);
    try appendNamedBool(output, allocator, "is_billing_export", false, true);
    try output.append(allocator, '}');
}

fn isNoChargeFoundationType(type_name: []const u8) bool {
    return std.mem.startsWith(u8, type_name, "gcp.resourcemanager.") or
        std.mem.startsWith(u8, type_name, "gcp.iam.") or
        std.mem.startsWith(u8, type_name, "gcp.orgpolicy.") or
        std.mem.startsWith(u8, type_name, "gcp.tags.") or
        std.mem.startsWith(u8, type_name, "gcp.accesscontextmanager.") or
        std.mem.startsWith(u8, type_name, "gcp.binaryauthorization.") or
        std.mem.eql(u8, type_name, "gcp.billing.ProjectBillingAssociation") or
        std.mem.eql(u8, type_name, "gcp.serviceusage.ServiceIdentity") or
        std.mem.eql(u8, type_name, "gcp.project.Service");
}

fn appendGovernanceDetails(output: *std.ArrayList(u8), allocator: std.mem.Allocator, node: resource.ResourceNode) !void {
    const kind = if (std.mem.eql(u8, node.type_name, "gcp.orgpolicy.Policy"))
        "organization_policy"
    else if (std.mem.eql(u8, node.type_name, "gcp.orgpolicy.CustomConstraint"))
        "custom_constraint"
    else if (std.mem.eql(u8, node.type_name, "gcp.tags.TagKey"))
        "tag_key"
    else if (std.mem.eql(u8, node.type_name, "gcp.tags.TagValue"))
        "tag_value"
    else if (std.mem.eql(u8, node.type_name, "gcp.tags.TagBinding"))
        "tag_binding"
    else if (std.mem.eql(u8, node.type_name, "gcp.tags.TagHold"))
        "tag_hold"
    else if (std.mem.eql(u8, node.type_name, "gcp.accesscontextmanager.AccessPolicy"))
        "access_policy"
    else if (std.mem.eql(u8, node.type_name, "gcp.accesscontextmanager.AccessLevel"))
        "access_level"
    else if (std.mem.eql(u8, node.type_name, "gcp.accesscontextmanager.ServicePerimeter"))
        "service_perimeter"
    else if (std.mem.eql(u8, node.type_name, "gcp.accesscontextmanager.GcpUserAccessBinding"))
        "user_access_binding"
    else
        return;
    try output.appendSlice(allocator, ",\"governance\":{");
    try appendNamedString(output, allocator, "kind", kind, false);
    try appendOptionalStorageString(output, allocator, node, "constraint", "constraint");
    try appendOptionalStorageString(output, allocator, node, "short_name", "short_name");
    try appendOptionalStorageString(output, allocator, node, "group_key", "group_key");
    try appendOptionalStorageString(output, allocator, node, "perimeter_type", "perimeter_type");
    try appendOptionalStorageString(output, allocator, node, "removal_policy", "removal_policy");
    try appendOptionalStorageBool(output, allocator, node, "has_dry_run_spec", "has_dry_run_spec");
    try appendOptionalStorageBool(output, allocator, node, "has_dry_run", "has_dry_run");
    try appendNestedListCount(output, allocator, node, "spec", "rules", "enforced_rule_count");
    try appendNestedListCount(output, allocator, node, "dry_run_spec", "rules", "dry_run_rule_count");
    try appendNestedListCount(output, allocator, node, "status", "restricted_services", "restricted_service_count");
    try appendNestedListCount(output, allocator, node, "dry_run", "restricted_services", "dry_run_restricted_service_count");
    try output.append(allocator, '}');
}

fn appendSecurityFoundationDetails(output: *std.ArrayList(u8), allocator: std.mem.Allocator, node: resource.ResourceNode) !void {
    const kind = if (std.mem.eql(u8, node.type_name, "gcp.securitycenter.Source"))
        "finding_source"
    else if (std.mem.eql(u8, node.type_name, "gcp.securitycenter.NotificationConfig"))
        "finding_notification"
    else if (std.mem.eql(u8, node.type_name, "gcp.securitycenter.MuteConfig"))
        "finding_mute"
    else if (std.mem.eql(u8, node.type_name, "gcp.securitycenter.BigQueryExport"))
        "finding_export"
    else if (std.mem.eql(u8, node.type_name, "gcp.securitycenter.ResourceValueConfig"))
        "resource_value"
    else if (std.mem.eql(u8, node.type_name, "gcp.binaryauthorization.Policy"))
        "admission_policy"
    else if (std.mem.eql(u8, node.type_name, "gcp.binaryauthorization.Attestor"))
        "artifact_attestor"
    else if (std.mem.eql(u8, node.type_name, "gcp.binaryauthorization.AttestorIamMember"))
        "attestor_iam"
    else if (std.mem.eql(u8, node.type_name, "gcp.privateca.CaPool"))
        "trust_pool"
    else if (std.mem.eql(u8, node.type_name, "gcp.privateca.CertificateAuthority"))
        "certificate_issuer"
    else if (std.mem.eql(u8, node.type_name, "gcp.privateca.CertificateTemplate"))
        "certificate_template"
    else if (std.mem.eql(u8, node.type_name, "gcp.privateca.Certificate"))
        "issued_certificate"
    else if (std.mem.eql(u8, node.type_name, "gcp.privateca.CaPoolIamMember") or
        std.mem.eql(u8, node.type_name, "gcp.privateca.CertificateTemplateIamMember"))
        "private_ca_iam"
    else
        return;
    try output.appendSlice(allocator, ",\"security\":{");
    try appendNamedString(output, allocator, "kind", kind, false);
    try appendOptionalStorageString(output, allocator, node, "filter", "filter");
    try appendOptionalStorageString(output, allocator, node, "config_type", "mute_type");
    try appendOptionalStorageString(output, allocator, node, "tier", "tier");
    try appendOptionalStorageString(output, allocator, node, "authority_type", "authority_type");
    try appendOptionalStorageString(output, allocator, node, "key_algorithm", "key_algorithm");
    try appendOptionalStorageString(output, allocator, node, "removal_policy", "removal_policy");
    try appendStorageListCount(output, allocator, node, "public_keys", "public_key_count");
    try output.append(allocator, '}');
}

fn appendDataEngineeringDetails(output: *std.ArrayList(u8), allocator: std.mem.Allocator, node: resource.ResourceNode) !void {
    const kind = if (std.mem.eql(u8, node.type_name, "gcp.datapipelines.Pipeline"))
        "dataflow_pipeline"
    else if (std.mem.eql(u8, node.type_name, "gcp.dataproc.Cluster"))
        "dataproc_cluster"
    else if (std.mem.eql(u8, node.type_name, "gcp.dataproc.AutoscalingPolicy"))
        "dataproc_autoscaling_policy"
    else if (std.mem.eql(u8, node.type_name, "gcp.dataproc.WorkflowTemplate"))
        "dataproc_workflow_template"
    else if (std.mem.eql(u8, node.type_name, "gcp.dataform.Repository"))
        "dataform_repository"
    else if (std.mem.eql(u8, node.type_name, "gcp.dataform.Workspace"))
        "dataform_workspace"
    else if (std.mem.eql(u8, node.type_name, "gcp.dataform.ReleaseConfig"))
        "dataform_release_config"
    else if (std.mem.eql(u8, node.type_name, "gcp.dataform.WorkflowConfig"))
        "dataform_workflow_config"
    else if (std.mem.startsWith(u8, node.type_name, "gcp.dataproc.") or std.mem.startsWith(u8, node.type_name, "gcp.dataform."))
        "data_engineering_iam"
    else
        return;

    try output.appendSlice(allocator, ",\"data_engineering\":{");
    try appendNamedString(output, allocator, "kind", kind, false);
    try appendOptionalStorageString(output, allocator, node, "pipeline_type", "pipeline_type");
    try appendOptionalStorageString(output, allocator, node, "image_version", "image_version");
    try appendOptionalStorageString(output, allocator, node, "git_commitish", "git_commitish");
    try appendOptionalStorageString(output, allocator, node, "cron_schedule", "cron_schedule");
    try appendOptionalStorageString(output, allocator, node, "time_zone", "time_zone");
    try appendOptionalStorageString(output, allocator, node, "repository_name", "repository_name");
    try appendOptionalStorageString(output, allocator, node, "role", "iam_role");
    try appendOptionalStorageBool(output, allocator, node, "disabled", "disabled");
    try appendOptionalStorageBool(output, allocator, node, "component_gateway", "component_gateway");
    try appendStorageListCount(output, allocator, node, "jobs", "job_count");
    try appendStorageListCount(output, allocator, node, "included_tags", "included_tag_count");
    try appendNestedDataEngineeringValue(output, allocator, node, "schedule", "cron", "schedule");
    try appendNestedDataEngineeringValue(output, allocator, node, "schedule", "time_zone", "schedule_time_zone");
    try appendNestedDataEngineeringValue(output, allocator, node, "placement", "kind", "placement_kind");
    try appendNestedDataEngineeringInteger(output, allocator, node, "worker", "instances", "worker_instances");
    try appendNestedDataEngineeringInteger(output, allocator, node, "worker", "min_instances", "min_worker_instances");
    try appendNestedDataEngineeringInteger(output, allocator, node, "worker", "max_instances", "max_worker_instances");
    try appendNamedUnsigned(output, allocator, "dag_edge_count", dataEngineeringDagEdgeCount(node), true);
    try output.append(allocator, '}');
}

fn appendEventIntegrationDetails(output: *std.ArrayList(u8), allocator: std.mem.Allocator, node: resource.ResourceNode) !void {
    const kind = if (std.mem.eql(u8, node.type_name, "gcp.eventarc.MessageBus"))
        "message_bus"
    else if (std.mem.eql(u8, node.type_name, "gcp.eventarc.Pipeline"))
        "event_pipeline"
    else if (std.mem.eql(u8, node.type_name, "gcp.eventarc.Enrollment"))
        "enrollment"
    else if (std.mem.eql(u8, node.type_name, "gcp.eventarc.GoogleApiSource"))
        "google_api_source"
    else if (std.mem.eql(u8, node.type_name, "gcp.connectors.Connection"))
        "connector_connection"
    else if (std.mem.eql(u8, node.type_name, "gcp.connectors.EndpointAttachment"))
        "connector_psc_endpoint"
    else if (std.mem.eql(u8, node.type_name, "gcp.connectors.EventSubscription"))
        "connector_event_subscription"
    else if (std.mem.eql(u8, node.type_name, "gcp.connectors.ManagedZone"))
        "connector_managed_zone"
    else if (std.mem.eql(u8, node.type_name, "gcp.connectors.RegionalSettings"))
        "connector_regional_settings"
    else if (std.mem.startsWith(u8, node.type_name, "gcp.eventarc.") or std.mem.startsWith(u8, node.type_name, "gcp.connectors."))
        "event_integration_iam"
    else
        return;
    try output.appendSlice(allocator, ",\"event_integration\":{");
    try appendNamedString(output, allocator, "kind", kind, false);
    try appendOptionalStorageString(output, allocator, node, "location", "location");
    try appendOptionalStorageString(output, allocator, node, "connector_version", "connector_version");
    try appendOptionalStorageString(output, allocator, node, "event_type_id", "event_type_id");
    try appendOptionalStorageString(output, allocator, node, "egress_mode", "egress_mode");
    try appendOptionalStorageString(output, allocator, node, "logging_severity", "logging_severity");
    try appendOptionalStorageString(output, allocator, node, "role", "iam_role");
    try appendOptionalStorageBool(output, allocator, node, "suspended", "suspended");
    try appendNestedDataEngineeringInteger(output, allocator, node, "node_config", "min_nodes", "min_nodes");
    try appendNestedDataEngineeringInteger(output, allocator, node, "node_config", "max_nodes", "max_nodes");
    try output.append(allocator, '}');
}

fn appendVertexAiDetails(output: *std.ArrayList(u8), allocator: std.mem.Allocator, node: resource.ResourceNode) !void {
    const kind = if (std.mem.eql(u8, node.type_name, "gcp.vertex.Dataset"))
        "dataset"
    else if (std.mem.eql(u8, node.type_name, "gcp.vertex.Model"))
        "model"
    else if (std.mem.eql(u8, node.type_name, "gcp.vertex.Endpoint"))
        "prediction_endpoint"
    else if (std.mem.eql(u8, node.type_name, "gcp.vertex.Index"))
        "vector_index"
    else if (std.mem.eql(u8, node.type_name, "gcp.vertex.IndexEndpoint"))
        "vector_index_endpoint"
    else if (std.mem.eql(u8, node.type_name, "gcp.vertex.FeatureGroup"))
        "feature_group"
    else if (std.mem.eql(u8, node.type_name, "gcp.vertex.Feature"))
        "feature"
    else if (std.mem.eql(u8, node.type_name, "gcp.vertex.FeatureOnlineStore"))
        "feature_online_store"
    else if (std.mem.eql(u8, node.type_name, "gcp.vertex.FeatureView"))
        "feature_view"
    else if (std.mem.eql(u8, node.type_name, "gcp.vertex.Tensorboard"))
        "tensorboard"
    else if (std.mem.eql(u8, node.type_name, "gcp.vertex.MetadataStore"))
        "metadata_store"
    else if (std.mem.startsWith(u8, node.type_name, "gcp.vertex."))
        "vertex_ai_iam"
    else
        return;
    try output.appendSlice(allocator, ",\"vertex_ai\":{");
    try appendNamedString(output, allocator, "kind", kind, false);
    try appendOptionalStorageString(output, allocator, node, "location", "location");
    try appendOptionalStorageString(output, allocator, node, "display_name", "display_name");
    try appendOptionalStorageString(output, allocator, node, "artifact_uri", "artifact_uri");
    try appendOptionalStorageString(output, allocator, node, "update_method", "update_method");
    try appendOptionalStorageString(output, allocator, node, "bigquery_source", "bigquery_source");
    try appendOptionalStorageString(output, allocator, node, "point_of_contact", "point_of_contact");
    try appendOptionalStorageString(output, allocator, node, "role", "iam_role");
    try appendOptionalStorageBool(output, allocator, node, "dedicated_endpoint", "dedicated_endpoint");
    try appendOptionalStorageBool(output, allocator, node, "is_default", "is_default");
    try appendOptionalStorageInteger(output, allocator, node, "sync_interval_seconds", "sync_interval_seconds");
    try appendStorageListCount(output, allocator, node, "entity_id_columns", "entity_id_column_count");
    try appendNestedDataEngineeringValue(output, allocator, node, "connectivity", "kind", "connectivity");
    try appendNestedDataEngineeringValue(output, allocator, node, "storage", "kind", "storage");
    try appendNestedDataEngineeringValue(output, allocator, node, "source", "kind", "source");
    try output.append(allocator, '}');
}

fn appendNestedDataEngineeringValue(output: *std.ArrayList(u8), allocator: std.mem.Allocator, node: resource.ResourceNode, object_name: []const u8, field_name: []const u8, output_name: []const u8) !void {
    const object = objectField(node.inputs, object_name) orelse return;
    if (object != .object) return;
    const field = objectFieldFromFields(object.object, field_name) orelse return;
    if (field == .string and field.string.len > 0) try appendNamedString(output, allocator, output_name, field.string, true);
}

fn appendNestedDataEngineeringInteger(output: *std.ArrayList(u8), allocator: std.mem.Allocator, node: resource.ResourceNode, object_name: []const u8, field_name: []const u8, output_name: []const u8) !void {
    const object = objectField(node.inputs, object_name) orelse return;
    if (object != .object) return;
    const field = objectFieldFromFields(object.object, field_name) orelse return;
    if (field == .integer and field.integer >= 0) try appendNamedUnsigned(output, allocator, output_name, @as(u64, @intCast(field.integer)), true);
}

fn dataEngineeringDagEdgeCount(node: resource.ResourceNode) usize {
    const jobs = objectField(node.inputs, "jobs") orelse return 0;
    if (jobs != .list) return 0;
    var count: usize = 0;
    for (jobs.list) |job| {
        if (job != .object) continue;
        const prerequisites = objectFieldFromFields(job.object, "prerequisite_step_ids") orelse continue;
        if (prerequisites == .list) count += prerequisites.list.len;
    }
    return count;
}

fn appendNestedListCount(output: *std.ArrayList(u8), allocator: std.mem.Allocator, node: resource.ResourceNode, object_name: []const u8, list_name: []const u8, output_name: []const u8) !void {
    const object = objectField(node.inputs, object_name) orelse return;
    if (object != .object) return;
    const list = objectField(object, list_name) orelse return;
    if (list == .list) try appendNamedUnsigned(output, allocator, output_name, list.list.len, true);
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
        .{ .role = "roles/bigquery.dataEditor", .access = "read_write", .permission = "bigquery.tables.updateData" },
        .{ .role = "roles/bigquery.dataViewer", .access = "read", .permission = "bigquery.tables.getData" },
        .{ .role = "roles/bigquery.jobUser", .access = "write", .permission = "bigquery.jobs.create" },
        .{ .role = "roles/cloudtasks.enqueuer", .access = "write", .permission = "cloudtasks.tasks.create" },
        .{ .role = "roles/cloudsql.client", .access = "connect", .permission = "cloudsql.instances.connect" },
        .{ .role = "roles/cloudsql.instanceUser", .access = "login", .permission = "cloudsql.instances.login" },
        .{ .role = "roles/cloudkms.cryptoKeyDecrypter", .access = "decrypt", .permission = "cloudkms.cryptoKeyVersions.useToDecrypt" },
        .{ .role = "roles/cloudkms.cryptoKeyEncrypterDecrypter", .access = "read_write", .permission = "cloudkms.cryptoKeyVersions.useToEncrypt" },
        .{ .role = "roles/binaryauthorization.attestorsVerifier", .access = "verify", .permission = "binaryauthorization.attestors.verifyImageAttested" },
        .{ .role = "roles/privateca.certificateRequester", .access = "issue", .permission = "privateca.certificates.create" },
        .{ .role = "roles/datastore.user", .access = "read_write", .permission = "datastore.entities.create" },
        .{ .role = "roles/datastore.viewer", .access = "read", .permission = "datastore.entities.get" },
        .{ .role = "roles/iam.workloadIdentityUser", .access = "invoke", .permission = "iam.serviceAccounts.getAccessToken" },
        .{ .role = "roles/pubsub.publisher", .access = "write", .permission = "pubsub.topics.publish" },
        .{ .role = "roles/pubsub.subscriber", .access = "read", .permission = "pubsub.subscriptions.consume" },
        .{ .role = "roles/run.invoker", .access = "invoke", .permission = "run.routes.invoke" },
        .{ .role = "roles/workflows.invoker", .access = "invoke", .permission = "workflows.executions.create" },
        .{ .role = "roles/parametermanager.parameterAccessor", .access = "read", .permission = "parametermanager.parameterVersions.render" },
        .{ .role = "roles/spanner.databaseUser", .access = "read_write", .permission = "spanner.databases.read" },
        .{ .role = "roles/redis.dbConnectionUser", .access = "connect", .permission = "redis.clusters.connect" },
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
    if (objectField(node.inputs, "replicas_json")) |replicas| if (replicas == .string) {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, replicas.string, .{}) catch return error.InvalidVisualArtifact;
        defer parsed.deinit();
        if (parsed.value == .array) for (parsed.value.array.items) |entry| if (entry == .object) {
            const location = entry.object.get("location") orelse continue;
            if (location == .string) try appendUniqueString(allocator, regions, location.string);
        };
    };
}

fn directRegion(node: resource.ResourceNode) ?[]const u8 {
    if (objectField(node.inputs, "region")) |region| {
        if (region == .string) return region.string;
    }
    if (objectField(node.inputs, "zone")) |zone| {
        if (zone == .string and zone.string.len > 0) {
            const separator = std.mem.lastIndexOfScalar(u8, zone.string, '-') orelse return null;
            if (separator > 0) return zone.string[0..separator];
        }
    }
    if (std.mem.eql(u8, node.type_name, "gcp.storage.Bucket") or
        std.mem.startsWith(u8, node.type_name, "gcp.bigquery.") or
        std.mem.startsWith(u8, node.type_name, "gcp.firestore.") or
        std.mem.startsWith(u8, node.type_name, "gcp.sql.") or
        std.mem.startsWith(u8, node.type_name, "gcp.redis.") or
        std.mem.startsWith(u8, node.type_name, "gcp.workflows.") or
        std.mem.startsWith(u8, node.type_name, "gcp.apigateway.") or
        std.mem.startsWith(u8, node.type_name, "gcp.parametermanager.") or
        std.mem.startsWith(u8, node.type_name, "gcp.kms.") or
        std.mem.startsWith(u8, node.type_name, "gcp.cloudbuild.") or
        std.mem.startsWith(u8, node.type_name, "gcp.artifact.") or
        std.mem.startsWith(u8, node.type_name, "gcp.deploy.") or
        std.mem.startsWith(u8, node.type_name, "gcp.tasks.") or
        std.mem.startsWith(u8, node.type_name, "gcp.eventarc.") or
        std.mem.startsWith(u8, node.type_name, "gcp.vertex.") or
        std.mem.startsWith(u8, node.type_name, "gcp.privateca.") or
        std.mem.startsWith(u8, node.type_name, "gcp.securitycenter."))
    {
        const location = objectField(node.inputs, "location") orelse return null;
        return if (location == .string) location.string else null;
    }
    return null;
}

fn appendComputeWorkloadDetails(output: *std.ArrayList(u8), allocator: std.mem.Allocator, node: resource.ResourceNode) !void {
    const kind = if (std.mem.eql(u8, node.type_name, "gcp.compute.Disk"))
        "disk"
    else if (std.mem.eql(u8, node.type_name, "gcp.compute.RegionDisk"))
        "regional_disk"
    else if (std.mem.eql(u8, node.type_name, "gcp.compute.Image"))
        "image"
    else if (std.mem.eql(u8, node.type_name, "gcp.compute.Instance"))
        "instance"
    else if (std.mem.eql(u8, node.type_name, "gcp.compute.InstanceTemplate"))
        "instance_template"
    else if (std.mem.eql(u8, node.type_name, "gcp.compute.InstanceGroupManager"))
        "instance_group_manager"
    else if (std.mem.eql(u8, node.type_name, "gcp.compute.RegionInstanceGroupManager"))
        "regional_instance_group_manager"
    else if (std.mem.eql(u8, node.type_name, "gcp.compute.Autoscaler"))
        "autoscaler"
    else if (std.mem.eql(u8, node.type_name, "gcp.compute.RegionAutoscaler"))
        "regional_autoscaler"
    else
        return;
    try output.appendSlice(allocator, ",\"compute_workload\":{");
    try appendNamedString(output, allocator, "kind", kind, false);
    try appendOptionalStorageString(output, allocator, node, "zone", "zone");
    try appendOptionalStorageString(output, allocator, node, "region", "region");
    try appendOptionalStorageString(output, allocator, node, "machine_type", "machine_type");
    try appendOptionalStorageString(output, allocator, node, "disk_type", "disk_type");
    try appendOptionalStorageString(output, allocator, node, "provisioning_model", "provisioning_model");
    try appendOptionalStorageString(output, allocator, node, "mode", "autoscaling_mode");
    try appendOptionalStorageInteger(output, allocator, node, "size_gb", "size_gb");
    try appendOptionalStorageInteger(output, allocator, node, "boot_disk_size_gb", "boot_disk_size_gb");
    try appendOptionalStorageInteger(output, allocator, node, "target_size", "target_size");
    try appendOptionalStorageInteger(output, allocator, node, "min_replicas", "min_replicas");
    try appendOptionalStorageInteger(output, allocator, node, "max_replicas", "max_replicas");
    try appendStorageListCount(output, allocator, node, "network_interfaces", "network_interface_count");
    try appendStorageListCount(output, allocator, node, "replica_zones", "replica_zone_count");
    try appendStorageListCount(output, allocator, node, "distribution_zones", "distribution_zone_count");
    try output.append(allocator, '}');
}

fn appendNetworkDeliveryDetails(output: *std.ArrayList(u8), allocator: std.mem.Allocator, node: resource.ResourceNode) !void {
    const kind = if (std.mem.eql(u8, node.type_name, "gcp.compute.Firewall"))
        "firewall"
    else if (std.mem.eql(u8, node.type_name, "gcp.compute.Route"))
        "route"
    else if (std.mem.eql(u8, node.type_name, "gcp.compute.HealthCheck"))
        "health_check"
    else if (std.mem.eql(u8, node.type_name, "gcp.compute.RegionHealthCheck"))
        "region_health_check"
    else if (std.mem.eql(u8, node.type_name, "gcp.compute.InternalAddress"))
        "internal_address"
    else if (std.mem.eql(u8, node.type_name, "gcp.compute.RegionBackendService"))
        "region_backend_service"
    else if (std.mem.eql(u8, node.type_name, "gcp.compute.RegionUrlMap"))
        "region_url_map"
    else if (std.mem.eql(u8, node.type_name, "gcp.compute.RegionTargetHttpProxy"))
        "region_target_http_proxy"
    else if (std.mem.eql(u8, node.type_name, "gcp.compute.ForwardingRule"))
        "forwarding_rule"
    else
        return;
    try output.appendSlice(allocator, ",\"network_delivery\":{");
    try appendNamedString(output, allocator, "kind", kind, false);
    try appendOptionalStorageString(output, allocator, node, "region", "region");
    try appendOptionalStorageString(output, allocator, node, "direction", "direction");
    try appendOptionalStorageString(output, allocator, node, "action", "action");
    try appendOptionalStorageString(output, allocator, node, "destination_range", "destination_range");
    try appendOptionalStorageString(output, allocator, node, "next_hop_kind", "next_hop_kind");
    try appendOptionalStorageString(output, allocator, node, "protocol", "protocol");
    try appendOptionalStorageString(output, allocator, node, "request_path", "request_path");
    try appendOptionalStorageString(output, allocator, node, "load_balancing_scheme", "load_balancing_scheme");
    try appendOptionalStorageString(output, allocator, node, "purpose", "purpose");
    try appendOptionalStorageString(output, allocator, node, "target_kind", "target_kind");
    try appendOptionalStorageInteger(output, allocator, node, "priority", "priority");
    try appendOptionalStorageInteger(output, allocator, node, "port", "health_port");
    try appendStorageListCount(output, allocator, node, "ports", "port_count");
    try appendStorageListCount(output, allocator, node, "backends", "backend_count");
    try appendOptionalStorageBool(output, allocator, node, "logging", "logging");
    try appendOptionalStorageBool(output, allocator, node, "disabled", "disabled");
    try appendOptionalStorageBool(output, allocator, node, "all_ports", "all_ports");
    try appendOptionalStorageBool(output, allocator, node, "allow_global_access", "allow_global_access");
    try output.append(allocator, '}');
}

fn appendEdgeSecurityDetails(output: *std.ArrayList(u8), allocator: std.mem.Allocator, node: resource.ResourceNode) !void {
    const kind = if (std.mem.eql(u8, node.type_name, "gcp.compute.BackendBucket"))
        "backend_bucket"
    else if (std.mem.eql(u8, node.type_name, "gcp.compute.SecurityPolicy"))
        "security_policy"
    else if (std.mem.eql(u8, node.type_name, "gcp.compute.SslPolicy"))
        "ssl_policy"
    else if (std.mem.eql(u8, node.type_name, "gcp.certificatemanager.DnsAuthorization"))
        "dns_authorization"
    else if (std.mem.eql(u8, node.type_name, "gcp.certificatemanager.Certificate"))
        "certificate"
    else if (std.mem.eql(u8, node.type_name, "gcp.certificatemanager.CertificateMap"))
        "certificate_map"
    else if (std.mem.eql(u8, node.type_name, "gcp.certificatemanager.CertificateMapEntry"))
        "certificate_map_entry"
    else if (std.mem.eql(u8, node.type_name, "gcp.compute.CertificateMapTargetHttpsProxy"))
        "target_https_proxy"
    else
        return;
    try output.appendSlice(allocator, ",\"edge_security\":{");
    try appendNamedString(output, allocator, "kind", kind, false);
    try appendOptionalStorageString(output, allocator, node, "location", "location");
    try appendOptionalStorageString(output, allocator, node, "cache_mode", "cache_mode");
    try appendOptionalStorageString(output, allocator, node, "compression_mode", "compression_mode");
    try appendOptionalStorageString(output, allocator, node, "policy_type", "policy_type");
    try appendOptionalStorageString(output, allocator, node, "minimum_tls_version", "minimum_tls_version");
    try appendOptionalStorageString(output, allocator, node, "profile", "profile");
    try appendOptionalStorageString(output, allocator, node, "domain", "domain");
    try appendOptionalStorageString(output, allocator, node, "scope", "certificate_scope");
    try appendOptionalStorageString(output, allocator, node, "matcher_kind", "matcher_kind");
    try appendOptionalStorageString(output, allocator, node, "matcher_value", "matcher_value");
    try appendOptionalStorageString(output, allocator, node, "quic_override", "quic_override");
    try appendOptionalStorageInteger(output, allocator, node, "default_ttl_seconds", "default_ttl_seconds");
    try appendOptionalStorageInteger(output, allocator, node, "max_ttl_seconds", "max_ttl_seconds");
    try appendStorageListCount(output, allocator, node, "rules", "rule_count");
    try appendStorageListCount(output, allocator, node, "domains", "domain_count");
    try appendStorageListCount(output, allocator, node, "certificates", "certificate_count");
    try appendOptionalStorageBool(output, allocator, node, "enable_cdn", "enable_cdn");
    try appendOptionalStorageBool(output, allocator, node, "negative_caching", "negative_caching");
    try output.append(allocator, '}');
}

fn appendConnectivityDetails(output: *std.ArrayList(u8), allocator: std.mem.Allocator, node: resource.ResourceNode) !void {
    const kind = if (std.mem.eql(u8, node.type_name, "gcp.compute.HaVpnGateway"))
        "ha_vpn_gateway"
    else if (std.mem.eql(u8, node.type_name, "gcp.compute.ExternalVpnGateway"))
        "external_vpn_gateway"
    else if (std.mem.eql(u8, node.type_name, "gcp.compute.VpnTunnel"))
        "vpn_tunnel"
    else if (std.mem.eql(u8, node.type_name, "gcp.compute.RouterInterface"))
        "router_interface"
    else if (std.mem.eql(u8, node.type_name, "gcp.compute.RouterBgpPeer"))
        "bgp_peer"
    else if (std.mem.eql(u8, node.type_name, "gcp.compute.NetworkPeering"))
        "network_peering"
    else if (std.mem.eql(u8, node.type_name, "gcp.networkconnectivity.Hub"))
        "hub"
    else if (std.mem.eql(u8, node.type_name, "gcp.networkconnectivity.Spoke"))
        "spoke"
    else if (std.mem.eql(u8, node.type_name, "gcp.networkconnectivity.ServiceConnectionPolicy"))
        "service_connection_policy"
    else
        return;
    try output.appendSlice(allocator, ",\"connectivity\":{");
    try appendNamedString(output, allocator, "kind", kind, false);
    try appendOptionalStorageString(output, allocator, node, "region", "region");
    try appendOptionalStorageString(output, allocator, node, "location", "location");
    try appendOptionalStorageString(output, allocator, node, "stack_type", "stack_type");
    try appendOptionalStorageString(output, allocator, node, "redundancy_type", "redundancy_type");
    try appendOptionalStorageString(output, allocator, node, "link_kind", "link_kind");
    try appendOptionalStorageString(output, allocator, node, "topology", "topology");
    try appendOptionalStorageString(output, allocator, node, "service_class", "service_class");
    try appendOptionalStorageString(output, allocator, node, "producer_location", "producer_location");
    try appendOptionalStorageInteger(output, allocator, node, "peer_asn", "peer_asn");
    try appendOptionalStorageInteger(output, allocator, node, "route_priority", "route_priority");
    try appendStorageListCount(output, allocator, node, "interfaces", "interface_count");
    try appendStorageListCount(output, allocator, node, "links", "link_count");
    try appendStorageListCount(output, allocator, node, "subnetworks", "subnetwork_count");
    try appendOptionalStorageBool(output, allocator, node, "site_to_site_data_transfer", "site_to_site_data_transfer");
    try output.append(allocator, '}');
}

fn appendContainerPlatformDetails(output: *std.ArrayList(u8), allocator: std.mem.Allocator, node: resource.ResourceNode) !void {
    const kind = if (std.mem.eql(u8, node.type_name, "gcp.container.Cluster"))
        "cluster"
    else if (std.mem.eql(u8, node.type_name, "gcp.container.NodePool"))
        "node_pool"
    else if (std.mem.eql(u8, node.type_name, "gcp.gkehub.Fleet"))
        "fleet"
    else if (std.mem.eql(u8, node.type_name, "gcp.gkehub.Membership"))
        "membership"
    else if (std.mem.eql(u8, node.type_name, "gcp.functions.FunctionV2"))
        "function"
    else if (std.mem.eql(u8, node.type_name, "gcp.batch.Job"))
        "batch_job"
    else
        return;
    try output.appendSlice(allocator, ",\"container_platform\":{");
    try appendNamedString(output, allocator, "kind", kind, false);
    try appendOptionalStorageString(output, allocator, node, "location", "location");
    try appendOptionalStorageString(output, allocator, node, "mode", "mode");
    try appendOptionalStorageString(output, allocator, node, "release_channel", "release_channel");
    try appendOptionalStorageString(output, allocator, node, "machine_type", "machine_type");
    try appendOptionalStorageString(output, allocator, node, "runtime", "runtime");
    try appendOptionalStorageString(output, allocator, node, "trigger_kind", "trigger_kind");
    try appendOptionalStorageString(output, allocator, node, "provisioning_model", "provisioning_model");
    try appendOptionalStorageInteger(output, allocator, node, "node_count", "node_count");
    try appendOptionalStorageInteger(output, allocator, node, "task_count", "task_count");
    try appendOptionalStorageInteger(output, allocator, node, "parallelism", "parallelism");
    try appendOptionalStorageBool(output, allocator, node, "private_nodes", "private_nodes");
    try appendOptionalStorageBool(output, allocator, node, "spot", "spot");
    try appendOptionalStorageBool(output, allocator, node, "autoscaling_enabled", "autoscaling");
    try output.append(allocator, '}');
}

fn appendMonitoringDetails(output: *std.ArrayList(u8), allocator: std.mem.Allocator, node: resource.ResourceNode) !void {
    const kind = if (std.mem.eql(u8, node.type_name, "gcp.monitoring.AlertPolicy"))
        "alert_policy"
    else if (std.mem.eql(u8, node.type_name, "gcp.monitoring.UptimeCheck"))
        "uptime_check"
    else if (std.mem.eql(u8, node.type_name, "gcp.monitoring.NotificationChannel"))
        "notification_channel"
    else if (std.mem.eql(u8, node.type_name, "gcp.monitoring.Dashboard"))
        "dashboard"
    else if (std.mem.eql(u8, node.type_name, "gcp.monitoring.Service"))
        "service"
    else if (std.mem.eql(u8, node.type_name, "gcp.monitoring.ServiceLevelObjective"))
        "slo"
    else
        return;
    try output.appendSlice(allocator, ",\"monitoring\":{");
    try appendNamedString(output, allocator, "kind", kind, false);
    try appendOptionalStorageString(output, allocator, node, "display_name", "display_name");
    try appendOptionalStorageString(output, allocator, node, "type", "channel_type");
    try appendOptionalStorageString(output, allocator, node, "protocol", "protocol");
    try appendOptionalStorageString(output, allocator, node, "severity", "severity");
    try appendOptionalStorageInteger(output, allocator, node, "period_seconds", "period_seconds");
    try appendOptionalStorageInteger(output, allocator, node, "timeout_seconds", "timeout_seconds");
    try appendOptionalStorageInteger(output, allocator, node, "goal_micros", "goal_micros");
    try appendOptionalStorageInteger(output, allocator, node, "columns", "columns");
    try appendOptionalStorageBool(output, allocator, node, "enabled", "enabled");
    try appendOptionalStorageBool(output, allocator, node, "disabled", "disabled");
    try appendStorageListCount(output, allocator, node, "conditions", "condition_count");
    try appendStorageListCount(output, allocator, node, "notification_channels", "notification_channel_count");
    try appendStorageListCount(output, allocator, node, "tiles", "tile_count");
    try output.append(allocator, '}');
}

fn appendLoggingDetails(output: *std.ArrayList(u8), allocator: std.mem.Allocator, node: resource.ResourceNode) !void {
    const kind = if (std.mem.eql(u8, node.type_name, "gcp.logging.Bucket"))
        "bucket"
    else if (std.mem.eql(u8, node.type_name, "gcp.logging.View"))
        "view"
    else if (std.mem.eql(u8, node.type_name, "gcp.logging.Sink"))
        "sink"
    else if (std.mem.eql(u8, node.type_name, "gcp.logging.Exclusion"))
        "exclusion"
    else if (std.mem.eql(u8, node.type_name, "gcp.logging.Metric"))
        "metric"
    else
        return;
    try output.appendSlice(allocator, ",\"logging\":{");
    try appendNamedString(output, allocator, "kind", kind, false);
    try appendOptionalStorageString(output, allocator, node, "location", "location");
    try appendOptionalStorageString(output, allocator, node, "filter", "filter");
    try appendOptionalStorageString(output, allocator, node, "metric_kind", "metric_kind");
    try appendOptionalStorageString(output, allocator, node, "value_type", "value_type");
    try appendOptionalStorageInteger(output, allocator, node, "retention_days", "retention_days");
    try appendOptionalStorageBool(output, allocator, node, "analytics_enabled", "analytics_enabled");
    try appendOptionalStorageBool(output, allocator, node, "locked", "locked");
    try appendOptionalStorageBool(output, allocator, node, "disabled", "disabled");
    try appendStorageListCount(output, allocator, node, "restricted_fields", "restricted_field_count");
    try appendStorageListCount(output, allocator, node, "indexes", "index_count");
    try appendStorageListCount(output, allocator, node, "exclusions", "exclusion_count");
    try appendStorageListCount(output, allocator, node, "labels", "label_count");
    try output.append(allocator, '}');
}

fn appendBuildDeliveryDetails(output: *std.ArrayList(u8), allocator: std.mem.Allocator, node: resource.ResourceNode) !void {
    const kind = if (std.mem.eql(u8, node.type_name, "gcp.cloudbuild.Connection"))
        "connection"
    else if (std.mem.eql(u8, node.type_name, "gcp.cloudbuild.Repository"))
        "source_repository"
    else if (std.mem.eql(u8, node.type_name, "gcp.cloudbuild.WorkerPool"))
        "worker_pool"
    else if (std.mem.eql(u8, node.type_name, "gcp.cloudbuild.Trigger"))
        "trigger"
    else if (std.mem.eql(u8, node.type_name, "gcp.artifact.Repository"))
        "artifact_repository"
    else if (std.mem.eql(u8, node.type_name, "gcp.artifact.ProjectSettings"))
        "project_settings"
    else if (std.mem.eql(u8, node.type_name, "gcp.artifact.VpcscConfig"))
        "vpcsc_config"
    else
        return;
    try output.appendSlice(allocator, ",\"build_delivery\":{");
    try appendNamedString(output, allocator, "kind", kind, false);
    try appendOptionalStorageString(output, allocator, node, "location", "location");
    try appendOptionalStorageString(output, allocator, node, "format", "format");
    try appendOptionalStorageString(output, allocator, node, "mode", "mode");
    try appendOptionalStorageString(output, allocator, node, "machine_type", "machine_type");
    try appendOptionalStorageString(output, allocator, node, "remote_uri", "remote_uri");
    try appendOptionalStorageString(output, allocator, node, "redirection", "redirection");
    try appendOptionalStorageString(output, allocator, node, "policy", "vpcsc_policy");
    try appendOptionalStorageBool(output, allocator, node, "disabled", "disabled");
    try appendOptionalStorageBool(output, allocator, node, "cleanup_policy_dry_run", "cleanup_policy_dry_run");
    try appendStorageListCount(output, allocator, node, "cleanup_policies", "cleanup_policy_count");
    try output.append(allocator, '}');
}

fn appendCloudDeployDetails(output: *std.ArrayList(u8), allocator: std.mem.Allocator, node: resource.ResourceNode) !void {
    const kind = if (std.mem.eql(u8, node.type_name, "gcp.deploy.DeliveryPipeline"))
        "delivery_pipeline"
    else if (std.mem.eql(u8, node.type_name, "gcp.deploy.Target"))
        "target"
    else if (std.mem.eql(u8, node.type_name, "gcp.deploy.CustomTargetType"))
        "custom_target_type"
    else if (std.mem.eql(u8, node.type_name, "gcp.deploy.Automation"))
        "automation"
    else if (std.mem.eql(u8, node.type_name, "gcp.deploy.DeployPolicy"))
        "deploy_policy"
    else
        return;
    try output.appendSlice(allocator, ",\"cloud_deploy\":{");
    try appendNamedString(output, allocator, "kind", kind, false);
    try appendOptionalStorageString(output, allocator, node, "location", "location");
    try appendOptionalStorageString(output, allocator, node, "service_account", "service_account");
    try appendOptionalStorageBool(output, allocator, node, "require_approval", "require_approval");
    try appendOptionalStorageBool(output, allocator, node, "suspended", "suspended");
    try appendStorageListCount(output, allocator, node, "stages", "stage_count");
    try appendStorageListCount(output, allocator, node, "execution", "execution_count");
    try appendStorageListCount(output, allocator, node, "rules", "rule_count");
    try appendStorageListCount(output, allocator, node, "selectors", "selector_count");
    try appendStorageListCount(output, allocator, node, "target_ids", "target_count");
    try output.append(allocator, '}');
}

fn appendKmsSecretDetails(output: *std.ArrayList(u8), allocator: std.mem.Allocator, node: resource.ResourceNode) !void {
    const kind = if (std.mem.eql(u8, node.type_name, "gcp.kms.KeyRing"))
        "key_ring"
    else if (std.mem.eql(u8, node.type_name, "gcp.kms.CryptoKey"))
        "crypto_key"
    else if (std.mem.eql(u8, node.type_name, "gcp.kms.CryptoKeyVersion"))
        "crypto_key_version"
    else if (std.mem.eql(u8, node.type_name, "gcp.kms.KeyRingIamMember"))
        "key_ring_iam_member"
    else if (std.mem.eql(u8, node.type_name, "gcp.kms.CryptoKeyIamMember"))
        "crypto_key_iam_member"
    else if (std.mem.eql(u8, node.type_name, "gcp.secret.Secret"))
        "secret"
    else if (std.mem.eql(u8, node.type_name, "gcp.secret.SecretVersion"))
        "secret_version"
    else if (std.mem.eql(u8, node.type_name, "gcp.secret.SecretIamMember"))
        "secret_iam_member"
    else
        return;
    try output.appendSlice(allocator, ",\"kms_secret\":{");
    try appendNamedString(output, allocator, "kind", kind, false);
    try appendOptionalStorageString(output, allocator, node, "location", "location");
    try appendOptionalStorageString(output, allocator, node, "purpose", "purpose");
    try appendOptionalStorageString(output, allocator, node, "algorithm", "algorithm");
    try appendOptionalStorageString(output, allocator, node, "protection_level", "protection_level");
    try appendOptionalStorageString(output, allocator, node, "state", "state");
    try appendOptionalStorageString(output, allocator, node, "replication_mode", "replication_mode");
    try appendOptionalStorageString(output, allocator, node, "removal_policy", "removal_policy");
    try appendOptionalStorageInteger(output, allocator, node, "rotation_period_seconds", "rotation_period_seconds");
    try appendStorageListCount(output, allocator, node, "topics", "topic_count");
    try appendStorageObjectCount(output, allocator, node, "version_aliases", "alias_count");
    try appendJsonArrayStringCount(output, allocator, node, "replicas_json", "replica_count");
    try output.append(allocator, '}');
}

fn appendOrganizationFoundationDetails(output: *std.ArrayList(u8), allocator: std.mem.Allocator, node: resource.ResourceNode) !void {
    const kind = if (std.mem.eql(u8, node.type_name, "gcp.resourcemanager.Folder"))
        "folder"
    else if (std.mem.eql(u8, node.type_name, "gcp.resourcemanager.Project"))
        "project"
    else if (std.mem.eql(u8, node.type_name, "gcp.resourcemanager.Lien"))
        "lien"
    else if (std.mem.eql(u8, node.type_name, "gcp.billing.ProjectBillingAssociation"))
        "billing_association"
    else if (std.mem.eql(u8, node.type_name, "gcp.serviceusage.ServiceIdentity"))
        "service_identity"
    else if (std.mem.eql(u8, node.type_name, "gcp.project.Service"))
        "enabled_service"
    else
        return;
    try output.appendSlice(allocator, ",\"organization_foundation\":{");
    try appendNamedString(output, allocator, "kind", kind, false);
    try appendOptionalStorageString(output, allocator, node, "display_name", "display_name");
    try appendOptionalStorageString(output, allocator, node, "project_id", "project_id");
    try appendOptionalStorageString(output, allocator, node, "billing_account", "billing_account");
    try appendOptionalStorageString(output, allocator, node, "service", "service");
    try appendOptionalStorageString(output, allocator, node, "origin", "origin");
    try appendOptionalStorageString(output, allocator, node, "removal_policy", "removal_policy");
    try appendOptionalStorageBool(output, allocator, node, "request_delete", "request_delete");
    try appendStorageListCount(output, allocator, node, "restrictions", "restriction_count");
    try output.append(allocator, '}');
}

fn appendApplicationServicesDetails(output: *std.ArrayList(u8), allocator: std.mem.Allocator, node: resource.ResourceNode) !void {
    if (std.mem.eql(u8, node.type_name, "gcp.workflows.Workflow")) {
        try output.appendSlice(allocator, ",\"workflow\":{");
        try appendNamedString(output, allocator, "kind", "workflow", false);
        try appendOptionalStorageString(output, allocator, node, "workflow_id", "workflow_id");
        try appendOptionalStorageString(output, allocator, node, "location", "location");
        try appendOptionalStorageString(output, allocator, node, "source_sha256", "source_sha256");
        try appendOptionalStorageString(output, allocator, node, "call_log_level", "call_log_level");
        try appendOptionalStorageString(output, allocator, node, "execution_history", "execution_history");
        try appendOptionalStorageBool(output, allocator, node, "deletion_protection", "deletion_protection");
        try output.append(allocator, '}');
        return;
    }
    if (std.mem.startsWith(u8, node.type_name, "gcp.apigateway.")) {
        try output.appendSlice(allocator, ",\"api_gateway\":{");
        const kind = if (std.mem.eql(u8, node.type_name, "gcp.apigateway.Api"))
            "api"
        else if (std.mem.eql(u8, node.type_name, "gcp.apigateway.ApiConfig"))
            "config"
        else if (std.mem.eql(u8, node.type_name, "gcp.apigateway.Gateway"))
            "gateway"
        else
            "iam_member";
        try appendNamedString(output, allocator, "kind", kind, false);
        try appendOptionalStorageString(output, allocator, node, "api_id", "api_id");
        try appendOptionalStorageString(output, allocator, node, "config_id", "config_id");
        try appendOptionalStorageString(output, allocator, node, "gateway_id", "gateway_id");
        try appendOptionalStorageString(output, allocator, node, "location", "location");
        try appendStorageListCount(output, allocator, node, "documents", "document_count");
        try appendOptionalStorageBool(output, allocator, node, "deletion_protection", "deletion_protection");
        try output.append(allocator, '}');
        return;
    }
    if (std.mem.startsWith(u8, node.type_name, "gcp.identity.")) {
        try output.appendSlice(allocator, ",\"identity\":{");
        const kind = if (std.mem.eql(u8, node.type_name, "gcp.identity.ProjectConfig"))
            "project_config"
        else if (std.mem.eql(u8, node.type_name, "gcp.identity.Tenant"))
            "tenant"
        else if (std.mem.endsWith(u8, node.type_name, "OAuthIdpConfig"))
            "oidc"
        else if (std.mem.endsWith(u8, node.type_name, "InboundSamlConfig"))
            "saml"
        else
            "iam_member";
        try appendNamedString(output, allocator, "kind", kind, false);
        try appendOptionalStorageString(output, allocator, node, "tenant_id", "tenant_id");
        try appendOptionalStorageString(output, allocator, node, "provider_id", "provider_id");
        try appendOptionalStorageString(output, allocator, node, "display_name", "display_name");
        try appendOptionalStorageString(output, allocator, node, "mfa_state", "mfa_state");
        try appendOptionalStorageBool(output, allocator, node, "enabled", "enabled");
        try appendOptionalStorageBool(output, allocator, node, "disable_auth", "disable_auth");
        try output.append(allocator, '}');
        return;
    }
    if (std.mem.startsWith(u8, node.type_name, "gcp.parametermanager.")) {
        try output.appendSlice(allocator, ",\"parameter_manager\":{");
        const kind = if (std.mem.eql(u8, node.type_name, "gcp.parametermanager.Parameter"))
            "parameter"
        else if (std.mem.eql(u8, node.type_name, "gcp.parametermanager.ParameterVersion"))
            "parameter_version"
        else if (std.mem.eql(u8, node.type_name, "gcp.parametermanager.Template"))
            "template"
        else
            "template_version";
        try appendNamedString(output, allocator, "kind", kind, false);
        try appendOptionalStorageString(output, allocator, node, "resource_id", "resource_id");
        try appendOptionalStorageString(output, allocator, node, "parent_id", "parent_id");
        try appendOptionalStorageString(output, allocator, node, "version_id", "version_id");
        try appendOptionalStorageString(output, allocator, node, "location", "location");
        try appendOptionalStorageString(output, allocator, node, "format", "format");
        try appendOptionalStorageString(output, allocator, node, "payload_sha256", "payload_sha256");
        try appendOptionalStorageBool(output, allocator, node, "disabled", "disabled");
        try output.append(allocator, '}');
    }
}

fn appendSpannerDetails(output: *std.ArrayList(u8), allocator: std.mem.Allocator, node: resource.ResourceNode) !void {
    if (!std.mem.startsWith(u8, node.type_name, "gcp.spanner.")) return;
    try output.appendSlice(allocator, ",\"spanner\":{");
    if (std.mem.eql(u8, node.type_name, "gcp.spanner.Instance")) {
        try appendNamedString(output, allocator, "kind", "instance", false);
        try appendOptionalStorageString(output, allocator, node, "config", "config");
        try appendOptionalStorageString(output, allocator, node, "edition", "edition");
        try appendOptionalStorageString(output, allocator, node, "capacity_mode", "capacity_mode");
        try appendOptionalStorageInteger(output, allocator, node, "capacity_min", "capacity_min");
        try appendOptionalStorageInteger(output, allocator, node, "capacity_max", "capacity_max");
        try appendOptionalStorageString(output, allocator, node, "default_backup_schedule", "default_backup_schedule");
    } else if (std.mem.eql(u8, node.type_name, "gcp.spanner.Database")) {
        try appendNamedString(output, allocator, "kind", "database", false);
        try appendOptionalStorageString(output, allocator, node, "database_id", "database_id");
        try appendOptionalStorageString(output, allocator, node, "dialect", "dialect");
        try appendOptionalStorageString(output, allocator, node, "version_retention_period", "version_retention_period");
        try appendOptionalStorageBool(output, allocator, node, "drop_protection", "drop_protection");
        try appendOptionalStorageString(output, allocator, node, "kms_key_name", "kms_key_name");
        try appendJsonArrayCount(output, allocator, node, "ddl_json", "ddl_statement_count");
    } else if (std.mem.eql(u8, node.type_name, "gcp.spanner.Backup")) {
        try appendNamedString(output, allocator, "kind", "backup", false);
        try appendOptionalStorageString(output, allocator, node, "backup_id", "backup_id");
        try appendOptionalStorageString(output, allocator, node, "expire_time", "expire_time");
        try appendOptionalStorageString(output, allocator, node, "version_time", "version_time");
        try appendOptionalStorageString(output, allocator, node, "kms_key_name", "kms_key_name");
    } else if (std.mem.eql(u8, node.type_name, "gcp.spanner.BackupSchedule")) {
        try appendNamedString(output, allocator, "kind", "backup_schedule", false);
        try appendOptionalStorageString(output, allocator, node, "schedule_id", "schedule_id");
        try appendOptionalStorageString(output, allocator, node, "cron", "cron");
        try appendOptionalStorageInteger(output, allocator, node, "retention_seconds", "retention_seconds");
        try appendOptionalStorageString(output, allocator, node, "mode", "mode");
        try appendOptionalStorageString(output, allocator, node, "kms_key_name", "kms_key_name");
    } else {
        try appendNamedString(output, allocator, "kind", "iam_member", false);
        try appendOptionalStorageString(output, allocator, node, "role", "iam_role");
        try appendOptionalStorageString(output, allocator, node, "member", "iam_member");
    }
    try output.append(allocator, '}');
}

fn appendMemorystoreDetails(output: *std.ArrayList(u8), allocator: std.mem.Allocator, node: resource.ResourceNode) !void {
    if (!std.mem.startsWith(u8, node.type_name, "gcp.redis.")) return;
    try output.appendSlice(allocator, ",\"memorystore\":{");
    if (std.mem.eql(u8, node.type_name, "gcp.redis.Instance")) {
        try appendNamedString(output, allocator, "kind", "instance", false);
        try appendOptionalStorageString(output, allocator, node, "location", "location");
        try appendOptionalStorageString(output, allocator, node, "tier", "tier");
        try appendOptionalStorageInteger(output, allocator, node, "memory_size_gb", "memory_size_gb");
        try appendOptionalStorageString(output, allocator, node, "redis_version", "redis_version");
        try appendOptionalStorageString(output, allocator, node, "connect_mode", "connect_mode");
        try appendOptionalStorageString(output, allocator, node, "transit_encryption", "transit_encryption");
        try appendOptionalStorageBool(output, allocator, node, "auth_enabled", "auth_enabled");
        try appendOptionalStorageInteger(output, allocator, node, "read_replicas", "read_replicas");
        try appendOptionalStorageString(output, allocator, node, "persistence_mode", "persistence");
        try appendOptionalStorageString(output, allocator, node, "maintenance_day", "maintenance_day");
        try appendOptionalStorageInteger(output, allocator, node, "maintenance_hour_utc", "maintenance_hour_utc");
    } else if (std.mem.eql(u8, node.type_name, "gcp.redis.Cluster")) {
        try appendNamedString(output, allocator, "kind", "cluster", false);
        try appendOptionalStorageString(output, allocator, node, "location", "location");
        try appendOptionalStorageInteger(output, allocator, node, "shard_count", "shard_count");
        try appendOptionalStorageInteger(output, allocator, node, "replica_count", "replica_count");
        try appendOptionalStorageString(output, allocator, node, "node_type", "node_type");
        try appendOptionalStorageString(output, allocator, node, "authorization", "authorization");
        try appendOptionalStorageString(output, allocator, node, "transit_encryption", "transit_encryption");
        try appendOptionalStorageString(output, allocator, node, "persistence", "persistence");
        try appendOptionalStorageBool(output, allocator, node, "deletion_protection", "deletion_protection");
    } else {
        try appendNamedString(output, allocator, "kind", "acl_policy", false);
        try appendOptionalStorageString(output, allocator, node, "location", "location");
        try appendOptionalStorageString(output, allocator, node, "policy_id", "policy_id");
        try appendStorageListCount(output, allocator, node, "rules", "rule_count");
    }
    try output.append(allocator, '}');
}

fn appendPrivateConnectivityDetails(output: *std.ArrayList(u8), allocator: std.mem.Allocator, node: resource.ResourceNode) !void {
    const is_range = std.mem.eql(u8, node.type_name, "gcp.compute.PrivateServiceRange");
    const is_connection = std.mem.eql(u8, node.type_name, "gcp.servicenetworking.Connection");
    if (!is_range and !is_connection) return;
    try output.appendSlice(allocator, ",\"private_connectivity\":{");
    try appendNamedString(output, allocator, "kind", if (is_range) "range" else "connection", false);
    try appendOptionalStorageString(output, allocator, node, "network", "network");
    if (is_range) {
        try appendOptionalStorageString(output, allocator, node, "name", "name");
        try appendOptionalStorageString(output, allocator, node, "address", "address");
        try appendOptionalStorageInteger(output, allocator, node, "prefix_length", "prefix_length");
        try appendOptionalStorageString(output, allocator, node, "purpose", "purpose");
    } else {
        try appendOptionalStorageString(output, allocator, node, "service", "service");
        try appendOptionalStorageString(output, allocator, node, "reserved_ranges", "reserved_ranges");
    }
    try output.append(allocator, '}');
}

fn appendCloudSqlDetails(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
) !void {
    if (!std.mem.startsWith(u8, node.type_name, "gcp.sql.")) return;
    try output.appendSlice(allocator, ",\"cloud_sql\":{");
    if (std.mem.eql(u8, node.type_name, "gcp.sql.Instance") or std.mem.eql(u8, node.type_name, "gcp.sql.ReadReplica")) {
        try appendNamedString(output, allocator, "kind", "instance", false);
        try appendOptionalStorageString(output, allocator, node, "database_version", "engine");
        try appendOptionalStorageString(output, allocator, node, "edition", "edition");
        try appendOptionalStorageString(output, allocator, node, "availability", "availability");
        try appendNamedString(output, allocator, "role", if (std.mem.eql(u8, node.type_name, "gcp.sql.ReadReplica")) "read_replica" else "primary", true);
        try appendNamedBool(output, allocator, "private_ip", nonEmptyInputString(node, "private_network"), true);
        try appendOptionalStorageBool(output, allocator, node, "ipv4_enabled", "public_ip");
        try appendOptionalStorageBool(output, allocator, node, "backup_enabled", "backup");
        try appendOptionalStorageBool(output, allocator, node, "point_in_time_recovery", "pitr");
        try appendOptionalStorageString(output, allocator, node, "ssl_mode", "ssl_mode");
        try appendOptionalStorageString(output, allocator, node, "connector_enforcement", "connector_enforcement");
    } else if (std.mem.eql(u8, node.type_name, "gcp.sql.Database")) {
        try appendNamedString(output, allocator, "kind", "database", false);
        try appendOptionalStorageString(output, allocator, node, "instance_id", "instance_id");
        try appendOptionalStorageString(output, allocator, node, "name", "name");
        try appendOptionalStorageString(output, allocator, node, "charset", "charset");
    } else if (std.mem.eql(u8, node.type_name, "gcp.sql.User")) {
        try appendNamedString(output, allocator, "kind", "user", false);
        try appendOptionalStorageString(output, allocator, node, "instance_id", "instance_id");
        try appendOptionalStorageString(output, allocator, node, "name", "name");
        try appendOptionalStorageString(output, allocator, node, "user_type", "user_type");
    } else {
        try appendNamedString(output, allocator, "kind", "client_certificate", false);
        try appendOptionalStorageString(output, allocator, node, "instance_id", "instance_id");
        try appendOptionalStorageString(output, allocator, node, "common_name", "common_name");
    }
    try output.append(allocator, '}');
}

fn nonEmptyInputString(node: resource.ResourceNode, name: []const u8) bool {
    const present = objectField(node.inputs, name) orelse return false;
    return present == .string and present.string.len > 0;
}

fn appendFirestoreDetails(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
) !void {
    if (!std.mem.startsWith(u8, node.type_name, "gcp.firestore.")) return;
    try output.appendSlice(allocator, ",\"firestore\":{");
    if (std.mem.eql(u8, node.type_name, "gcp.firestore.Database")) {
        try appendNamedString(output, allocator, "kind", "database", false);
        try appendOptionalStorageString(output, allocator, node, "database_id", "database_id");
        try appendOptionalStorageString(output, allocator, node, "location", "location");
        try appendOptionalStorageString(output, allocator, node, "database_type", "database_type");
        try appendOptionalStorageString(output, allocator, node, "edition", "edition");
        try appendOptionalStorageBool(output, allocator, node, "point_in_time_recovery", "point_in_time_recovery");
        try appendOptionalStorageBool(output, allocator, node, "delete_protection", "delete_protection");
        try appendOptionalStorageString(output, allocator, node, "kms_key_name", "kms_key_name");
    } else if (std.mem.eql(u8, node.type_name, "gcp.firestore.Index")) {
        try appendNamedString(output, allocator, "kind", "index", false);
        try appendOptionalStorageString(output, allocator, node, "database_id", "database_id");
        try appendOptionalStorageString(output, allocator, node, "collection_group", "collection_group");
        try appendOptionalStorageString(output, allocator, node, "query_scope", "query_scope");
        try appendOptionalStorageString(output, allocator, node, "api_scope", "api_scope");
        try appendJsonArrayCount(output, allocator, node, "fields_json", "field_count");
    } else if (std.mem.eql(u8, node.type_name, "gcp.firestore.Field")) {
        try appendNamedString(output, allocator, "kind", "field", false);
        try appendOptionalStorageString(output, allocator, node, "database_id", "database_id");
        try appendOptionalStorageString(output, allocator, node, "collection_group", "collection_group");
        try appendOptionalStorageString(output, allocator, node, "field_path", "field_path");
        try appendOptionalStorageBool(output, allocator, node, "ttl_enabled", "ttl_enabled");
        try appendJsonArrayCount(output, allocator, node, "index_modes_json", "index_mode_count");
    } else if (std.mem.eql(u8, node.type_name, "gcp.firestore.BackupSchedule")) {
        try appendNamedString(output, allocator, "kind", "backup_schedule", false);
        try appendOptionalStorageString(output, allocator, node, "database_id", "database_id");
        try appendOptionalStorageString(output, allocator, node, "recurrence", "recurrence");
        try appendOptionalStorageString(output, allocator, node, "day_of_week", "day_of_week");
        try appendOptionalStorageInteger(output, allocator, node, "retention_seconds", "retention_seconds");
    } else {
        try appendNamedString(output, allocator, "kind", "iam_member", false);
        try appendOptionalStorageString(output, allocator, node, "role", "iam_role");
        try appendOptionalStorageString(output, allocator, node, "member", "iam_member");
    }
    try output.append(allocator, '}');
}

fn appendJsonArrayCount(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    input_name: []const u8,
    output_name: []const u8,
) !void {
    const encoded = objectField(node.inputs, input_name) orelse return;
    if (encoded != .string) return;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, encoded.string, .{}) catch return;
    defer parsed.deinit();
    const count = switch (parsed.value) {
        .array => |array| array.items.len,
        else => return,
    };
    try appendNamedUnsigned(output, allocator, output_name, count, true);
}

fn appendBigqueryDetails(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
) !void {
    if (!std.mem.startsWith(u8, node.type_name, "gcp.bigquery.")) return;
    try output.appendSlice(allocator, ",\"bigquery\":{");
    if (std.mem.eql(u8, node.type_name, "gcp.bigquery.Dataset")) {
        try appendNamedString(output, allocator, "kind", "dataset", false);
        try appendOptionalStorageString(output, allocator, node, "location", "location");
        try appendOptionalStorageString(output, allocator, node, "kms_key_name", "kms_key_name");
        try appendOptionalStorageInteger(output, allocator, node, "default_table_expiration_ms", "default_table_expiration_ms");
    } else if (std.mem.eql(u8, node.type_name, "gcp.bigquery.Table")) {
        try appendNamedString(output, allocator, "kind", "table", false);
        try appendOptionalStorageString(output, allocator, node, "dataset_id", "dataset_id");
        try appendSchemaFieldCount(output, allocator, node);
        try appendOptionalStorageBool(output, allocator, node, "require_partition_filter", "require_partition_filter");
        try appendStorageListCount(output, allocator, node, "clustering_fields", "clustering_field_count");
    } else if (std.mem.eql(u8, node.type_name, "gcp.bigquery.View")) {
        try appendNamedString(output, allocator, "kind", "view", false);
        try appendOptionalStorageString(output, allocator, node, "dataset_id", "dataset_id");
        try appendOptionalStorageBool(output, allocator, node, "use_legacy_sql", "use_legacy_sql");
    } else if (std.mem.eql(u8, node.type_name, "gcp.bigquery.Routine")) {
        try appendNamedString(output, allocator, "kind", "routine", false);
        try appendOptionalStorageString(output, allocator, node, "dataset_id", "dataset_id");
        try appendOptionalStorageString(output, allocator, node, "routine_type", "routine_type");
        try appendOptionalStorageString(output, allocator, node, "language", "language");
    } else if (std.mem.eql(u8, node.type_name, "gcp.bigquery.Connection")) {
        try appendNamedString(output, allocator, "kind", "connection", false);
        try appendOptionalStorageString(output, allocator, node, "location", "location");
        try appendOptionalStorageString(output, allocator, node, "connection_kind", "connection_kind");
    } else if (std.mem.eql(u8, node.type_name, "gcp.bigquery.Reservation")) {
        try appendNamedString(output, allocator, "kind", "reservation", false);
        try appendOptionalStorageString(output, allocator, node, "location", "location");
        try appendOptionalStorageInteger(output, allocator, node, "slot_capacity", "slot_capacity");
    } else if (std.mem.eql(u8, node.type_name, "gcp.bigquery.CapacityCommitment")) {
        try appendNamedString(output, allocator, "kind", "capacity_commitment", false);
        try appendOptionalStorageString(output, allocator, node, "location", "location");
        try appendOptionalStorageInteger(output, allocator, node, "slot_count", "slot_count");
        try appendOptionalStorageString(output, allocator, node, "plan", "plan");
    } else if (std.mem.eql(u8, node.type_name, "gcp.bigquery.ReservationAssignment")) {
        try appendNamedString(output, allocator, "kind", "reservation_assignment", false);
        try appendOptionalStorageString(output, allocator, node, "location", "location");
        try appendOptionalStorageString(output, allocator, node, "assignee", "assignee");
    } else {
        try appendNamedString(output, allocator, "kind", "iam_member", false);
        try appendOptionalStorageString(output, allocator, node, "role", "iam_role");
        try appendOptionalStorageString(output, allocator, node, "member", "iam_member");
    }
    try output.append(allocator, '}');
}

fn appendSchemaFieldCount(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
) !void {
    const schema_json = objectField(node.inputs, "schema_json") orelse return;
    if (schema_json != .string) return;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, schema_json.string, .{}) catch return;
    defer parsed.deinit();
    const count = switch (parsed.value) {
        .array => |array| array.items.len,
        else => return,
    };
    try appendNamedUnsigned(output, allocator, "schema_field_count", count, true);
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

fn appendStorageObjectCount(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    input_name: []const u8,
    output_name: []const u8,
) !void {
    const input = objectField(node.inputs, input_name) orelse return;
    if (input == .object) try appendNamedUnsigned(output, allocator, output_name, input.object.len, true);
}

fn appendJsonArrayStringCount(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    input_name: []const u8,
    output_name: []const u8,
) !void {
    const input = objectField(node.inputs, input_name) orelse return;
    if (input != .string) return;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, input.string, .{}) catch return error.InvalidVisualArtifact;
    defer parsed.deinit();
    if (parsed.value == .array) try appendNamedUnsigned(output, allocator, output_name, parsed.value.array.items.len, true);
}

fn resourceScope(node: resource.ResourceNode, regions: []const []const u8) []const u8 {
    if (std.mem.eql(u8, node.type_name, "gcp.orgpolicy.Policy")) {
        const parent = objectString(node, "parent") orelse return "hierarchy";
        if (std.mem.startsWith(u8, parent, "organizations/")) return "organization";
        if (std.mem.startsWith(u8, parent, "folders/")) return "folder";
        return "project";
    }
    if (std.mem.eql(u8, node.type_name, "gcp.orgpolicy.CustomConstraint") or
        std.mem.eql(u8, node.type_name, "gcp.tags.TagKey") or
        std.mem.eql(u8, node.type_name, "gcp.tags.TagValue") or
        std.mem.eql(u8, node.type_name, "gcp.tags.TagHold") or
        std.mem.startsWith(u8, node.type_name, "gcp.accesscontextmanager.")) return "organization";
    if (std.mem.eql(u8, node.type_name, "gcp.tags.TagBinding")) return "project";
    if (std.mem.startsWith(u8, node.type_name, "gcp.securitycenter.")) {
        const parent = objectString(node, "parent") orelse objectString(node, "organization") orelse return "hierarchy";
        if (std.mem.startsWith(u8, parent, "organizations/")) return "organization";
        if (std.mem.startsWith(u8, parent, "folders/")) return "folder";
        return "project";
    }
    if (std.mem.eql(u8, node.type_name, "gcp.resourcemanager.Folder")) return "folder";
    if (std.mem.eql(u8, node.type_name, "gcp.resourcemanager.Project") or
        std.mem.eql(u8, node.type_name, "gcp.resourcemanager.Lien") or
        std.mem.eql(u8, node.type_name, "gcp.billing.ProjectBillingAssociation") or
        std.mem.eql(u8, node.type_name, "gcp.serviceusage.ServiceIdentity")) return "project";
    if (isGlobalType(node.type_name)) return "global";
    if (objectField(node.inputs, "zone")) |zone| if (zone == .string and zone.string.len > 0) return "zonal";
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
        std.mem.eql(u8, type_name, "gcp.compute.ManagedSslCertificate") or
        std.mem.eql(u8, type_name, "gcp.compute.BackendBucket") or
        std.mem.eql(u8, type_name, "gcp.compute.SecurityPolicy") or
        std.mem.eql(u8, type_name, "gcp.compute.SslPolicy") or
        std.mem.eql(u8, type_name, "gcp.compute.CertificateMapTargetHttpsProxy") or
        std.mem.eql(u8, type_name, "gcp.compute.ExternalVpnGateway") or
        std.mem.eql(u8, type_name, "gcp.compute.NetworkPeering") or
        std.mem.eql(u8, type_name, "gcp.networkconnectivity.Hub") or
        std.mem.startsWith(u8, type_name, "gcp.certificatemanager.") or
        std.mem.eql(u8, type_name, "gcp.compute.Image") or
        std.mem.eql(u8, type_name, "gcp.compute.InstanceTemplate");
}

fn edgeKind(from_node: ?resource.ResourceNode, to_id: []const u8, from_type: []const u8, to_type: []const u8) []const u8 {
    if (std.mem.eql(u8, from_type, "gcp.securitycenter.NotificationConfig") and std.mem.eql(u8, to_type, "gcp.pubsub.Topic")) return "finding_notification";
    if (std.mem.eql(u8, from_type, "gcp.securitycenter.BigQueryExport") and std.mem.eql(u8, to_type, "gcp.bigquery.Dataset")) return "finding_export";
    if (std.mem.eql(u8, from_type, "gcp.binaryauthorization.Policy") and std.mem.eql(u8, to_type, "gcp.binaryauthorization.Attestor")) return "admission_attestor";
    if (std.mem.eql(u8, from_type, "gcp.privateca.CertificateAuthority") and std.mem.eql(u8, to_type, "gcp.privateca.CaPool")) return "trust_pool";
    if (std.mem.eql(u8, from_type, "gcp.privateca.Certificate") and std.mem.eql(u8, to_type, "gcp.privateca.CertificateTemplate")) return "certificate_template";
    if (std.mem.eql(u8, from_type, "gcp.privateca.Certificate") and std.mem.eql(u8, to_type, "gcp.privateca.CertificateAuthority")) return "certificate_issuer";
    if (std.mem.eql(u8, from_type, "gcp.orgpolicy.Policy") and
        (std.mem.eql(u8, to_type, "gcp.resourcemanager.Project") or std.mem.eql(u8, to_type, "gcp.resourcemanager.Folder"))) return "policy_scope";
    if (std.mem.eql(u8, from_type, "gcp.tags.TagValue") and std.mem.eql(u8, to_type, "gcp.tags.TagKey")) return "tag_membership";
    if (std.mem.eql(u8, from_type, "gcp.tags.TagBinding")) return "tag_assignment";
    if (std.mem.eql(u8, from_type, "gcp.tags.TagHold") and std.mem.eql(u8, to_type, "gcp.tags.TagValue")) return "tag_hold";
    if (std.mem.eql(u8, from_type, "gcp.accesscontextmanager.AccessLevel") and std.mem.eql(u8, to_type, "gcp.accesscontextmanager.AccessPolicy")) return "access_policy_membership";
    if (std.mem.eql(u8, from_type, "gcp.accesscontextmanager.ServicePerimeter") and std.mem.eql(u8, to_type, "gcp.accesscontextmanager.AccessPolicy")) return "perimeter_policy";
    if (std.mem.eql(u8, from_type, "gcp.accesscontextmanager.ServicePerimeter") and std.mem.eql(u8, to_type, "gcp.accesscontextmanager.AccessLevel")) return "perimeter_access";
    if (std.mem.eql(u8, from_type, "gcp.accesscontextmanager.ServicePerimeter") and
        (std.mem.eql(u8, to_type, "gcp.resourcemanager.Project") or std.mem.startsWith(u8, to_type, "gcp.compute.Network"))) return "perimeter_membership";
    if (std.mem.eql(u8, from_type, "gcp.accesscontextmanager.GcpUserAccessBinding") and std.mem.eql(u8, to_type, "gcp.accesscontextmanager.AccessLevel")) return "user_access";
    if (std.mem.eql(u8, from_type, "gcp.resourcemanager.Project") and std.mem.eql(u8, to_type, "gcp.resourcemanager.Folder")) return "hierarchy_parent";
    if (std.mem.eql(u8, from_type, "gcp.billing.ProjectBillingAssociation") and std.mem.eql(u8, to_type, "gcp.resourcemanager.Project")) return "billing_attachment";
    if (std.mem.eql(u8, from_type, "gcp.project.Service") and std.mem.eql(u8, to_type, "gcp.resourcemanager.Project")) return "api_enablement";
    if (std.mem.eql(u8, from_type, "gcp.serviceusage.ServiceIdentity") and std.mem.eql(u8, to_type, "gcp.resourcemanager.Project")) return "service_identity";
    if (std.mem.eql(u8, from_type, "gcp.resourcemanager.Lien") and std.mem.eql(u8, to_type, "gcp.resourcemanager.Project")) return "deletion_guard";
    if (std.mem.eql(u8, from_type, "gcp.kms.CryptoKey") and std.mem.eql(u8, to_type, "gcp.kms.KeyRing")) return "key_membership";
    if (std.mem.eql(u8, from_type, "gcp.kms.CryptoKeyVersion") and std.mem.eql(u8, to_type, "gcp.kms.CryptoKey")) return "key_version";
    if (std.mem.eql(u8, from_type, "gcp.secret.Secret") and std.mem.eql(u8, to_type, "gcp.kms.CryptoKey")) return "customer_managed_encryption";
    if (std.mem.eql(u8, from_type, "gcp.secret.SecretVersion") and std.mem.eql(u8, to_type, "gcp.secret.Secret")) return "secret_version";
    if (std.mem.eql(u8, from_type, "gcp.deploy.DeliveryPipeline") and std.mem.eql(u8, to_type, "gcp.deploy.Target")) return "delivery_stage";
    if (std.mem.eql(u8, from_type, "gcp.deploy.Automation") and std.mem.eql(u8, to_type, "gcp.deploy.DeliveryPipeline")) return "pipeline_automation";
    if (std.mem.eql(u8, from_type, "gcp.deploy.Target") and
        (std.mem.eql(u8, to_type, "gcp.run.Service") or std.mem.eql(u8, to_type, "gcp.container.Cluster") or std.mem.eql(u8, to_type, "gcp.gkehub.Membership"))) return "deployment_target";
    if (std.mem.eql(u8, from_type, "gcp.cloudbuild.Repository") and std.mem.eql(u8, to_type, "gcp.cloudbuild.Connection")) return "source_connection";
    if (std.mem.eql(u8, from_type, "gcp.cloudbuild.Trigger") and std.mem.eql(u8, to_type, "gcp.cloudbuild.Repository")) return "trigger_source";
    if (std.mem.eql(u8, from_type, "gcp.cloudbuild.Trigger") and std.mem.eql(u8, to_type, "gcp.cloudbuild.WorkerPool")) return "private_execution";
    if (std.mem.eql(u8, from_type, "gcp.cloudbuild.Trigger") and std.mem.eql(u8, to_type, "gcp.artifact.Repository")) return "build_artifact";
    if (std.mem.eql(u8, from_type, "gcp.logging.View") and std.mem.eql(u8, to_type, "gcp.logging.Bucket")) return "log_view";
    if (std.mem.eql(u8, from_type, "gcp.logging.Sink") and std.mem.eql(u8, to_type, "gcp.logging.Bucket")) return "log_route";
    if (std.mem.eql(u8, from_type, "gcp.logging.Metric") and std.mem.eql(u8, to_type, "gcp.logging.Bucket")) return "log_metric";
    if (std.mem.eql(u8, from_type, "gcp.monitoring.ServiceLevelObjective") and std.mem.eql(u8, to_type, "gcp.monitoring.Service")) return "service_slo";
    if (std.mem.eql(u8, from_type, "gcp.monitoring.UptimeCheck") and std.mem.eql(u8, to_type, "gcp.monitoring.Service")) return "probe_target";
    if (std.mem.eql(u8, from_type, "gcp.monitoring.AlertPolicy") and std.mem.eql(u8, to_type, "gcp.monitoring.UptimeCheck")) return "policy_evaluation";
    if (std.mem.eql(u8, from_type, "gcp.monitoring.AlertPolicy") and std.mem.eql(u8, to_type, "gcp.monitoring.NotificationChannel")) return "notification";
    if (std.mem.eql(u8, from_type, "gcp.monitoring.Dashboard") and std.mem.startsWith(u8, to_type, "gcp.monitoring.")) return "dashboard_visualizes";
    if (std.mem.eql(u8, from_type, "gcp.container.NodePool") and std.mem.eql(u8, to_type, "gcp.container.Cluster")) return "node_pool";
    if (std.mem.eql(u8, from_type, "gcp.gkehub.Membership") and
        (std.mem.eql(u8, to_type, "gcp.gkehub.Fleet") or std.mem.eql(u8, to_type, "gcp.container.Cluster"))) return "fleet_membership";
    if (from_node) |node| if (std.mem.eql(u8, from_type, "gcp.iam.ServiceAccountIamMember") and
        std.mem.eql(u8, objectString(node, "role") orelse "", "roles/iam.workloadIdentityUser")) return "workload_identity";
    if ((std.mem.eql(u8, from_type, "gcp.container.NodePool") or
        std.mem.eql(u8, from_type, "gcp.functions.FunctionV2") or
        std.mem.eql(u8, from_type, "gcp.batch.Job")) and
        std.mem.eql(u8, to_type, "gcp.iam.ServiceAccount")) return "runtime_identity";
    if (std.mem.eql(u8, from_type, "gcp.functions.FunctionV2") and std.mem.eql(u8, to_type, "gcp.pubsub.Topic")) return "event";
    if (std.mem.eql(u8, from_type, "gcp.compute.BackendBucket") and std.mem.eql(u8, to_type, "gcp.storage.Bucket")) return "cache_origin";
    if (std.mem.eql(u8, from_type, "gcp.compute.BackendBucket") and std.mem.eql(u8, to_type, "gcp.compute.SecurityPolicy")) return "security_enforcement";
    if (std.mem.eql(u8, from_type, "gcp.certificatemanager.Certificate") and std.mem.eql(u8, to_type, "gcp.certificatemanager.DnsAuthorization")) return "dns_authorization";
    if ((std.mem.eql(u8, from_type, "gcp.certificatemanager.CertificateMapEntry") and
        (std.mem.eql(u8, to_type, "gcp.certificatemanager.Certificate") or std.mem.eql(u8, to_type, "gcp.certificatemanager.CertificateMap"))) or
        (std.mem.eql(u8, from_type, "gcp.compute.CertificateMapTargetHttpsProxy") and std.mem.eql(u8, to_type, "gcp.certificatemanager.CertificateMap"))) return "certificate_selection";
    if (std.mem.eql(u8, from_type, "gcp.compute.CertificateMapTargetHttpsProxy") and std.mem.eql(u8, to_type, "gcp.compute.SslPolicy")) return "tls_policy";
    if ((std.mem.eql(u8, from_type, "gcp.compute.VpnTunnel") and
        (std.mem.eql(u8, to_type, "gcp.compute.HaVpnGateway") or std.mem.eql(u8, to_type, "gcp.compute.ExternalVpnGateway") or std.mem.eql(u8, to_type, "gcp.compute.Router"))) or
        (std.mem.eql(u8, from_type, "gcp.compute.RouterInterface") and std.mem.eql(u8, to_type, "gcp.compute.VpnTunnel"))) return "vpn_attachment";
    if (std.mem.eql(u8, from_type, "gcp.compute.RouterBgpPeer") and
        (std.mem.eql(u8, to_type, "gcp.compute.RouterInterface") or std.mem.eql(u8, to_type, "gcp.compute.Router"))) return "bgp_session";
    if (std.mem.eql(u8, from_type, "gcp.networkconnectivity.Spoke") and std.mem.eql(u8, to_type, "gcp.networkconnectivity.Hub")) return "hub_membership";
    if (std.mem.eql(u8, from_type, "gcp.networkconnectivity.Spoke") and std.mem.eql(u8, to_type, "gcp.compute.VpnTunnel")) return "hub_attachment";
    if (std.mem.eql(u8, from_type, "gcp.pubsub.Subscription") and std.mem.eql(u8, to_type, "gcp.pubsub.Topic")) return "event";
    if (std.mem.eql(u8, from_type, "gcp.eventarc.Trigger") and
        (std.mem.eql(u8, to_type, "gcp.pubsub.Topic") or std.mem.eql(u8, to_type, "gcp.run.Service"))) return "event";
    if (std.mem.startsWith(u8, from_type, "gcp.tasks.Queue") and std.mem.eql(u8, to_type, "gcp.run.Service")) return "event";
    if (std.mem.indexOf(u8, from_type, "IamMember") != null or
        std.mem.indexOf(u8, from_type, "IamBinding") != null or
        std.mem.indexOf(u8, from_type, "IamPolicy") != null or
        std.mem.startsWith(u8, from_type, "gcp.iam.")) return "iam";
    if (isPrivateTrafficPair(from_type, to_type)) return "private_traffic";
    if (std.mem.eql(u8, from_type, "gcp.compute.RegionBackendService") and
        (std.mem.eql(u8, to_type, "gcp.compute.RegionHealthCheck") or std.mem.eql(u8, to_type, "gcp.compute.HealthCheck"))) return "health_probe";
    if (from_node) |node| if (containsOutputReference(node.inputs, to_id)) return "output";
    if (isTrafficPair(from_type, to_type)) return "traffic";
    if (std.mem.startsWith(u8, from_type, "cockroach.") != std.mem.startsWith(u8, to_type, "cockroach.")) {
        return "connectivity";
    }
    return "dependency";
}

fn isPrivateTrafficPair(from_type: []const u8, to_type: []const u8) bool {
    return (std.mem.eql(u8, from_type, "gcp.compute.ForwardingRule") and
        (std.mem.eql(u8, to_type, "gcp.compute.RegionBackendService") or std.mem.eql(u8, to_type, "gcp.compute.RegionTargetHttpProxy"))) or
        (std.mem.eql(u8, from_type, "gcp.compute.RegionTargetHttpProxy") and std.mem.eql(u8, to_type, "gcp.compute.RegionUrlMap")) or
        (std.mem.eql(u8, from_type, "gcp.compute.RegionUrlMap") and std.mem.eql(u8, to_type, "gcp.compute.RegionBackendService"));
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
