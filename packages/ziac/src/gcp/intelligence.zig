const std = @import("std");
const global = @import("global/root.zig");
const resource = @import("../resource.zig");

pub const RpcUsage = struct {
    service: []const u8,
    method: []const u8,
};

pub const PermissionAudience = enum { deployer, runtime };

pub const PermissionRequirement = struct {
    audience: PermissionAudience,
    permission: []const u8,
    resource_id: []const u8,
    operation: []const u8,
};

pub const PermissionPlan = struct {
    entries: []PermissionRequirement,
    deployer_permissions: []const []const u8,
    runtime_permissions: []const []const u8,

    pub fn deinit(self: *PermissionPlan, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| {
            allocator.free(entry.permission);
            allocator.free(entry.resource_id);
            allocator.free(entry.operation);
        }
        allocator.free(self.entries);
        freeStrings(allocator, self.deployer_permissions);
        freeStrings(allocator, self.runtime_permissions);
        self.* = undefined;
    }

    pub fn hasPermission(self: PermissionPlan, audience: PermissionAudience, permission: []const u8) bool {
        return contains(switch (audience) {
            .deployer => self.deployer_permissions,
            .runtime => self.runtime_permissions,
        }, permission);
    }
};

pub const CustomRoleProposal = struct {
    role_id: []const u8,
    audience: PermissionAudience,
    permissions: []const []const u8,

    pub fn deinit(self: *CustomRoleProposal, allocator: std.mem.Allocator) void {
        allocator.free(self.role_id);
        freeStrings(allocator, self.permissions);
        self.* = undefined;
    }
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

pub fn synthesizePermissionPlan(
    allocator: std.mem.Allocator,
    graph: *const resource.ResourceGraph,
) std.mem.Allocator.Error!PermissionPlan {
    var entries: std.ArrayList(PermissionRequirement) = .empty;
    errdefer deinitPermissionEntries(allocator, &entries);
    var deployer: std.ArrayList([]const u8) = .empty;
    errdefer deinitList(allocator, &deployer);
    var runtime: std.ArrayList([]const u8) = .empty;
    errdefer deinitList(allocator, &runtime);
    for (graph.resources.items) |node| {
        for (rpcUsagesForType(node.type_name)) |usage| {
            const permission = permissionForMethod(usage.method) orelse continue;
            try appendPermissionEntry(allocator, &entries, .deployer, permission, node.id, usage.method);
            try appendUnique(allocator, &deployer, permission);
        }
        if (inputString(node, "role")) |role| if (permissionForRuntimeRole(role)) |permission| {
            try appendPermissionEntry(allocator, &entries, .runtime, permission, node.id, role);
            try appendUnique(allocator, &runtime, permission);
        };
    }
    std.mem.sort([]const u8, deployer.items, {}, lessThan);
    std.mem.sort([]const u8, runtime.items, {}, lessThan);
    std.mem.sort(PermissionRequirement, entries.items, {}, lessThanPermissionRequirement);
    const owned_entries = try entries.toOwnedSlice(allocator);
    errdefer freePermissionEntries(allocator, owned_entries);
    const owned_deployer = try deployer.toOwnedSlice(allocator);
    errdefer freeStrings(allocator, owned_deployer);
    const owned_runtime = try runtime.toOwnedSlice(allocator);
    return .{
        .entries = owned_entries,
        .deployer_permissions = owned_deployer,
        .runtime_permissions = owned_runtime,
    };
}

pub fn proposeCustomRole(
    allocator: std.mem.Allocator,
    permission_plan: PermissionPlan,
    audience: PermissionAudience,
    role_id: []const u8,
) std.mem.Allocator.Error!CustomRoleProposal {
    return .{
        .role_id = try allocator.dupe(u8, role_id),
        .audience = audience,
        .permissions = try dupeStrings(allocator, switch (audience) {
            .deployer => permission_plan.deployer_permissions,
            .runtime => permission_plan.runtime_permissions,
        }),
    };
}

pub const FindingKind = enum {
    api_disabled,
    permission_denied,
    billing_disabled,
    region_unavailable,
    quota_insufficient,
    service_agent_missing,
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
    required_service_agents: []const []const u8 = &.{},
    available_service_agents: []const []const u8 = &.{},
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
    for (inventory.required_service_agents) |agent| if (!contains(inventory.available_service_agents, agent)) {
        try appendFinding(allocator, &findings, .service_agent_missing, agent);
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
        .{ .suffix = "Jobs.CreateJob", .permission = "run.jobs.create" },
        .{ .suffix = "Jobs.GetJob", .permission = "run.jobs.get" },
        .{ .suffix = "Jobs.ListJobs", .permission = "run.jobs.list" },
        .{ .suffix = "Jobs.UpdateJob", .permission = "run.jobs.update" },
        .{ .suffix = "Jobs.DeleteJob", .permission = "run.jobs.delete" },
        .{ .suffix = "Jobs.RunJob", .permission = "run.jobs.run" },
        .{ .suffix = "Jobs.GetIamPolicy", .permission = "run.jobs.getIamPolicy" },
        .{ .suffix = "Jobs.SetIamPolicy", .permission = "run.jobs.setIamPolicy" },
        .{ .suffix = "Executions.GetExecution", .permission = "run.executions.get" },
        .{ .suffix = "Executions.CancelExecution", .permission = "run.executions.cancel" },
        .{ .suffix = "WorkerPools.CreateWorkerPool", .permission = "run.workerpools.create" },
        .{ .suffix = "WorkerPools.GetWorkerPool", .permission = "run.workerpools.get" },
        .{ .suffix = "WorkerPools.ListWorkerPools", .permission = "run.workerpools.list" },
        .{ .suffix = "WorkerPools.UpdateWorkerPool", .permission = "run.workerpools.update" },
        .{ .suffix = "WorkerPools.DeleteWorkerPool", .permission = "run.workerpools.delete" },
        .{ .suffix = "Buckets.GetBucket", .permission = "storage.buckets.get" },
        .{ .suffix = "Buckets.CreateBucket", .permission = "storage.buckets.create" },
        .{ .suffix = "Buckets.UpdateBucket", .permission = "storage.buckets.update" },
        .{ .suffix = "Buckets.DeleteBucket", .permission = "storage.buckets.delete" },
        .{ .suffix = "Buckets.GetIamPolicy", .permission = "storage.buckets.getIamPolicy" },
        .{ .suffix = "Buckets.SetIamPolicy", .permission = "storage.buckets.setIamPolicy" },
        .{ .suffix = "Objects.GetObject", .permission = "storage.objects.get" },
        .{ .suffix = "Objects.CreateObject", .permission = "storage.objects.create" },
        .{ .suffix = "Objects.DeleteObject", .permission = "storage.objects.delete" },
        .{ .suffix = "Datasets.GetDataset", .permission = "bigquery.datasets.get" },
        .{ .suffix = "Datasets.CreateDataset", .permission = "bigquery.datasets.create" },
        .{ .suffix = "Datasets.UpdateDataset", .permission = "bigquery.datasets.update" },
        .{ .suffix = "Datasets.DeleteDataset", .permission = "bigquery.datasets.delete" },
        .{ .suffix = "Datasets.GetIamPolicy", .permission = "bigquery.datasets.getIamPolicy" },
        .{ .suffix = "Datasets.SetIamPolicy", .permission = "bigquery.datasets.setIamPolicy" },
        .{ .suffix = "Tables.GetTable", .permission = "bigquery.tables.get" },
        .{ .suffix = "Tables.CreateTable", .permission = "bigquery.tables.create" },
        .{ .suffix = "Tables.UpdateTable", .permission = "bigquery.tables.update" },
        .{ .suffix = "Tables.DeleteTable", .permission = "bigquery.tables.delete" },
        .{ .suffix = "Tables.GetIamPolicy", .permission = "bigquery.tables.getIamPolicy" },
        .{ .suffix = "Tables.SetIamPolicy", .permission = "bigquery.tables.setIamPolicy" },
        .{ .suffix = "Routines.GetRoutine", .permission = "bigquery.routines.get" },
        .{ .suffix = "Routines.CreateRoutine", .permission = "bigquery.routines.create" },
        .{ .suffix = "Routines.UpdateRoutine", .permission = "bigquery.routines.update" },
        .{ .suffix = "Routines.DeleteRoutine", .permission = "bigquery.routines.delete" },
        .{ .suffix = "Routines.GetIamPolicy", .permission = "bigquery.routines.getIamPolicy" },
        .{ .suffix = "Routines.SetIamPolicy", .permission = "bigquery.routines.setIamPolicy" },
        .{ .suffix = "Connections.GetConnection", .permission = "bigquery.connections.get" },
        .{ .suffix = "Connections.CreateConnection", .permission = "bigquery.connections.create" },
        .{ .suffix = "Connections.UpdateConnection", .permission = "bigquery.connections.update" },
        .{ .suffix = "Connections.DeleteConnection", .permission = "bigquery.connections.delete" },
        .{ .suffix = "Connections.GetIamPolicy", .permission = "bigquery.connections.getIamPolicy" },
        .{ .suffix = "Connections.SetIamPolicy", .permission = "bigquery.connections.setIamPolicy" },
        .{ .suffix = "Reservations.GetReservation", .permission = "bigquery.reservations.get" },
        .{ .suffix = "Reservations.CreateReservation", .permission = "bigquery.reservations.create" },
        .{ .suffix = "Reservations.UpdateReservation", .permission = "bigquery.reservations.update" },
        .{ .suffix = "Reservations.DeleteReservation", .permission = "bigquery.reservations.delete" },
        .{ .suffix = "Reservations.GetIamPolicy", .permission = "bigquery.reservations.getIamPolicy" },
        .{ .suffix = "Reservations.SetIamPolicy", .permission = "bigquery.reservations.setIamPolicy" },
        .{ .suffix = "CapacityCommitments.GetCapacityCommitment", .permission = "bigquery.capacityCommitments.get" },
        .{ .suffix = "CapacityCommitments.CreateCapacityCommitment", .permission = "bigquery.capacityCommitments.create" },
        .{ .suffix = "CapacityCommitments.DeleteCapacityCommitment", .permission = "bigquery.capacityCommitments.delete" },
        .{ .suffix = "Assignments.GetAssignment", .permission = "bigquery.reservationAssignments.get" },
        .{ .suffix = "Assignments.CreateAssignment", .permission = "bigquery.reservationAssignments.create" },
        .{ .suffix = "Assignments.DeleteAssignment", .permission = "bigquery.reservationAssignments.delete" },
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
        .{ .suffix = "CloudTasks.GetQueue", .permission = "cloudtasks.queues.get" },
        .{ .suffix = "CloudTasks.CreateQueue", .permission = "cloudtasks.queues.create" },
        .{ .suffix = "CloudTasks.UpdateQueue", .permission = "cloudtasks.queues.update" },
        .{ .suffix = "CloudTasks.DeleteQueue", .permission = "cloudtasks.queues.delete" },
        .{ .suffix = "CloudTasks.GetIamPolicy", .permission = "cloudtasks.queues.getIamPolicy" },
        .{ .suffix = "CloudTasks.SetIamPolicy", .permission = "cloudtasks.queues.setIamPolicy" },
        .{ .suffix = "Eventarc.GetTrigger", .permission = "eventarc.triggers.get" },
        .{ .suffix = "Eventarc.CreateTrigger", .permission = "eventarc.triggers.create" },
        .{ .suffix = "Eventarc.UpdateTrigger", .permission = "eventarc.triggers.update" },
        .{ .suffix = "Eventarc.DeleteTrigger", .permission = "eventarc.triggers.delete" },
        .{ .suffix = "FirestoreAdmin.GetDatabase", .permission = "datastore.databases.get" },
        .{ .suffix = "FirestoreAdmin.CreateDatabase", .permission = "datastore.databases.create" },
        .{ .suffix = "FirestoreAdmin.UpdateDatabase", .permission = "datastore.databases.update" },
        .{ .suffix = "FirestoreAdmin.DeleteDatabase", .permission = "datastore.databases.delete" },
        .{ .suffix = "FirestoreAdmin.GetIndex", .permission = "datastore.indexes.get" },
        .{ .suffix = "FirestoreAdmin.CreateIndex", .permission = "datastore.indexes.create" },
        .{ .suffix = "FirestoreAdmin.DeleteIndex", .permission = "datastore.indexes.delete" },
        .{ .suffix = "FirestoreAdmin.GetField", .permission = "datastore.fields.get" },
        .{ .suffix = "FirestoreAdmin.UpdateField", .permission = "datastore.fields.update" },
        .{ .suffix = "FirestoreAdmin.GetBackupSchedule", .permission = "datastore.backupSchedules.get" },
        .{ .suffix = "FirestoreAdmin.CreateBackupSchedule", .permission = "datastore.backupSchedules.create" },
        .{ .suffix = "FirestoreAdmin.UpdateBackupSchedule", .permission = "datastore.backupSchedules.update" },
        .{ .suffix = "FirestoreAdmin.DeleteBackupSchedule", .permission = "datastore.backupSchedules.delete" },
        .{ .suffix = "FirestoreAdmin.GetIamPolicy", .permission = "datastore.databases.getIamPolicy" },
        .{ .suffix = "FirestoreAdmin.SetIamPolicy", .permission = "datastore.databases.setIamPolicy" },
        .{ .suffix = "CloudScheduler.GetJob", .permission = "cloudscheduler.jobs.get" },
        .{ .suffix = "CloudScheduler.CreateJob", .permission = "cloudscheduler.jobs.create" },
        .{ .suffix = "CloudScheduler.UpdateJob", .permission = "cloudscheduler.jobs.update" },
        .{ .suffix = "CloudScheduler.DeleteJob", .permission = "cloudscheduler.jobs.delete" },
        .{ .suffix = "ServiceAccounts.ActAs", .permission = "iam.serviceAccounts.actAs" },
        .{ .suffix = "IAM.GetServiceAccount", .permission = "iam.serviceAccounts.get" },
        .{ .suffix = "IAM.CreateServiceAccount", .permission = "iam.serviceAccounts.create" },
        .{ .suffix = "IAM.PatchServiceAccount", .permission = "iam.serviceAccounts.update" },
        .{ .suffix = "IAM.DeleteServiceAccount", .permission = "iam.serviceAccounts.delete" },
        .{ .suffix = "Projects.GetIamPolicy", .permission = "resourcemanager.projects.getIamPolicy" },
        .{ .suffix = "Projects.SetIamPolicy", .permission = "resourcemanager.projects.setIamPolicy" },
        .{ .suffix = "Folders.GetIamPolicy", .permission = "resourcemanager.folders.getIamPolicy" },
        .{ .suffix = "Folders.SetIamPolicy", .permission = "resourcemanager.folders.setIamPolicy" },
        .{ .suffix = "Organizations.GetIamPolicy", .permission = "resourcemanager.organizations.getIamPolicy" },
        .{ .suffix = "Organizations.SetIamPolicy", .permission = "resourcemanager.organizations.setIamPolicy" },
        .{ .suffix = "ServiceAccounts.GetIamPolicy", .permission = "iam.serviceAccounts.getIamPolicy" },
        .{ .suffix = "ServiceAccounts.SetIamPolicy", .permission = "iam.serviceAccounts.setIamPolicy" },
        .{ .suffix = "Roles.GetRole", .permission = "iam.roles.get" },
        .{ .suffix = "Roles.CreateRole", .permission = "iam.roles.create" },
        .{ .suffix = "Roles.UpdateRole", .permission = "iam.roles.update" },
        .{ .suffix = "Roles.DeleteRole", .permission = "iam.roles.delete" },
        .{ .suffix = "WorkloadIdentityPools.GetWorkloadIdentityPool", .permission = "iam.workloadIdentityPools.get" },
        .{ .suffix = "WorkloadIdentityPools.CreateWorkloadIdentityPool", .permission = "iam.workloadIdentityPools.create" },
        .{ .suffix = "WorkloadIdentityPools.UpdateWorkloadIdentityPool", .permission = "iam.workloadIdentityPools.update" },
        .{ .suffix = "WorkloadIdentityPools.DeleteWorkloadIdentityPool", .permission = "iam.workloadIdentityPools.delete" },
        .{ .suffix = "WorkloadIdentityPoolProviders.GetWorkloadIdentityPoolProvider", .permission = "iam.workloadIdentityPoolProviders.get" },
        .{ .suffix = "WorkloadIdentityPoolProviders.CreateWorkloadIdentityPoolProvider", .permission = "iam.workloadIdentityPoolProviders.create" },
        .{ .suffix = "WorkloadIdentityPoolProviders.UpdateWorkloadIdentityPoolProvider", .permission = "iam.workloadIdentityPoolProviders.update" },
        .{ .suffix = "WorkloadIdentityPoolProviders.DeleteWorkloadIdentityPoolProvider", .permission = "iam.workloadIdentityPoolProviders.delete" },
        .{ .suffix = "backendServices.insert", .permission = "compute.backendServices.create" },
        .{ .suffix = "backendServices.get", .permission = "compute.backendServices.get" },
        .{ .suffix = "networkEndpointGroups.insert", .permission = "compute.networkEndpointGroups.create" },
    };
    for (mappings) |mapping| if (std.mem.endsWith(u8, method, mapping.suffix)) return mapping.permission;
    return null;
}

pub fn jobExecutionUsages() []const RpcUsage {
    const usages = [_]RpcUsage{
        .{ .service = "run.googleapis.com", .method = "google.cloud.run.v2.Jobs.RunJob" },
        .{ .service = "run.googleapis.com", .method = "google.cloud.run.v2.Executions.GetExecution" },
        .{ .service = "run.googleapis.com", .method = "google.cloud.run.v2.Executions.CancelExecution" },
    };
    return &usages;
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
    const run_job = [_]RpcUsage{
        .{ .service = "run.googleapis.com", .method = "google.cloud.run.v2.Jobs.GetJob" },
        .{ .service = "run.googleapis.com", .method = "google.cloud.run.v2.Jobs.CreateJob" },
        .{ .service = "run.googleapis.com", .method = "google.cloud.run.v2.Jobs.UpdateJob" },
        .{ .service = "run.googleapis.com", .method = "google.cloud.run.v2.Jobs.DeleteJob" },
        .{ .service = "iam.googleapis.com", .method = "google.iam.v1.ServiceAccounts.ActAs" },
    };
    const run_job_iam = [_]RpcUsage{
        .{ .service = "run.googleapis.com", .method = "google.cloud.run.v2.Jobs.GetIamPolicy" },
        .{ .service = "run.googleapis.com", .method = "google.cloud.run.v2.Jobs.SetIamPolicy" },
    };
    const run_worker_pool = [_]RpcUsage{
        .{ .service = "run.googleapis.com", .method = "google.cloud.run.v2.WorkerPools.GetWorkerPool" },
        .{ .service = "run.googleapis.com", .method = "google.cloud.run.v2.WorkerPools.CreateWorkerPool" },
        .{ .service = "run.googleapis.com", .method = "google.cloud.run.v2.WorkerPools.UpdateWorkerPool" },
        .{ .service = "run.googleapis.com", .method = "google.cloud.run.v2.WorkerPools.DeleteWorkerPool" },
        .{ .service = "iam.googleapis.com", .method = "google.iam.v1.ServiceAccounts.ActAs" },
    };
    const storage_bucket = [_]RpcUsage{
        .{ .service = "storage.googleapis.com", .method = "google.storage.v1.Buckets.GetBucket" },
        .{ .service = "storage.googleapis.com", .method = "google.storage.v1.Buckets.CreateBucket" },
        .{ .service = "storage.googleapis.com", .method = "google.storage.v1.Buckets.UpdateBucket" },
        .{ .service = "storage.googleapis.com", .method = "google.storage.v1.Buckets.DeleteBucket" },
    };
    const storage_bucket_iam = [_]RpcUsage{
        .{ .service = "storage.googleapis.com", .method = "google.storage.v1.Buckets.GetIamPolicy" },
        .{ .service = "storage.googleapis.com", .method = "google.storage.v1.Buckets.SetIamPolicy" },
    };
    const storage_object = [_]RpcUsage{
        .{ .service = "storage.googleapis.com", .method = "google.storage.v1.Objects.GetObject" },
        .{ .service = "storage.googleapis.com", .method = "google.storage.v1.Objects.CreateObject" },
        .{ .service = "storage.googleapis.com", .method = "google.storage.v1.Objects.DeleteObject" },
    };
    const bigquery_dataset = [_]RpcUsage{
        .{ .service = "bigquery.googleapis.com", .method = "google.cloud.bigquery.v2.Datasets.GetDataset" },
        .{ .service = "bigquery.googleapis.com", .method = "google.cloud.bigquery.v2.Datasets.CreateDataset" },
        .{ .service = "bigquery.googleapis.com", .method = "google.cloud.bigquery.v2.Datasets.UpdateDataset" },
        .{ .service = "bigquery.googleapis.com", .method = "google.cloud.bigquery.v2.Datasets.DeleteDataset" },
    };
    const bigquery_dataset_iam = [_]RpcUsage{
        .{ .service = "bigquery.googleapis.com", .method = "google.cloud.bigquery.v2.Datasets.GetIamPolicy" },
        .{ .service = "bigquery.googleapis.com", .method = "google.cloud.bigquery.v2.Datasets.SetIamPolicy" },
    };
    const bigquery_table = [_]RpcUsage{
        .{ .service = "bigquery.googleapis.com", .method = "google.cloud.bigquery.v2.Tables.GetTable" },
        .{ .service = "bigquery.googleapis.com", .method = "google.cloud.bigquery.v2.Tables.CreateTable" },
        .{ .service = "bigquery.googleapis.com", .method = "google.cloud.bigquery.v2.Tables.UpdateTable" },
        .{ .service = "bigquery.googleapis.com", .method = "google.cloud.bigquery.v2.Tables.DeleteTable" },
    };
    const bigquery_table_iam = [_]RpcUsage{
        .{ .service = "bigquery.googleapis.com", .method = "google.cloud.bigquery.v2.Tables.GetIamPolicy" },
        .{ .service = "bigquery.googleapis.com", .method = "google.cloud.bigquery.v2.Tables.SetIamPolicy" },
    };
    const bigquery_routine = [_]RpcUsage{
        .{ .service = "bigquery.googleapis.com", .method = "google.cloud.bigquery.v2.Routines.GetRoutine" },
        .{ .service = "bigquery.googleapis.com", .method = "google.cloud.bigquery.v2.Routines.CreateRoutine" },
        .{ .service = "bigquery.googleapis.com", .method = "google.cloud.bigquery.v2.Routines.UpdateRoutine" },
        .{ .service = "bigquery.googleapis.com", .method = "google.cloud.bigquery.v2.Routines.DeleteRoutine" },
    };
    const bigquery_routine_iam = [_]RpcUsage{
        .{ .service = "bigquery.googleapis.com", .method = "google.cloud.bigquery.v2.Routines.GetIamPolicy" },
        .{ .service = "bigquery.googleapis.com", .method = "google.cloud.bigquery.v2.Routines.SetIamPolicy" },
    };
    const bigquery_connection = [_]RpcUsage{
        .{ .service = "bigqueryconnection.googleapis.com", .method = "google.cloud.bigquery.connection.v1.Connections.GetConnection" },
        .{ .service = "bigqueryconnection.googleapis.com", .method = "google.cloud.bigquery.connection.v1.Connections.CreateConnection" },
        .{ .service = "bigqueryconnection.googleapis.com", .method = "google.cloud.bigquery.connection.v1.Connections.UpdateConnection" },
        .{ .service = "bigqueryconnection.googleapis.com", .method = "google.cloud.bigquery.connection.v1.Connections.DeleteConnection" },
    };
    const bigquery_connection_iam = [_]RpcUsage{
        .{ .service = "bigqueryconnection.googleapis.com", .method = "google.cloud.bigquery.connection.v1.Connections.GetIamPolicy" },
        .{ .service = "bigqueryconnection.googleapis.com", .method = "google.cloud.bigquery.connection.v1.Connections.SetIamPolicy" },
    };
    const bigquery_reservation = [_]RpcUsage{
        .{ .service = "bigqueryreservation.googleapis.com", .method = "google.cloud.bigquery.reservation.v1.Reservations.GetReservation" },
        .{ .service = "bigqueryreservation.googleapis.com", .method = "google.cloud.bigquery.reservation.v1.Reservations.CreateReservation" },
        .{ .service = "bigqueryreservation.googleapis.com", .method = "google.cloud.bigquery.reservation.v1.Reservations.UpdateReservation" },
        .{ .service = "bigqueryreservation.googleapis.com", .method = "google.cloud.bigquery.reservation.v1.Reservations.DeleteReservation" },
    };
    const bigquery_reservation_iam = [_]RpcUsage{
        .{ .service = "bigqueryreservation.googleapis.com", .method = "google.cloud.bigquery.reservation.v1.Reservations.GetIamPolicy" },
        .{ .service = "bigqueryreservation.googleapis.com", .method = "google.cloud.bigquery.reservation.v1.Reservations.SetIamPolicy" },
    };
    const bigquery_commitment = [_]RpcUsage{
        .{ .service = "bigqueryreservation.googleapis.com", .method = "google.cloud.bigquery.reservation.v1.CapacityCommitments.GetCapacityCommitment" },
        .{ .service = "bigqueryreservation.googleapis.com", .method = "google.cloud.bigquery.reservation.v1.CapacityCommitments.CreateCapacityCommitment" },
        .{ .service = "bigqueryreservation.googleapis.com", .method = "google.cloud.bigquery.reservation.v1.CapacityCommitments.DeleteCapacityCommitment" },
    };
    const bigquery_assignment = [_]RpcUsage{
        .{ .service = "bigqueryreservation.googleapis.com", .method = "google.cloud.bigquery.reservation.v1.Assignments.GetAssignment" },
        .{ .service = "bigqueryreservation.googleapis.com", .method = "google.cloud.bigquery.reservation.v1.Assignments.CreateAssignment" },
        .{ .service = "bigqueryreservation.googleapis.com", .method = "google.cloud.bigquery.reservation.v1.Assignments.DeleteAssignment" },
    };
    const firestore_database = [_]RpcUsage{
        .{ .service = "firestore.googleapis.com", .method = "google.firestore.admin.v1.FirestoreAdmin.GetDatabase" },
        .{ .service = "firestore.googleapis.com", .method = "google.firestore.admin.v1.FirestoreAdmin.CreateDatabase" },
        .{ .service = "firestore.googleapis.com", .method = "google.firestore.admin.v1.FirestoreAdmin.UpdateDatabase" },
        .{ .service = "firestore.googleapis.com", .method = "google.firestore.admin.v1.FirestoreAdmin.DeleteDatabase" },
    };
    const firestore_index = [_]RpcUsage{
        .{ .service = "firestore.googleapis.com", .method = "google.firestore.admin.v1.FirestoreAdmin.GetIndex" },
        .{ .service = "firestore.googleapis.com", .method = "google.firestore.admin.v1.FirestoreAdmin.CreateIndex" },
        .{ .service = "firestore.googleapis.com", .method = "google.firestore.admin.v1.FirestoreAdmin.DeleteIndex" },
    };
    const firestore_field = [_]RpcUsage{
        .{ .service = "firestore.googleapis.com", .method = "google.firestore.admin.v1.FirestoreAdmin.GetField" },
        .{ .service = "firestore.googleapis.com", .method = "google.firestore.admin.v1.FirestoreAdmin.UpdateField" },
    };
    const firestore_backup_schedule = [_]RpcUsage{
        .{ .service = "firestore.googleapis.com", .method = "google.firestore.admin.v1.FirestoreAdmin.GetBackupSchedule" },
        .{ .service = "firestore.googleapis.com", .method = "google.firestore.admin.v1.FirestoreAdmin.CreateBackupSchedule" },
        .{ .service = "firestore.googleapis.com", .method = "google.firestore.admin.v1.FirestoreAdmin.UpdateBackupSchedule" },
        .{ .service = "firestore.googleapis.com", .method = "google.firestore.admin.v1.FirestoreAdmin.DeleteBackupSchedule" },
    };
    const firestore_database_iam = [_]RpcUsage{
        .{ .service = "firestore.googleapis.com", .method = "google.firestore.admin.v1.FirestoreAdmin.GetIamPolicy" },
        .{ .service = "firestore.googleapis.com", .method = "google.firestore.admin.v1.FirestoreAdmin.SetIamPolicy" },
    };
    const iam_service_account = [_]RpcUsage{
        .{ .service = "iam.googleapis.com", .method = "google.iam.admin.v1.IAM.GetServiceAccount" },
        .{ .service = "iam.googleapis.com", .method = "google.iam.admin.v1.IAM.CreateServiceAccount" },
        .{ .service = "iam.googleapis.com", .method = "google.iam.admin.v1.IAM.PatchServiceAccount" },
        .{ .service = "iam.googleapis.com", .method = "google.iam.admin.v1.IAM.DeleteServiceAccount" },
    };
    const project_iam = [_]RpcUsage{
        .{ .service = "cloudresourcemanager.googleapis.com", .method = "google.cloud.resourcemanager.v3.Projects.GetIamPolicy" },
        .{ .service = "cloudresourcemanager.googleapis.com", .method = "google.cloud.resourcemanager.v3.Projects.SetIamPolicy" },
    };
    const folder_iam = [_]RpcUsage{
        .{ .service = "cloudresourcemanager.googleapis.com", .method = "google.cloud.resourcemanager.v3.Folders.GetIamPolicy" },
        .{ .service = "cloudresourcemanager.googleapis.com", .method = "google.cloud.resourcemanager.v3.Folders.SetIamPolicy" },
    };
    const organization_iam = [_]RpcUsage{
        .{ .service = "cloudresourcemanager.googleapis.com", .method = "google.cloud.resourcemanager.v3.Organizations.GetIamPolicy" },
        .{ .service = "cloudresourcemanager.googleapis.com", .method = "google.cloud.resourcemanager.v3.Organizations.SetIamPolicy" },
    };
    const service_account_iam = [_]RpcUsage{
        .{ .service = "iam.googleapis.com", .method = "google.iam.v1.ServiceAccounts.GetIamPolicy" },
        .{ .service = "iam.googleapis.com", .method = "google.iam.v1.ServiceAccounts.SetIamPolicy" },
    };
    const custom_role = [_]RpcUsage{
        .{ .service = "iam.googleapis.com", .method = "google.iam.admin.v1.Roles.GetRole" },
        .{ .service = "iam.googleapis.com", .method = "google.iam.admin.v1.Roles.CreateRole" },
        .{ .service = "iam.googleapis.com", .method = "google.iam.admin.v1.Roles.UpdateRole" },
        .{ .service = "iam.googleapis.com", .method = "google.iam.admin.v1.Roles.DeleteRole" },
    };
    const workload_identity_pool = [_]RpcUsage{
        .{ .service = "iam.googleapis.com", .method = "google.iam.v1.WorkloadIdentityPools.GetWorkloadIdentityPool" },
        .{ .service = "iam.googleapis.com", .method = "google.iam.v1.WorkloadIdentityPools.CreateWorkloadIdentityPool" },
        .{ .service = "iam.googleapis.com", .method = "google.iam.v1.WorkloadIdentityPools.UpdateWorkloadIdentityPool" },
        .{ .service = "iam.googleapis.com", .method = "google.iam.v1.WorkloadIdentityPools.DeleteWorkloadIdentityPool" },
    };
    const workload_identity_pool_provider = [_]RpcUsage{
        .{ .service = "iam.googleapis.com", .method = "google.iam.v1.WorkloadIdentityPoolProviders.GetWorkloadIdentityPoolProvider" },
        .{ .service = "iam.googleapis.com", .method = "google.iam.v1.WorkloadIdentityPoolProviders.CreateWorkloadIdentityPoolProvider" },
        .{ .service = "iam.googleapis.com", .method = "google.iam.v1.WorkloadIdentityPoolProviders.UpdateWorkloadIdentityPoolProvider" },
        .{ .service = "iam.googleapis.com", .method = "google.iam.v1.WorkloadIdentityPoolProviders.DeleteWorkloadIdentityPoolProvider" },
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
    const tasks_queue = [_]RpcUsage{
        .{ .service = "cloudtasks.googleapis.com", .method = "google.cloud.tasks.v2.CloudTasks.GetQueue" },
        .{ .service = "cloudtasks.googleapis.com", .method = "google.cloud.tasks.v2.CloudTasks.CreateQueue" },
        .{ .service = "cloudtasks.googleapis.com", .method = "google.cloud.tasks.v2.CloudTasks.UpdateQueue" },
        .{ .service = "cloudtasks.googleapis.com", .method = "google.cloud.tasks.v2.CloudTasks.DeleteQueue" },
        .{ .service = "iam.googleapis.com", .method = "google.iam.v1.ServiceAccounts.ActAs" },
    };
    const tasks_queue_iam = [_]RpcUsage{
        .{ .service = "cloudtasks.googleapis.com", .method = "google.cloud.tasks.v2.CloudTasks.GetIamPolicy" },
        .{ .service = "cloudtasks.googleapis.com", .method = "google.cloud.tasks.v2.CloudTasks.SetIamPolicy" },
    };
    const eventarc_trigger = [_]RpcUsage{
        .{ .service = "eventarc.googleapis.com", .method = "google.cloud.eventarc.v1.Eventarc.GetTrigger" },
        .{ .service = "eventarc.googleapis.com", .method = "google.cloud.eventarc.v1.Eventarc.CreateTrigger" },
        .{ .service = "eventarc.googleapis.com", .method = "google.cloud.eventarc.v1.Eventarc.UpdateTrigger" },
        .{ .service = "eventarc.googleapis.com", .method = "google.cloud.eventarc.v1.Eventarc.DeleteTrigger" },
        .{ .service = "iam.googleapis.com", .method = "google.iam.v1.ServiceAccounts.ActAs" },
    };
    const scheduler_job = [_]RpcUsage{
        .{ .service = "cloudscheduler.googleapis.com", .method = "google.cloud.scheduler.v1.CloudScheduler.GetJob" },
        .{ .service = "cloudscheduler.googleapis.com", .method = "google.cloud.scheduler.v1.CloudScheduler.CreateJob" },
        .{ .service = "cloudscheduler.googleapis.com", .method = "google.cloud.scheduler.v1.CloudScheduler.UpdateJob" },
        .{ .service = "cloudscheduler.googleapis.com", .method = "google.cloud.scheduler.v1.CloudScheduler.DeleteJob" },
        .{ .service = "iam.googleapis.com", .method = "google.iam.v1.ServiceAccounts.ActAs" },
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
    if (std.mem.eql(u8, type_name, "gcp.run.Job")) return &run_job;
    if (std.mem.eql(u8, type_name, "gcp.run.JobIamMember")) return &run_job_iam;
    if (std.mem.eql(u8, type_name, "gcp.run.WorkerPool")) return &run_worker_pool;
    if (std.mem.eql(u8, type_name, "gcp.storage.Bucket")) return &storage_bucket;
    if (std.mem.eql(u8, type_name, "gcp.storage.BucketIamMember")) return &storage_bucket_iam;
    if (std.mem.eql(u8, type_name, "gcp.storage.Object")) return &storage_object;
    if (std.mem.eql(u8, type_name, "gcp.bigquery.Dataset")) return &bigquery_dataset;
    if (std.mem.eql(u8, type_name, "gcp.bigquery.DatasetIamMember")) return &bigquery_dataset_iam;
    if (std.mem.eql(u8, type_name, "gcp.bigquery.Table") or std.mem.eql(u8, type_name, "gcp.bigquery.View")) return &bigquery_table;
    if (std.mem.eql(u8, type_name, "gcp.bigquery.TableIamMember")) return &bigquery_table_iam;
    if (std.mem.eql(u8, type_name, "gcp.bigquery.Routine")) return &bigquery_routine;
    if (std.mem.eql(u8, type_name, "gcp.bigquery.RoutineIamMember")) return &bigquery_routine_iam;
    if (std.mem.eql(u8, type_name, "gcp.bigquery.Connection")) return &bigquery_connection;
    if (std.mem.eql(u8, type_name, "gcp.bigquery.ConnectionIamMember")) return &bigquery_connection_iam;
    if (std.mem.eql(u8, type_name, "gcp.bigquery.Reservation")) return &bigquery_reservation;
    if (std.mem.eql(u8, type_name, "gcp.bigquery.ReservationIamMember")) return &bigquery_reservation_iam;
    if (std.mem.eql(u8, type_name, "gcp.bigquery.CapacityCommitment")) return &bigquery_commitment;
    if (std.mem.eql(u8, type_name, "gcp.bigquery.ReservationAssignment")) return &bigquery_assignment;
    if (std.mem.eql(u8, type_name, "gcp.firestore.Database")) return &firestore_database;
    if (std.mem.eql(u8, type_name, "gcp.firestore.DatabaseIamMember")) return &firestore_database_iam;
    if (std.mem.eql(u8, type_name, "gcp.firestore.Index")) return &firestore_index;
    if (std.mem.eql(u8, type_name, "gcp.firestore.Field")) return &firestore_field;
    if (std.mem.eql(u8, type_name, "gcp.firestore.BackupSchedule")) return &firestore_backup_schedule;
    if (std.mem.eql(u8, type_name, "gcp.iam.ServiceAccount")) return &iam_service_account;
    if (std.mem.startsWith(u8, type_name, "gcp.iam.Project") and
        !std.mem.eql(u8, type_name, "gcp.iam.ProjectCustomRole")) return &project_iam;
    if (std.mem.startsWith(u8, type_name, "gcp.iam.Folder")) return &folder_iam;
    if (std.mem.startsWith(u8, type_name, "gcp.iam.Organization") and
        !std.mem.eql(u8, type_name, "gcp.iam.OrganizationCustomRole")) return &organization_iam;
    if (std.mem.startsWith(u8, type_name, "gcp.iam.ServiceAccountIam")) return &service_account_iam;
    if (std.mem.eql(u8, type_name, "gcp.iam.ProjectCustomRole") or
        std.mem.eql(u8, type_name, "gcp.iam.OrganizationCustomRole")) return &custom_role;
    if (std.mem.eql(u8, type_name, "gcp.iam.WorkloadIdentityPool")) return &workload_identity_pool;
    if (std.mem.eql(u8, type_name, "gcp.iam.WorkloadIdentityPoolProvider")) return &workload_identity_pool_provider;
    if (std.mem.eql(u8, type_name, "gcp.pubsub.Topic")) return &pubsub_topic;
    if (std.mem.eql(u8, type_name, "gcp.pubsub.TopicIamMember")) return &pubsub_topic_iam;
    if (std.mem.eql(u8, type_name, "gcp.pubsub.Subscription")) return &pubsub_subscription;
    if (std.mem.eql(u8, type_name, "gcp.pubsub.SubscriptionIamMember")) return &pubsub_subscription_iam;
    if (std.mem.eql(u8, type_name, "gcp.pubsub.Snapshot")) return &pubsub_snapshot;
    if (std.mem.eql(u8, type_name, "gcp.pubsub.Schema")) return &pubsub_schema;
    if (std.mem.eql(u8, type_name, "gcp.tasks.Queue")) return &tasks_queue;
    if (std.mem.eql(u8, type_name, "gcp.tasks.QueueIamMember")) return &tasks_queue_iam;
    if (std.mem.eql(u8, type_name, "gcp.eventarc.Trigger")) return &eventarc_trigger;
    if (std.mem.eql(u8, type_name, "gcp.scheduler.Job")) return &scheduler_job;
    if (std.mem.eql(u8, type_name, "gcp.compute.BackendService")) return &compute_backend;
    if (std.mem.eql(u8, type_name, "gcp.compute.RegionServerlessNeg")) return &compute_neg;
    if (std.mem.startsWith(u8, type_name, "gcp.compute.")) return &compute_generic;
    if (std.mem.eql(u8, type_name, "gcp.dns.RecordSet")) return &dns;
    return &.{};
}

fn permissionForRuntimeRole(role: []const u8) ?[]const u8 {
    const mappings = [_]struct { role: []const u8, permission: []const u8 }{
        .{ .role = "roles/artifactregistry.reader", .permission = "artifactregistry.repositories.downloadArtifacts" },
        .{ .role = "roles/bigquery.dataViewer", .permission = "bigquery.tables.getData" },
        .{ .role = "roles/bigquery.dataEditor", .permission = "bigquery.tables.updateData" },
        .{ .role = "roles/bigquery.jobUser", .permission = "bigquery.jobs.create" },
        .{ .role = "roles/datastore.user", .permission = "datastore.entities.create" },
        .{ .role = "roles/datastore.viewer", .permission = "datastore.entities.get" },
        .{ .role = "roles/bigquery.connectionUser", .permission = "bigquery.connections.use" },
        .{ .role = "roles/cloudtasks.enqueuer", .permission = "cloudtasks.tasks.create" },
        .{ .role = "roles/iam.workloadIdentityUser", .permission = "iam.serviceAccounts.getAccessToken" },
        .{ .role = "roles/pubsub.publisher", .permission = "pubsub.topics.publish" },
        .{ .role = "roles/pubsub.subscriber", .permission = "pubsub.subscriptions.consume" },
        .{ .role = "roles/run.invoker", .permission = "run.routes.invoke" },
        .{ .role = "roles/secretmanager.secretAccessor", .permission = "secretmanager.versions.access" },
        .{ .role = "roles/storage.objectCreator", .permission = "storage.objects.create" },
        .{ .role = "roles/storage.objectUser", .permission = "storage.objects.create" },
        .{ .role = "roles/storage.objectViewer", .permission = "storage.objects.get" },
    };
    for (mappings) |mapping| if (std.mem.eql(u8, mapping.role, role)) return mapping.permission;
    return null;
}

fn inputString(node: resource.ResourceNode, name: []const u8) ?[]const u8 {
    const fields = switch (node.inputs) {
        .object => |items| items,
        else => return null,
    };
    for (fields) |field| {
        if (!std.mem.eql(u8, field.name, name)) continue;
        return switch (field.value) {
            .string => |text| text,
            else => null,
        };
    }
    return null;
}

fn appendPermissionEntry(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(PermissionRequirement),
    audience: PermissionAudience,
    permission: []const u8,
    resource_id: []const u8,
    operation: []const u8,
) std.mem.Allocator.Error!void {
    for (entries.items) |entry| {
        if (entry.audience == audience and
            std.mem.eql(u8, entry.permission, permission) and
            std.mem.eql(u8, entry.resource_id, resource_id) and
            std.mem.eql(u8, entry.operation, operation)) return;
    }
    const owned_permission = try allocator.dupe(u8, permission);
    errdefer allocator.free(owned_permission);
    const owned_resource = try allocator.dupe(u8, resource_id);
    errdefer allocator.free(owned_resource);
    const owned_operation = try allocator.dupe(u8, operation);
    errdefer allocator.free(owned_operation);
    try entries.append(allocator, .{
        .audience = audience,
        .permission = owned_permission,
        .resource_id = owned_resource,
        .operation = owned_operation,
    });
}

fn lessThanPermissionRequirement(_: void, left: PermissionRequirement, right: PermissionRequirement) bool {
    if (left.audience != right.audience) return @intFromEnum(left.audience) < @intFromEnum(right.audience);
    const permission = std.mem.order(u8, left.permission, right.permission);
    if (permission != .eq) return permission == .lt;
    const resource_id = std.mem.order(u8, left.resource_id, right.resource_id);
    if (resource_id != .eq) return resource_id == .lt;
    return std.mem.lessThan(u8, left.operation, right.operation);
}

fn deinitPermissionEntries(allocator: std.mem.Allocator, entries: *std.ArrayList(PermissionRequirement)) void {
    for (entries.items) |entry| {
        allocator.free(entry.permission);
        allocator.free(entry.resource_id);
        allocator.free(entry.operation);
    }
    entries.deinit(allocator);
}

fn freePermissionEntries(allocator: std.mem.Allocator, entries: []PermissionRequirement) void {
    for (entries) |entry| {
        allocator.free(entry.permission);
        allocator.free(entry.resource_id);
        allocator.free(entry.operation);
    }
    allocator.free(entries);
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
