const std = @import("std");
const global = @import("global/root.zig");
const resource = @import("../resource.zig");

pub const RpcUsage = struct {
    service: []const u8,
    method: []const u8,
};

pub const Requirements = struct {
    apis: []const []const u8,
    methods: []const []const u8,
    permissions: []const []const u8,

    pub fn deinit(self: *Requirements, allocator: std.mem.Allocator) void {
        freeStrings(allocator, self.apis);
        freeStrings(allocator, self.methods);
        freeStrings(allocator, self.permissions);
        self.* = undefined;
    }

    pub fn hasPermission(self: Requirements, permission: []const u8) bool {
        return contains(self.permissions, permission);
    }
};

pub fn synthesize(allocator: std.mem.Allocator, usages: []const RpcUsage) std.mem.Allocator.Error!Requirements {
    var apis: std.ArrayList([]const u8) = .empty;
    errdefer deinitList(allocator, &apis);
    var permissions: std.ArrayList([]const u8) = .empty;
    errdefer deinitList(allocator, &permissions);
    var methods: std.ArrayList([]const u8) = .empty;
    errdefer deinitList(allocator, &methods);
    for (usages) |usage| {
        try appendUnique(allocator, &apis, usage.service);
        try appendUnique(allocator, &methods, usage.method);
        if (permissionForMethod(usage.method)) |permission| try appendUnique(allocator, &permissions, permission);
    }
    std.mem.sort([]const u8, apis.items, {}, lessThan);
    std.mem.sort([]const u8, methods.items, {}, lessThan);
    std.mem.sort([]const u8, permissions.items, {}, lessThan);
    return .{
        .apis = try apis.toOwnedSlice(allocator),
        .methods = try methods.toOwnedSlice(allocator),
        .permissions = try permissions.toOwnedSlice(allocator),
    };
}

pub fn synthesizeGraph(allocator: std.mem.Allocator, graph: *const resource.ResourceGraph) std.mem.Allocator.Error!Requirements {
    var usages: std.ArrayList(RpcUsage) = .empty;
    defer usages.deinit(allocator);
    for (graph.resources.items) |node| {
        const contracts = rpcUsagesForType(node.type_name);
        try usages.appendSlice(allocator, contracts);
    }
    return synthesize(allocator, usages.items);
}

pub const FindingKind = enum {
    api_disabled,
    permission_denied,
    billing_disabled,
    region_unavailable,
    quota_insufficient,
    org_policy_denied,
    vpc_service_controls_denied,
};

pub const Finding = struct {
    kind: FindingKind,
    subject: []const u8,
};

pub const PreflightInventory = struct {
    enabled_apis: []const []const u8 = &.{},
    granted_permissions: []const []const u8 = &.{},
    billing_enabled: bool = false,
    available_regions: []const []const u8 = &.{},
    requested_regions: []const []const u8 = &.{},
    quota_sufficient: bool = true,
    org_policy_allows: bool = true,
    vpc_service_controls_allows: bool = true,
};

pub const PreflightReport = struct {
    ready: bool,
    findings: []Finding,

    pub fn deinit(self: *PreflightReport, allocator: std.mem.Allocator) void {
        for (self.findings) |finding| allocator.free(finding.subject);
        allocator.free(self.findings);
        self.* = undefined;
    }

    pub fn hasFinding(self: PreflightReport, kind: FindingKind) bool {
        for (self.findings) |finding| if (finding.kind == kind) return true;
        return false;
    }
};

pub fn evaluatePreflight(
    allocator: std.mem.Allocator,
    requirements: Requirements,
    inventory: PreflightInventory,
) std.mem.Allocator.Error!PreflightReport {
    var findings: std.ArrayList(Finding) = .empty;
    errdefer deinitFindings(allocator, &findings);
    for (requirements.apis) |api| if (!contains(inventory.enabled_apis, api)) {
        try appendFinding(allocator, &findings, .api_disabled, api);
    };
    for (requirements.permissions) |permission| if (!contains(inventory.granted_permissions, permission)) {
        try appendFinding(allocator, &findings, .permission_denied, permission);
    };
    if (!inventory.billing_enabled) try appendFinding(allocator, &findings, .billing_disabled, "billing");
    for (inventory.requested_regions) |region| if (!contains(inventory.available_regions, region)) {
        try appendFinding(allocator, &findings, .region_unavailable, region);
    };
    if (!inventory.quota_sufficient) try appendFinding(allocator, &findings, .quota_insufficient, "quota");
    if (!inventory.org_policy_allows) try appendFinding(allocator, &findings, .org_policy_denied, "org-policy");
    if (!inventory.vpc_service_controls_allows) try appendFinding(allocator, &findings, .vpc_service_controls_denied, "vpc-service-controls");
    const owned = try findings.toOwnedSlice(allocator);
    return .{ .ready = owned.len == 0, .findings = owned };
}

pub const AdviceFinding = enum {
    residency_violation,
    database_locality_gap,
    private_connectivity_requires_fleet,
    independent_canary_requires_fleet,
};

pub const TopologyPolicy = struct {
    cloud_run_regions: []const []const u8,
    cockroach_regions: []const []const u8,
    allowed_regions: []const []const u8 = &.{},
    require_private_connectivity: bool = false,
    independent_canary: bool = false,
};

pub const TopologyAdvice = struct {
    realization: global.Realization,
    declared_regions: []const []const u8,
    findings: []AdviceFinding,

    pub fn deinit(self: *TopologyAdvice, allocator: std.mem.Allocator) void {
        freeStrings(allocator, self.declared_regions);
        allocator.free(self.findings);
        self.* = undefined;
    }

    pub fn hasFinding(self: TopologyAdvice, kind: AdviceFinding) bool {
        for (self.findings) |finding| if (finding == kind) return true;
        return false;
    }
};

pub fn adviseTopology(allocator: std.mem.Allocator, policy: TopologyPolicy) std.mem.Allocator.Error!TopologyAdvice {
    var findings: std.ArrayList(AdviceFinding) = .empty;
    defer findings.deinit(allocator);
    if (policy.require_private_connectivity) try findings.append(allocator, .private_connectivity_requires_fleet);
    if (policy.independent_canary) try findings.append(allocator, .independent_canary_requires_fleet);
    for (policy.cloud_run_regions) |region| {
        if (policy.allowed_regions.len > 0 and !contains(policy.allowed_regions, region)) {
            try appendEnumUnique(&findings, allocator, .residency_violation);
        }
        if (!contains(policy.cockroach_regions, region)) {
            try appendEnumUnique(&findings, allocator, .database_locality_gap);
        }
    }
    const declared = try dupeStrings(allocator, policy.cloud_run_regions);
    errdefer freeStrings(allocator, declared);
    const owned_findings = try allocator.dupe(AdviceFinding, findings.items);
    return .{
        .realization = if (policy.require_private_connectivity or policy.independent_canary)
            .controlled_regional_fleet
        else
            .native_multi_region,
        .declared_regions = declared,
        .findings = owned_findings,
    };
}

pub const AssetDrift = struct {
    missing: bool,
    unexpected: bool,
    reconciling: bool,
};

pub const DriftDisposition = enum { clean, wait, repair, import_or_remove };

pub fn classifyAssetDrift(drift: AssetDrift) DriftDisposition {
    if (drift.reconciling) return .wait;
    if (drift.missing) return .repair;
    if (drift.unexpected) return .import_or_remove;
    return .clean;
}

pub const RolloutSignal = struct {
    availability: f64,
    latency_p95_millis: u64,
    error_budget_remaining: f64,
};

pub const RolloutGate = struct {
    minimum_availability: f64 = 0.999,
    maximum_latency_p95_millis: u64 = 1000,
    minimum_error_budget_remaining: f64 = 0.1,
};

pub fn rolloutAllowed(signal: RolloutSignal, gate: RolloutGate) bool {
    return signal.availability >= gate.minimum_availability and
        signal.latency_p95_millis <= gate.maximum_latency_p95_millis and
        signal.error_budget_remaining >= gate.minimum_error_budget_remaining;
}

fn permissionForMethod(method: []const u8) ?[]const u8 {
    const mappings = [_]struct { suffix: []const u8, permission: []const u8 }{
        .{ .suffix = "Services.CreateService", .permission = "run.services.create" },
        .{ .suffix = "Services.GetService", .permission = "run.services.get" },
        .{ .suffix = "Services.ListServices", .permission = "run.services.list" },
        .{ .suffix = "Services.UpdateService", .permission = "run.services.update" },
        .{ .suffix = "Services.DeleteService", .permission = "run.services.delete" },
        .{ .suffix = "Services.GetIamPolicy", .permission = "run.services.getIamPolicy" },
        .{ .suffix = "Services.SetIamPolicy", .permission = "run.services.setIamPolicy" },
        .{ .suffix = "Services.TestIamPermissions", .permission = "run.services.getIamPolicy" },
        .{ .suffix = "Publisher.GetTopic", .permission = "pubsub.topics.get" },
        .{ .suffix = "Publisher.CreateTopic", .permission = "pubsub.topics.create" },
        .{ .suffix = "Publisher.UpdateTopic", .permission = "pubsub.topics.update" },
        .{ .suffix = "Publisher.DeleteTopic", .permission = "pubsub.topics.delete" },
        .{ .suffix = "Publisher.GetIamPolicy", .permission = "pubsub.topics.getIamPolicy" },
        .{ .suffix = "Publisher.SetIamPolicy", .permission = "pubsub.topics.setIamPolicy" },
        .{ .suffix = "Subscriber.GetSubscription", .permission = "pubsub.subscriptions.get" },
        .{ .suffix = "Subscriber.CreateSubscription", .permission = "pubsub.subscriptions.create" },
        .{ .suffix = "Subscriber.UpdateSubscription", .permission = "pubsub.subscriptions.update" },
        .{ .suffix = "Subscriber.DeleteSubscription", .permission = "pubsub.subscriptions.delete" },
        .{ .suffix = "Subscriber.GetIamPolicy", .permission = "pubsub.subscriptions.getIamPolicy" },
        .{ .suffix = "Subscriber.SetIamPolicy", .permission = "pubsub.subscriptions.setIamPolicy" },
        .{ .suffix = "Subscriber.GetSnapshot", .permission = "pubsub.snapshots.get" },
        .{ .suffix = "Subscriber.CreateSnapshot", .permission = "pubsub.snapshots.create" },
        .{ .suffix = "Subscriber.UpdateSnapshot", .permission = "pubsub.snapshots.update" },
        .{ .suffix = "Subscriber.DeleteSnapshot", .permission = "pubsub.snapshots.delete" },
        .{ .suffix = "SchemaService.GetSchema", .permission = "pubsub.schemas.get" },
        .{ .suffix = "SchemaService.CreateSchema", .permission = "pubsub.schemas.create" },
        .{ .suffix = "SchemaService.CommitSchema", .permission = "pubsub.schemas.commit" },
        .{ .suffix = "SchemaService.DeleteSchema", .permission = "pubsub.schemas.delete" },
        .{ .suffix = "IAM.GetServiceAccount", .permission = "iam.serviceAccounts.get" },
        .{ .suffix = "IAM.CreateServiceAccount", .permission = "iam.serviceAccounts.create" },
        .{ .suffix = "IAM.PatchServiceAccount", .permission = "iam.serviceAccounts.update" },
        .{ .suffix = "IAM.DeleteServiceAccount", .permission = "iam.serviceAccounts.delete" },
        .{ .suffix = "backendServices.insert", .permission = "compute.backendServices.create" },
        .{ .suffix = "backendServices.get", .permission = "compute.backendServices.get" },
        .{ .suffix = "networkEndpointGroups.insert", .permission = "compute.networkEndpointGroups.create" },
    };
    for (mappings) |mapping| if (std.mem.endsWith(u8, method, mapping.suffix)) return mapping.permission;
    return null;
}

fn rpcUsagesForType(type_name: []const u8) []const RpcUsage {
    const run = [_]RpcUsage{
        .{ .service = "run.googleapis.com", .method = "google.cloud.run.v2.Services.GetService" },
        .{ .service = "run.googleapis.com", .method = "google.cloud.run.v2.Services.CreateService" },
        .{ .service = "run.googleapis.com", .method = "google.cloud.run.v2.Services.UpdateService" },
        .{ .service = "run.googleapis.com", .method = "google.cloud.run.v2.Services.DeleteService" },
    };
    const run_iam = [_]RpcUsage{
        .{ .service = "run.googleapis.com", .method = "google.cloud.run.v2.Services.GetIamPolicy" },
        .{ .service = "run.googleapis.com", .method = "google.cloud.run.v2.Services.SetIamPolicy" },
    };
    const iam_service_account = [_]RpcUsage{
        .{ .service = "iam.googleapis.com", .method = "google.iam.admin.v1.IAM.GetServiceAccount" },
        .{ .service = "iam.googleapis.com", .method = "google.iam.admin.v1.IAM.CreateServiceAccount" },
        .{ .service = "iam.googleapis.com", .method = "google.iam.admin.v1.IAM.PatchServiceAccount" },
        .{ .service = "iam.googleapis.com", .method = "google.iam.admin.v1.IAM.DeleteServiceAccount" },
    };
    const pubsub_topic = [_]RpcUsage{
        .{ .service = "pubsub.googleapis.com", .method = "google.pubsub.v1.Publisher.GetTopic" },
        .{ .service = "pubsub.googleapis.com", .method = "google.pubsub.v1.Publisher.CreateTopic" },
        .{ .service = "pubsub.googleapis.com", .method = "google.pubsub.v1.Publisher.UpdateTopic" },
        .{ .service = "pubsub.googleapis.com", .method = "google.pubsub.v1.Publisher.DeleteTopic" },
    };
    const pubsub_topic_iam = [_]RpcUsage{
        .{ .service = "pubsub.googleapis.com", .method = "google.pubsub.v1.Publisher.GetIamPolicy" },
        .{ .service = "pubsub.googleapis.com", .method = "google.pubsub.v1.Publisher.SetIamPolicy" },
    };
    const pubsub_subscription = [_]RpcUsage{
        .{ .service = "pubsub.googleapis.com", .method = "google.pubsub.v1.Subscriber.GetSubscription" },
        .{ .service = "pubsub.googleapis.com", .method = "google.pubsub.v1.Subscriber.CreateSubscription" },
        .{ .service = "pubsub.googleapis.com", .method = "google.pubsub.v1.Subscriber.UpdateSubscription" },
        .{ .service = "pubsub.googleapis.com", .method = "google.pubsub.v1.Subscriber.DeleteSubscription" },
    };
    const pubsub_subscription_iam = [_]RpcUsage{
        .{ .service = "pubsub.googleapis.com", .method = "google.pubsub.v1.Subscriber.GetIamPolicy" },
        .{ .service = "pubsub.googleapis.com", .method = "google.pubsub.v1.Subscriber.SetIamPolicy" },
    };
    const pubsub_snapshot = [_]RpcUsage{
        .{ .service = "pubsub.googleapis.com", .method = "google.pubsub.v1.Subscriber.GetSnapshot" },
        .{ .service = "pubsub.googleapis.com", .method = "google.pubsub.v1.Subscriber.CreateSnapshot" },
        .{ .service = "pubsub.googleapis.com", .method = "google.pubsub.v1.Subscriber.UpdateSnapshot" },
        .{ .service = "pubsub.googleapis.com", .method = "google.pubsub.v1.Subscriber.DeleteSnapshot" },
    };
    const pubsub_schema = [_]RpcUsage{
        .{ .service = "pubsub.googleapis.com", .method = "google.pubsub.v1.SchemaService.GetSchema" },
        .{ .service = "pubsub.googleapis.com", .method = "google.pubsub.v1.SchemaService.CreateSchema" },
        .{ .service = "pubsub.googleapis.com", .method = "google.pubsub.v1.SchemaService.CommitSchema" },
        .{ .service = "pubsub.googleapis.com", .method = "google.pubsub.v1.SchemaService.DeleteSchema" },
    };
    const compute_backend = [_]RpcUsage{
        .{ .service = "compute.googleapis.com", .method = "compute.backendServices.get" },
        .{ .service = "compute.googleapis.com", .method = "compute.backendServices.insert" },
    };
    const compute_neg = [_]RpcUsage{
        .{ .service = "compute.googleapis.com", .method = "compute.networkEndpointGroups.insert" },
    };
    const compute_generic = [_]RpcUsage{
        .{ .service = "compute.googleapis.com", .method = "compute.resources.mutate" },
    };
    const dns = [_]RpcUsage{
        .{ .service = "dns.googleapis.com", .method = "dns.changes.create" },
    };
    if (std.mem.eql(u8, type_name, "gcp.run.Service")) return &run;
    if (std.mem.eql(u8, type_name, "gcp.run.ServiceIamMember")) return &run_iam;
    if (std.mem.eql(u8, type_name, "gcp.iam.ServiceAccount")) return &iam_service_account;
    if (std.mem.eql(u8, type_name, "gcp.pubsub.Topic")) return &pubsub_topic;
    if (std.mem.eql(u8, type_name, "gcp.pubsub.TopicIamMember")) return &pubsub_topic_iam;
    if (std.mem.eql(u8, type_name, "gcp.pubsub.Subscription")) return &pubsub_subscription;
    if (std.mem.eql(u8, type_name, "gcp.pubsub.SubscriptionIamMember")) return &pubsub_subscription_iam;
    if (std.mem.eql(u8, type_name, "gcp.pubsub.Snapshot")) return &pubsub_snapshot;
    if (std.mem.eql(u8, type_name, "gcp.pubsub.Schema")) return &pubsub_schema;
    if (std.mem.eql(u8, type_name, "gcp.compute.BackendService")) return &compute_backend;
    if (std.mem.eql(u8, type_name, "gcp.compute.RegionServerlessNeg")) return &compute_neg;
    if (std.mem.startsWith(u8, type_name, "gcp.compute.")) return &compute_generic;
    if (std.mem.eql(u8, type_name, "gcp.dns.RecordSet")) return &dns;
    return &.{};
}

fn appendFinding(allocator: std.mem.Allocator, findings: *std.ArrayList(Finding), kind: FindingKind, subject: []const u8) !void {
    try findings.append(allocator, .{ .kind = kind, .subject = try allocator.dupe(u8, subject) });
}

fn deinitFindings(allocator: std.mem.Allocator, findings: *std.ArrayList(Finding)) void {
    for (findings.items) |finding| allocator.free(finding.subject);
    findings.deinit(allocator);
}

fn appendUnique(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), value: []const u8) !void {
    if (!contains(list.items, value)) try list.append(allocator, try allocator.dupe(u8, value));
}

fn appendEnumUnique(list: *std.ArrayList(AdviceFinding), allocator: std.mem.Allocator, value: AdviceFinding) !void {
    for (list.items) |item| if (item == value) return;
    try list.append(allocator, value);
}

fn contains(values: []const []const u8, target: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, target)) return true;
    return false;
}

fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn dupeStrings(allocator: std.mem.Allocator, values: []const []const u8) ![][]const u8 {
    const result = try allocator.alloc([]const u8, values.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |value| allocator.free(value);
        allocator.free(result);
    }
    for (values, 0..) |value, index| {
        result[index] = try allocator.dupe(u8, value);
        initialized += 1;
    }
    return result;
}

fn freeStrings(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn deinitList(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |value| allocator.free(value);
    list.deinit(allocator);
}
