const std = @import("std");
const ziac = @import("ziac");

test "GCP intelligence synthesizes exact API and IAM preflight requirements" {
    const intelligence = ziac.gcp.intelligence;
    const usages = [_]intelligence.RpcUsage{
        .{ .service = "run.googleapis.com", .method = "google.cloud.run.v2.Services.CreateService" },
        .{ .service = "compute.googleapis.com", .method = "compute.backendServices.insert" },
        .{ .service = "run.googleapis.com", .method = "google.cloud.run.v2.Services.GetService" },
    };
    var requirements = try intelligence.synthesize(std.testing.allocator, &usages);
    defer requirements.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), requirements.apis.len);
    try std.testing.expectEqual(@as(usize, 3), requirements.methods.len);
    try std.testing.expect(requirements.hasPermission("run.services.create"));
    try std.testing.expect(requirements.hasPermission("run.services.get"));
    try std.testing.expect(requirements.hasPermission("compute.backendServices.create"));

    var report = try intelligence.evaluatePreflight(std.testing.allocator, requirements, .{
        .enabled_apis = &.{"run.googleapis.com"},
        .granted_permissions = &.{ "run.services.create", "run.services.get" },
        .billing_enabled = true,
        .available_regions = &.{ "europe-west1", "us-central1" },
        .requested_regions = &.{ "europe-west1", "us-central1" },
    });
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(!report.ready);
    try std.testing.expect(report.hasFinding(.api_disabled));
    try std.testing.expect(report.hasFinding(.permission_denied));
}

test "ZigSubscriber graph synthesizes Pub/Sub Run IAM and identity preflight" {
    var subscriber = try ziac.gcp.ZigSubscriber.build(std.testing.allocator, .{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    }, .{
        .name = "orders",
        .project_number = "123456789012",
        .service = ziac.PublicOutput([]const u8).known("projects/ziac-dev/locations/europe-west1/services/orders-worker"),
        .push_endpoint = "https://orders-worker.example.run.app/events/orders",
        .oidc_audience = "https://orders-worker.example.run.app",
        .publishers = &.{"serviceAccount:orders-api@ziac-dev.iam.gserviceaccount.com"},
    });
    defer subscriber.deinit();

    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &subscriber.graph);
    defer requirements.deinit(std.testing.allocator);
    try std.testing.expect(contains(requirements.apis, "pubsub.googleapis.com"));
    try std.testing.expect(contains(requirements.apis, "run.googleapis.com"));
    try std.testing.expect(contains(requirements.apis, "iam.googleapis.com"));
    try std.testing.expect(requirements.hasPermission("pubsub.topics.create"));
    try std.testing.expect(requirements.hasPermission("pubsub.topics.setIamPolicy"));
    try std.testing.expect(requirements.hasPermission("pubsub.subscriptions.create"));
    try std.testing.expect(requirements.hasPermission("pubsub.subscriptions.setIamPolicy"));
    try std.testing.expect(requirements.hasPermission("run.services.getIamPolicy"));
    try std.testing.expect(requirements.hasPermission("run.services.setIamPolicy"));
    try std.testing.expect(requirements.hasPermission("iam.serviceAccounts.create"));
}

test "general storage graph synthesizes bucket object and IAM preflight" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    var bucket = try ziac.gcp.storage.Bucket.build(std.testing.allocator, .{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    }, .{ .name = "ziac-assets", .location = "EU" });
    defer bucket.deinit(std.testing.allocator);
    var member = try ziac.gcp.storage.BucketIamMember.build(std.testing.allocator, .{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    }, .{
        .name = "api-reader",
        .bucket = bucket.name,
        .role = "roles/storage.objectViewer",
        .member = "serviceAccount:api@ziac-dev.iam.gserviceaccount.com",
    });
    defer member.deinit(std.testing.allocator);
    try graph.addResource(bucket.node);
    try graph.addResource(member.node);

    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &graph);
    defer requirements.deinit(std.testing.allocator);
    try std.testing.expect(contains(requirements.apis, "storage.googleapis.com"));
    try std.testing.expect(requirements.hasPermission("storage.buckets.create"));
    try std.testing.expect(requirements.hasPermission("storage.buckets.update"));
    try std.testing.expect(requirements.hasPermission("storage.buckets.getIamPolicy"));
    try std.testing.expect(requirements.hasPermission("storage.buckets.setIamPolicy"));
}

test "async delivery graph synthesizes Cloud Tasks Eventarc and act-as preflight" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    var queue = try ziac.gcp.tasks.Queue.build(std.testing.allocator, .{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    }, .{ .name = "invoice-worker" });
    defer queue.deinit(std.testing.allocator);
    var queue_member = try ziac.gcp.tasks.QueueIamMember.build(std.testing.allocator, .{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    }, .{
        .name = "invoice-enqueuer",
        .queue = queue.name,
        .role = "roles/cloudtasks.enqueuer",
        .member = "serviceAccount:api@ziac-dev.iam.gserviceaccount.com",
    });
    defer queue_member.deinit(std.testing.allocator);
    var trigger = try ziac.gcp.eventarc.Trigger.build(std.testing.allocator, .{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    }, .{
        .name = "orders-created",
        .event_filters = &.{.{ .attribute = "type", .value = "google.cloud.pubsub.topic.v1.messagePublished" }},
        .service_account = "orders-events@ziac-dev.iam.gserviceaccount.com",
        .destination = .{ .cloud_run = .{ .service = "orders-worker", .region = "europe-west1" } },
    });
    defer trigger.deinit(std.testing.allocator);
    try graph.addResource(queue.node);
    try graph.addResource(queue_member.node);
    try graph.addResource(trigger.node);

    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &graph);
    defer requirements.deinit(std.testing.allocator);
    try std.testing.expect(contains(requirements.apis, "cloudtasks.googleapis.com"));
    try std.testing.expect(contains(requirements.apis, "eventarc.googleapis.com"));
    try std.testing.expect(contains(requirements.apis, "iam.googleapis.com"));
    try std.testing.expect(requirements.hasPermission("cloudtasks.queues.create"));
    try std.testing.expect(requirements.hasPermission("cloudtasks.queues.setIamPolicy"));
    try std.testing.expect(requirements.hasPermission("eventarc.triggers.create"));
    try std.testing.expect(requirements.hasPermission("iam.serviceAccounts.actAs"));
}

test "Cloud Run workload components synthesize lifecycle IAM scheduler and action preflight" {
    var scheduled = try ziac.gcp.ScheduledZigJob.build(std.testing.allocator, .{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    }, .{
        .workload = .{
            .name = "nightly-report",
            .containers = &.{.{
                .name = "main",
                .image = "example.invalid/report@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            }},
        },
        .schedule = "0 2 * * *",
    });
    defer scheduled.deinit();
    var worker = try ziac.gcp.ZigWorkerPool.build(std.testing.allocator, .{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    }, .{
        .workload = .{
            .name = "events",
            .containers = &.{.{
                .name = "worker",
                .image = "example.invalid/events@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            }},
        },
    });
    defer worker.deinit();

    for (worker.graph.resources.items) |node| try scheduled.graph.addResource(node);
    for (worker.graph.dependencies.items) |edge| try scheduled.graph.addDependency(edge.from, edge.to);
    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &scheduled.graph);
    defer requirements.deinit(std.testing.allocator);

    try std.testing.expect(contains(requirements.apis, "run.googleapis.com"));
    try std.testing.expect(contains(requirements.apis, "cloudscheduler.googleapis.com"));
    try std.testing.expect(requirements.hasPermission("run.jobs.create"));
    try std.testing.expect(requirements.hasPermission("run.jobs.update"));
    try std.testing.expect(requirements.hasPermission("run.jobs.getIamPolicy"));
    try std.testing.expect(requirements.hasPermission("run.jobs.setIamPolicy"));
    try std.testing.expect(requirements.hasPermission("run.workerpools.create"));
    try std.testing.expect(requirements.hasPermission("run.workerpools.update"));
    try std.testing.expect(requirements.hasPermission("cloudscheduler.jobs.create"));
    try std.testing.expect(requirements.hasPermission("iam.serviceAccounts.actAs"));

    var action_requirements = try ziac.gcp.intelligence.synthesize(std.testing.allocator, ziac.gcp.intelligence.jobExecutionUsages());
    defer action_requirements.deinit(std.testing.allocator);
    try std.testing.expect(action_requirements.hasPermission("run.jobs.run"));
    try std.testing.expect(action_requirements.hasPermission("run.executions.get"));
    try std.testing.expect(action_requirements.hasPermission("run.executions.cancel"));
}

test "permission plan separates deployer and runtime authority with provenance" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    var service = try ziac.gcp.cloud_run.Service.build(std.testing.allocator, .{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    }, .{
        .name = "api",
        .image = "example.invalid/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    });
    defer service.deinit(std.testing.allocator);
    var secret_access = try ziac.gcp.iam.ProjectMember.build(std.testing.allocator, .{
        .project_id = "ziac-dev",
        .primary_region = "europe-west1",
    }, .{
        .name = "api-secret-access",
        .role = "roles/secretmanager.secretAccessor",
        .member = "serviceAccount:api@ziac-dev.iam.gserviceaccount.com",
    });
    defer secret_access.deinit(std.testing.allocator);
    try graph.addResource(service.node);
    try graph.addResource(secret_access.node);

    var permission_plan = try ziac.gcp.intelligence.synthesizePermissionPlan(std.testing.allocator, &graph);
    defer permission_plan.deinit(std.testing.allocator);
    try std.testing.expect(permission_plan.hasPermission(.deployer, "run.services.create"));
    try std.testing.expect(permission_plan.hasPermission(.deployer, "resourcemanager.projects.setIamPolicy"));
    try std.testing.expect(permission_plan.hasPermission(.runtime, "secretmanager.versions.access"));
    var found_provenance = false;
    for (permission_plan.entries) |entry| {
        if (entry.audience == .runtime and std.mem.eql(u8, entry.permission, "secretmanager.versions.access")) {
            found_provenance = std.mem.eql(u8, entry.resource_id, secret_access.node.id) and
                std.mem.eql(u8, entry.operation, "roles/secretmanager.secretAccessor");
        }
    }
    try std.testing.expect(found_provenance);

    var proposal = try ziac.gcp.intelligence.proposeCustomRole(
        std.testing.allocator,
        permission_plan,
        .deployer,
        "ziacDeployer",
    );
    defer proposal.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ziacDeployer", proposal.role_id);
    try std.testing.expect(contains(proposal.permissions, "run.services.create"));
    try std.testing.expect(contains(proposal.permissions, "resourcemanager.projects.setIamPolicy"));
}

test "preflight reports missing Google service agents separately from permissions" {
    var requirements = try ziac.gcp.intelligence.synthesize(std.testing.allocator, &.{.{
        .service = "eventarc.googleapis.com",
        .method = "google.cloud.eventarc.v1.Eventarc.CreateTrigger",
    }});
    defer requirements.deinit(std.testing.allocator);
    var report = try ziac.gcp.intelligence.evaluatePreflight(std.testing.allocator, requirements, .{
        .enabled_apis = &.{"eventarc.googleapis.com"},
        .granted_permissions = &.{"eventarc.triggers.create"},
        .billing_enabled = true,
        .required_service_agents = &.{"service-123456789012@gcp-sa-eventarc.iam.gserviceaccount.com"},
        .available_service_agents = &.{},
    });
    defer report.deinit(std.testing.allocator);
    try std.testing.expect(report.hasFinding(.service_agent_missing));
}

test "governance graphs synthesize exact Org Policy Tags and Access Context authority" {
    var graph = ziac.ResourceGraph.init(std.testing.allocator);
    defer graph.deinit();
    const provider = ziac.gcp.ProviderConfig{ .project_id = "host-project", .primary_region = "europe-west1" };
    var policy = try ziac.gcp.governance.Policy.build(std.testing.allocator, provider, .{
        .name = "allowed-regions",
        .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
        .constraint = "gcp.resourceLocations",
        .spec = .{ .rules = &.{.{ .effect = .{ .values = .{ .allowed = &.{"in:eu-locations"} } } }} },
        .removal_policy = .delete,
    });
    defer policy.deinit(std.testing.allocator);
    var binding = try ziac.gcp.governance.TagBinding.build(std.testing.allocator, provider, .{
        .name = "platform-production",
        .parent = ziac.PublicOutput([]const u8).known("//cloudresourcemanager.googleapis.com/projects/987654321"),
        .tag_value = ziac.PublicOutput([]const u8).known("tagValues/222"),
        .removal_policy = .delete,
    });
    defer binding.deinit(std.testing.allocator);
    var perimeter = try ziac.gcp.governance.ServicePerimeter.build(std.testing.allocator, provider, .{
        .name = "production_data",
        .policy = ziac.PublicOutput([]const u8).known("accessPolicies/123"),
        .title = "Production data",
        .status = .{ .resources = &.{ziac.PublicOutput([]const u8).known("projects/987654321")} },
        .removal_policy = .delete,
    });
    defer perimeter.deinit(std.testing.allocator);
    try graph.addResource(policy.node);
    try graph.addResource(binding.node);
    try graph.addResource(perimeter.node);

    var requirements = try ziac.gcp.intelligence.synthesizeGraph(std.testing.allocator, &graph);
    defer requirements.deinit(std.testing.allocator);
    try std.testing.expect(contains(requirements.apis, "orgpolicy.googleapis.com"));
    try std.testing.expect(contains(requirements.apis, "cloudresourcemanager.googleapis.com"));
    try std.testing.expect(contains(requirements.apis, "accesscontextmanager.googleapis.com"));
    try std.testing.expect(requirements.hasPermission("orgpolicy.policies.get"));
    try std.testing.expect(requirements.hasPermission("orgpolicy.policies.create"));
    try std.testing.expect(requirements.hasPermission("orgpolicy.policies.update"));
    try std.testing.expect(requirements.hasPermission("orgpolicy.policies.delete"));
    try std.testing.expect(requirements.hasPermission("resourcemanager.tagBindings.list"));
    try std.testing.expect(requirements.hasPermission("resourcemanager.tagBindings.create"));
    try std.testing.expect(requirements.hasPermission("resourcemanager.tagBindings.delete"));
    try std.testing.expect(requirements.hasPermission("accesscontextmanager.servicePerimeters.get"));
    try std.testing.expect(requirements.hasPermission("accesscontextmanager.servicePerimeters.create"));
    try std.testing.expect(requirements.hasPermission("accesscontextmanager.servicePerimeters.update"));
    try std.testing.expect(requirements.hasPermission("accesscontextmanager.servicePerimeters.delete"));
}

test "topology advice respects residency and Cockroach locality without mutating policy" {
    const intelligence = ziac.gcp.intelligence;
    var advice = try intelligence.adviseTopology(std.testing.allocator, .{
        .cloud_run_regions = &.{ "europe-west1", "us-central1", "asia-northeast1" },
        .cockroach_regions = &.{ "europe-west1", "us-central1" },
        .allowed_regions = &.{ "europe-west1", "us-central1" },
        .require_private_connectivity = true,
        .independent_canary = false,
    });
    defer advice.deinit(std.testing.allocator);
    try std.testing.expectEqual(ziac.gcp.global.Realization.controlled_regional_fleet, advice.realization);
    try std.testing.expect(advice.hasFinding(.residency_violation));
    try std.testing.expect(advice.hasFinding(.database_locality_gap));
    try std.testing.expectEqual(@as(usize, 3), advice.declared_regions.len);
}

fn contains(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, expected)) return true;
    return false;
}
