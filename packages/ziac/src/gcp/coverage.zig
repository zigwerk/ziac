const std = @import("std");

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
    plannedResource("gcp.eventarc.Trigger", .eventarc, .location, .googleapis_proto, "M59"),
    plannedResource("gcp.iam.ProjectBinding", .iam, .project, .google_rest, "M61"),
    managed("gcp.iam.ProjectMember", .iam, .project, .google_rest, "M4", additive_iam),
    plannedResource("gcp.iam.ProjectPolicy", .iam, .project, .google_rest, "M61"),
    managed("gcp.iam.ServiceAccount", .iam, .project, .google_rest, "M4", full),
    plannedResource("gcp.iam.ServiceAccountIamMember", .iam, .project, .google_rest, "M61"),
    plannedResource("gcp.iam.WorkloadIdentityPool", .iam, .global, .google_rest, "M61"),
    plannedResource("gcp.iam.WorkloadIdentityPoolProvider", .iam, .global, .google_rest, "M61"),
    managed("gcp.kms.CryptoKey", .kms, .location, .google_rest, "M26", retained),
    managed("gcp.kms.KeyRing", .kms, .location, .google_rest, "M26", retained_replaceable),
    managed("gcp.project.Service", .service_usage, .project, .googleapis_proto, "M4", replaceable),
    plannedResource("gcp.pubsub.Schema", .pubsub, .project, .googleapis_proto, "M58"),
    plannedResource("gcp.pubsub.Snapshot", .pubsub, .project, .googleapis_proto, "M58"),
    plannedResource("gcp.pubsub.Subscription", .pubsub, .project, .googleapis_proto, "M58"),
    plannedResource("gcp.pubsub.SubscriptionIamMember", .pubsub, .project, .google_rest, "M58"),
    plannedResource("gcp.pubsub.Topic", .pubsub, .project, .googleapis_proto, "M58"),
    plannedResource("gcp.pubsub.TopicIamMember", .pubsub, .project, .google_rest, "M58"),
    plannedResource("gcp.run.Job", .cloud_run, .region, .googleapis_proto, "M60"),
    managed("gcp.run.Service", .cloud_run, .region, .googleapis_proto, "M4", withProduct(full)),
    plannedResource("gcp.run.WorkerPool", .cloud_run, .region, .googleapis_proto, "M60"),
    managed("gcp.scheduler.Job", .scheduler, .region, .googleapis_proto, "M36", full),
    managed("gcp.secret.Secret", .iam, .project, .googleapis_proto, "M4", full),
    managed("gcp.secret.SecretIamMember", .iam, .project, .google_rest, "M4", additive_iam),
    managed("gcp.secret.SecretVersion", .iam, .project, .googleapis_proto, "M4", replaceable),
    managed("gcp.storage.Bucket", .storage, .global, .google_discovery, "M57", withProduct(full)),
    managed("gcp.storage.BucketIamMember", .storage, .global, .google_rest, "M57", withProduct(additive_iam)),
    managed("gcp.storage.BuildBucket", .storage, .global, .google_discovery, "M8", retained),
    plannedResource("gcp.storage.Object", .storage, .global, .google_discovery, "M57"),
    managed("gcp.storage.SourceObject", .storage, .global, .google_discovery, "M8", retained_replaceable),
    plannedResource("gcp.tasks.Queue", .tasks, .location, .googleapis_proto, "M59"),
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
