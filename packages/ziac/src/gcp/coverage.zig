const std = @import("std");
const discovery_contract = @import("discovery_contract.zig");
const proto_contract = @import("proto_contract.zig");

pub const Stage = enum {
    planned,
    contract,
    managed,
    qualified,
};

pub const Service = enum {
    api_gateway,
    artifact_registry,
    batch,
    bigquery,
    certificate_manager,
    cloud_build,
    cloud_functions,
    cloud_run,
    compute,
    container,
    dns,
    eventarc,
    firestore,
    gke_hub,
    iam,
    identity_platform,
    kms,
    network_connectivity,
    parameter_manager,
    pubsub,
    redis,
    scheduler,
    service_networking,
    service_usage,
    spanner,
    sql_admin,
    storage,
    tasks,
    workflows,
};

pub const Scope = enum {
    organization,
    folder,
    project,
    global,
    region,
    zone,
    location,
};

pub const Contract = enum {
    googleapis_proto,
    google_discovery,
    google_rest,
};

pub const Capabilities = struct {
    declaration: bool = false,
    read: bool = false,
    create: bool = false,
    update: bool = false,
    delete_resource: bool = false,
    import_resource: bool = false,
    iam: bool = false,
    estate: bool = false,
    visual: bool = false,
    cost: bool = false,

    pub fn any(self: Capabilities) bool {
        return self.declaration or self.read or self.create or self.update or
            self.delete_resource or self.import_resource or self.iam or
            self.estate or self.visual or self.cost;
    }
};

pub const Resource = struct {
    type_name: []const u8,
    service: Service,
    scope: Scope,
    stage: Stage,
    contract: Contract,
    milestone: []const u8,
    capabilities: Capabilities,
};

const full = Capabilities{
    .declaration = true,
    .read = true,
    .create = true,
    .update = true,
    .delete_resource = true,
    .import_resource = true,
};

const replaceable = Capabilities{
    .declaration = true,
    .read = true,
    .create = true,
    .delete_resource = true,
    .import_resource = true,
};

const additive_iam = Capabilities{
    .declaration = true,
    .read = true,
    .create = true,
    .delete_resource = true,
    .import_resource = true,
    .iam = true,
};

const authoritative_iam = Capabilities{
    .declaration = true,
    .read = true,
    .create = true,
    .update = true,
    .delete_resource = true,
    .import_resource = true,
    .iam = true,
};

const retained = Capabilities{
    .declaration = true,
    .read = true,
    .create = true,
    .update = true,
    .import_resource = true,
};

const retained_replaceable = Capabilities{
    .declaration = true,
    .read = true,
    .create = true,
    .import_resource = true,
};

const planned = Capabilities{};

pub const resources = [_]Resource{
    managed("gcp.apigateway.Api", .api_gateway, .global, .google_discovery, "M67", withProduct(full)),
    managed("gcp.apigateway.ApiConfig", .api_gateway, .global, .google_discovery, "M67", withProduct(replaceable)),
    managed("gcp.apigateway.ApiConfigIamMember", .api_gateway, .global, .google_rest, "M67", withVisual(additive_iam)),
    managed("gcp.apigateway.ApiIamMember", .api_gateway, .global, .google_rest, "M67", withVisual(additive_iam)),
    managed("gcp.apigateway.Gateway", .api_gateway, .region, .google_discovery, "M67", withProduct(full)),
    managed("gcp.apigateway.GatewayIamMember", .api_gateway, .region, .google_rest, "M67", withVisual(additive_iam)),
    managed("gcp.artifact.Repository", .artifact_registry, .location, .google_rest, "M4", full),
    managed("gcp.batch.Job", .batch, .location, .google_discovery, "M72", withVisualCost(replaceable)),
    managed("gcp.bigquery.CapacityCommitment", .bigquery, .location, .googleapis_proto, "M63", withVisualCost(retained_replaceable)),
    managed("gcp.bigquery.Connection", .bigquery, .location, .googleapis_proto, "M63", withVisualCost(full)),
    managed("gcp.bigquery.ConnectionIamMember", .bigquery, .location, .google_rest, "M63", withVisualCost(additive_iam)),
    managed("gcp.bigquery.Dataset", .bigquery, .location, .google_rest, "M63", withProduct(full)),
    managed("gcp.bigquery.DatasetIamMember", .bigquery, .location, .google_rest, "M63", withVisualCost(additive_iam)),
    managed("gcp.bigquery.Reservation", .bigquery, .location, .googleapis_proto, "M63", withProduct(full)),
    managed("gcp.bigquery.ReservationAssignment", .bigquery, .location, .googleapis_proto, "M63", withVisualCost(replaceable)),
    managed("gcp.bigquery.ReservationIamMember", .bigquery, .location, .google_rest, "M63", withVisualCost(additive_iam)),
    managed("gcp.bigquery.Routine", .bigquery, .location, .google_rest, "M63", withProduct(full)),
    managed("gcp.bigquery.RoutineIamMember", .bigquery, .location, .google_rest, "M63", withVisualCost(additive_iam)),
    managed("gcp.bigquery.Table", .bigquery, .location, .google_rest, "M63", withProduct(full)),
    managed("gcp.bigquery.TableIamMember", .bigquery, .location, .google_rest, "M63", withVisualCost(additive_iam)),
    managed("gcp.bigquery.View", .bigquery, .location, .google_rest, "M63", withVisualCost(full)),
    managed("gcp.certificatemanager.Certificate", .certificate_manager, .location, .googleapis_proto, "M70", withProduct(replaceable)),
    managed("gcp.certificatemanager.CertificateMap", .certificate_manager, .location, .googleapis_proto, "M70", withProduct(replaceable)),
    managed("gcp.certificatemanager.CertificateMapEntry", .certificate_manager, .location, .googleapis_proto, "M70", withProduct(replaceable)),
    managed("gcp.certificatemanager.DnsAuthorization", .certificate_manager, .location, .googleapis_proto, "M70", withProduct(replaceable)),
    managed("gcp.cloudbuild.ZigImage", .cloud_build, .global, .google_rest, "M8", retained_replaceable),
    managed("gcp.compute.Autoscaler", .compute, .zone, .google_discovery, "M68", withProduct(full)),
    managed("gcp.compute.BackendBucket", .compute, .global, .google_discovery, "M70", withProduct(full)),
    managed("gcp.compute.BackendService", .compute, .global, .google_discovery, "M5", full),
    managed("gcp.compute.CertificateMapTargetHttpsProxy", .compute, .global, .google_discovery, "M70", withProduct(replaceable)),
    managed("gcp.compute.Disk", .compute, .zone, .google_discovery, "M68", withProduct(full)),
    managed("gcp.compute.ExternalVpnGateway", .compute, .global, .google_discovery, "M71", withProduct(replaceable)),
    managed("gcp.compute.Firewall", .compute, .global, .google_discovery, "M69", withProduct(full)),
    managed("gcp.compute.ForwardingRule", .compute, .region, .google_discovery, "M69", withProduct(replaceable)),
    managed("gcp.compute.GlobalAddress", .compute, .global, .google_discovery, "M5", full),
    managed("gcp.compute.GlobalForwardingRule", .compute, .global, .google_discovery, "M5", full),
    managed("gcp.compute.HaVpnGateway", .compute, .region, .google_discovery, "M71", withProduct(replaceable)),
    managed("gcp.compute.HealthCheck", .compute, .global, .google_discovery, "M69", withProduct(full)),
    managed("gcp.compute.HttpRedirectUrlMap", .compute, .global, .google_discovery, "M5", full),
    managed("gcp.compute.Image", .compute, .global, .google_discovery, "M68", withProduct(replaceable)),
    managed("gcp.compute.Instance", .compute, .zone, .google_discovery, "M68", withProduct(replaceable)),
    managed("gcp.compute.InstanceGroupManager", .compute, .zone, .google_discovery, "M68", withProduct(full)),
    managed("gcp.compute.InstanceTemplate", .compute, .global, .google_discovery, "M68", withProduct(replaceable)),
    managed("gcp.compute.InternalAddress", .compute, .region, .google_discovery, "M69", withProduct(retained_replaceable)),
    managed("gcp.compute.ManagedSslCertificate", .compute, .global, .google_discovery, "M5", replaceable),
    managed("gcp.compute.Network", .compute, .global, .google_discovery, "M5", full),
    managed("gcp.compute.NetworkPeering", .compute, .global, .google_discovery, "M71", withProduct(full)),
    managed("gcp.compute.PrivateServiceRange", .compute, .global, .google_discovery, "M66", withVisual(replaceable)),
    managed("gcp.compute.PscAddress", .compute, .region, .google_discovery, "M7", full),
    managed("gcp.compute.PscEndpoint", .compute, .region, .google_discovery, "M7", full),
    managed("gcp.compute.RegionAutoscaler", .compute, .region, .google_discovery, "M68", withProduct(full)),
    managed("gcp.compute.RegionBackendService", .compute, .region, .google_discovery, "M69", withProduct(full)),
    managed("gcp.compute.RegionDisk", .compute, .region, .google_discovery, "M68", withProduct(full)),
    managed("gcp.compute.RegionHealthCheck", .compute, .region, .google_discovery, "M69", withProduct(full)),
    managed("gcp.compute.RegionInstanceGroupManager", .compute, .region, .google_discovery, "M68", withProduct(full)),
    managed("gcp.compute.RegionServerlessNeg", .compute, .region, .google_discovery, "M5", full),
    managed("gcp.compute.RegionTargetHttpProxy", .compute, .region, .google_discovery, "M69", withProduct(full)),
    managed("gcp.compute.RegionUrlMap", .compute, .region, .google_discovery, "M69", withProduct(full)),
    managed("gcp.compute.RegionalAddress", .compute, .region, .google_discovery, "M5", full),
    managed("gcp.compute.Route", .compute, .global, .google_discovery, "M69", withProduct(replaceable)),
    managed("gcp.compute.Router", .compute, .region, .google_discovery, "M5", full),
    managed("gcp.compute.RouterBgpPeer", .compute, .region, .google_discovery, "M71", withProduct(full)),
    managed("gcp.compute.RouterInterface", .compute, .region, .google_discovery, "M71", withProduct(full)),
    managed("gcp.compute.RouterNat", .compute, .region, .google_discovery, "M5", full),
    managed("gcp.compute.SecurityPolicy", .compute, .global, .google_discovery, "M70", withProduct(full)),
    managed("gcp.compute.SslPolicy", .compute, .global, .google_discovery, "M70", withProduct(full)),
    managed("gcp.compute.Subnetwork", .compute, .region, .google_discovery, "M5", full),
    managed("gcp.compute.TargetHttpProxy", .compute, .global, .google_discovery, "M5", full),
    managed("gcp.compute.TargetHttpsProxy", .compute, .global, .google_discovery, "M5", full),
    managed("gcp.compute.UrlMap", .compute, .global, .google_discovery, "M5", full),
    managed("gcp.compute.VpnTunnel", .compute, .region, .google_discovery, "M71", withProduct(replaceable)),
    managed("gcp.container.Cluster", .container, .location, .google_discovery, "M72", withProduct(full)),
    managed("gcp.container.NodePool", .container, .location, .google_discovery, "M72", withProduct(full)),
    managed("gcp.dns.ManagedZone", .dns, .global, .google_discovery, "M5", full),
    managed("gcp.dns.RecordSet", .dns, .global, .google_discovery, "M5", full),
    managed("gcp.eventarc.Trigger", .eventarc, .location, .googleapis_proto, "M59", withProduct(full)),
    managed("gcp.firestore.BackupSchedule", .firestore, .location, .googleapis_proto, "M64", withVisualCost(full)),
    managed("gcp.firestore.Database", .firestore, .location, .googleapis_proto, "M64", withProduct(full)),
    managed("gcp.firestore.DatabaseIamMember", .firestore, .location, .google_rest, "M64", withVisualCost(additive_iam)),
    managed("gcp.firestore.Field", .firestore, .location, .googleapis_proto, "M64", withVisualCost(full)),
    managed("gcp.firestore.Index", .firestore, .location, .googleapis_proto, "M64", withVisualCost(replaceable)),
    managed("gcp.functions.FunctionIamMember", .cloud_functions, .region, .google_rest, "M72", withVisual(additive_iam)),
    managed("gcp.functions.FunctionV2", .cloud_functions, .region, .google_discovery, "M72", withProduct(full)),
    managed("gcp.gkehub.Fleet", .gke_hub, .global, .google_discovery, "M72", withProduct(full)),
    managed("gcp.gkehub.Membership", .gke_hub, .location, .google_discovery, "M72", withProduct(full)),
    managed("gcp.iam.FolderBinding", .iam, .folder, .google_rest, "M61", authoritative_iam),
    managed("gcp.iam.FolderMember", .iam, .folder, .google_rest, "M61", additive_iam),
    managed("gcp.iam.FolderPolicy", .iam, .folder, .google_rest, "M61", authoritative_iam),
    managed("gcp.iam.OrganizationBinding", .iam, .organization, .google_rest, "M61", authoritative_iam),
    managed("gcp.iam.OrganizationCustomRole", .iam, .organization, .google_rest, "M61", full),
    managed("gcp.iam.OrganizationMember", .iam, .organization, .google_rest, "M61", additive_iam),
    managed("gcp.iam.OrganizationPolicy", .iam, .organization, .google_rest, "M61", authoritative_iam),
    managed("gcp.iam.ProjectBinding", .iam, .project, .google_rest, "M61", authoritative_iam),
    managed("gcp.iam.ProjectCustomRole", .iam, .project, .google_rest, "M61", full),
    managed("gcp.iam.ProjectMember", .iam, .project, .google_rest, "M4", additive_iam),
    managed("gcp.iam.ProjectPolicy", .iam, .project, .google_rest, "M61", authoritative_iam),
    managed("gcp.iam.ServiceAccount", .iam, .project, .google_rest, "M4", full),
    managed("gcp.iam.ServiceAccountIamBinding", .iam, .project, .google_rest, "M61", authoritative_iam),
    managed("gcp.iam.ServiceAccountIamMember", .iam, .project, .google_rest, "M61", additive_iam),
    managed("gcp.iam.WorkloadIdentityPool", .iam, .global, .google_rest, "M61", full),
    managed("gcp.iam.WorkloadIdentityPoolProvider", .iam, .global, .google_rest, "M61", full),
    managed("gcp.identity.ProjectConfig", .identity_platform, .project, .google_discovery, "M67", withProduct(retained)),
    managed("gcp.identity.ProjectInboundSamlConfig", .identity_platform, .project, .google_discovery, "M67", withProduct(full)),
    managed("gcp.identity.ProjectOAuthIdpConfig", .identity_platform, .project, .google_discovery, "M67", withProduct(full)),
    managed("gcp.identity.Tenant", .identity_platform, .project, .google_discovery, "M67", withProduct(full)),
    managed("gcp.identity.TenantIamMember", .identity_platform, .project, .google_rest, "M67", withVisual(additive_iam)),
    managed("gcp.identity.TenantInboundSamlConfig", .identity_platform, .project, .google_discovery, "M67", withProduct(full)),
    managed("gcp.identity.TenantOAuthIdpConfig", .identity_platform, .project, .google_discovery, "M67", withProduct(full)),
    managed("gcp.kms.CryptoKey", .kms, .location, .google_rest, "M26", retained),
    managed("gcp.kms.KeyRing", .kms, .location, .google_rest, "M26", retained_replaceable),
    managed("gcp.networkconnectivity.Hub", .network_connectivity, .global, .google_discovery, "M71", withProduct(full)),
    managed("gcp.networkconnectivity.ServiceConnectionPolicy", .network_connectivity, .region, .google_discovery, "M71", withProduct(full)),
    managed("gcp.networkconnectivity.Spoke", .network_connectivity, .global, .google_discovery, "M71", withProduct(full)),
    managed("gcp.parametermanager.Parameter", .parameter_manager, .location, .google_discovery, "M67", withProduct(full)),
    managed("gcp.parametermanager.ParameterVersion", .parameter_manager, .location, .google_discovery, "M67", withProduct(full)),
    managed("gcp.parametermanager.Template", .parameter_manager, .location, .google_discovery, "M67", withProduct(full)),
    managed("gcp.parametermanager.TemplateVersion", .parameter_manager, .location, .google_discovery, "M67", withProduct(full)),
    managed("gcp.project.Service", .service_usage, .project, .googleapis_proto, "M4", replaceable),
    managed("gcp.pubsub.Schema", .pubsub, .project, .googleapis_proto, "M58", withVisual(full)),
    managed("gcp.pubsub.Snapshot", .pubsub, .project, .googleapis_proto, "M58", withVisualCost(full)),
    managed("gcp.pubsub.Subscription", .pubsub, .project, .googleapis_proto, "M58", withProduct(full)),
    managed("gcp.pubsub.SubscriptionIamMember", .pubsub, .project, .google_rest, "M58", withVisual(additive_iam)),
    managed("gcp.pubsub.Topic", .pubsub, .project, .googleapis_proto, "M58", withProduct(full)),
    managed("gcp.pubsub.TopicIamMember", .pubsub, .project, .google_rest, "M58", withVisual(additive_iam)),
    managed("gcp.redis.AclPolicy", .redis, .region, .google_discovery, "M66", withVisual(full)),
    managed("gcp.redis.Cluster", .redis, .region, .google_discovery, "M66", withProduct(full)),
    managed("gcp.redis.Instance", .redis, .region, .google_discovery, "M66", withProduct(full)),
    managed("gcp.run.Job", .cloud_run, .region, .googleapis_proto, "M60", withProduct(full)),
    managed("gcp.run.JobIamMember", .cloud_run, .region, .googleapis_proto, "M60", withVisual(additive_iam)),
    managed("gcp.run.Service", .cloud_run, .region, .googleapis_proto, "M4", withProduct(full)),
    managed("gcp.run.ServiceIamMember", .cloud_run, .region, .googleapis_proto, "M58", withVisual(additive_iam)),
    managed("gcp.run.WorkerPool", .cloud_run, .region, .googleapis_proto, "M60", withProduct(full)),
    managed("gcp.scheduler.Job", .scheduler, .region, .googleapis_proto, "M36", full),
    managed("gcp.secret.Secret", .iam, .project, .googleapis_proto, "M4", full),
    managed("gcp.secret.SecretIamMember", .iam, .project, .google_rest, "M4", additive_iam),
    managed("gcp.secret.SecretVersion", .iam, .project, .googleapis_proto, "M4", replaceable),
    managed("gcp.servicenetworking.Connection", .service_networking, .global, .google_discovery, "M66", withVisual(full)),
    managed("gcp.spanner.Backup", .spanner, .location, .google_discovery, "M66", withProduct(full)),
    managed("gcp.spanner.BackupSchedule", .spanner, .location, .google_discovery, "M66", withVisual(full)),
    managed("gcp.spanner.Database", .spanner, .location, .google_discovery, "M66", withProduct(full)),
    managed("gcp.spanner.DatabaseIamMember", .spanner, .location, .google_rest, "M66", withVisual(additive_iam)),
    managed("gcp.spanner.Instance", .spanner, .global, .google_discovery, "M66", withProduct(full)),
    managed("gcp.spanner.InstanceIamMember", .spanner, .global, .google_rest, "M66", withVisual(additive_iam)),
    managed("gcp.sql.ClientCertificate", .sql_admin, .region, .google_discovery, "M65", withVisualCost(replaceable)),
    managed("gcp.sql.Database", .sql_admin, .region, .google_discovery, "M65", withVisualCost(full)),
    managed("gcp.sql.Instance", .sql_admin, .region, .google_discovery, "M65", withProduct(full)),
    managed("gcp.sql.ReadReplica", .sql_admin, .region, .google_discovery, "M65", withVisualCost(full)),
    managed("gcp.sql.User", .sql_admin, .region, .google_discovery, "M65", withVisualCost(full)),
    managed("gcp.storage.Bucket", .storage, .global, .google_discovery, "M57", withProduct(full)),
    managed("gcp.storage.BucketIamMember", .storage, .global, .google_rest, "M57", withProduct(additive_iam)),
    managed("gcp.storage.BuildBucket", .storage, .global, .google_discovery, "M8", retained),
    managed("gcp.storage.Object", .storage, .global, .google_discovery, "M57", withProduct(replaceable)),
    managed("gcp.storage.SourceObject", .storage, .global, .google_discovery, "M8", retained_replaceable),
    managed("gcp.tasks.Queue", .tasks, .location, .googleapis_proto, "M59", withProduct(full)),
    managed("gcp.tasks.QueueIamMember", .tasks, .location, .google_rest, "M59", withVisual(additive_iam)),
    managed("gcp.workflows.Workflow", .workflows, .location, .google_discovery, "M67", withProduct(full)),
};

pub const ValidationError = error{
    DuplicateType,
    InvalidManagedCapabilities,
    InvalidPlannedCapabilities,
    InvalidTypeName,
    MissingMilestone,
    UnsortedTypes,
};

pub fn validate() ValidationError!void {
    for (resources, 0..) |entry, index| {
        if (!std.mem.startsWith(u8, entry.type_name, "gcp.") or entry.type_name.len <= "gcp.".len) {
            return error.InvalidTypeName;
        }
        if (entry.milestone.len == 0) return error.MissingMilestone;
        if (entry.stage == .planned and entry.capabilities.any()) return error.InvalidPlannedCapabilities;
        if ((entry.stage == .managed or entry.stage == .qualified) and
            (!entry.capabilities.declaration or !entry.capabilities.read or !entry.capabilities.create))
        {
            return error.InvalidManagedCapabilities;
        }
        if (index > 0) {
            const order = std.mem.order(u8, resources[index - 1].type_name, entry.type_name);
            if (order == .eq) return error.DuplicateType;
            if (order == .gt) return error.UnsortedTypes;
        }
    }
}

pub fn find(type_name: []const u8) ?Resource {
    var low: usize = 0;
    var high: usize = resources.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        switch (std.mem.order(u8, type_name, resources[middle].type_name)) {
            .eq => return resources[middle],
            .lt => high = middle,
            .gt => low = middle + 1,
        }
    }
    return null;
}

pub const Filter = struct {
    service: ?Service = null,
};

pub fn parseService(value: []const u8) ?Service {
    inline for (@typeInfo(Service).@"enum".fields) |field| {
        if (serviceNameMatches(value, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

pub fn jsonAlloc(allocator: std.mem.Allocator, filter: Filter) std.mem.Allocator.Error![]u8 {
    var selected: std.ArrayList(Resource) = .empty;
    defer selected.deinit(allocator);
    for (resources) |entry| {
        if (filter.service) |service| if (entry.service != service) continue;
        try selected.append(allocator, entry);
    }
    return std.json.Stringify.valueAlloc(allocator, .{
        .schema = "ziac.gcp.provider-coverage.v1",
        .filter = if (filter.service) |service| @tagName(service) else null,
        .contracts = .{
            .googleapis_revision = proto_contract.googleapis_revision,
            .proto_descriptor_sha256 = proto_contract.descriptor_sha256,
            .proto_snapshot_sha256 = proto_contract.snapshot_sha256,
            .discovery_pinned_at = discovery_contract.pinned_at,
            .discovery = &discovery_contract.sources,
        },
        .resources = selected.items,
    }, .{}) catch return error.OutOfMemory;
}

pub fn markdownAlloc(allocator: std.mem.Allocator, filter: Filter) std.mem.Allocator.Error![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "# Ziac GCP Provider Resources\n\n");
    try output.print(allocator, "Google APIs contract: `{s}`  \n", .{proto_contract.googleapis_revision});
    try output.print(allocator, "Proto descriptor: `{s}`  \n", .{proto_contract.descriptor_sha256});
    try output.print(allocator, "Discovery contracts pinned: `{s}`\n\n", .{discovery_contract.pinned_at});
    try output.appendSlice(allocator, "| Resource | Service | Scope | Stage | Contract | Milestone | Capabilities |\n");
    try output.appendSlice(allocator, "| --- | --- | --- | --- | --- | --- | --- |\n");
    for (resources) |entry| {
        if (filter.service) |service| if (entry.service != service) continue;
        try output.print(allocator, "| `{s}` | {s} | {s} | {s} | {s} | {s} | ", .{
            entry.type_name,
            @tagName(entry.service),
            @tagName(entry.scope),
            @tagName(entry.stage),
            @tagName(entry.contract),
            entry.milestone,
        });
        try appendCapabilities(&output, allocator, entry.capabilities);
        try output.appendSlice(allocator, " |\n");
    }
    return output.toOwnedSlice(allocator);
}

fn appendCapabilities(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: Capabilities) !void {
    var first = true;
    inline for (@typeInfo(Capabilities).@"struct".fields) |field| {
        if (@field(value, field.name)) {
            if (!first) try output.appendSlice(allocator, ", ");
            try output.appendSlice(allocator, field.name);
            first = false;
        }
    }
    if (first) try output.appendSlice(allocator, "planned");
}

fn serviceNameMatches(value: []const u8, enum_name: []const u8) bool {
    if (value.len != enum_name.len) return false;
    for (value, enum_name) |left, right| {
        if (left != right and !(left == '-' and right == '_')) return false;
    }
    return true;
}

fn managed(
    type_name: []const u8,
    service: Service,
    scope: Scope,
    contract: Contract,
    milestone: []const u8,
    capabilities: Capabilities,
) Resource {
    return .{
        .type_name = type_name,
        .service = service,
        .scope = scope,
        .stage = .managed,
        .contract = contract,
        .milestone = milestone,
        .capabilities = capabilities,
    };
}

fn plannedResource(
    type_name: []const u8,
    service: Service,
    scope: Scope,
    contract: Contract,
    milestone: []const u8,
) Resource {
    return .{
        .type_name = type_name,
        .service = service,
        .scope = scope,
        .stage = .planned,
        .contract = contract,
        .milestone = milestone,
        .capabilities = planned,
    };
}

fn withProduct(capabilities: Capabilities) Capabilities {
    var result = capabilities;
    result.estate = true;
    result.visual = true;
    result.cost = true;
    return result;
}

fn withVisual(capabilities: Capabilities) Capabilities {
    var result = capabilities;
    result.visual = true;
    return result;
}

fn withVisualCost(capabilities: Capabilities) Capabilities {
    var result = withVisual(capabilities);
    result.cost = true;
    return result;
}
