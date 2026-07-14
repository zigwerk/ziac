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
        if (std.mem.eql(u8, node.type_name, "gcp.redis.Instance") and (inputBool(node, "auth_enabled") orelse false)) {
            try usages.append(allocator, .{
                .service = "secretmanager.googleapis.com",
                .method = "google.cloud.secretmanager.v1.SecretVersions.AddSecretVersion",
            });
        }
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
        if (std.mem.eql(u8, node.type_name, "gcp.redis.Instance") and (inputBool(node, "auth_enabled") orelse false)) {
            const usage = RpcUsage{
                .service = "secretmanager.googleapis.com",
                .method = "google.cloud.secretmanager.v1.SecretVersions.AddSecretVersion",
            };
            const permission = permissionForMethod(usage.method).?;
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
        .{ .suffix = "RepositoryManager.GetConnection", .permission = "cloudbuild.connections.get" },
        .{ .suffix = "RepositoryManager.CreateConnection", .permission = "cloudbuild.connections.create" },
        .{ .suffix = "RepositoryManager.UpdateConnection", .permission = "cloudbuild.connections.update" },
        .{ .suffix = "RepositoryManager.DeleteConnection", .permission = "cloudbuild.connections.delete" },
        .{ .suffix = "RepositoryManager.GetRepository", .permission = "cloudbuild.repositories.get" },
        .{ .suffix = "RepositoryManager.CreateRepository", .permission = "cloudbuild.repositories.create" },
        .{ .suffix = "RepositoryManager.DeleteRepository", .permission = "cloudbuild.repositories.delete" },
        .{ .suffix = "CloudBuild.GetWorkerPool", .permission = "cloudbuild.workerpools.get" },
        .{ .suffix = "CloudBuild.CreateWorkerPool", .permission = "cloudbuild.workerpools.create" },
        .{ .suffix = "CloudBuild.UpdateWorkerPool", .permission = "cloudbuild.workerpools.update" },
        .{ .suffix = "CloudBuild.DeleteWorkerPool", .permission = "cloudbuild.workerpools.delete" },
        .{ .suffix = "CloudBuild.GetBuildTrigger", .permission = "cloudbuild.builds.get" },
        .{ .suffix = "CloudBuild.CreateBuildTrigger", .permission = "cloudbuild.builds.create" },
        .{ .suffix = "CloudBuild.PatchBuildTrigger", .permission = "cloudbuild.builds.update" },
        .{ .suffix = "CloudBuild.DeleteBuildTrigger", .permission = "cloudbuild.builds.delete" },
        .{ .suffix = "CloudDeploy.GetDeliveryPipeline", .permission = "clouddeploy.deliveryPipelines.get" },
        .{ .suffix = "CloudDeploy.CreateDeliveryPipeline", .permission = "clouddeploy.deliveryPipelines.create" },
        .{ .suffix = "CloudDeploy.UpdateDeliveryPipeline", .permission = "clouddeploy.deliveryPipelines.update" },
        .{ .suffix = "CloudDeploy.DeleteDeliveryPipeline", .permission = "clouddeploy.deliveryPipelines.delete" },
        .{ .suffix = "CloudDeploy.GetTarget", .permission = "clouddeploy.targets.get" },
        .{ .suffix = "CloudDeploy.CreateTarget", .permission = "clouddeploy.targets.create" },
        .{ .suffix = "CloudDeploy.UpdateTarget", .permission = "clouddeploy.targets.update" },
        .{ .suffix = "CloudDeploy.DeleteTarget", .permission = "clouddeploy.targets.delete" },
        .{ .suffix = "CloudDeploy.GetCustomTargetType", .permission = "clouddeploy.customTargetTypes.get" },
        .{ .suffix = "CloudDeploy.CreateCustomTargetType", .permission = "clouddeploy.customTargetTypes.create" },
        .{ .suffix = "CloudDeploy.UpdateCustomTargetType", .permission = "clouddeploy.customTargetTypes.update" },
        .{ .suffix = "CloudDeploy.DeleteCustomTargetType", .permission = "clouddeploy.customTargetTypes.delete" },
        .{ .suffix = "CloudDeploy.GetAutomation", .permission = "clouddeploy.automations.get" },
        .{ .suffix = "CloudDeploy.CreateAutomation", .permission = "clouddeploy.automations.create" },
        .{ .suffix = "CloudDeploy.UpdateAutomation", .permission = "clouddeploy.automations.update" },
        .{ .suffix = "CloudDeploy.DeleteAutomation", .permission = "clouddeploy.automations.delete" },
        .{ .suffix = "CloudDeploy.GetDeployPolicy", .permission = "clouddeploy.deployPolicies.get" },
        .{ .suffix = "CloudDeploy.CreateDeployPolicy", .permission = "clouddeploy.deployPolicies.create" },
        .{ .suffix = "CloudDeploy.UpdateDeployPolicy", .permission = "clouddeploy.deployPolicies.update" },
        .{ .suffix = "CloudDeploy.DeleteDeployPolicy", .permission = "clouddeploy.deployPolicies.delete" },
        .{ .suffix = "ArtifactRegistry.GetRepository", .permission = "artifactregistry.repositories.get" },
        .{ .suffix = "ArtifactRegistry.CreateRepository", .permission = "artifactregistry.repositories.create" },
        .{ .suffix = "ArtifactRegistry.UpdateRepository", .permission = "artifactregistry.repositories.update" },
        .{ .suffix = "ArtifactRegistry.DeleteRepository", .permission = "artifactregistry.repositories.delete" },
        .{ .suffix = "ArtifactRegistry.GetProjectSettings", .permission = "artifactregistry.projectsettings.get" },
        .{ .suffix = "ArtifactRegistry.UpdateProjectSettings", .permission = "artifactregistry.projectsettings.update" },
        .{ .suffix = "ArtifactRegistry.GetVPCSCConfig", .permission = "artifactregistry.vpcscconfigs.get" },
        .{ .suffix = "ArtifactRegistry.UpdateVPCSCConfig", .permission = "artifactregistry.vpcscconfigs.update" },
        .{ .suffix = "ConfigServiceV2.GetBucket", .permission = "logging.buckets.get" },
        .{ .suffix = "ConfigServiceV2.CreateBucketAsync", .permission = "logging.buckets.create" },
        .{ .suffix = "ConfigServiceV2.UpdateBucketAsync", .permission = "logging.buckets.update" },
        .{ .suffix = "ConfigServiceV2.DeleteBucket", .permission = "logging.buckets.delete" },
        .{ .suffix = "ConfigServiceV2.GetView", .permission = "logging.views.get" },
        .{ .suffix = "ConfigServiceV2.CreateView", .permission = "logging.views.create" },
        .{ .suffix = "ConfigServiceV2.UpdateView", .permission = "logging.views.update" },
        .{ .suffix = "ConfigServiceV2.DeleteView", .permission = "logging.views.delete" },
        .{ .suffix = "ConfigServiceV2.GetSink", .permission = "logging.sinks.get" },
        .{ .suffix = "ConfigServiceV2.CreateSink", .permission = "logging.sinks.create" },
        .{ .suffix = "ConfigServiceV2.UpdateSink", .permission = "logging.sinks.update" },
        .{ .suffix = "ConfigServiceV2.DeleteSink", .permission = "logging.sinks.delete" },
        .{ .suffix = "ConfigServiceV2.GetExclusion", .permission = "logging.exclusions.get" },
        .{ .suffix = "ConfigServiceV2.CreateExclusion", .permission = "logging.exclusions.create" },
        .{ .suffix = "ConfigServiceV2.UpdateExclusion", .permission = "logging.exclusions.update" },
        .{ .suffix = "ConfigServiceV2.DeleteExclusion", .permission = "logging.exclusions.delete" },
        .{ .suffix = "MetricsServiceV2.GetLogMetric", .permission = "logging.logMetrics.get" },
        .{ .suffix = "MetricsServiceV2.CreateLogMetric", .permission = "logging.logMetrics.create" },
        .{ .suffix = "MetricsServiceV2.UpdateLogMetric", .permission = "logging.logMetrics.update" },
        .{ .suffix = "MetricsServiceV2.DeleteLogMetric", .permission = "logging.logMetrics.delete" },
        .{ .suffix = "AlertPolicyService.GetAlertPolicy", .permission = "monitoring.alertPolicies.get" },
        .{ .suffix = "AlertPolicyService.CreateAlertPolicy", .permission = "monitoring.alertPolicies.create" },
        .{ .suffix = "AlertPolicyService.UpdateAlertPolicy", .permission = "monitoring.alertPolicies.update" },
        .{ .suffix = "AlertPolicyService.DeleteAlertPolicy", .permission = "monitoring.alertPolicies.delete" },
        .{ .suffix = "UptimeCheckService.GetUptimeCheckConfig", .permission = "monitoring.uptimeCheckConfigs.get" },
        .{ .suffix = "UptimeCheckService.CreateUptimeCheckConfig", .permission = "monitoring.uptimeCheckConfigs.create" },
        .{ .suffix = "UptimeCheckService.UpdateUptimeCheckConfig", .permission = "monitoring.uptimeCheckConfigs.update" },
        .{ .suffix = "UptimeCheckService.DeleteUptimeCheckConfig", .permission = "monitoring.uptimeCheckConfigs.delete" },
        .{ .suffix = "NotificationChannelService.GetNotificationChannel", .permission = "monitoring.notificationChannels.get" },
        .{ .suffix = "NotificationChannelService.CreateNotificationChannel", .permission = "monitoring.notificationChannels.create" },
        .{ .suffix = "NotificationChannelService.UpdateNotificationChannel", .permission = "monitoring.notificationChannels.update" },
        .{ .suffix = "NotificationChannelService.DeleteNotificationChannel", .permission = "monitoring.notificationChannels.delete" },
        .{ .suffix = "DashboardsService.GetDashboard", .permission = "monitoring.dashboards.get" },
        .{ .suffix = "DashboardsService.CreateDashboard", .permission = "monitoring.dashboards.create" },
        .{ .suffix = "DashboardsService.UpdateDashboard", .permission = "monitoring.dashboards.update" },
        .{ .suffix = "DashboardsService.DeleteDashboard", .permission = "monitoring.dashboards.delete" },
        .{ .suffix = "ServiceMonitoringService.GetService", .permission = "monitoring.services.get" },
        .{ .suffix = "ServiceMonitoringService.CreateService", .permission = "monitoring.services.create" },
        .{ .suffix = "ServiceMonitoringService.UpdateService", .permission = "monitoring.services.update" },
        .{ .suffix = "ServiceMonitoringService.DeleteService", .permission = "monitoring.services.delete" },
        .{ .suffix = "ServiceMonitoringService.GetServiceLevelObjective", .permission = "monitoring.slos.get" },
        .{ .suffix = "ServiceMonitoringService.CreateServiceLevelObjective", .permission = "monitoring.slos.create" },
        .{ .suffix = "ServiceMonitoringService.UpdateServiceLevelObjective", .permission = "monitoring.slos.update" },
        .{ .suffix = "ServiceMonitoringService.DeleteServiceLevelObjective", .permission = "monitoring.slos.delete" },
        .{ .suffix = "ClusterManager.GetCluster", .permission = "container.clusters.get" },
        .{ .suffix = "ClusterManager.CreateCluster", .permission = "container.clusters.create" },
        .{ .suffix = "ClusterManager.UpdateCluster", .permission = "container.clusters.update" },
        .{ .suffix = "ClusterManager.DeleteCluster", .permission = "container.clusters.delete" },
        .{ .suffix = "ClusterManager.GetNodePool", .permission = "container.clusters.get" },
        .{ .suffix = "ClusterManager.CreateNodePool", .permission = "container.clusters.update" },
        .{ .suffix = "ClusterManager.UpdateNodePool", .permission = "container.clusters.update" },
        .{ .suffix = "ClusterManager.DeleteNodePool", .permission = "container.clusters.update" },
        .{ .suffix = "GkeHub.GetFleet", .permission = "gkehub.fleet.get" },
        .{ .suffix = "GkeHub.CreateFleet", .permission = "gkehub.fleet.create" },
        .{ .suffix = "GkeHub.UpdateFleet", .permission = "gkehub.fleet.update" },
        .{ .suffix = "GkeHub.DeleteFleet", .permission = "gkehub.fleet.delete" },
        .{ .suffix = "GkeHub.GetMembership", .permission = "gkehub.memberships.get" },
        .{ .suffix = "GkeHub.CreateMembership", .permission = "gkehub.memberships.create" },
        .{ .suffix = "GkeHub.UpdateMembership", .permission = "gkehub.memberships.update" },
        .{ .suffix = "GkeHub.DeleteMembership", .permission = "gkehub.memberships.delete" },
        .{ .suffix = "FunctionService.GetFunction", .permission = "cloudfunctions.functions.get" },
        .{ .suffix = "FunctionService.CreateFunction", .permission = "cloudfunctions.functions.create" },
        .{ .suffix = "FunctionService.UpdateFunction", .permission = "cloudfunctions.functions.update" },
        .{ .suffix = "FunctionService.DeleteFunction", .permission = "cloudfunctions.functions.delete" },
        .{ .suffix = "FunctionIam.GetIamPolicy", .permission = "cloudfunctions.functions.getIamPolicy" },
        .{ .suffix = "FunctionIam.SetIamPolicy", .permission = "cloudfunctions.functions.setIamPolicy" },
        .{ .suffix = "BatchService.GetJob", .permission = "batch.jobs.get" },
        .{ .suffix = "BatchService.CreateJob", .permission = "batch.jobs.create" },
        .{ .suffix = "BatchService.DeleteJob", .permission = "batch.jobs.delete" },
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
        .{ .suffix = "SqlInstancesService.Get", .permission = "cloudsql.instances.get" },
        .{ .suffix = "SqlInstancesService.Create", .permission = "cloudsql.instances.create" },
        .{ .suffix = "SqlInstancesService.Update", .permission = "cloudsql.instances.update" },
        .{ .suffix = "SqlInstancesService.Delete", .permission = "cloudsql.instances.delete" },
        .{ .suffix = "SqlDatabasesService.Get", .permission = "cloudsql.databases.get" },
        .{ .suffix = "SqlDatabasesService.Create", .permission = "cloudsql.databases.create" },
        .{ .suffix = "SqlDatabasesService.Update", .permission = "cloudsql.databases.update" },
        .{ .suffix = "SqlDatabasesService.Delete", .permission = "cloudsql.databases.delete" },
        .{ .suffix = "SqlUsersService.Get", .permission = "cloudsql.users.get" },
        .{ .suffix = "SqlUsersService.Create", .permission = "cloudsql.users.create" },
        .{ .suffix = "SqlUsersService.Update", .permission = "cloudsql.users.update" },
        .{ .suffix = "SqlUsersService.Delete", .permission = "cloudsql.users.delete" },
        .{ .suffix = "SqlSslCertsService.Get", .permission = "cloudsql.sslCerts.get" },
        .{ .suffix = "SqlSslCertsService.Create", .permission = "cloudsql.sslCerts.create" },
        .{ .suffix = "SqlSslCertsService.Delete", .permission = "cloudsql.sslCerts.delete" },
        .{ .suffix = "SpannerInstanceAdmin.GetInstance", .permission = "spanner.instances.get" },
        .{ .suffix = "SpannerInstanceAdmin.CreateInstance", .permission = "spanner.instances.create" },
        .{ .suffix = "SpannerInstanceAdmin.UpdateInstance", .permission = "spanner.instances.update" },
        .{ .suffix = "SpannerInstanceAdmin.DeleteInstance", .permission = "spanner.instances.delete" },
        .{ .suffix = "SpannerInstanceAdmin.GetIamPolicy", .permission = "spanner.instances.getIamPolicy" },
        .{ .suffix = "SpannerInstanceAdmin.SetIamPolicy", .permission = "spanner.instances.setIamPolicy" },
        .{ .suffix = "SpannerDatabaseAdmin.GetDatabase", .permission = "spanner.databases.get" },
        .{ .suffix = "SpannerDatabaseAdmin.CreateDatabase", .permission = "spanner.databases.create" },
        .{ .suffix = "SpannerDatabaseAdmin.UpdateDatabaseDdl", .permission = "spanner.databases.updateDdl" },
        .{ .suffix = "SpannerDatabaseAdmin.DropDatabase", .permission = "spanner.databases.drop" },
        .{ .suffix = "SpannerDatabaseAdmin.GetIamPolicy", .permission = "spanner.databases.getIamPolicy" },
        .{ .suffix = "SpannerDatabaseAdmin.SetIamPolicy", .permission = "spanner.databases.setIamPolicy" },
        .{ .suffix = "SpannerDatabaseAdmin.GetBackup", .permission = "spanner.backups.get" },
        .{ .suffix = "SpannerDatabaseAdmin.CreateBackup", .permission = "spanner.backups.create" },
        .{ .suffix = "SpannerDatabaseAdmin.AuthorizeCreateBackup", .permission = "spanner.databases.createBackup" },
        .{ .suffix = "SpannerDatabaseAdmin.UpdateBackup", .permission = "spanner.backups.update" },
        .{ .suffix = "SpannerDatabaseAdmin.DeleteBackup", .permission = "spanner.backups.delete" },
        .{ .suffix = "SpannerDatabaseAdmin.GetBackupSchedule", .permission = "spanner.backupSchedules.get" },
        .{ .suffix = "SpannerDatabaseAdmin.CreateBackupSchedule", .permission = "spanner.backupSchedules.create" },
        .{ .suffix = "SpannerDatabaseAdmin.UpdateBackupSchedule", .permission = "spanner.backupSchedules.update" },
        .{ .suffix = "SpannerDatabaseAdmin.DeleteBackupSchedule", .permission = "spanner.backupSchedules.delete" },
        .{ .suffix = "RedisInstances.Get", .permission = "redis.instances.get" },
        .{ .suffix = "RedisInstances.Create", .permission = "redis.instances.create" },
        .{ .suffix = "RedisInstances.Update", .permission = "redis.instances.update" },
        .{ .suffix = "RedisInstances.Delete", .permission = "redis.instances.delete" },
        .{ .suffix = "RedisInstances.Upgrade", .permission = "redis.instances.upgrade" },
        .{ .suffix = "RedisInstances.GetAuthString", .permission = "redis.instances.getAuthString" },
        .{ .suffix = "RedisClusters.Get", .permission = "redis.clusters.get" },
        .{ .suffix = "RedisClusters.Create", .permission = "redis.clusters.create" },
        .{ .suffix = "RedisClusters.Update", .permission = "redis.clusters.update" },
        .{ .suffix = "RedisClusters.Delete", .permission = "redis.clusters.delete" },
        .{ .suffix = "RedisAclPolicies.Get", .permission = "redis.aclPolicies.get" },
        .{ .suffix = "RedisAclPolicies.Create", .permission = "redis.aclPolicies.create" },
        .{ .suffix = "RedisAclPolicies.Update", .permission = "redis.aclPolicies.update" },
        .{ .suffix = "RedisAclPolicies.Delete", .permission = "redis.aclPolicies.delete" },
        .{ .suffix = "Workflows.GetWorkflow", .permission = "workflows.workflows.get" },
        .{ .suffix = "Workflows.CreateWorkflow", .permission = "workflows.workflows.create" },
        .{ .suffix = "Workflows.UpdateWorkflow", .permission = "workflows.workflows.update" },
        .{ .suffix = "Workflows.DeleteWorkflow", .permission = "workflows.workflows.delete" },
        .{ .suffix = "Apis.GetApi", .permission = "apigateway.apis.get" },
        .{ .suffix = "Apis.CreateApi", .permission = "apigateway.apis.create" },
        .{ .suffix = "Apis.UpdateApi", .permission = "apigateway.apis.update" },
        .{ .suffix = "Apis.DeleteApi", .permission = "apigateway.apis.delete" },
        .{ .suffix = "Apis.GetIamPolicy", .permission = "apigateway.apis.getIamPolicy" },
        .{ .suffix = "Apis.SetIamPolicy", .permission = "apigateway.apis.setIamPolicy" },
        .{ .suffix = "ApiConfigs.GetApiConfig", .permission = "apigateway.apiconfigs.get" },
        .{ .suffix = "ApiConfigs.CreateApiConfig", .permission = "apigateway.apiconfigs.create" },
        .{ .suffix = "ApiConfigs.UpdateApiConfig", .permission = "apigateway.apiconfigs.update" },
        .{ .suffix = "ApiConfigs.DeleteApiConfig", .permission = "apigateway.apiconfigs.delete" },
        .{ .suffix = "ApiConfigs.GetIamPolicy", .permission = "apigateway.apiconfigs.getIamPolicy" },
        .{ .suffix = "ApiConfigs.SetIamPolicy", .permission = "apigateway.apiconfigs.setIamPolicy" },
        .{ .suffix = "Gateways.GetGateway", .permission = "apigateway.gateways.get" },
        .{ .suffix = "Gateways.CreateGateway", .permission = "apigateway.gateways.create" },
        .{ .suffix = "Gateways.UpdateGateway", .permission = "apigateway.gateways.update" },
        .{ .suffix = "Gateways.DeleteGateway", .permission = "apigateway.gateways.delete" },
        .{ .suffix = "Gateways.GetIamPolicy", .permission = "apigateway.gateways.getIamPolicy" },
        .{ .suffix = "Gateways.SetIamPolicy", .permission = "apigateway.gateways.setIamPolicy" },
        .{ .suffix = "Projects.GetConfig", .permission = "identitytoolkit.configs.get" },
        .{ .suffix = "Projects.UpdateConfig", .permission = "identitytoolkit.configs.update" },
        .{ .suffix = "Tenants.GetTenant", .permission = "identitytoolkit.tenants.get" },
        .{ .suffix = "Tenants.CreateTenant", .permission = "identitytoolkit.tenants.create" },
        .{ .suffix = "Tenants.UpdateTenant", .permission = "identitytoolkit.tenants.update" },
        .{ .suffix = "Tenants.DeleteTenant", .permission = "identitytoolkit.tenants.delete" },
        .{ .suffix = "Tenants.GetIamPolicy", .permission = "identitytoolkit.tenants.getIamPolicy" },
        .{ .suffix = "Tenants.SetIamPolicy", .permission = "identitytoolkit.tenants.setIamPolicy" },
        .{ .suffix = "OAuthIdpConfigs.GetOAuthIdpConfig", .permission = "identitytoolkit.oauthIdpConfigs.get" },
        .{ .suffix = "OAuthIdpConfigs.CreateOAuthIdpConfig", .permission = "identitytoolkit.oauthIdpConfigs.create" },
        .{ .suffix = "OAuthIdpConfigs.UpdateOAuthIdpConfig", .permission = "identitytoolkit.oauthIdpConfigs.update" },
        .{ .suffix = "OAuthIdpConfigs.DeleteOAuthIdpConfig", .permission = "identitytoolkit.oauthIdpConfigs.delete" },
        .{ .suffix = "InboundSamlConfigs.GetInboundSamlConfig", .permission = "identitytoolkit.inboundSamlConfigs.get" },
        .{ .suffix = "InboundSamlConfigs.CreateInboundSamlConfig", .permission = "identitytoolkit.inboundSamlConfigs.create" },
        .{ .suffix = "InboundSamlConfigs.UpdateInboundSamlConfig", .permission = "identitytoolkit.inboundSamlConfigs.update" },
        .{ .suffix = "InboundSamlConfigs.DeleteInboundSamlConfig", .permission = "identitytoolkit.inboundSamlConfigs.delete" },
        .{ .suffix = "ParameterManager.GetParameter", .permission = "parametermanager.parameters.get" },
        .{ .suffix = "ParameterManager.CreateParameter", .permission = "parametermanager.parameters.create" },
        .{ .suffix = "ParameterManager.UpdateParameter", .permission = "parametermanager.parameters.update" },
        .{ .suffix = "ParameterManager.DeleteParameter", .permission = "parametermanager.parameters.delete" },
        .{ .suffix = "ParameterManager.GetParameterVersion", .permission = "parametermanager.parameterVersions.get" },
        .{ .suffix = "ParameterManager.CreateParameterVersion", .permission = "parametermanager.parameterVersions.create" },
        .{ .suffix = "ParameterManager.UpdateParameterVersion", .permission = "parametermanager.parameterVersions.update" },
        .{ .suffix = "ParameterManager.DeleteParameterVersion", .permission = "parametermanager.parameterVersions.delete" },
        .{ .suffix = "ParameterManager.GetTemplate", .permission = "parametermanager.templates.get" },
        .{ .suffix = "ParameterManager.CreateTemplate", .permission = "parametermanager.templates.create" },
        .{ .suffix = "ParameterManager.UpdateTemplate", .permission = "parametermanager.templates.update" },
        .{ .suffix = "ParameterManager.DeleteTemplate", .permission = "parametermanager.templates.delete" },
        .{ .suffix = "ParameterManager.GetTemplateVersion", .permission = "parametermanager.templateVersions.get" },
        .{ .suffix = "ParameterManager.CreateTemplateVersion", .permission = "parametermanager.templateVersions.create" },
        .{ .suffix = "ParameterManager.UpdateTemplateVersion", .permission = "parametermanager.templateVersions.update" },
        .{ .suffix = "ParameterManager.DeleteTemplateVersion", .permission = "parametermanager.templateVersions.delete" },
        .{ .suffix = "PrivateServiceRanges.Get", .permission = "compute.globalAddresses.get" },
        .{ .suffix = "PrivateServiceRanges.Create", .permission = "compute.globalAddresses.create" },
        .{ .suffix = "PrivateServiceRanges.Delete", .permission = "compute.globalAddresses.delete" },
        .{ .suffix = "ServiceNetworkingConnections.Get", .permission = "servicenetworking.services.get" },
        .{ .suffix = "ServiceNetworkingConnections.Create", .permission = "servicenetworking.services.addPeering" },
        .{ .suffix = "ServiceNetworkingConnections.Update", .permission = "servicenetworking.services.addPeering" },
        .{ .suffix = "ServiceNetworkingConnections.Delete", .permission = "servicenetworking.services.deleteConnection" },
        .{ .suffix = "KeyRings.GetKeyRing", .permission = "cloudkms.keyRings.get" },
        .{ .suffix = "KeyRings.CreateKeyRing", .permission = "cloudkms.keyRings.create" },
        .{ .suffix = "KeyRings.GetIamPolicy", .permission = "cloudkms.keyRings.getIamPolicy" },
        .{ .suffix = "KeyRings.SetIamPolicy", .permission = "cloudkms.keyRings.setIamPolicy" },
        .{ .suffix = "CryptoKeys.GetCryptoKey", .permission = "cloudkms.cryptoKeys.get" },
        .{ .suffix = "CryptoKeys.CreateCryptoKey", .permission = "cloudkms.cryptoKeys.create" },
        .{ .suffix = "CryptoKeys.UpdateCryptoKey", .permission = "cloudkms.cryptoKeys.update" },
        .{ .suffix = "CryptoKeys.GetIamPolicy", .permission = "cloudkms.cryptoKeys.getIamPolicy" },
        .{ .suffix = "CryptoKeys.SetIamPolicy", .permission = "cloudkms.cryptoKeys.setIamPolicy" },
        .{ .suffix = "CryptoKeyVersions.GetCryptoKeyVersion", .permission = "cloudkms.cryptoKeyVersions.get" },
        .{ .suffix = "CryptoKeyVersions.CreateCryptoKeyVersion", .permission = "cloudkms.cryptoKeyVersions.create" },
        .{ .suffix = "CryptoKeyVersions.UpdateCryptoKeyVersion", .permission = "cloudkms.cryptoKeyVersions.update" },
        .{ .suffix = "SecretManagerService.GetSecret", .permission = "secretmanager.secrets.get" },
        .{ .suffix = "SecretManagerService.CreateSecret", .permission = "secretmanager.secrets.create" },
        .{ .suffix = "SecretManagerService.UpdateSecret", .permission = "secretmanager.secrets.update" },
        .{ .suffix = "SecretManagerService.DeleteSecret", .permission = "secretmanager.secrets.delete" },
        .{ .suffix = "SecretManagerService.GetSecretVersion", .permission = "secretmanager.versions.get" },
        .{ .suffix = "SecretVersions.AddSecretVersion", .permission = "secretmanager.versions.add" },
        .{ .suffix = "SecretManagerService.EnableSecretVersion", .permission = "secretmanager.versions.enable" },
        .{ .suffix = "SecretManagerService.DisableSecretVersion", .permission = "secretmanager.versions.disable" },
        .{ .suffix = "SecretManagerService.GetIamPolicy", .permission = "secretmanager.secrets.getIamPolicy" },
        .{ .suffix = "SecretManagerService.SetIamPolicy", .permission = "secretmanager.secrets.setIamPolicy" },
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
        .{ .suffix = "Disks.Get", .permission = "compute.disks.get" },
        .{ .suffix = "Disks.Insert", .permission = "compute.disks.create" },
        .{ .suffix = "Disks.Delete", .permission = "compute.disks.delete" },
        .{ .suffix = "Disks.Resize", .permission = "compute.disks.update" },
        .{ .suffix = "Images.Get", .permission = "compute.images.get" },
        .{ .suffix = "Images.Insert", .permission = "compute.images.create" },
        .{ .suffix = "Images.Delete", .permission = "compute.images.delete" },
        .{ .suffix = "Images.UseReadOnly", .permission = "compute.images.useReadOnly" },
        .{ .suffix = "Instances.Get", .permission = "compute.instances.get" },
        .{ .suffix = "Instances.Insert", .permission = "compute.instances.create" },
        .{ .suffix = "Instances.Delete", .permission = "compute.instances.delete" },
        .{ .suffix = "Instances.SetDeletionProtection", .permission = "compute.instances.update" },
        .{ .suffix = "InstanceTemplates.Get", .permission = "compute.instanceTemplates.get" },
        .{ .suffix = "InstanceTemplates.Insert", .permission = "compute.instanceTemplates.create" },
        .{ .suffix = "InstanceTemplates.Delete", .permission = "compute.instanceTemplates.delete" },
        .{ .suffix = "InstanceGroupManagers.Get", .permission = "compute.instanceGroupManagers.get" },
        .{ .suffix = "InstanceGroupManagers.Insert", .permission = "compute.instanceGroupManagers.create" },
        .{ .suffix = "InstanceGroupManagers.Patch", .permission = "compute.instanceGroupManagers.update" },
        .{ .suffix = "InstanceGroupManagers.Delete", .permission = "compute.instanceGroupManagers.delete" },
        .{ .suffix = "Autoscalers.Get", .permission = "compute.autoscalers.get" },
        .{ .suffix = "Autoscalers.Insert", .permission = "compute.autoscalers.create" },
        .{ .suffix = "Autoscalers.Patch", .permission = "compute.autoscalers.update" },
        .{ .suffix = "Autoscalers.Delete", .permission = "compute.autoscalers.delete" },
        .{ .suffix = "Firewalls.Get", .permission = "compute.firewalls.get" },
        .{ .suffix = "Firewalls.Insert", .permission = "compute.firewalls.create" },
        .{ .suffix = "Firewalls.Patch", .permission = "compute.firewalls.update" },
        .{ .suffix = "Firewalls.Delete", .permission = "compute.firewalls.delete" },
        .{ .suffix = "Routes.Get", .permission = "compute.routes.get" },
        .{ .suffix = "Routes.Insert", .permission = "compute.routes.create" },
        .{ .suffix = "Routes.Delete", .permission = "compute.routes.delete" },
        .{ .suffix = "RegionHealthChecks.Get", .permission = "compute.regionHealthChecks.get" },
        .{ .suffix = "RegionHealthChecks.Insert", .permission = "compute.regionHealthChecks.create" },
        .{ .suffix = "RegionHealthChecks.Update", .permission = "compute.regionHealthChecks.update" },
        .{ .suffix = "RegionHealthChecks.Delete", .permission = "compute.regionHealthChecks.delete" },
        .{ .suffix = "RegionHealthChecks.UseReadOnly", .permission = "compute.regionHealthChecks.useReadOnly" },
        .{ .suffix = "HealthChecks.Get", .permission = "compute.healthChecks.get" },
        .{ .suffix = "HealthChecks.Insert", .permission = "compute.healthChecks.create" },
        .{ .suffix = "HealthChecks.Update", .permission = "compute.healthChecks.update" },
        .{ .suffix = "HealthChecks.Delete", .permission = "compute.healthChecks.delete" },
        .{ .suffix = "HealthChecks.UseReadOnly", .permission = "compute.healthChecks.useReadOnly" },
        .{ .suffix = "Addresses.Get", .permission = "compute.addresses.get" },
        .{ .suffix = "Addresses.InsertInternal", .permission = "compute.addresses.createInternal" },
        .{ .suffix = "Addresses.DeleteInternal", .permission = "compute.addresses.deleteInternal" },
        .{ .suffix = "Addresses.Use", .permission = "compute.addresses.use" },
        .{ .suffix = "Addresses.UseInternal", .permission = "compute.addresses.useInternal" },
        .{ .suffix = "RegionBackendServices.Get", .permission = "compute.regionBackendServices.get" },
        .{ .suffix = "RegionBackendServices.Insert", .permission = "compute.regionBackendServices.create" },
        .{ .suffix = "RegionBackendServices.Update", .permission = "compute.regionBackendServices.update" },
        .{ .suffix = "RegionBackendServices.Delete", .permission = "compute.regionBackendServices.delete" },
        .{ .suffix = "RegionBackendServices.Use", .permission = "compute.regionBackendServices.use" },
        .{ .suffix = "RegionUrlMaps.Get", .permission = "compute.regionUrlMaps.get" },
        .{ .suffix = "RegionUrlMaps.Insert", .permission = "compute.regionUrlMaps.create" },
        .{ .suffix = "RegionUrlMaps.Update", .permission = "compute.regionUrlMaps.update" },
        .{ .suffix = "RegionUrlMaps.Delete", .permission = "compute.regionUrlMaps.delete" },
        .{ .suffix = "RegionUrlMaps.Use", .permission = "compute.regionUrlMaps.use" },
        .{ .suffix = "RegionTargetHttpProxies.Get", .permission = "compute.regionTargetHttpProxies.get" },
        .{ .suffix = "RegionTargetHttpProxies.Insert", .permission = "compute.regionTargetHttpProxies.create" },
        .{ .suffix = "RegionTargetHttpProxies.SetUrlMap", .permission = "compute.regionTargetHttpProxies.setUrlMap" },
        .{ .suffix = "RegionTargetHttpProxies.Delete", .permission = "compute.regionTargetHttpProxies.delete" },
        .{ .suffix = "RegionTargetHttpProxies.Use", .permission = "compute.regionTargetHttpProxies.use" },
        .{ .suffix = "ForwardingRules.Get", .permission = "compute.forwardingRules.get" },
        .{ .suffix = "ForwardingRules.Insert", .permission = "compute.forwardingRules.create" },
        .{ .suffix = "ForwardingRules.Delete", .permission = "compute.forwardingRules.delete" },
        .{ .suffix = "Networks.Use", .permission = "compute.networks.use" },
        .{ .suffix = "Networks.Get", .permission = "compute.networks.get" },
        .{ .suffix = "Subnetworks.Use", .permission = "compute.subnetworks.use" },
        .{ .suffix = "Disks.Use", .permission = "compute.disks.use" },
        .{ .suffix = "BackendBuckets.Get", .permission = "compute.backendBuckets.get" },
        .{ .suffix = "BackendBuckets.Insert", .permission = "compute.backendBuckets.create" },
        .{ .suffix = "BackendBuckets.Patch", .permission = "compute.backendBuckets.update" },
        .{ .suffix = "BackendBuckets.SetSecurityPolicy", .permission = "compute.backendBuckets.setSecurityPolicy" },
        .{ .suffix = "BackendBuckets.Delete", .permission = "compute.backendBuckets.delete" },
        .{ .suffix = "SecurityPolicies.Get", .permission = "compute.securityPolicies.get" },
        .{ .suffix = "SecurityPolicies.Insert", .permission = "compute.securityPolicies.create" },
        .{ .suffix = "SecurityPolicies.Patch", .permission = "compute.securityPolicies.update" },
        .{ .suffix = "SecurityPolicies.Delete", .permission = "compute.securityPolicies.delete" },
        .{ .suffix = "SslPolicies.Get", .permission = "compute.sslPolicies.get" },
        .{ .suffix = "SslPolicies.Insert", .permission = "compute.sslPolicies.create" },
        .{ .suffix = "SslPolicies.Patch", .permission = "compute.sslPolicies.update" },
        .{ .suffix = "SslPolicies.Delete", .permission = "compute.sslPolicies.delete" },
        .{ .suffix = "SslPolicies.Use", .permission = "compute.sslPolicies.use" },
        .{ .suffix = "TargetHttpsProxies.Get", .permission = "compute.targetHttpsProxies.get" },
        .{ .suffix = "TargetHttpsProxies.Insert", .permission = "compute.targetHttpsProxies.create" },
        .{ .suffix = "TargetHttpsProxies.Delete", .permission = "compute.targetHttpsProxies.delete" },
        .{ .suffix = "UrlMaps.Use", .permission = "compute.urlMaps.use" },
        .{ .suffix = "ExternalVpnGateways.Get", .permission = "compute.externalVpnGateways.get" },
        .{ .suffix = "ExternalVpnGateways.Insert", .permission = "compute.externalVpnGateways.create" },
        .{ .suffix = "ExternalVpnGateways.Delete", .permission = "compute.externalVpnGateways.delete" },
        .{ .suffix = "ExternalVpnGateways.Use", .permission = "compute.externalVpnGateways.use" },
        .{ .suffix = "VpnGateways.Get", .permission = "compute.vpnGateways.get" },
        .{ .suffix = "VpnGateways.Insert", .permission = "compute.vpnGateways.create" },
        .{ .suffix = "VpnGateways.Delete", .permission = "compute.vpnGateways.delete" },
        .{ .suffix = "VpnGateways.Use", .permission = "compute.vpnGateways.use" },
        .{ .suffix = "VpnTunnels.Get", .permission = "compute.vpnTunnels.get" },
        .{ .suffix = "VpnTunnels.Insert", .permission = "compute.vpnTunnels.create" },
        .{ .suffix = "VpnTunnels.Delete", .permission = "compute.vpnTunnels.delete" },
        .{ .suffix = "VpnTunnels.Use", .permission = "compute.vpnTunnels.use" },
        .{ .suffix = "Routers.Get", .permission = "compute.routers.get" },
        .{ .suffix = "Routers.Insert", .permission = "compute.routers.create" },
        .{ .suffix = "Routers.Patch", .permission = "compute.routers.update" },
        .{ .suffix = "Routers.Delete", .permission = "compute.routers.delete" },
        .{ .suffix = "Networks.AddPeering", .permission = "compute.networks.addPeering" },
        .{ .suffix = "Networks.UpdatePeering", .permission = "compute.networks.updatePeering" },
        .{ .suffix = "Networks.RemovePeering", .permission = "compute.networks.removePeering" },
        .{ .suffix = "Hubs.GetHub", .permission = "networkconnectivity.hubs.get" },
        .{ .suffix = "Hubs.CreateHub", .permission = "networkconnectivity.hubs.create" },
        .{ .suffix = "Hubs.UpdateHub", .permission = "networkconnectivity.hubs.update" },
        .{ .suffix = "Hubs.DeleteHub", .permission = "networkconnectivity.hubs.delete" },
        .{ .suffix = "Spokes.GetSpoke", .permission = "networkconnectivity.spokes.get" },
        .{ .suffix = "Spokes.CreateSpoke", .permission = "networkconnectivity.spokes.create" },
        .{ .suffix = "Spokes.UpdateSpoke", .permission = "networkconnectivity.spokes.update" },
        .{ .suffix = "Spokes.DeleteSpoke", .permission = "networkconnectivity.spokes.delete" },
        .{ .suffix = "ServiceConnectionPolicies.GetServiceConnectionPolicy", .permission = "networkconnectivity.serviceConnectionPolicies.get" },
        .{ .suffix = "ServiceConnectionPolicies.CreateServiceConnectionPolicy", .permission = "networkconnectivity.serviceConnectionPolicies.create" },
        .{ .suffix = "ServiceConnectionPolicies.UpdateServiceConnectionPolicy", .permission = "networkconnectivity.serviceConnectionPolicies.update" },
        .{ .suffix = "ServiceConnectionPolicies.DeleteServiceConnectionPolicy", .permission = "networkconnectivity.serviceConnectionPolicies.delete" },
        .{ .suffix = "DnsAuthorizations.GetDnsAuthorization", .permission = "certificatemanager.dnsauthorizations.get" },
        .{ .suffix = "DnsAuthorizations.CreateDnsAuthorization", .permission = "certificatemanager.dnsauthorizations.create" },
        .{ .suffix = "DnsAuthorizations.DeleteDnsAuthorization", .permission = "certificatemanager.dnsauthorizations.delete" },
        .{ .suffix = "DnsAuthorizations.UseDnsAuthorization", .permission = "certificatemanager.dnsauthorizations.use" },
        .{ .suffix = "Certificates.GetCertificate", .permission = "certificatemanager.certs.get" },
        .{ .suffix = "Certificates.CreateCertificate", .permission = "certificatemanager.certs.create" },
        .{ .suffix = "Certificates.DeleteCertificate", .permission = "certificatemanager.certs.delete" },
        .{ .suffix = "Certificates.UseCertificate", .permission = "certificatemanager.certs.use" },
        .{ .suffix = "CertificateMaps.GetCertificateMap", .permission = "certificatemanager.certmaps.get" },
        .{ .suffix = "CertificateMaps.CreateCertificateMap", .permission = "certificatemanager.certmaps.create" },
        .{ .suffix = "CertificateMaps.DeleteCertificateMap", .permission = "certificatemanager.certmaps.delete" },
        .{ .suffix = "CertificateMaps.UseCertificateMap", .permission = "certificatemanager.certmaps.use" },
        .{ .suffix = "CertificateMapEntries.GetCertificateMapEntry", .permission = "certificatemanager.certmapentries.get" },
        .{ .suffix = "CertificateMapEntries.CreateCertificateMapEntry", .permission = "certificatemanager.certmapentries.create" },
        .{ .suffix = "CertificateMapEntries.DeleteCertificateMapEntry", .permission = "certificatemanager.certmapentries.delete" },
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
    const build_connection = [_]RpcUsage{
        .{ .service = "cloudbuild.googleapis.com", .method = "google.devtools.cloudbuild.v2.RepositoryManager.GetConnection" },
        .{ .service = "cloudbuild.googleapis.com", .method = "google.devtools.cloudbuild.v2.RepositoryManager.CreateConnection" },
        .{ .service = "cloudbuild.googleapis.com", .method = "google.devtools.cloudbuild.v2.RepositoryManager.UpdateConnection" },
        .{ .service = "cloudbuild.googleapis.com", .method = "google.devtools.cloudbuild.v2.RepositoryManager.DeleteConnection" },
    };
    const build_repository = [_]RpcUsage{
        .{ .service = "cloudbuild.googleapis.com", .method = "google.devtools.cloudbuild.v2.RepositoryManager.GetRepository" },
        .{ .service = "cloudbuild.googleapis.com", .method = "google.devtools.cloudbuild.v2.RepositoryManager.CreateRepository" },
        .{ .service = "cloudbuild.googleapis.com", .method = "google.devtools.cloudbuild.v2.RepositoryManager.DeleteRepository" },
    };
    const build_worker_pool = [_]RpcUsage{
        .{ .service = "cloudbuild.googleapis.com", .method = "google.devtools.cloudbuild.v1.CloudBuild.GetWorkerPool" },
        .{ .service = "cloudbuild.googleapis.com", .method = "google.devtools.cloudbuild.v1.CloudBuild.CreateWorkerPool" },
        .{ .service = "cloudbuild.googleapis.com", .method = "google.devtools.cloudbuild.v1.CloudBuild.UpdateWorkerPool" },
        .{ .service = "cloudbuild.googleapis.com", .method = "google.devtools.cloudbuild.v1.CloudBuild.DeleteWorkerPool" },
    };
    const build_trigger = [_]RpcUsage{
        .{ .service = "cloudbuild.googleapis.com", .method = "google.devtools.cloudbuild.v1.CloudBuild.GetBuildTrigger" },
        .{ .service = "cloudbuild.googleapis.com", .method = "google.devtools.cloudbuild.v1.CloudBuild.CreateBuildTrigger" },
        .{ .service = "cloudbuild.googleapis.com", .method = "google.devtools.cloudbuild.v1.CloudBuild.PatchBuildTrigger" },
        .{ .service = "cloudbuild.googleapis.com", .method = "google.devtools.cloudbuild.v1.CloudBuild.DeleteBuildTrigger" },
    };
    const deploy_pipeline = [_]RpcUsage{
        .{ .service = "clouddeploy.googleapis.com", .method = "google.cloud.deploy.v1.CloudDeploy.GetDeliveryPipeline" },
        .{ .service = "clouddeploy.googleapis.com", .method = "google.cloud.deploy.v1.CloudDeploy.CreateDeliveryPipeline" },
        .{ .service = "clouddeploy.googleapis.com", .method = "google.cloud.deploy.v1.CloudDeploy.UpdateDeliveryPipeline" },
        .{ .service = "clouddeploy.googleapis.com", .method = "google.cloud.deploy.v1.CloudDeploy.DeleteDeliveryPipeline" },
    };
    const deploy_target = [_]RpcUsage{
        .{ .service = "clouddeploy.googleapis.com", .method = "google.cloud.deploy.v1.CloudDeploy.GetTarget" },
        .{ .service = "clouddeploy.googleapis.com", .method = "google.cloud.deploy.v1.CloudDeploy.CreateTarget" },
        .{ .service = "clouddeploy.googleapis.com", .method = "google.cloud.deploy.v1.CloudDeploy.UpdateTarget" },
        .{ .service = "clouddeploy.googleapis.com", .method = "google.cloud.deploy.v1.CloudDeploy.DeleteTarget" },
        .{ .service = "iam.googleapis.com", .method = "google.iam.admin.v1.ServiceAccounts.ActAs" },
    };
    const deploy_custom_target_type = [_]RpcUsage{
        .{ .service = "clouddeploy.googleapis.com", .method = "google.cloud.deploy.v1.CloudDeploy.GetCustomTargetType" },
        .{ .service = "clouddeploy.googleapis.com", .method = "google.cloud.deploy.v1.CloudDeploy.CreateCustomTargetType" },
        .{ .service = "clouddeploy.googleapis.com", .method = "google.cloud.deploy.v1.CloudDeploy.UpdateCustomTargetType" },
        .{ .service = "clouddeploy.googleapis.com", .method = "google.cloud.deploy.v1.CloudDeploy.DeleteCustomTargetType" },
    };
    const deploy_automation = [_]RpcUsage{
        .{ .service = "clouddeploy.googleapis.com", .method = "google.cloud.deploy.v1.CloudDeploy.GetAutomation" },
        .{ .service = "clouddeploy.googleapis.com", .method = "google.cloud.deploy.v1.CloudDeploy.CreateAutomation" },
        .{ .service = "clouddeploy.googleapis.com", .method = "google.cloud.deploy.v1.CloudDeploy.UpdateAutomation" },
        .{ .service = "clouddeploy.googleapis.com", .method = "google.cloud.deploy.v1.CloudDeploy.DeleteAutomation" },
        .{ .service = "iam.googleapis.com", .method = "google.iam.admin.v1.ServiceAccounts.ActAs" },
    };
    const deploy_policy = [_]RpcUsage{
        .{ .service = "clouddeploy.googleapis.com", .method = "google.cloud.deploy.v1.CloudDeploy.GetDeployPolicy" },
        .{ .service = "clouddeploy.googleapis.com", .method = "google.cloud.deploy.v1.CloudDeploy.CreateDeployPolicy" },
        .{ .service = "clouddeploy.googleapis.com", .method = "google.cloud.deploy.v1.CloudDeploy.UpdateDeployPolicy" },
        .{ .service = "clouddeploy.googleapis.com", .method = "google.cloud.deploy.v1.CloudDeploy.DeleteDeployPolicy" },
    };
    const artifact_repository = [_]RpcUsage{
        .{ .service = "artifactregistry.googleapis.com", .method = "google.devtools.artifactregistry.v1.ArtifactRegistry.GetRepository" },
        .{ .service = "artifactregistry.googleapis.com", .method = "google.devtools.artifactregistry.v1.ArtifactRegistry.CreateRepository" },
        .{ .service = "artifactregistry.googleapis.com", .method = "google.devtools.artifactregistry.v1.ArtifactRegistry.UpdateRepository" },
        .{ .service = "artifactregistry.googleapis.com", .method = "google.devtools.artifactregistry.v1.ArtifactRegistry.DeleteRepository" },
    };
    const artifact_project_settings = [_]RpcUsage{
        .{ .service = "artifactregistry.googleapis.com", .method = "google.devtools.artifactregistry.v1.ArtifactRegistry.GetProjectSettings" },
        .{ .service = "artifactregistry.googleapis.com", .method = "google.devtools.artifactregistry.v1.ArtifactRegistry.UpdateProjectSettings" },
    };
    const artifact_vpcsc = [_]RpcUsage{
        .{ .service = "artifactregistry.googleapis.com", .method = "google.devtools.artifactregistry.v1.ArtifactRegistry.GetVPCSCConfig" },
        .{ .service = "artifactregistry.googleapis.com", .method = "google.devtools.artifactregistry.v1.ArtifactRegistry.UpdateVPCSCConfig" },
    };
    const logging_bucket = [_]RpcUsage{
        .{ .service = "logging.googleapis.com", .method = "google.logging.v2.ConfigServiceV2.GetBucket" },
        .{ .service = "logging.googleapis.com", .method = "google.logging.v2.ConfigServiceV2.CreateBucketAsync" },
        .{ .service = "logging.googleapis.com", .method = "google.logging.v2.ConfigServiceV2.UpdateBucketAsync" },
        .{ .service = "logging.googleapis.com", .method = "google.logging.v2.ConfigServiceV2.DeleteBucket" },
    };
    const logging_view = [_]RpcUsage{
        .{ .service = "logging.googleapis.com", .method = "google.logging.v2.ConfigServiceV2.GetView" },
        .{ .service = "logging.googleapis.com", .method = "google.logging.v2.ConfigServiceV2.CreateView" },
        .{ .service = "logging.googleapis.com", .method = "google.logging.v2.ConfigServiceV2.UpdateView" },
        .{ .service = "logging.googleapis.com", .method = "google.logging.v2.ConfigServiceV2.DeleteView" },
    };
    const logging_sink = [_]RpcUsage{
        .{ .service = "logging.googleapis.com", .method = "google.logging.v2.ConfigServiceV2.GetSink" },
        .{ .service = "logging.googleapis.com", .method = "google.logging.v2.ConfigServiceV2.CreateSink" },
        .{ .service = "logging.googleapis.com", .method = "google.logging.v2.ConfigServiceV2.UpdateSink" },
        .{ .service = "logging.googleapis.com", .method = "google.logging.v2.ConfigServiceV2.DeleteSink" },
    };
    const logging_exclusion = [_]RpcUsage{
        .{ .service = "logging.googleapis.com", .method = "google.logging.v2.ConfigServiceV2.GetExclusion" },
        .{ .service = "logging.googleapis.com", .method = "google.logging.v2.ConfigServiceV2.CreateExclusion" },
        .{ .service = "logging.googleapis.com", .method = "google.logging.v2.ConfigServiceV2.UpdateExclusion" },
        .{ .service = "logging.googleapis.com", .method = "google.logging.v2.ConfigServiceV2.DeleteExclusion" },
    };
    const logging_metric = [_]RpcUsage{
        .{ .service = "logging.googleapis.com", .method = "google.logging.v2.MetricsServiceV2.GetLogMetric" },
        .{ .service = "logging.googleapis.com", .method = "google.logging.v2.MetricsServiceV2.CreateLogMetric" },
        .{ .service = "logging.googleapis.com", .method = "google.logging.v2.MetricsServiceV2.UpdateLogMetric" },
        .{ .service = "logging.googleapis.com", .method = "google.logging.v2.MetricsServiceV2.DeleteLogMetric" },
    };
    const monitoring_alert_policy = [_]RpcUsage{
        .{ .service = "monitoring.googleapis.com", .method = "google.monitoring.v3.AlertPolicyService.GetAlertPolicy" },
        .{ .service = "monitoring.googleapis.com", .method = "google.monitoring.v3.AlertPolicyService.CreateAlertPolicy" },
        .{ .service = "monitoring.googleapis.com", .method = "google.monitoring.v3.AlertPolicyService.UpdateAlertPolicy" },
        .{ .service = "monitoring.googleapis.com", .method = "google.monitoring.v3.AlertPolicyService.DeleteAlertPolicy" },
    };
    const monitoring_uptime_check = [_]RpcUsage{
        .{ .service = "monitoring.googleapis.com", .method = "google.monitoring.v3.UptimeCheckService.GetUptimeCheckConfig" },
        .{ .service = "monitoring.googleapis.com", .method = "google.monitoring.v3.UptimeCheckService.CreateUptimeCheckConfig" },
        .{ .service = "monitoring.googleapis.com", .method = "google.monitoring.v3.UptimeCheckService.UpdateUptimeCheckConfig" },
        .{ .service = "monitoring.googleapis.com", .method = "google.monitoring.v3.UptimeCheckService.DeleteUptimeCheckConfig" },
    };
    const monitoring_channel = [_]RpcUsage{
        .{ .service = "monitoring.googleapis.com", .method = "google.monitoring.v3.NotificationChannelService.GetNotificationChannel" },
        .{ .service = "monitoring.googleapis.com", .method = "google.monitoring.v3.NotificationChannelService.CreateNotificationChannel" },
        .{ .service = "monitoring.googleapis.com", .method = "google.monitoring.v3.NotificationChannelService.UpdateNotificationChannel" },
        .{ .service = "monitoring.googleapis.com", .method = "google.monitoring.v3.NotificationChannelService.DeleteNotificationChannel" },
    };
    const monitoring_dashboard = [_]RpcUsage{
        .{ .service = "monitoring.googleapis.com", .method = "google.monitoring.dashboard.v1.DashboardsService.GetDashboard" },
        .{ .service = "monitoring.googleapis.com", .method = "google.monitoring.dashboard.v1.DashboardsService.CreateDashboard" },
        .{ .service = "monitoring.googleapis.com", .method = "google.monitoring.dashboard.v1.DashboardsService.UpdateDashboard" },
        .{ .service = "monitoring.googleapis.com", .method = "google.monitoring.dashboard.v1.DashboardsService.DeleteDashboard" },
    };
    const monitoring_service = [_]RpcUsage{
        .{ .service = "monitoring.googleapis.com", .method = "google.monitoring.v3.ServiceMonitoringService.GetService" },
        .{ .service = "monitoring.googleapis.com", .method = "google.monitoring.v3.ServiceMonitoringService.CreateService" },
        .{ .service = "monitoring.googleapis.com", .method = "google.monitoring.v3.ServiceMonitoringService.UpdateService" },
        .{ .service = "monitoring.googleapis.com", .method = "google.monitoring.v3.ServiceMonitoringService.DeleteService" },
    };
    const monitoring_slo = [_]RpcUsage{
        .{ .service = "monitoring.googleapis.com", .method = "google.monitoring.v3.ServiceMonitoringService.GetServiceLevelObjective" },
        .{ .service = "monitoring.googleapis.com", .method = "google.monitoring.v3.ServiceMonitoringService.CreateServiceLevelObjective" },
        .{ .service = "monitoring.googleapis.com", .method = "google.monitoring.v3.ServiceMonitoringService.UpdateServiceLevelObjective" },
        .{ .service = "monitoring.googleapis.com", .method = "google.monitoring.v3.ServiceMonitoringService.DeleteServiceLevelObjective" },
    };
    const container_cluster = [_]RpcUsage{
        .{ .service = "container.googleapis.com", .method = "google.container.v1.ClusterManager.GetCluster" },
        .{ .service = "container.googleapis.com", .method = "google.container.v1.ClusterManager.CreateCluster" },
        .{ .service = "container.googleapis.com", .method = "google.container.v1.ClusterManager.UpdateCluster" },
        .{ .service = "container.googleapis.com", .method = "google.container.v1.ClusterManager.DeleteCluster" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Networks.Use" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Subnetworks.Use" },
    };
    const container_node_pool = [_]RpcUsage{
        .{ .service = "container.googleapis.com", .method = "google.container.v1.ClusterManager.GetNodePool" },
        .{ .service = "container.googleapis.com", .method = "google.container.v1.ClusterManager.CreateNodePool" },
        .{ .service = "container.googleapis.com", .method = "google.container.v1.ClusterManager.UpdateNodePool" },
        .{ .service = "container.googleapis.com", .method = "google.container.v1.ClusterManager.DeleteNodePool" },
        .{ .service = "iam.googleapis.com", .method = "google.iam.v1.ServiceAccounts.ActAs" },
    };
    const gke_fleet = [_]RpcUsage{
        .{ .service = "gkehub.googleapis.com", .method = "google.cloud.gkehub.v1.GkeHub.GetFleet" },
        .{ .service = "gkehub.googleapis.com", .method = "google.cloud.gkehub.v1.GkeHub.CreateFleet" },
        .{ .service = "gkehub.googleapis.com", .method = "google.cloud.gkehub.v1.GkeHub.UpdateFleet" },
        .{ .service = "gkehub.googleapis.com", .method = "google.cloud.gkehub.v1.GkeHub.DeleteFleet" },
    };
    const gke_membership = [_]RpcUsage{
        .{ .service = "gkehub.googleapis.com", .method = "google.cloud.gkehub.v1.GkeHub.GetMembership" },
        .{ .service = "gkehub.googleapis.com", .method = "google.cloud.gkehub.v1.GkeHub.CreateMembership" },
        .{ .service = "gkehub.googleapis.com", .method = "google.cloud.gkehub.v1.GkeHub.UpdateMembership" },
        .{ .service = "gkehub.googleapis.com", .method = "google.cloud.gkehub.v1.GkeHub.DeleteMembership" },
    };
    const cloud_function = [_]RpcUsage{
        .{ .service = "cloudfunctions.googleapis.com", .method = "google.cloud.functions.v2.FunctionService.GetFunction" },
        .{ .service = "cloudfunctions.googleapis.com", .method = "google.cloud.functions.v2.FunctionService.CreateFunction" },
        .{ .service = "cloudfunctions.googleapis.com", .method = "google.cloud.functions.v2.FunctionService.UpdateFunction" },
        .{ .service = "cloudfunctions.googleapis.com", .method = "google.cloud.functions.v2.FunctionService.DeleteFunction" },
        .{ .service = "iam.googleapis.com", .method = "google.iam.v1.ServiceAccounts.ActAs" },
    };
    const cloud_function_iam = [_]RpcUsage{
        .{ .service = "cloudfunctions.googleapis.com", .method = "google.cloud.functions.v2.FunctionIam.GetIamPolicy" },
        .{ .service = "cloudfunctions.googleapis.com", .method = "google.cloud.functions.v2.FunctionIam.SetIamPolicy" },
    };
    const batch_job = [_]RpcUsage{
        .{ .service = "batch.googleapis.com", .method = "google.cloud.batch.v1.BatchService.GetJob" },
        .{ .service = "batch.googleapis.com", .method = "google.cloud.batch.v1.BatchService.CreateJob" },
        .{ .service = "batch.googleapis.com", .method = "google.cloud.batch.v1.BatchService.DeleteJob" },
        .{ .service = "iam.googleapis.com", .method = "google.iam.v1.ServiceAccounts.ActAs" },
    };
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
    const sql_instance = [_]RpcUsage{
        .{ .service = "sqladmin.googleapis.com", .method = "google.cloud.sql.v1.SqlInstancesService.Get" },
        .{ .service = "sqladmin.googleapis.com", .method = "google.cloud.sql.v1.SqlInstancesService.Create" },
        .{ .service = "sqladmin.googleapis.com", .method = "google.cloud.sql.v1.SqlInstancesService.Update" },
        .{ .service = "sqladmin.googleapis.com", .method = "google.cloud.sql.v1.SqlInstancesService.Delete" },
    };
    const sql_database = [_]RpcUsage{
        .{ .service = "sqladmin.googleapis.com", .method = "google.cloud.sql.v1.SqlDatabasesService.Get" },
        .{ .service = "sqladmin.googleapis.com", .method = "google.cloud.sql.v1.SqlDatabasesService.Create" },
        .{ .service = "sqladmin.googleapis.com", .method = "google.cloud.sql.v1.SqlDatabasesService.Update" },
        .{ .service = "sqladmin.googleapis.com", .method = "google.cloud.sql.v1.SqlDatabasesService.Delete" },
    };
    const sql_user = [_]RpcUsage{
        .{ .service = "sqladmin.googleapis.com", .method = "google.cloud.sql.v1.SqlUsersService.Get" },
        .{ .service = "sqladmin.googleapis.com", .method = "google.cloud.sql.v1.SqlUsersService.Create" },
        .{ .service = "sqladmin.googleapis.com", .method = "google.cloud.sql.v1.SqlUsersService.Update" },
        .{ .service = "sqladmin.googleapis.com", .method = "google.cloud.sql.v1.SqlUsersService.Delete" },
    };
    const sql_certificate = [_]RpcUsage{
        .{ .service = "sqladmin.googleapis.com", .method = "google.cloud.sql.v1.SqlSslCertsService.Get" },
        .{ .service = "sqladmin.googleapis.com", .method = "google.cloud.sql.v1.SqlSslCertsService.Create" },
        .{ .service = "sqladmin.googleapis.com", .method = "google.cloud.sql.v1.SqlSslCertsService.Delete" },
    };
    const spanner_instance = [_]RpcUsage{
        .{ .service = "spanner.googleapis.com", .method = "ziac.gcp.SpannerInstanceAdmin.GetInstance" },
        .{ .service = "spanner.googleapis.com", .method = "ziac.gcp.SpannerInstanceAdmin.CreateInstance" },
        .{ .service = "spanner.googleapis.com", .method = "ziac.gcp.SpannerInstanceAdmin.UpdateInstance" },
        .{ .service = "spanner.googleapis.com", .method = "ziac.gcp.SpannerInstanceAdmin.DeleteInstance" },
    };
    const spanner_instance_iam = [_]RpcUsage{
        .{ .service = "spanner.googleapis.com", .method = "ziac.gcp.SpannerInstanceAdmin.GetIamPolicy" },
        .{ .service = "spanner.googleapis.com", .method = "ziac.gcp.SpannerInstanceAdmin.SetIamPolicy" },
    };
    const spanner_database = [_]RpcUsage{
        .{ .service = "spanner.googleapis.com", .method = "ziac.gcp.SpannerDatabaseAdmin.GetDatabase" },
        .{ .service = "spanner.googleapis.com", .method = "ziac.gcp.SpannerDatabaseAdmin.CreateDatabase" },
        .{ .service = "spanner.googleapis.com", .method = "ziac.gcp.SpannerDatabaseAdmin.UpdateDatabaseDdl" },
        .{ .service = "spanner.googleapis.com", .method = "ziac.gcp.SpannerDatabaseAdmin.DropDatabase" },
    };
    const spanner_database_iam = [_]RpcUsage{
        .{ .service = "spanner.googleapis.com", .method = "ziac.gcp.SpannerDatabaseAdmin.GetIamPolicy" },
        .{ .service = "spanner.googleapis.com", .method = "ziac.gcp.SpannerDatabaseAdmin.SetIamPolicy" },
    };
    const spanner_backup = [_]RpcUsage{
        .{ .service = "spanner.googleapis.com", .method = "ziac.gcp.SpannerDatabaseAdmin.GetBackup" },
        .{ .service = "spanner.googleapis.com", .method = "ziac.gcp.SpannerDatabaseAdmin.CreateBackup" },
        .{ .service = "spanner.googleapis.com", .method = "ziac.gcp.SpannerDatabaseAdmin.AuthorizeCreateBackup" },
        .{ .service = "spanner.googleapis.com", .method = "ziac.gcp.SpannerDatabaseAdmin.UpdateBackup" },
        .{ .service = "spanner.googleapis.com", .method = "ziac.gcp.SpannerDatabaseAdmin.DeleteBackup" },
    };
    const spanner_backup_schedule = [_]RpcUsage{
        .{ .service = "spanner.googleapis.com", .method = "ziac.gcp.SpannerDatabaseAdmin.GetBackupSchedule" },
        .{ .service = "spanner.googleapis.com", .method = "ziac.gcp.SpannerDatabaseAdmin.CreateBackupSchedule" },
        .{ .service = "spanner.googleapis.com", .method = "ziac.gcp.SpannerDatabaseAdmin.UpdateBackupSchedule" },
        .{ .service = "spanner.googleapis.com", .method = "ziac.gcp.SpannerDatabaseAdmin.DeleteBackupSchedule" },
    };
    const redis_instance = [_]RpcUsage{
        .{ .service = "redis.googleapis.com", .method = "ziac.gcp.RedisInstances.Get" },
        .{ .service = "redis.googleapis.com", .method = "ziac.gcp.RedisInstances.Create" },
        .{ .service = "redis.googleapis.com", .method = "ziac.gcp.RedisInstances.Update" },
        .{ .service = "redis.googleapis.com", .method = "ziac.gcp.RedisInstances.Delete" },
        .{ .service = "redis.googleapis.com", .method = "ziac.gcp.RedisInstances.Upgrade" },
        .{ .service = "redis.googleapis.com", .method = "ziac.gcp.RedisInstances.GetAuthString" },
    };
    const redis_cluster = [_]RpcUsage{
        .{ .service = "redis.googleapis.com", .method = "ziac.gcp.RedisClusters.Get" },
        .{ .service = "redis.googleapis.com", .method = "ziac.gcp.RedisClusters.Create" },
        .{ .service = "redis.googleapis.com", .method = "ziac.gcp.RedisClusters.Update" },
        .{ .service = "redis.googleapis.com", .method = "ziac.gcp.RedisClusters.Delete" },
    };
    const redis_acl_policy = [_]RpcUsage{
        .{ .service = "redis.googleapis.com", .method = "ziac.gcp.RedisAclPolicies.Get" },
        .{ .service = "redis.googleapis.com", .method = "ziac.gcp.RedisAclPolicies.Create" },
        .{ .service = "redis.googleapis.com", .method = "ziac.gcp.RedisAclPolicies.Update" },
        .{ .service = "redis.googleapis.com", .method = "ziac.gcp.RedisAclPolicies.Delete" },
    };
    const private_service_range = [_]RpcUsage{
        .{ .service = "compute.googleapis.com", .method = "ziac.gcp.PrivateServiceRanges.Get" },
        .{ .service = "compute.googleapis.com", .method = "ziac.gcp.PrivateServiceRanges.Create" },
        .{ .service = "compute.googleapis.com", .method = "ziac.gcp.PrivateServiceRanges.Delete" },
    };
    const service_networking_connection = [_]RpcUsage{
        .{ .service = "servicenetworking.googleapis.com", .method = "ziac.gcp.ServiceNetworkingConnections.Get" },
        .{ .service = "servicenetworking.googleapis.com", .method = "ziac.gcp.ServiceNetworkingConnections.Create" },
        .{ .service = "servicenetworking.googleapis.com", .method = "ziac.gcp.ServiceNetworkingConnections.Update" },
        .{ .service = "servicenetworking.googleapis.com", .method = "ziac.gcp.ServiceNetworkingConnections.Delete" },
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
    const workflow = [_]RpcUsage{
        .{ .service = "workflows.googleapis.com", .method = "google.cloud.workflows.v1.Workflows.GetWorkflow" },
        .{ .service = "workflows.googleapis.com", .method = "google.cloud.workflows.v1.Workflows.CreateWorkflow" },
        .{ .service = "workflows.googleapis.com", .method = "google.cloud.workflows.v1.Workflows.UpdateWorkflow" },
        .{ .service = "workflows.googleapis.com", .method = "google.cloud.workflows.v1.Workflows.DeleteWorkflow" },
        .{ .service = "iam.googleapis.com", .method = "google.iam.v1.ServiceAccounts.ActAs" },
    };
    const api_gateway_api = [_]RpcUsage{
        .{ .service = "apigateway.googleapis.com", .method = "google.cloud.apigateway.v1.Apis.GetApi" },
        .{ .service = "apigateway.googleapis.com", .method = "google.cloud.apigateway.v1.Apis.CreateApi" },
        .{ .service = "apigateway.googleapis.com", .method = "google.cloud.apigateway.v1.Apis.UpdateApi" },
        .{ .service = "apigateway.googleapis.com", .method = "google.cloud.apigateway.v1.Apis.DeleteApi" },
    };
    const api_gateway_config = [_]RpcUsage{
        .{ .service = "apigateway.googleapis.com", .method = "google.cloud.apigateway.v1.ApiConfigs.GetApiConfig" },
        .{ .service = "apigateway.googleapis.com", .method = "google.cloud.apigateway.v1.ApiConfigs.CreateApiConfig" },
        .{ .service = "apigateway.googleapis.com", .method = "google.cloud.apigateway.v1.ApiConfigs.UpdateApiConfig" },
        .{ .service = "apigateway.googleapis.com", .method = "google.cloud.apigateway.v1.ApiConfigs.DeleteApiConfig" },
        .{ .service = "iam.googleapis.com", .method = "google.iam.v1.ServiceAccounts.ActAs" },
    };
    const api_gateway_gateway = [_]RpcUsage{
        .{ .service = "apigateway.googleapis.com", .method = "google.cloud.apigateway.v1.Gateways.GetGateway" },
        .{ .service = "apigateway.googleapis.com", .method = "google.cloud.apigateway.v1.Gateways.CreateGateway" },
        .{ .service = "apigateway.googleapis.com", .method = "google.cloud.apigateway.v1.Gateways.UpdateGateway" },
        .{ .service = "apigateway.googleapis.com", .method = "google.cloud.apigateway.v1.Gateways.DeleteGateway" },
    };
    const api_gateway_api_iam = [_]RpcUsage{
        .{ .service = "apigateway.googleapis.com", .method = "google.cloud.apigateway.v1.Apis.GetIamPolicy" },
        .{ .service = "apigateway.googleapis.com", .method = "google.cloud.apigateway.v1.Apis.SetIamPolicy" },
    };
    const api_gateway_config_iam = [_]RpcUsage{
        .{ .service = "apigateway.googleapis.com", .method = "google.cloud.apigateway.v1.ApiConfigs.GetIamPolicy" },
        .{ .service = "apigateway.googleapis.com", .method = "google.cloud.apigateway.v1.ApiConfigs.SetIamPolicy" },
    };
    const api_gateway_gateway_iam = [_]RpcUsage{
        .{ .service = "apigateway.googleapis.com", .method = "google.cloud.apigateway.v1.Gateways.GetIamPolicy" },
        .{ .service = "apigateway.googleapis.com", .method = "google.cloud.apigateway.v1.Gateways.SetIamPolicy" },
    };
    const identity_project_config = [_]RpcUsage{
        .{ .service = "identitytoolkit.googleapis.com", .method = "google.cloud.identitytoolkit.v2.Projects.GetConfig" },
        .{ .service = "identitytoolkit.googleapis.com", .method = "google.cloud.identitytoolkit.v2.Projects.UpdateConfig" },
    };
    const identity_tenant = [_]RpcUsage{
        .{ .service = "identitytoolkit.googleapis.com", .method = "google.cloud.identitytoolkit.v2.Tenants.GetTenant" },
        .{ .service = "identitytoolkit.googleapis.com", .method = "google.cloud.identitytoolkit.v2.Tenants.CreateTenant" },
        .{ .service = "identitytoolkit.googleapis.com", .method = "google.cloud.identitytoolkit.v2.Tenants.UpdateTenant" },
        .{ .service = "identitytoolkit.googleapis.com", .method = "google.cloud.identitytoolkit.v2.Tenants.DeleteTenant" },
    };
    const identity_tenant_iam = [_]RpcUsage{
        .{ .service = "identitytoolkit.googleapis.com", .method = "google.cloud.identitytoolkit.v2.Tenants.GetIamPolicy" },
        .{ .service = "identitytoolkit.googleapis.com", .method = "google.cloud.identitytoolkit.v2.Tenants.SetIamPolicy" },
    };
    const identity_oidc = [_]RpcUsage{
        .{ .service = "identitytoolkit.googleapis.com", .method = "google.cloud.identitytoolkit.v2.OAuthIdpConfigs.GetOAuthIdpConfig" },
        .{ .service = "identitytoolkit.googleapis.com", .method = "google.cloud.identitytoolkit.v2.OAuthIdpConfigs.CreateOAuthIdpConfig" },
        .{ .service = "identitytoolkit.googleapis.com", .method = "google.cloud.identitytoolkit.v2.OAuthIdpConfigs.UpdateOAuthIdpConfig" },
        .{ .service = "identitytoolkit.googleapis.com", .method = "google.cloud.identitytoolkit.v2.OAuthIdpConfigs.DeleteOAuthIdpConfig" },
    };
    const identity_saml = [_]RpcUsage{
        .{ .service = "identitytoolkit.googleapis.com", .method = "google.cloud.identitytoolkit.v2.InboundSamlConfigs.GetInboundSamlConfig" },
        .{ .service = "identitytoolkit.googleapis.com", .method = "google.cloud.identitytoolkit.v2.InboundSamlConfigs.CreateInboundSamlConfig" },
        .{ .service = "identitytoolkit.googleapis.com", .method = "google.cloud.identitytoolkit.v2.InboundSamlConfigs.UpdateInboundSamlConfig" },
        .{ .service = "identitytoolkit.googleapis.com", .method = "google.cloud.identitytoolkit.v2.InboundSamlConfigs.DeleteInboundSamlConfig" },
    };
    const parameter = [_]RpcUsage{
        .{ .service = "parametermanager.googleapis.com", .method = "google.cloud.parametermanager.v1.ParameterManager.GetParameter" },
        .{ .service = "parametermanager.googleapis.com", .method = "google.cloud.parametermanager.v1.ParameterManager.CreateParameter" },
        .{ .service = "parametermanager.googleapis.com", .method = "google.cloud.parametermanager.v1.ParameterManager.UpdateParameter" },
        .{ .service = "parametermanager.googleapis.com", .method = "google.cloud.parametermanager.v1.ParameterManager.DeleteParameter" },
    };
    const parameter_version = [_]RpcUsage{
        .{ .service = "parametermanager.googleapis.com", .method = "google.cloud.parametermanager.v1.ParameterManager.GetParameterVersion" },
        .{ .service = "parametermanager.googleapis.com", .method = "google.cloud.parametermanager.v1.ParameterManager.CreateParameterVersion" },
        .{ .service = "parametermanager.googleapis.com", .method = "google.cloud.parametermanager.v1.ParameterManager.UpdateParameterVersion" },
        .{ .service = "parametermanager.googleapis.com", .method = "google.cloud.parametermanager.v1.ParameterManager.DeleteParameterVersion" },
    };
    const parameter_template = [_]RpcUsage{
        .{ .service = "parametermanager.googleapis.com", .method = "google.cloud.parametermanager.v1.ParameterManager.GetTemplate" },
        .{ .service = "parametermanager.googleapis.com", .method = "google.cloud.parametermanager.v1.ParameterManager.CreateTemplate" },
        .{ .service = "parametermanager.googleapis.com", .method = "google.cloud.parametermanager.v1.ParameterManager.UpdateTemplate" },
        .{ .service = "parametermanager.googleapis.com", .method = "google.cloud.parametermanager.v1.ParameterManager.DeleteTemplate" },
    };
    const parameter_template_version = [_]RpcUsage{
        .{ .service = "parametermanager.googleapis.com", .method = "google.cloud.parametermanager.v1.ParameterManager.GetTemplateVersion" },
        .{ .service = "parametermanager.googleapis.com", .method = "google.cloud.parametermanager.v1.ParameterManager.CreateTemplateVersion" },
        .{ .service = "parametermanager.googleapis.com", .method = "google.cloud.parametermanager.v1.ParameterManager.UpdateTemplateVersion" },
        .{ .service = "parametermanager.googleapis.com", .method = "google.cloud.parametermanager.v1.ParameterManager.DeleteTemplateVersion" },
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
    const compute_disk = [_]RpcUsage{
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Disks.Get" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Disks.Insert" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Disks.Resize" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Disks.Delete" },
    };
    const compute_image = [_]RpcUsage{
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Images.Get" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Images.Insert" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Images.Delete" },
    };
    const compute_instance = [_]RpcUsage{
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Instances.Get" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Instances.Insert" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Instances.SetDeletionProtection" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Instances.Delete" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Disks.Use" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Networks.Use" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Subnetworks.Use" },
        .{ .service = "iam.googleapis.com", .method = "google.iam.v1.ServiceAccounts.ActAs" },
    };
    const compute_template = [_]RpcUsage{
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.InstanceTemplates.Get" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.InstanceTemplates.Insert" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.InstanceTemplates.Delete" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Images.UseReadOnly" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Networks.Use" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Subnetworks.Use" },
        .{ .service = "iam.googleapis.com", .method = "google.iam.v1.ServiceAccounts.ActAs" },
    };
    const compute_group = [_]RpcUsage{
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.InstanceGroupManagers.Get" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.InstanceGroupManagers.Insert" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.InstanceGroupManagers.Patch" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.InstanceGroupManagers.Delete" },
    };
    const compute_autoscaler = [_]RpcUsage{
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Autoscalers.Get" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Autoscalers.Insert" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Autoscalers.Patch" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Autoscalers.Delete" },
    };
    const compute_firewall = [_]RpcUsage{
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Firewalls.Get" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Firewalls.Insert" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Firewalls.Patch" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Firewalls.Delete" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Networks.Use" },
    };
    const compute_route = [_]RpcUsage{
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Routes.Get" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Routes.Insert" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Routes.Delete" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Networks.Use" },
    };
    const compute_health_check = [_]RpcUsage{
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.HealthChecks.Get" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.HealthChecks.Insert" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.HealthChecks.Update" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.HealthChecks.Delete" },
    };
    const compute_region_health_check = [_]RpcUsage{
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.RegionHealthChecks.Get" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.RegionHealthChecks.Insert" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.RegionHealthChecks.Update" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.RegionHealthChecks.Delete" },
    };
    const compute_internal_address = [_]RpcUsage{
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Addresses.Get" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Addresses.InsertInternal" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Addresses.DeleteInternal" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Subnetworks.Use" },
    };
    const compute_region_backend = [_]RpcUsage{
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.RegionBackendServices.Get" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.RegionBackendServices.Insert" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.RegionBackendServices.Update" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.RegionBackendServices.Delete" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.RegionHealthChecks.UseReadOnly" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Networks.Use" },
    };
    const compute_region_url_map = [_]RpcUsage{
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.RegionUrlMaps.Get" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.RegionUrlMaps.Insert" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.RegionUrlMaps.Update" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.RegionUrlMaps.Delete" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.RegionBackendServices.Use" },
    };
    const compute_region_http_proxy = [_]RpcUsage{
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.RegionTargetHttpProxies.Get" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.RegionTargetHttpProxies.Insert" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.RegionTargetHttpProxies.SetUrlMap" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.RegionTargetHttpProxies.Delete" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.RegionUrlMaps.Use" },
    };
    const compute_forwarding_rule = [_]RpcUsage{
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.ForwardingRules.Get" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.ForwardingRules.Insert" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.ForwardingRules.Delete" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Addresses.UseInternal" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Networks.Use" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Subnetworks.Use" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.RegionBackendServices.Use" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.RegionTargetHttpProxies.Use" },
    };
    const compute_backend_bucket = [_]RpcUsage{
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.BackendBuckets.Get" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.BackendBuckets.Insert" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.BackendBuckets.Patch" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.BackendBuckets.SetSecurityPolicy" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.BackendBuckets.Delete" },
    };
    const compute_security_policy = [_]RpcUsage{
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.SecurityPolicies.Get" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.SecurityPolicies.Insert" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.SecurityPolicies.Patch" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.SecurityPolicies.Delete" },
    };
    const compute_ssl_policy = [_]RpcUsage{
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.SslPolicies.Get" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.SslPolicies.Insert" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.SslPolicies.Patch" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.SslPolicies.Delete" },
    };
    const compute_certificate_map_proxy = [_]RpcUsage{
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.TargetHttpsProxies.Get" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.TargetHttpsProxies.Insert" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.TargetHttpsProxies.Delete" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.UrlMaps.Use" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.SslPolicies.Use" },
        .{ .service = "certificatemanager.googleapis.com", .method = "google.cloud.certificatemanager.v1.CertificateMaps.UseCertificateMap" },
    };
    const compute_ha_vpn_gateway = [_]RpcUsage{
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.VpnGateways.Get" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.VpnGateways.Insert" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.VpnGateways.Delete" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Networks.Use" },
    };
    const compute_external_vpn_gateway = [_]RpcUsage{
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.ExternalVpnGateways.Get" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.ExternalVpnGateways.Insert" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.ExternalVpnGateways.Delete" },
    };
    const compute_vpn_tunnel = [_]RpcUsage{
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.VpnTunnels.Get" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.VpnTunnels.Insert" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.VpnTunnels.Delete" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.VpnGateways.Use" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.ExternalVpnGateways.Use" },
    };
    const compute_router = [_]RpcUsage{
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Routers.Get" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Routers.Insert" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Routers.Patch" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Routers.Delete" },
    };
    const compute_network_peering = [_]RpcUsage{
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Networks.Get" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Networks.AddPeering" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Networks.UpdatePeering" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Networks.RemovePeering" },
    };
    const connectivity_hub = [_]RpcUsage{
        .{ .service = "networkconnectivity.googleapis.com", .method = "google.cloud.networkconnectivity.v1.Hubs.GetHub" },
        .{ .service = "networkconnectivity.googleapis.com", .method = "google.cloud.networkconnectivity.v1.Hubs.CreateHub" },
        .{ .service = "networkconnectivity.googleapis.com", .method = "google.cloud.networkconnectivity.v1.Hubs.UpdateHub" },
        .{ .service = "networkconnectivity.googleapis.com", .method = "google.cloud.networkconnectivity.v1.Hubs.DeleteHub" },
    };
    const connectivity_spoke = [_]RpcUsage{
        .{ .service = "networkconnectivity.googleapis.com", .method = "google.cloud.networkconnectivity.v1.Spokes.GetSpoke" },
        .{ .service = "networkconnectivity.googleapis.com", .method = "google.cloud.networkconnectivity.v1.Spokes.CreateSpoke" },
        .{ .service = "networkconnectivity.googleapis.com", .method = "google.cloud.networkconnectivity.v1.Spokes.UpdateSpoke" },
        .{ .service = "networkconnectivity.googleapis.com", .method = "google.cloud.networkconnectivity.v1.Spokes.DeleteSpoke" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Networks.Use" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.VpnTunnels.Use" },
    };
    const connectivity_service_policy = [_]RpcUsage{
        .{ .service = "networkconnectivity.googleapis.com", .method = "google.cloud.networkconnectivity.v1.ServiceConnectionPolicies.GetServiceConnectionPolicy" },
        .{ .service = "networkconnectivity.googleapis.com", .method = "google.cloud.networkconnectivity.v1.ServiceConnectionPolicies.CreateServiceConnectionPolicy" },
        .{ .service = "networkconnectivity.googleapis.com", .method = "google.cloud.networkconnectivity.v1.ServiceConnectionPolicies.UpdateServiceConnectionPolicy" },
        .{ .service = "networkconnectivity.googleapis.com", .method = "google.cloud.networkconnectivity.v1.ServiceConnectionPolicies.DeleteServiceConnectionPolicy" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Networks.Use" },
        .{ .service = "compute.googleapis.com", .method = "google.cloud.compute.v1.Subnetworks.Use" },
    };
    const certificate_dns_authorization = [_]RpcUsage{
        .{ .service = "certificatemanager.googleapis.com", .method = "google.cloud.certificatemanager.v1.DnsAuthorizations.GetDnsAuthorization" },
        .{ .service = "certificatemanager.googleapis.com", .method = "google.cloud.certificatemanager.v1.DnsAuthorizations.CreateDnsAuthorization" },
        .{ .service = "certificatemanager.googleapis.com", .method = "google.cloud.certificatemanager.v1.DnsAuthorizations.DeleteDnsAuthorization" },
    };
    const certificate = [_]RpcUsage{
        .{ .service = "certificatemanager.googleapis.com", .method = "google.cloud.certificatemanager.v1.Certificates.GetCertificate" },
        .{ .service = "certificatemanager.googleapis.com", .method = "google.cloud.certificatemanager.v1.Certificates.CreateCertificate" },
        .{ .service = "certificatemanager.googleapis.com", .method = "google.cloud.certificatemanager.v1.Certificates.DeleteCertificate" },
        .{ .service = "certificatemanager.googleapis.com", .method = "google.cloud.certificatemanager.v1.DnsAuthorizations.UseDnsAuthorization" },
    };
    const certificate_map = [_]RpcUsage{
        .{ .service = "certificatemanager.googleapis.com", .method = "google.cloud.certificatemanager.v1.CertificateMaps.GetCertificateMap" },
        .{ .service = "certificatemanager.googleapis.com", .method = "google.cloud.certificatemanager.v1.CertificateMaps.CreateCertificateMap" },
        .{ .service = "certificatemanager.googleapis.com", .method = "google.cloud.certificatemanager.v1.CertificateMaps.DeleteCertificateMap" },
    };
    const certificate_map_entry = [_]RpcUsage{
        .{ .service = "certificatemanager.googleapis.com", .method = "google.cloud.certificatemanager.v1.CertificateMapEntries.GetCertificateMapEntry" },
        .{ .service = "certificatemanager.googleapis.com", .method = "google.cloud.certificatemanager.v1.CertificateMapEntries.CreateCertificateMapEntry" },
        .{ .service = "certificatemanager.googleapis.com", .method = "google.cloud.certificatemanager.v1.CertificateMapEntries.DeleteCertificateMapEntry" },
        .{ .service = "certificatemanager.googleapis.com", .method = "google.cloud.certificatemanager.v1.Certificates.UseCertificate" },
    };
    const dns = [_]RpcUsage{
        .{ .service = "dns.googleapis.com", .method = "dns.changes.create" },
    };
    const kms_key_ring = [_]RpcUsage{
        .{ .service = "cloudkms.googleapis.com", .method = "google.cloud.kms.v1.KeyRings.GetKeyRing" },
        .{ .service = "cloudkms.googleapis.com", .method = "google.cloud.kms.v1.KeyRings.CreateKeyRing" },
    };
    const kms_crypto_key = [_]RpcUsage{
        .{ .service = "cloudkms.googleapis.com", .method = "google.cloud.kms.v1.CryptoKeys.GetCryptoKey" },
        .{ .service = "cloudkms.googleapis.com", .method = "google.cloud.kms.v1.CryptoKeys.CreateCryptoKey" },
        .{ .service = "cloudkms.googleapis.com", .method = "google.cloud.kms.v1.CryptoKeys.UpdateCryptoKey" },
    };
    const kms_version = [_]RpcUsage{
        .{ .service = "cloudkms.googleapis.com", .method = "google.cloud.kms.v1.CryptoKeyVersions.GetCryptoKeyVersion" },
        .{ .service = "cloudkms.googleapis.com", .method = "google.cloud.kms.v1.CryptoKeyVersions.CreateCryptoKeyVersion" },
        .{ .service = "cloudkms.googleapis.com", .method = "google.cloud.kms.v1.CryptoKeyVersions.UpdateCryptoKeyVersion" },
    };
    const kms_key_ring_iam = [_]RpcUsage{
        .{ .service = "cloudkms.googleapis.com", .method = "google.cloud.kms.v1.KeyRings.GetIamPolicy" },
        .{ .service = "cloudkms.googleapis.com", .method = "google.cloud.kms.v1.KeyRings.SetIamPolicy" },
    };
    const kms_crypto_key_iam = [_]RpcUsage{
        .{ .service = "cloudkms.googleapis.com", .method = "google.cloud.kms.v1.CryptoKeys.GetIamPolicy" },
        .{ .service = "cloudkms.googleapis.com", .method = "google.cloud.kms.v1.CryptoKeys.SetIamPolicy" },
    };
    const secret = [_]RpcUsage{
        .{ .service = "secretmanager.googleapis.com", .method = "google.cloud.secretmanager.v1.SecretManagerService.GetSecret" },
        .{ .service = "secretmanager.googleapis.com", .method = "google.cloud.secretmanager.v1.SecretManagerService.CreateSecret" },
        .{ .service = "secretmanager.googleapis.com", .method = "google.cloud.secretmanager.v1.SecretManagerService.UpdateSecret" },
        .{ .service = "secretmanager.googleapis.com", .method = "google.cloud.secretmanager.v1.SecretManagerService.DeleteSecret" },
    };
    const secret_version = [_]RpcUsage{
        .{ .service = "secretmanager.googleapis.com", .method = "google.cloud.secretmanager.v1.SecretManagerService.GetSecretVersion" },
        .{ .service = "secretmanager.googleapis.com", .method = "google.cloud.secretmanager.v1.SecretVersions.AddSecretVersion" },
        .{ .service = "secretmanager.googleapis.com", .method = "google.cloud.secretmanager.v1.SecretManagerService.EnableSecretVersion" },
        .{ .service = "secretmanager.googleapis.com", .method = "google.cloud.secretmanager.v1.SecretManagerService.DisableSecretVersion" },
    };
    const secret_iam = [_]RpcUsage{
        .{ .service = "secretmanager.googleapis.com", .method = "google.cloud.secretmanager.v1.SecretManagerService.GetIamPolicy" },
        .{ .service = "secretmanager.googleapis.com", .method = "google.cloud.secretmanager.v1.SecretManagerService.SetIamPolicy" },
    };
    if (std.mem.eql(u8, type_name, "gcp.cloudbuild.Connection")) return &build_connection;
    if (std.mem.eql(u8, type_name, "gcp.cloudbuild.Repository")) return &build_repository;
    if (std.mem.eql(u8, type_name, "gcp.cloudbuild.WorkerPool")) return &build_worker_pool;
    if (std.mem.eql(u8, type_name, "gcp.cloudbuild.Trigger")) return &build_trigger;
    if (std.mem.eql(u8, type_name, "gcp.deploy.DeliveryPipeline")) return &deploy_pipeline;
    if (std.mem.eql(u8, type_name, "gcp.deploy.Target")) return &deploy_target;
    if (std.mem.eql(u8, type_name, "gcp.deploy.CustomTargetType")) return &deploy_custom_target_type;
    if (std.mem.eql(u8, type_name, "gcp.deploy.Automation")) return &deploy_automation;
    if (std.mem.eql(u8, type_name, "gcp.deploy.DeployPolicy")) return &deploy_policy;
    if (std.mem.eql(u8, type_name, "gcp.artifact.Repository")) return &artifact_repository;
    if (std.mem.eql(u8, type_name, "gcp.artifact.ProjectSettings")) return &artifact_project_settings;
    if (std.mem.eql(u8, type_name, "gcp.artifact.VpcscConfig")) return &artifact_vpcsc;
    if (std.mem.eql(u8, type_name, "gcp.logging.Bucket")) return &logging_bucket;
    if (std.mem.eql(u8, type_name, "gcp.logging.View")) return &logging_view;
    if (std.mem.eql(u8, type_name, "gcp.logging.Sink")) return &logging_sink;
    if (std.mem.eql(u8, type_name, "gcp.logging.Exclusion")) return &logging_exclusion;
    if (std.mem.eql(u8, type_name, "gcp.logging.Metric")) return &logging_metric;
    if (std.mem.eql(u8, type_name, "gcp.monitoring.AlertPolicy")) return &monitoring_alert_policy;
    if (std.mem.eql(u8, type_name, "gcp.monitoring.UptimeCheck")) return &monitoring_uptime_check;
    if (std.mem.eql(u8, type_name, "gcp.monitoring.NotificationChannel")) return &monitoring_channel;
    if (std.mem.eql(u8, type_name, "gcp.monitoring.Dashboard")) return &monitoring_dashboard;
    if (std.mem.eql(u8, type_name, "gcp.monitoring.Service")) return &monitoring_service;
    if (std.mem.eql(u8, type_name, "gcp.monitoring.ServiceLevelObjective")) return &monitoring_slo;
    if (std.mem.eql(u8, type_name, "gcp.container.Cluster")) return &container_cluster;
    if (std.mem.eql(u8, type_name, "gcp.container.NodePool")) return &container_node_pool;
    if (std.mem.eql(u8, type_name, "gcp.gkehub.Fleet")) return &gke_fleet;
    if (std.mem.eql(u8, type_name, "gcp.gkehub.Membership")) return &gke_membership;
    if (std.mem.eql(u8, type_name, "gcp.functions.FunctionV2")) return &cloud_function;
    if (std.mem.eql(u8, type_name, "gcp.functions.FunctionIamMember")) return &cloud_function_iam;
    if (std.mem.eql(u8, type_name, "gcp.batch.Job")) return &batch_job;
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
    if (std.mem.eql(u8, type_name, "gcp.sql.Instance") or std.mem.eql(u8, type_name, "gcp.sql.ReadReplica")) return &sql_instance;
    if (std.mem.eql(u8, type_name, "gcp.sql.Database")) return &sql_database;
    if (std.mem.eql(u8, type_name, "gcp.sql.User")) return &sql_user;
    if (std.mem.eql(u8, type_name, "gcp.sql.ClientCertificate")) return &sql_certificate;
    if (std.mem.eql(u8, type_name, "gcp.spanner.Instance")) return &spanner_instance;
    if (std.mem.eql(u8, type_name, "gcp.spanner.InstanceIamMember")) return &spanner_instance_iam;
    if (std.mem.eql(u8, type_name, "gcp.spanner.Database")) return &spanner_database;
    if (std.mem.eql(u8, type_name, "gcp.spanner.DatabaseIamMember")) return &spanner_database_iam;
    if (std.mem.eql(u8, type_name, "gcp.spanner.Backup")) return &spanner_backup;
    if (std.mem.eql(u8, type_name, "gcp.spanner.BackupSchedule")) return &spanner_backup_schedule;
    if (std.mem.eql(u8, type_name, "gcp.redis.Instance")) return &redis_instance;
    if (std.mem.eql(u8, type_name, "gcp.redis.Cluster")) return &redis_cluster;
    if (std.mem.eql(u8, type_name, "gcp.redis.AclPolicy")) return &redis_acl_policy;
    if (std.mem.eql(u8, type_name, "gcp.compute.PrivateServiceRange")) return &private_service_range;
    if (std.mem.eql(u8, type_name, "gcp.servicenetworking.Connection")) return &service_networking_connection;
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
    if (std.mem.eql(u8, type_name, "gcp.workflows.Workflow")) return &workflow;
    if (std.mem.eql(u8, type_name, "gcp.apigateway.Api")) return &api_gateway_api;
    if (std.mem.eql(u8, type_name, "gcp.apigateway.ApiConfig")) return &api_gateway_config;
    if (std.mem.eql(u8, type_name, "gcp.apigateway.Gateway")) return &api_gateway_gateway;
    if (std.mem.eql(u8, type_name, "gcp.apigateway.ApiIamMember")) return &api_gateway_api_iam;
    if (std.mem.eql(u8, type_name, "gcp.apigateway.ApiConfigIamMember")) return &api_gateway_config_iam;
    if (std.mem.eql(u8, type_name, "gcp.apigateway.GatewayIamMember")) return &api_gateway_gateway_iam;
    if (std.mem.eql(u8, type_name, "gcp.identity.ProjectConfig")) return &identity_project_config;
    if (std.mem.eql(u8, type_name, "gcp.identity.Tenant")) return &identity_tenant;
    if (std.mem.eql(u8, type_name, "gcp.identity.TenantIamMember")) return &identity_tenant_iam;
    if (std.mem.eql(u8, type_name, "gcp.identity.ProjectOAuthIdpConfig") or std.mem.eql(u8, type_name, "gcp.identity.TenantOAuthIdpConfig")) return &identity_oidc;
    if (std.mem.eql(u8, type_name, "gcp.identity.ProjectInboundSamlConfig") or std.mem.eql(u8, type_name, "gcp.identity.TenantInboundSamlConfig")) return &identity_saml;
    if (std.mem.eql(u8, type_name, "gcp.parametermanager.Parameter")) return &parameter;
    if (std.mem.eql(u8, type_name, "gcp.parametermanager.ParameterVersion")) return &parameter_version;
    if (std.mem.eql(u8, type_name, "gcp.parametermanager.Template")) return &parameter_template;
    if (std.mem.eql(u8, type_name, "gcp.parametermanager.TemplateVersion")) return &parameter_template_version;
    if (std.mem.eql(u8, type_name, "gcp.kms.KeyRing")) return &kms_key_ring;
    if (std.mem.eql(u8, type_name, "gcp.kms.CryptoKey")) return &kms_crypto_key;
    if (std.mem.eql(u8, type_name, "gcp.kms.CryptoKeyVersion")) return &kms_version;
    if (std.mem.eql(u8, type_name, "gcp.kms.KeyRingIamMember")) return &kms_key_ring_iam;
    if (std.mem.eql(u8, type_name, "gcp.kms.CryptoKeyIamMember")) return &kms_crypto_key_iam;
    if (std.mem.eql(u8, type_name, "gcp.secret.Secret")) return &secret;
    if (std.mem.eql(u8, type_name, "gcp.secret.SecretVersion")) return &secret_version;
    if (std.mem.eql(u8, type_name, "gcp.secret.SecretIamMember")) return &secret_iam;
    if (std.mem.eql(u8, type_name, "gcp.compute.BackendService")) return &compute_backend;
    if (std.mem.eql(u8, type_name, "gcp.compute.RegionServerlessNeg")) return &compute_neg;
    if (std.mem.eql(u8, type_name, "gcp.compute.Disk") or std.mem.eql(u8, type_name, "gcp.compute.RegionDisk")) return &compute_disk;
    if (std.mem.eql(u8, type_name, "gcp.compute.Image")) return &compute_image;
    if (std.mem.eql(u8, type_name, "gcp.compute.Instance")) return &compute_instance;
    if (std.mem.eql(u8, type_name, "gcp.compute.InstanceTemplate")) return &compute_template;
    if (std.mem.eql(u8, type_name, "gcp.compute.InstanceGroupManager") or std.mem.eql(u8, type_name, "gcp.compute.RegionInstanceGroupManager")) return &compute_group;
    if (std.mem.eql(u8, type_name, "gcp.compute.Autoscaler") or std.mem.eql(u8, type_name, "gcp.compute.RegionAutoscaler")) return &compute_autoscaler;
    if (std.mem.eql(u8, type_name, "gcp.compute.Firewall")) return &compute_firewall;
    if (std.mem.eql(u8, type_name, "gcp.compute.Route")) return &compute_route;
    if (std.mem.eql(u8, type_name, "gcp.compute.HealthCheck")) return &compute_health_check;
    if (std.mem.eql(u8, type_name, "gcp.compute.RegionHealthCheck")) return &compute_region_health_check;
    if (std.mem.eql(u8, type_name, "gcp.compute.InternalAddress")) return &compute_internal_address;
    if (std.mem.eql(u8, type_name, "gcp.compute.RegionBackendService")) return &compute_region_backend;
    if (std.mem.eql(u8, type_name, "gcp.compute.RegionUrlMap")) return &compute_region_url_map;
    if (std.mem.eql(u8, type_name, "gcp.compute.RegionTargetHttpProxy")) return &compute_region_http_proxy;
    if (std.mem.eql(u8, type_name, "gcp.compute.ForwardingRule")) return &compute_forwarding_rule;
    if (std.mem.eql(u8, type_name, "gcp.compute.BackendBucket")) return &compute_backend_bucket;
    if (std.mem.eql(u8, type_name, "gcp.compute.SecurityPolicy")) return &compute_security_policy;
    if (std.mem.eql(u8, type_name, "gcp.compute.SslPolicy")) return &compute_ssl_policy;
    if (std.mem.eql(u8, type_name, "gcp.compute.CertificateMapTargetHttpsProxy")) return &compute_certificate_map_proxy;
    if (std.mem.eql(u8, type_name, "gcp.compute.HaVpnGateway")) return &compute_ha_vpn_gateway;
    if (std.mem.eql(u8, type_name, "gcp.compute.ExternalVpnGateway")) return &compute_external_vpn_gateway;
    if (std.mem.eql(u8, type_name, "gcp.compute.VpnTunnel")) return &compute_vpn_tunnel;
    if (std.mem.eql(u8, type_name, "gcp.compute.Router") or
        std.mem.eql(u8, type_name, "gcp.compute.RouterNat") or
        std.mem.eql(u8, type_name, "gcp.compute.RouterInterface") or
        std.mem.eql(u8, type_name, "gcp.compute.RouterBgpPeer")) return &compute_router;
    if (std.mem.eql(u8, type_name, "gcp.compute.NetworkPeering")) return &compute_network_peering;
    if (std.mem.eql(u8, type_name, "gcp.networkconnectivity.Hub")) return &connectivity_hub;
    if (std.mem.eql(u8, type_name, "gcp.networkconnectivity.Spoke")) return &connectivity_spoke;
    if (std.mem.eql(u8, type_name, "gcp.networkconnectivity.ServiceConnectionPolicy")) return &connectivity_service_policy;
    if (std.mem.eql(u8, type_name, "gcp.certificatemanager.DnsAuthorization")) return &certificate_dns_authorization;
    if (std.mem.eql(u8, type_name, "gcp.certificatemanager.Certificate")) return &certificate;
    if (std.mem.eql(u8, type_name, "gcp.certificatemanager.CertificateMap")) return &certificate_map;
    if (std.mem.eql(u8, type_name, "gcp.certificatemanager.CertificateMapEntry")) return &certificate_map_entry;
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
        .{ .role = "roles/cloudsql.client", .permission = "cloudsql.instances.connect" },
        .{ .role = "roles/cloudsql.instanceUser", .permission = "cloudsql.instances.login" },
        .{ .role = "roles/cloudkms.cryptoKeyDecrypter", .permission = "cloudkms.cryptoKeyVersions.useToDecrypt" },
        .{ .role = "roles/cloudkms.cryptoKeyEncrypterDecrypter", .permission = "cloudkms.cryptoKeyVersions.useToDecrypt" },
        .{ .role = "roles/iam.workloadIdentityUser", .permission = "iam.serviceAccounts.getAccessToken" },
        .{ .role = "roles/pubsub.publisher", .permission = "pubsub.topics.publish" },
        .{ .role = "roles/pubsub.subscriber", .permission = "pubsub.subscriptions.consume" },
        .{ .role = "roles/run.invoker", .permission = "run.routes.invoke" },
        .{ .role = "roles/workflows.invoker", .permission = "workflows.executions.create" },
        .{ .role = "roles/parametermanager.parameterAccessor", .permission = "parametermanager.parameterVersions.render" },
        .{ .role = "roles/spanner.databaseUser", .permission = "spanner.databases.read" },
        .{ .role = "roles/redis.dbConnectionUser", .permission = "redis.clusters.connect" },
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

fn inputBool(node: resource.ResourceNode, name: []const u8) ?bool {
    const fields = switch (node.inputs) {
        .object => |items| items,
        else => return null,
    };
    for (fields) |field| {
        if (!std.mem.eql(u8, field.name, name)) continue;
        return switch (field.value) {
            .boolean => |present| present,
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
