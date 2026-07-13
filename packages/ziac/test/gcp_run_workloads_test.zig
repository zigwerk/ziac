const std = @import("std");
const ziac = @import("ziac");

const provider = ziac.gcp.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
    .labels = &.{.{ .key = "managed-by", .value = "ziac" }},
};

test "Cloud Run Job declaration models containers tasks secrets VPC and GPU controls" {
    var job = try ziac.gcp.run_workloads.Job.build(std.testing.allocator, provider, .{
        .name = "migrate",
        .containers = &.{
            .{
                .name = "migration",
                .image = "europe-west1-docker.pkg.dev/ziac-dev/apps/migrate@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                .command = &.{"/app/migrate"},
                .args = &.{"up"},
                .cpu = "2",
                .memory = "1Gi",
                .env = &.{
                    .{ .name = "MODE", .value = "apply" },
                    .{ .name = "DATABASE_URL", .secret = true, .secret_name = "database-url" },
                },
            },
            .{
                .name = "audit",
                .image_output = ziac.PublicOutput([]const u8).fromResource("gcp.cloudbuild.ZigImage.audit", "image_ref"),
            },
        },
        .task_count = 16,
        .parallelism = 4,
        .max_retries = 2,
        .timeout_seconds = 1_800,
        .service_account = "migration@ziac-dev.iam.gserviceaccount.com",
        .secret_volumes = &.{.{
            .name = "signing-key",
            .secret = "migration-signing-key",
            .path = "key.pem",
            .mount_path = "/var/run/secrets/signing",
            .container = "migration",
        }},
        .direct_vpc = .{
            .network = "projects/ziac-dev/global/networks/app",
            .subnetwork = "projects/ziac-dev/regions/europe-west1/subnetworks/app",
            .egress = .all_traffic,
        },
        .encryption_key = "projects/ziac-dev/locations/europe-west1/keyRings/run/cryptoKeys/jobs",
        .gpu_accelerator = "nvidia-l4",
        .gpu_zonal_redundancy_disabled = true,
        .retain_on_delete = false,
    });
    defer job.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.run.Job.europe-west1.migrate", job.node.id);
    try std.testing.expectEqual(@as(i64, 16), integerField(job.node.inputs, "task_count"));
    try std.testing.expectEqual(@as(i64, 4), integerField(job.node.inputs, "parallelism"));
    try std.testing.expectEqual(@as(usize, 2), listField(job.node.inputs, "containers").len);
    try std.testing.expectEqualStrings("nvidia-l4", stringField(job.node.inputs, "gpu_accelerator"));
    try std.testing.expect(!job.node.lifecycle.retain_on_delete);
}

test "Cloud Run workload identifiers and multi-container mounts are unambiguous" {
    try std.testing.expectError(error.InvalidName, ziac.gcp.run_workloads.Job.build(std.testing.allocator, provider, .{
        .name = "Uppercase",
        .containers = &.{.{ .name = "main", .image = "example.invalid/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }},
    }));
    try std.testing.expectError(error.InvalidSecretVolume, ziac.gcp.run_workloads.Job.build(std.testing.allocator, provider, .{
        .name = "ambiguous-mount",
        .containers = &.{
            .{ .name = "main", .image = "example.invalid/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
            .{ .name = "audit", .image = "example.invalid/audit@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
        },
        .secret_volumes = &.{.{
            .name = "key",
            .secret = "signing-key",
            .path = "key.pem",
            .mount_path = "/var/run/key",
        }},
    }));
    try std.testing.expectError(error.InvalidSecretVolume, ziac.gcp.run_workloads.Job.build(std.testing.allocator, provider, .{
        .name = "missing-container",
        .containers = &.{.{ .name = "main", .image = "example.invalid/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }},
        .secret_volumes = &.{.{
            .name = "key",
            .secret = "signing-key",
            .path = "key.pem",
            .mount_path = "/var/run/key",
            .container = "audit",
        }},
    }));
}

test "Cloud Run Job declaration rejects incoherent parallelism and duplicate containers" {
    try std.testing.expectError(error.InvalidParallelism, ziac.gcp.run_workloads.Job.build(std.testing.allocator, provider, .{
        .name = "bad-parallelism",
        .containers = &.{.{ .name = "main", .image = "example.invalid/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }},
        .task_count = 2,
        .parallelism = 3,
    }));
    try std.testing.expectError(error.DuplicateContainer, ziac.gcp.run_workloads.Job.build(std.testing.allocator, provider, .{
        .name = "duplicate",
        .containers = &.{
            .{ .name = "main", .image = "example.invalid/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" },
            .{ .name = "main", .image = "example.invalid/audit@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" },
        },
    }));
    try std.testing.expectError(error.InvalidGpu, ziac.gcp.run_workloads.Job.build(std.testing.allocator, provider, .{
        .name = "bad-gpu",
        .containers = &.{.{ .name = "main", .image = "example.invalid/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }},
        .gpu_zonal_redundancy_disabled = true,
    }));
}

test "Cloud Run WorkerPool declaration models manual scale and revision splits" {
    var worker = try ziac.gcp.run_workloads.WorkerPool.build(std.testing.allocator, provider, .{
        .name = "events",
        .description = "Pull-based event processors",
        .containers = &.{.{
            .name = "worker",
            .image = "europe-west1-docker.pkg.dev/ziac-dev/apps/events@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            .cpu = "2",
            .memory = "2Gi",
        }},
        .manual_instance_count = 8,
        .revision = "events-v2",
        .instance_splits = &.{
            .{ .allocation = .latest, .percent = 20 },
            .{ .allocation = .revision, .revision = "events-v1", .percent = 80 },
        },
        .service_account = "events@ziac-dev.iam.gserviceaccount.com",
        .retain_on_delete = false,
    });
    defer worker.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.run.WorkerPool.europe-west1.events", worker.node.id);
    try std.testing.expectEqual(@as(i64, 8), integerField(worker.node.inputs, "manual_instance_count"));
    try std.testing.expectEqual(@as(usize, 2), listField(worker.node.inputs, "instance_splits").len);
    try std.testing.expectEqualStrings("events-v2", stringField(worker.node.inputs, "revision"));
}

test "Cloud Run WorkerPool declaration rejects invalid split ownership" {
    try std.testing.expectError(error.InvalidInstanceSplits, ziac.gcp.run_workloads.WorkerPool.build(std.testing.allocator, provider, .{
        .name = "events",
        .containers = &.{.{ .name = "worker", .image = "example.invalid/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }},
        .instance_splits = &.{
            .{ .allocation = .latest, .percent = 20 },
            .{ .allocation = .revision, .revision = "events-v1", .percent = 70 },
        },
    }));
    try std.testing.expectError(error.InvalidInstanceSplits, ziac.gcp.run_workloads.WorkerPool.build(std.testing.allocator, provider, .{
        .name = "events",
        .containers = &.{.{ .name = "worker", .image = "example.invalid/app@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }},
        .instance_splits = &.{.{ .allocation = .revision, .percent = 100 }},
    }));
}

test "Cloud Run Job IAM member binds the exact execution principal" {
    var job = try ziac.gcp.run_workloads.Job.build(std.testing.allocator, provider, .{
        .name = "nightly",
        .containers = &.{.{ .name = "main", .image = "example.invalid/nightly@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }},
    });
    defer job.deinit(std.testing.allocator);
    var binding = try ziac.gcp.run_workloads.JobIamMember.build(std.testing.allocator, provider, .{
        .name = "nightly-scheduler",
        .job = job.name,
        .role = "roles/run.invoker",
        .member = "serviceAccount:nightly-scheduler@ziac-dev.iam.gserviceaccount.com",
    });
    defer binding.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.run.JobIamMember.nightly-scheduler", binding.node.id);
    try std.testing.expect(field(binding.node.inputs, "resource") == .output_ref);
    try std.testing.expectError(error.InvalidRole, ziac.gcp.run_workloads.JobIamMember.build(std.testing.allocator, provider, .{
        .name = "wrong-role",
        .job = job.name,
        .role = "roles/storage.admin",
        .member = "serviceAccount:nightly-scheduler@ziac-dev.iam.gserviceaccount.com",
    }));
}

fn field(input: ziac.value.Value, name: []const u8) ziac.value.Value {
    for (input.object) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value;
    unreachable;
}

fn stringField(input: ziac.value.Value, name: []const u8) []const u8 {
    return switch (field(input, name)) {
        .string => |text| text,
        else => unreachable,
    };
}

fn integerField(input: ziac.value.Value, name: []const u8) i64 {
    return switch (field(input, name)) {
        .integer => |number| number,
        else => unreachable,
    };
}

fn listField(input: ziac.value.Value, name: []const u8) []const ziac.value.Value {
    return switch (field(input, name)) {
        .list => |items| items,
        else => unreachable,
    };
}
