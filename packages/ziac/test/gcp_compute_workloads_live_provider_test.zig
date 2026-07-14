const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;
const workloads = ziac.gcp.compute_workloads;

test "zonal disks checkpoint create and only grow in place" {
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"insert-disk\"}"),
        ok("{\"name\":\"insert-disk\",\"status\":\"DONE\"}"),
        ok(diskJson(20)),
        ok("{\"name\":\"resize-disk\"}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.compute_workloads_provider.Handler{
        .client = &harness.client,
        .operation_policy = .{ .poll_interval_millis = 0 },
    };
    var disk = try workloads.Disk.build(std.testing.allocator, config(), .{
        .name = "api-data",
        .zone = "europe-west1-b",
        .size_gb = 20,
        .protect = false,
        .retain_on_delete = false,
    });
    defer disk.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.create(&context, disk.node);
    defer pending.deinit();
    try std.testing.expect(!pending.completed);
    context.operation_handle = pending.operation_handle;
    var observed_read = try handler.read(&context, disk.node, null);
    defer observed_read.deinit();
    const observed = observed_read.present;
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].url, "/zones/europe-west1-b/operations/insert-disk") != null);
    try std.testing.expectEqual(@as(i64, 20), outputValue(observed, "size_gb").integer);

    var grown = try workloads.Disk.build(std.testing.allocator, config(), .{
        .name = "api-data",
        .zone = "europe-west1-b",
        .size_gb = 40,
        .protect = false,
        .retain_on_delete = false,
    });
    defer grown.deinit(std.testing.allocator);
    var grow_diff = try ziac.gcp.compute_workloads_provider.Handler.diff(&context, grown.node, &observed);
    defer grow_diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.update, grow_diff.kind);
    var resizing = try handler.update(&context, grown.node, &observed);
    defer resizing.deinit();
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[3].url, "/zones/europe-west1-b/disks/api-data/resize"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].body, "\"sizeGb\":\"40\"") != null);

    var shrunk = try workloads.Disk.build(std.testing.allocator, config(), .{
        .name = "api-data",
        .zone = "europe-west1-b",
        .size_gb = 10,
        .protect = false,
        .retain_on_delete = false,
    });
    defer shrunk.deinit(std.testing.allocator);
    var shrink_diff = try ziac.gcp.compute_workloads_provider.Handler.diff(&context, shrunk.node, &observed);
    defer shrink_diff.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.replace, shrink_diff.kind);
}

test "instances resolve startup scripts for mutation without retaining bytes" {
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"insert-instance\"}"),
        ok("{\"name\":\"insert-instance\",\"status\":\"DONE\"}"),
        ok(instanceJson()),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var secrets = FixedSecretSource{};
    const handler = ziac.gcp.compute_workloads_provider.Handler{
        .client = &harness.client,
        .operation_policy = .{ .poll_interval_millis = 0 },
        .secret_source = secrets.secretSource(),
    };
    var instance = try buildInstance();
    defer instance.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.create(&context, instance.node);
    defer pending.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "#!/bin/sh\\necho ziac") != null);
    const state_json = try pending.observed_inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(state_json);
    try std.testing.expect(std.mem.indexOf(u8, state_json, "echo ziac") == null);
    try std.testing.expect(std.mem.indexOf(u8, state_json, "gcp-secret-manager") != null);

    context.operation_handle = pending.operation_handle;
    var read = try handler.read(&context, instance.node, null);
    defer read.deinit();
    try std.testing.expectEqualStrings("10.42.0.9", outputValue(read.present, "internal_ip").string);
    try std.testing.expectEqualStrings("34.1.2.3", outputValue(read.present, "external_ip").string);
}

test "Compute reads surface remote label drift instead of cloning desired labels" {
    const responses = [_]zstd.Http.Response{ok(instanceJsonWithLabels())};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.compute_workloads_provider.Handler{ .client = &harness.client };
    var instance = try buildInstance();
    defer instance.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var read = try handler.read(&context, instance.node, null);
    defer read.deinit();
    var drift = try ziac.gcp.compute_workloads_provider.Handler.diff(&context, instance.node, &read.present);
    defer drift.deinit();

    try std.testing.expectEqual(ziac.provider.DiffKind.replace, drift.kind);
    const observed_json = try read.present.observed_inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(observed_json);
    try std.testing.expect(std.mem.indexOf(u8, observed_json, "outside-ziac") != null);
}

test "images and instance templates replace when desired state changes" {
    var image = try workloads.Image.build(std.testing.allocator, config(), .{
        .name = "api-image",
        .source_disk = ziac.PublicOutput([]const u8).known("projects/ziac-dev/zones/europe-west1-b/disks/api-data"),
    });
    defer image.deinit(std.testing.allocator);
    var template = try buildTemplate("e2-standard-2");
    defer template.deinit(std.testing.allocator);
    var changed = try buildTemplate("e2-standard-4");
    defer changed.deinit(std.testing.allocator);
    var observed = try ziac.provider.ResourceResult.init(std.testing.allocator, "projects/ziac-dev/global/instanceTemplates/api-template", template.node.inputs, &.{}, null);
    defer observed.deinit();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var same = try ziac.gcp.compute_workloads_provider.Handler.diff(&context, template.node, &observed);
    defer same.deinit();
    var replacement = try ziac.gcp.compute_workloads_provider.Handler.diff(&context, changed.node, &observed);
    defer replacement.deinit();
    try std.testing.expectEqual(ziac.provider.DiffKind.noop, same.kind);
    try std.testing.expectEqual(ziac.provider.DiffKind.replace, replacement.kind);
    try std.testing.expect(ziac.gcp.compute_workloads_provider.supports(image.node));
}

test "regional managed groups retry fingerprint conflicts and preserve update intent" {
    const remote_a = groupJson("fingerprint-a", 2);
    const remote_b = groupJson("fingerprint-b", 2);
    const responses = [_]zstd.Http.Response{
        ok(remote_a),
        .{ .status = 412, .body = "{\"error\":{\"code\":412,\"message\":\"fingerprint mismatch\"}}" },
        ok(remote_b),
        ok("{\"name\":\"patch-group\"}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.compute_workloads_provider.Handler{ .client = &harness.client, .conflict_retries = 1 };
    var group = try buildRegionalGroup(4);
    defer group.deinit(std.testing.allocator);
    var observed = try ziac.provider.ResourceResult.init(std.testing.allocator, "projects/ziac-dev/regions/europe-west1/instanceGroupManagers/api-fleet", group.node.inputs, &.{}, null);
    defer observed.deinit();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try handler.update(&context, group.node, &observed);
    defer pending.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[1].body, "\"fingerprint\":\"fingerprint-a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].body, "\"fingerprint\":\"fingerprint-b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].body, "\"targetSize\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[3].body, "\"type\":\"PROACTIVE\"") != null);
}

test "regional autoscalers update and import through canonical scope" {
    const remote = "{\"name\":\"api-scale\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/regions/europe-west1/autoscalers/api-scale\",\"target\":\"projects/ziac-dev/regions/europe-west1/instanceGroupManagers/api-fleet\",\"status\":\"ACTIVE\",\"recommendedSize\":3,\"autoscalingPolicy\":{\"minNumReplicas\":2,\"maxNumReplicas\":10,\"coolDownPeriodSec\":60,\"mode\":\"ON\",\"cpuUtilization\":{\"utilizationTarget\":0.6},\"scaleInControl\":{\"timeWindowSec\":600}}}";
    const responses = [_]zstd.Http.Response{ ok(remote), ok(remote), ok("{\"name\":\"patch-autoscaler\"}") };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    const handler = ziac.gcp.compute_workloads_provider.Handler{ .client = &harness.client };
    var autoscaler = try buildRegionalAutoscaler(12);
    defer autoscaler.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var imported = try handler.importResource(&context, autoscaler.node, "projects/ziac-dev/regions/europe-west1/autoscalers/api-scale");
    defer imported.deinit();
    try std.testing.expectEqual(@as(i64, 3), outputValue(imported, "recommended_size").integer);
    var pending = try handler.update(&context, autoscaler.node, &imported);
    defer pending.deinit();
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[2].body, "\"maxNumReplicas\":12") != null);
}

test "live provider dispatches Compute workload resources with shared secret authority" {
    const responses = [_]zstd.Http.Response{ok("{\"name\":\"insert-instance\"}")};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var secrets = FixedSecretSource{};
    var live = ziac.gcp.live_provider.LiveProvider.init(&harness.client);
    live.secret_source = secrets.secretSource();
    const provider = live.provider();
    var instance = try buildInstance();
    defer instance.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);

    var pending = try provider.createWithContext(&context, instance.node);
    defer pending.deinit();
    try std.testing.expect(!pending.completed);
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[0].url, "/compute/v1/projects/ziac-dev/zones/europe-west1-b/instances"));
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "startup-script") != null);
}

const Harness = struct {
    source: FixedTokenSource,
    cache: auth.TokenCache,
    transport: @import("gcp_client_test.zig").RecordingTransport,
    client: gclient.Client,

    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.source = .{};
        self.cache = auth.TokenCache.init(self.source.tokenSource(), 300);
        self.transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{ .compute = "https://compute.example.test" });
    }

    fn deinit(self: *Harness) void {
        self.transport.deinit();
        self.cache.deinit(std.testing.allocator);
    }
};

const FixedTokenSource = struct {
    fn tokenSource(self: *FixedTokenSource) auth.TokenSource {
        return .{ .ptr = self, .fetchFn = fetch };
    }
    fn fetch(_: *anyopaque, allocator: std.mem.Allocator, now: u64) auth.AuthError!auth.AccessToken {
        return auth.AccessToken.initOwned(allocator, .{ .access_token = "token", .token_type = "Bearer", .expires_at_seconds = now + 3600 });
    }
};

const FixedSecretSource = struct {
    fn secretSource(self: *FixedSecretSource) ziac.secret.SecretSource {
        return .{ .ptr = self, .resolveFn = resolve };
    }
    fn resolve(_: *anyopaque, _: *ziac.provider.OperationContext, allocator: std.mem.Allocator, _: ziac.value.SecretReference) ziac.provider.ProviderError!ziac.secret.SecretPayload {
        return ziac.secret.SecretPayload.initOwned(allocator, "#!/bin/sh\necho ziac\n", null);
    }
};

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
}

fn startupReference() ziac.SecretOutput(ziac.value.SecretReference) {
    return .known(.{ .provider = "gcp-secret-manager", .resource = "projects/ziac-dev/secrets/startup", .version = "1" });
}

fn networkInterface() workloads.NetworkInterface {
    return .{ .network = ziac.PublicOutput([]const u8).known("projects/ziac-dev/global/networks/api"), .subnetwork = ziac.PublicOutput([]const u8).known("projects/ziac-dev/regions/europe-west1/subnetworks/api"), .external_access = true };
}

fn buildInstance() !workloads.Instance {
    return workloads.Instance.build(std.testing.allocator, config(), .{
        .name = "api-vm",
        .zone = "europe-west1-b",
        .machine_type = "e2-standard-2",
        .boot_disk = ziac.PublicOutput([]const u8).known("projects/ziac-dev/zones/europe-west1-b/disks/api-data"),
        .network_interfaces = &.{networkInterface()},
        .service_account = ziac.PublicOutput([]const u8).known("api@ziac-dev.iam.gserviceaccount.com"),
        .startup_script = startupReference(),
        .startup_script_sha256 = "52e6a26d1835b1d555a7701bf98e54d67f74fef5ea39c7f4422351137eab3cbd",
        .protect = false,
        .retain_on_delete = false,
    });
}

fn buildTemplate(machine_type: []const u8) !workloads.InstanceTemplate {
    return workloads.InstanceTemplate.build(std.testing.allocator, config(), .{
        .name = "api-template",
        .machine_type = machine_type,
        .source_image = ziac.PublicOutput([]const u8).known("projects/ziac-dev/global/images/api-image"),
        .network_interfaces = &.{networkInterface()},
        .service_account = ziac.PublicOutput([]const u8).known("api@ziac-dev.iam.gserviceaccount.com"),
    });
}

fn buildRegionalGroup(target_size: u32) !workloads.RegionInstanceGroupManager {
    return workloads.RegionInstanceGroupManager.build(std.testing.allocator, config(), .{
        .name = "api-fleet",
        .region = "europe-west1",
        .distribution_zones = &.{ "europe-west1-b", "europe-west1-c" },
        .instance_template = ziac.PublicOutput([]const u8).known("projects/ziac-dev/global/instanceTemplates/api-template"),
        .base_instance_name = "api",
        .target_size = target_size,
        .protect = false,
    });
}

fn buildRegionalAutoscaler(max_replicas: u32) !workloads.RegionAutoscaler {
    return workloads.RegionAutoscaler.build(std.testing.allocator, config(), .{
        .name = "api-scale",
        .region = "europe-west1",
        .target = ziac.PublicOutput([]const u8).known("projects/ziac-dev/regions/europe-west1/instanceGroupManagers/api-fleet"),
        .min_replicas = 2,
        .max_replicas = max_replicas,
    });
}

fn outputValue(result: ziac.provider.ResourceResult, name: []const u8) ziac.value.Value {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name)) return item.value;
    unreachable;
}

fn diskJson(size: u64) []const u8 {
    return if (size == 20)
        "{\"name\":\"api-data\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/zones/europe-west1-b/disks/api-data\",\"status\":\"READY\",\"sizeGb\":\"20\",\"type\":\"projects/ziac-dev/zones/europe-west1-b/diskTypes/pd-balanced\",\"physicalBlockSizeBytes\":4096,\"provisionedIops\":0,\"labels\":{}}"
    else
        unreachable;
}

fn instanceJson() []const u8 {
    return "{\"name\":\"api-vm\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/zones/europe-west1-b/instances/api-vm\",\"zone\":\"projects/ziac-dev/zones/europe-west1-b\",\"status\":\"RUNNING\",\"machineType\":\"projects/ziac-dev/zones/europe-west1-b/machineTypes/e2-standard-2\",\"networkInterfaces\":[{\"network\":\"projects/ziac-dev/global/networks/api\",\"subnetwork\":\"projects/ziac-dev/regions/europe-west1/subnetworks/api\",\"networkIP\":\"10.42.0.9\",\"nicType\":\"GVNIC\",\"stackType\":\"IPV4_ONLY\",\"accessConfigs\":[{\"natIP\":\"34.1.2.3\"}]}],\"disks\":[{\"source\":\"projects/ziac-dev/zones/europe-west1-b/disks/api-data\",\"boot\":true,\"autoDelete\":false}],\"serviceAccounts\":[{\"email\":\"api@ziac-dev.iam.gserviceaccount.com\",\"scopes\":[\"https://www.googleapis.com/auth/cloud-platform\"]}],\"metadata\":{\"items\":[{\"key\":\"startup-script\",\"value\":\"redacted-by-provider\"}]},\"tags\":{\"items\":[]},\"labels\":{},\"deletionProtection\":true,\"canIpForward\":false}";
}

fn instanceJsonWithLabels() []const u8 {
    return "{\"name\":\"api-vm\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/zones/europe-west1-b/instances/api-vm\",\"zone\":\"projects/ziac-dev/zones/europe-west1-b\",\"status\":\"RUNNING\",\"machineType\":\"projects/ziac-dev/zones/europe-west1-b/machineTypes/e2-standard-2\",\"networkInterfaces\":[{\"network\":\"projects/ziac-dev/global/networks/api\",\"subnetwork\":\"projects/ziac-dev/regions/europe-west1/subnetworks/api\",\"networkIP\":\"10.42.0.9\",\"nicType\":\"GVNIC\",\"stackType\":\"IPV4_ONLY\",\"accessConfigs\":[{\"natIP\":\"34.1.2.3\"}]}],\"disks\":[{\"source\":\"projects/ziac-dev/zones/europe-west1-b/disks/api-data\",\"boot\":true,\"autoDelete\":false}],\"serviceAccounts\":[{\"email\":\"api@ziac-dev.iam.gserviceaccount.com\",\"scopes\":[\"https://www.googleapis.com/auth/cloud-platform\"]}],\"metadata\":{\"items\":[{\"key\":\"startup-script\",\"value\":\"redacted-by-provider\"}]},\"tags\":{\"items\":[]},\"labels\":{\"owner\":\"outside-ziac\"},\"deletionProtection\":true,\"canIpForward\":false}";
}

fn groupJson(fingerprint: []const u8, target_size: u32) []const u8 {
    if (std.mem.eql(u8, fingerprint, "fingerprint-a") and target_size == 2) return "{\"name\":\"api-fleet\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/regions/europe-west1/instanceGroupManagers/api-fleet\",\"instanceGroup\":\"projects/ziac-dev/regions/europe-west1/instanceGroups/api-fleet\",\"status\":{\"isStable\":true},\"targetSize\":2,\"fingerprint\":\"fingerprint-a\"}";
    if (std.mem.eql(u8, fingerprint, "fingerprint-b") and target_size == 2) return "{\"name\":\"api-fleet\",\"selfLink\":\"https://compute.googleapis.com/compute/v1/projects/ziac-dev/regions/europe-west1/instanceGroupManagers/api-fleet\",\"instanceGroup\":\"projects/ziac-dev/regions/europe-west1/instanceGroups/api-fleet\",\"status\":{\"isStable\":true},\"targetSize\":2,\"fingerprint\":\"fingerprint-b\"}";
    unreachable;
}

fn ok(body: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = @constCast(body) };
}
