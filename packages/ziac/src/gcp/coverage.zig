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
    artifact_registry,
    cloud_build,
    cloud_run,
    compute,
    dns,
    eventarc,
    iam,
    kms,
    pubsub,
    scheduler,
    service_usage,
    storage,
    tasks,
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
    managed("gcp.artifact.Repository", .artifact_registry, .location, .google_rest, "M4", full),
    managed("gcp.cloudbuild.ZigImage", .cloud_build, .global, .google_rest, "M8", retained_replaceable),
    managed("gcp.compute.BackendService", .compute, .global, .google_discovery, "M5", full),
    managed("gcp.compute.GlobalAddress", .compute, .global, .google_discovery, "M5", full),
    managed("gcp.compute.GlobalForwardingRule", .compute, .global, .google_discovery, "M5", full),
    managed("gcp.compute.HttpRedirectUrlMap", .compute, .global, .google_discovery, "M5", full),
    managed("gcp.compute.ManagedSslCertificate", .compute, .global, .google_discovery, "M5", replaceable),
    managed("gcp.compute.Network", .compute, .global, .google_discovery, "M5", full),
    managed("gcp.compute.PscAddress", .compute, .region, .google_discovery, "M7", full),
    managed("gcp.compute.PscEndpoint", .compute, .region, .google_discovery, "M7", full),
    managed("gcp.compute.RegionServerlessNeg", .compute, .region, .google_discovery, "M5", full),
    managed("gcp.compute.RegionalAddress", .compute, .region, .google_discovery, "M5", full),
    managed("gcp.compute.Router", .compute, .region, .google_discovery, "M5", full),
    managed("gcp.compute.RouterNat", .compute, .region, .google_discovery, "M5", full),
    managed("gcp.compute.Subnetwork", .compute, .region, .google_discovery, "M5", full),
    managed("gcp.compute.TargetHttpProxy", .compute, .global, .google_discovery, "M5", full),
    managed("gcp.compute.TargetHttpsProxy", .compute, .global, .google_discovery, "M5", full),
    managed("gcp.compute.UrlMap", .compute, .global, .google_discovery, "M5", full),
    managed("gcp.dns.ManagedZone", .dns, .global, .google_discovery, "M5", full),
    managed("gcp.dns.RecordSet", .dns, .global, .google_discovery, "M5", full),
    managed("gcp.eventarc.Trigger", .eventarc, .location, .googleapis_proto, "M59", withProduct(full)),
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
    managed("gcp.kms.CryptoKey", .kms, .location, .google_rest, "M26", retained),
    managed("gcp.kms.KeyRing", .kms, .location, .google_rest, "M26", retained_replaceable),
    managed("gcp.project.Service", .service_usage, .project, .googleapis_proto, "M4", replaceable),
    managed("gcp.pubsub.Schema", .pubsub, .project, .googleapis_proto, "M58", withVisual(full)),
    managed("gcp.pubsub.Snapshot", .pubsub, .project, .googleapis_proto, "M58", withVisualCost(full)),
    managed("gcp.pubsub.Subscription", .pubsub, .project, .googleapis_proto, "M58", withProduct(full)),
    managed("gcp.pubsub.SubscriptionIamMember", .pubsub, .project, .google_rest, "M58", withVisual(additive_iam)),
    managed("gcp.pubsub.Topic", .pubsub, .project, .googleapis_proto, "M58", withProduct(full)),
    managed("gcp.pubsub.TopicIamMember", .pubsub, .project, .google_rest, "M58", withVisual(additive_iam)),
    managed("gcp.run.Job", .cloud_run, .region, .googleapis_proto, "M60", withProduct(full)),
    managed("gcp.run.JobIamMember", .cloud_run, .region, .googleapis_proto, "M60", withVisual(additive_iam)),
    managed("gcp.run.Service", .cloud_run, .region, .googleapis_proto, "M4", withProduct(full)),
    managed("gcp.run.ServiceIamMember", .cloud_run, .region, .googleapis_proto, "M58", withVisual(additive_iam)),
    managed("gcp.run.WorkerPool", .cloud_run, .region, .googleapis_proto, "M60", withProduct(full)),
    managed("gcp.scheduler.Job", .scheduler, .region, .googleapis_proto, "M36", full),
    managed("gcp.secret.Secret", .iam, .project, .googleapis_proto, "M4", full),
    managed("gcp.secret.SecretIamMember", .iam, .project, .google_rest, "M4", additive_iam),
    managed("gcp.secret.SecretVersion", .iam, .project, .googleapis_proto, "M4", replaceable),
    managed("gcp.storage.Bucket", .storage, .global, .google_discovery, "M57", withProduct(full)),
    managed("gcp.storage.BucketIamMember", .storage, .global, .google_rest, "M57", withProduct(additive_iam)),
    managed("gcp.storage.BuildBucket", .storage, .global, .google_discovery, "M8", retained),
    managed("gcp.storage.Object", .storage, .global, .google_discovery, "M57", withProduct(replaceable)),
    managed("gcp.storage.SourceObject", .storage, .global, .google_discovery, "M8", retained_replaceable),
    managed("gcp.tasks.Queue", .tasks, .location, .googleapis_proto, "M59", withProduct(full)),
    managed("gcp.tasks.QueueIamMember", .tasks, .location, .google_rest, "M59", withVisual(additive_iam)),
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
