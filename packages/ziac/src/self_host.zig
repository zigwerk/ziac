const std = @import("std");
const gcp = @import("gcp/root.zig");
const cockroach = @import("cockroach/root.zig");
const output = @import("output.zig");
const resource = @import("resource.zig");
const stack_registry = @import("stack_registry.zig");
const self_host_migrations = @import("self_host_migrations.zig");

pub const BootstrapConfig = struct {
    project_id: []const u8,
    primary_region: []const u8,
    regions: []const []const u8,
    state_bucket: []const u8,
};

pub const ControlPlaneConfig = struct {
    project_id: []const u8,
    primary_region: []const u8,
    regions: []const []const u8,
    domain: []const u8,
    dns_zone: []const u8,
    image: []const u8,
    database_secret: []const u8,
    oauth_client_id_secret: []const u8,
    oauth_client_secret: []const u8,
    kms_key: []const u8,
};

pub const BillingConfig = struct {
    project_id: []const u8,
    region: []const u8,
    image: []const u8,
    billing_project: []const u8,
    export_table: []const u8,
    control_plane_url: []const u8,
    database_secret: []const u8,
};

pub const DataConfig = struct {
    project_id: []const u8,
    primary_region: []const u8,
    regions: []const []const u8,
    cluster_id: []const u8,
    admin_secret_version: []const u8,
};

pub fn buildBootstrap(allocator: std.mem.Allocator, config: BootstrapConfig) !stack_registry.StackProgram {
    const provider = gcp.ProviderConfig{
        .project_id = config.project_id,
        .primary_region = config.primary_region,
        .service_regions = config.regions,
        .network_tier = .premium,
    };
    try provider.validate();
    var graph = resource.ResourceGraph.init(allocator);
    errdefer graph.deinit();
    const services = [_][]const u8{
        "serviceusage.googleapis.com",
        "iam.googleapis.com",
        "storage.googleapis.com",
        "artifactregistry.googleapis.com",
        "cloudbuild.googleapis.com",
        "cloudresourcemanager.googleapis.com",
        "logging.googleapis.com",
        "cloudkms.googleapis.com",
        "run.googleapis.com",
        "compute.googleapis.com",
        "secretmanager.googleapis.com",
        "cloudbilling.googleapis.com",
        "bigquery.googleapis.com",
    };
    for (services) |service_name| {
        var service = try gcp.project_service.Service.build(allocator, provider, .{ .service = service_name });
        defer service.deinit(allocator);
        try graph.addResource(service.node);
    }
    var bucket = try gcp.storage.BuildBucket.build(allocator, provider, .{
        .name = config.state_bucket,
        .location = config.primary_region,
        .lifecycle_age_days = 3650,
    });
    defer bucket.deinit(allocator);
    try graph.addResource(bucket.node);
    try graph.addDependency(bucket.node.id, "gcp.project.Service.storage.googleapis.com");

    var repository = try gcp.artifact_registry.DockerRepository.build(allocator, provider, .{
        .name = "ziac-cloud",
        .location = config.primary_region,
    });
    defer repository.deinit(allocator);
    repository.node.lifecycle.retain_on_delete = true;
    try graph.addResource(repository.node);
    try graph.addDependency(repository.node.id, "gcp.project.Service.artifactregistry.googleapis.com");

    var ring = try gcp.kms.KeyRing.build(allocator, provider, .{ .name = "ziac-cloud", .location = config.primary_region });
    defer ring.deinit(allocator);
    try graph.addResource(ring.node);
    try graph.addDependency(ring.node.id, "gcp.project.Service.cloudkms.googleapis.com");
    var key = try gcp.kms.CryptoKey.build(allocator, provider, .{ .name = "connection-vault", .key_ring = ring.name });
    defer key.deinit(allocator);
    try graph.addResource(key.node);
    try graph.bindOutput(key.node.id, ring.name);

    const secret_names = [_][]const u8{ "cockroach-admin-url", "google-oauth-client-id", "google-oauth-client-secret" };
    for (secret_names) |secret_name| {
        var secret = try gcp.secret_manager.Secret.build(allocator, provider, .{ .name = secret_name });
        defer secret.deinit(allocator);
        secret.node.lifecycle.retain_on_delete = true;
        try graph.addResource(secret.node);
        try graph.addDependency(secret.node.id, "gcp.project.Service.secretmanager.googleapis.com");
    }

    var deployer = try gcp.iam.ServiceAccount.build(allocator, provider, .{
        .account_id = "ziac-deployer",
        .display_name = "Ziac Cloud deployer",
        .description = "Applies digest-approved Ziac Cloud plans",
    });
    defer deployer.deinit(allocator);
    try graph.addResource(deployer.node);
    const member = try std.fmt.allocPrint(allocator, "serviceAccount:ziac-deployer@{s}.iam.gserviceaccount.com", .{config.project_id});
    defer allocator.free(member);
    const roles = [_][]const u8{
        "roles/run.admin",
        "roles/iam.serviceAccountAdmin",
        "roles/iam.serviceAccountUser",
        "roles/storage.admin",
        "roles/cloudkms.admin",
        "roles/secretmanager.admin",
        "roles/compute.admin",
        "roles/dns.admin",
        "roles/cloudbuild.builds.editor",
        "roles/artifactregistry.writer",
        "roles/logging.logWriter",
    };
    for (roles, 0..) |role, index| {
        const name = try std.fmt.allocPrint(allocator, "ziac-deployer-{d}", .{index});
        defer allocator.free(name);
        var binding = try gcp.iam.ProjectMember.build(allocator, provider, .{ .name = name, .role = role, .member = member });
        defer binding.deinit(allocator);
        try graph.addResource(binding.node);
        try graph.addDependency(binding.node.id, deployer.node.id);
    }
    var outputs = std.ArrayList(stack_registry.OutputDefinition).empty;
    errdefer deinitOutputs(allocator, &outputs);
    try appendRef(allocator, &outputs, "state_bucket", bucket.name.resource_ref, false);
    try appendRef(allocator, &outputs, "artifact_repository", repository.repository_url.resource_ref, false);
    try appendRef(allocator, &outputs, "kms_key", key.name.resource_ref, false);
    try appendRef(allocator, &outputs, "deployer_service_account", deployer.email.resource_ref, false);
    try appendRef(allocator, &outputs, "cockroach_admin_secret", gcp.secret_manager.Secret.Outputs.ResourceName.fromResource("gcp.secret.Secret.cockroach-admin-url").resource_ref, false);
    try appendRef(allocator, &outputs, "oauth_client_id_secret", gcp.secret_manager.Secret.Outputs.ResourceName.fromResource("gcp.secret.Secret.google-oauth-client-id").resource_ref, false);
    try appendRef(allocator, &outputs, "oauth_client_secret", gcp.secret_manager.Secret.Outputs.ResourceName.fromResource("gcp.secret.Secret.google-oauth-client-secret").resource_ref, false);
    return .{ .allocator = allocator, .graph = graph, .outputs = outputs };
}

pub fn buildData(allocator: std.mem.Allocator, config: DataConfig) !stack_registry.StackProgram {
    const google = gcp.ProviderConfig{
        .project_id = config.project_id,
        .primary_region = config.primary_region,
        .service_regions = config.regions,
        .network_tier = .premium,
    };
    const migrations = [_]cockroach.migration.Spec{
        .{ .id = "001_estate_control_plane", .sql = self_host_migrations.estate_control_plane },
        .{ .id = "002_billing_intelligence", .sql = self_host_migrations.billing_intelligence },
    };
    const admin_resource = try std.fmt.allocPrint(allocator, "projects/{s}/secrets/cockroach-admin-url", .{config.project_id});
    defer allocator.free(admin_resource);
    var database = try cockroach.application_database.ApplicationDatabase.build(allocator, google, .{}, .{
        .name = "ziac-cloud",
        .cluster_id = config.cluster_id,
        .plan = .standard,
        .regions = config.regions,
        .database = "ziac_cloud",
        .username = "ziac_control_plane",
        .secret_id = "database-url",
        .admin_connection = .{
            .provider = "gcp-secret-manager",
            .resource = admin_resource,
            .version = config.admin_secret_version,
        },
        .migrations = &migrations,
    });
    defer database.deinit();
    var graph = database.takeGraph();
    errdefer graph.deinit();
    var outputs = std.ArrayList(stack_registry.OutputDefinition).empty;
    errdefer deinitOutputs(allocator, &outputs);
    try appendRef(allocator, &outputs, "database_name", database.database_name.resource_ref, false);
    return .{ .allocator = allocator, .graph = graph, .outputs = outputs };
}

pub fn buildControlPlane(allocator: std.mem.Allocator, config: ControlPlaneConfig) !stack_registry.StackProgram {
    if (config.regions.len < 2) return error.InsufficientRegions;
    const provider = gcp.ProviderConfig{
        .project_id = config.project_id,
        .primary_region = config.primary_region,
        .service_regions = config.regions,
        .network_tier = .premium,
    };
    try provider.validate();
    var foundation = resource.ResourceGraph.init(allocator);
    defer foundation.deinit();
    const services = [_][]const u8{ "run.googleapis.com", "compute.googleapis.com", "secretmanager.googleapis.com", "cloudkms.googleapis.com", "dns.googleapis.com" };
    for (services) |service_name| {
        var service = try gcp.project_service.Service.build(allocator, provider, .{ .service = service_name });
        defer service.deinit(allocator);
        try foundation.addResource(service.node);
    }
    var runtime = try gcp.iam.ServiceAccount.build(allocator, provider, .{
        .account_id = "ziac-control-plane",
        .display_name = "Ziac Estate control plane",
        .description = "Runtime identity for the local-first Ziac hosted services",
    });
    defer runtime.deinit(allocator);
    try foundation.addResource(runtime.node);
    const runtime_email = try std.fmt.allocPrint(allocator, "ziac-control-plane@{s}.iam.gserviceaccount.com", .{config.project_id});
    defer allocator.free(runtime_email);
    const member = try std.fmt.allocPrint(allocator, "serviceAccount:{s}", .{runtime_email});
    defer allocator.free(member);
    const roles = [_][]const u8{ "roles/secretmanager.secretAccessor", "roles/cloudkms.cryptoKeyEncrypterDecrypter", "roles/logging.logWriter" };
    for (roles, 0..) |role, index| {
        const name = try std.fmt.allocPrint(allocator, "control-plane-{d}", .{index});
        defer allocator.free(name);
        var binding = try gcp.iam.ProjectMember.build(allocator, provider, .{ .name = name, .role = role, .member = member });
        defer binding.deinit(allocator);
        try foundation.addResource(binding.node);
        try foundation.addDependency(binding.node.id, runtime.node.id);
    }
    const env = [_]gcp.cloud_run.EnvVar{
        .{ .name = "DATABASE_URL", .secret = true, .secret_name = config.database_secret },
        .{ .name = "GOOGLE_OAUTH_CLIENT_ID", .secret = true, .secret_name = config.oauth_client_id_secret },
        .{ .name = "GOOGLE_OAUTH_CLIENT_SECRET", .secret = true, .secret_name = config.oauth_client_secret },
        .{ .name = "ZIAC_ESTATE_KMS_KEY", .value = config.kms_key },
    };
    var component = try gcp.global.ContainerService.build(allocator, provider, .{
        .base_graph = &foundation,
        .name = "ziac-control-plane",
        .image = config.image,
        .regions = config.regions,
        .domain = config.domain,
        .dns_zone = config.dns_zone,
        .service_account = runtime_email,
        .env = &env,
        .health_mode = .standard,
        .min_instances = 0,
        .rollout = .{ .strategy = .canary_then_fleet, .canary_region = config.primary_region },
    });
    defer component.deinit();
    for (component.graph.resources.items) |node| {
        if (!std.mem.eql(u8, node.type_name, "gcp.run.Service")) continue;
        try component.graph.addDependency(node.id, runtime.node.id);
        for (roles, 0..) |_, index| {
            const binding_id = try std.fmt.allocPrint(allocator, "gcp.iam.ProjectMember.control-plane-{d}", .{index});
            defer allocator.free(binding_id);
            try component.graph.addDependency(node.id, binding_id);
        }
    }
    var graph = resource.ResourceGraph.init(allocator);
    errdefer graph.deinit();
    try graph.appendGraph(&component.graph);
    var outputs = std.ArrayList(stack_registry.OutputDefinition).empty;
    errdefer deinitOutputs(allocator, &outputs);
    try appendLiteral(allocator, &outputs, "url", component.url.value, false);
    try appendRef(allocator, &outputs, "ip_address", component.ip_address.resource_ref, false);
    try appendRef(allocator, &outputs, "runtime_service_account", runtime.email.resource_ref, false);
    return .{ .allocator = allocator, .graph = graph, .outputs = outputs };
}

pub fn buildBilling(allocator: std.mem.Allocator, config: BillingConfig) !stack_registry.StackProgram {
    const provider = gcp.ProviderConfig{ .project_id = config.project_id, .primary_region = config.region };
    try provider.validate();
    var graph = resource.ResourceGraph.init(allocator);
    errdefer graph.deinit();
    const services = [_][]const u8{ "run.googleapis.com", "bigquery.googleapis.com", "cloudbilling.googleapis.com", "secretmanager.googleapis.com", "cloudscheduler.googleapis.com" };
    for (services) |service_name| {
        var service_api = try gcp.project_service.Service.build(allocator, provider, .{ .service = service_name });
        defer service_api.deinit(allocator);
        try graph.addResource(service_api.node);
    }
    var runtime = try gcp.iam.ServiceAccount.build(allocator, provider, .{
        .account_id = "ziac-billing-worker",
        .display_name = "Ziac billing ingestion",
        .description = "Reads customer-authorized billing exports and stores attributed snapshots",
    });
    defer runtime.deinit(allocator);
    try graph.addResource(runtime.node);
    const runtime_email = try std.fmt.allocPrint(allocator, "ziac-billing-worker@{s}.iam.gserviceaccount.com", .{config.project_id});
    defer allocator.free(runtime_email);
    const member = try std.fmt.allocPrint(allocator, "serviceAccount:{s}", .{runtime_email});
    defer allocator.free(member);
    const roles = [_][]const u8{ "roles/bigquery.jobUser", "roles/bigquery.dataViewer", "roles/billing.viewer", "roles/secretmanager.secretAccessor", "roles/logging.logWriter" };
    for (roles, 0..) |role, index| {
        const name = try std.fmt.allocPrint(allocator, "billing-worker-{d}", .{index});
        defer allocator.free(name);
        var binding = try gcp.iam.ProjectMember.build(allocator, provider, .{ .name = name, .role = role, .member = member });
        defer binding.deinit(allocator);
        try graph.addResource(binding.node);
        try graph.addDependency(binding.node.id, runtime.node.id);
    }
    var scheduler_account = try gcp.iam.ServiceAccount.build(allocator, provider, .{
        .account_id = "ziac-billing-scheduler",
        .display_name = "Ziac billing scheduler",
        .description = "Invokes the private billing ingestion service with OIDC",
    });
    defer scheduler_account.deinit(allocator);
    try graph.addResource(scheduler_account.node);
    const scheduler_email = try std.fmt.allocPrint(allocator, "ziac-billing-scheduler@{s}.iam.gserviceaccount.com", .{config.project_id});
    defer allocator.free(scheduler_email);
    const scheduler_member = try std.fmt.allocPrint(allocator, "serviceAccount:{s}", .{scheduler_email});
    defer allocator.free(scheduler_member);
    var invoker = try gcp.iam.ProjectMember.build(allocator, provider, .{
        .name = "billing-scheduler-run-invoker",
        .role = "roles/run.invoker",
        .member = scheduler_member,
    });
    defer invoker.deinit(allocator);
    try graph.addResource(invoker.node);
    try graph.addDependency(invoker.node.id, scheduler_account.node.id);
    const env = [_]gcp.cloud_run.EnvVar{
        .{ .name = "DATABASE_URL", .secret = true, .secret_name = config.database_secret },
        .{ .name = "ZIAC_GCP_PROJECT", .value = config.project_id },
        .{ .name = "ZIAC_BILLING_PROJECT", .value = config.billing_project },
        .{ .name = "ZIAC_BILLING_EXPORT_TABLE", .value = config.export_table },
        .{ .name = "ZIAC_CONTROL_PLANE_URL", .value = config.control_plane_url },
    };
    var service = try gcp.cloud_run.Service.build(allocator, provider, .{
        .name = "ziac-billing-worker",
        .image = config.image,
        .region = config.region,
        .ingress = .internal,
        .allow_unauthenticated = false,
        .service_account = runtime_email,
        .env = &env,
        .timeout_seconds = 900,
        .max_instances = 10,
    });
    defer service.deinit(allocator);
    try graph.addResource(service.node);
    try graph.addDependency(service.node.id, runtime.node.id);
    for (services) |service_name| {
        const api_id = try std.fmt.allocPrint(allocator, "gcp.project.Service.{s}", .{service_name});
        defer allocator.free(api_id);
        try graph.addDependency(service.node.id, api_id);
    }
    var schedule = try gcp.scheduler.Job.build(allocator, provider, .{
        .name = "ziac-billing-hourly",
        .schedule = "7 * * * *",
        .service_url = service.service_url,
        .path = "/v1/billing:ingest",
        .service_account = scheduler_email,
    });
    defer schedule.deinit(allocator);
    try graph.addResource(schedule.node);
    try graph.bindOutput(schedule.node.id, service.service_url);
    try graph.addDependency(schedule.node.id, scheduler_account.node.id);
    try graph.addDependency(schedule.node.id, invoker.node.id);
    try graph.addDependency(schedule.node.id, "gcp.project.Service.cloudscheduler.googleapis.com");
    var outputs = std.ArrayList(stack_registry.OutputDefinition).empty;
    errdefer deinitOutputs(allocator, &outputs);
    try appendRef(allocator, &outputs, "service_url", service.service_url.resource_ref, false);
    try appendRef(allocator, &outputs, "runtime_service_account", runtime.email.resource_ref, false);
    try appendRef(allocator, &outputs, "scheduler_job", schedule.name.resource_ref, false);
    return .{ .allocator = allocator, .graph = graph, .outputs = outputs };
}

fn appendLiteral(allocator: std.mem.Allocator, outputs: *std.ArrayList(stack_registry.OutputDefinition), name: []const u8, literal: []const u8, secret: bool) !void {
    try outputs.append(allocator, .{ .name = try allocator.dupe(u8, name), .source = .{ .literal = try allocator.dupe(u8, literal) }, .secret = secret });
}
fn appendRef(allocator: std.mem.Allocator, outputs: *std.ArrayList(stack_registry.OutputDefinition), name: []const u8, reference: output.OutputRef, secret: bool) !void {
    try outputs.append(allocator, .{ .name = try allocator.dupe(u8, name), .source = .{ .resource_ref = .{
        .resource_id = try allocator.dupe(u8, reference.resource_id),
        .field = try allocator.dupe(u8, reference.field),
    } }, .secret = secret });
}
fn deinitOutputs(allocator: std.mem.Allocator, outputs: *std.ArrayList(stack_registry.OutputDefinition)) void {
    for (outputs.items) |*entry| entry.deinit(allocator);
    outputs.deinit(allocator);
}
