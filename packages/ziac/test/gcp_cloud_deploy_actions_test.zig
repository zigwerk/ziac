const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const actions = ziac.gcp.cloud_deploy_actions;
const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;

test "Cloud Deploy actions require exact payload-bound capability digests" {
    const responses = [_]zstd.Http.Response{};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    const runner = actions.Runner{ .client = &harness.client };
    const target = pipelineTarget();
    const args = actions.CreateReleaseArgs{ .release_id = "release-42", .skaffold_config_uri = "gs://releases/42.tar.gz" };
    const digest = actions.createReleaseDigest(target, args);

    try std.testing.expectError(error.ActionDigestMismatch, runner.createReleaseAlloc(&context, capability(digest[0..]), target, args, "wrong"));
    var denied = capability(digest[0..]);
    denied.permissions.apply = false;
    try std.testing.expectError(error.ActionDenied, runner.createReleaseAlloc(&context, denied, target, args, digest[0..]));
    try std.testing.expectEqual(@as(usize, 0), harness.transport.requests.items.len);
}

test "Cloud Deploy action digests bind every mutable payload field" {
    const target = pipelineTarget();
    const release = actions.CreateReleaseArgs{
        .release_id = "release-42",
        .skaffold_config_uri = "gs://releases/42.tar.gz",
        .skaffold_config_path = "deploy/skaffold.yaml",
        .skaffold_version = "2.13",
        .description = "release 42",
    };
    var changed_release = release;
    changed_release.skaffold_config_uri = "gs://releases/tampered.tar.gz";
    try std.testing.expect(!std.mem.eql(u8, &actions.createReleaseDigest(target, release), &actions.createReleaseDigest(target, changed_release)));

    const release_target = actions.Target{ .stage = "prod", .project = "ziac-dev", .resource_name = "projects/ziac-dev/locations/europe-west1/deliveryPipelines/api/releases/release-42", .now_millis = 1_000, .started_at_millis = 900 };
    const promote_args = actions.PromoteArgs{ .rollout_id = "prod-42", .target_id = "prod", .starting_phase_id = "canary-10", .description = "promote" };
    var changed_promote = promote_args;
    changed_promote.target_id = "staging";
    try std.testing.expect(!std.mem.eql(u8, &actions.promoteDigest(release_target, promote_args), &actions.promoteDigest(release_target, changed_promote)));

    const rollout_target = actions.Target{ .stage = "prod", .project = "ziac-dev", .resource_name = release_target.resource_name ++ "/rollouts/prod-42", .now_millis = 1_000, .started_at_millis = 900 };
    try std.testing.expect(!std.mem.eql(
        u8,
        &actions.mutationDigest(.approve, rollout_target, .{ .approve = true }),
        &actions.mutationDigest(.approve, rollout_target, .{ .approve = false }),
    ));
    try std.testing.expect(!std.mem.eql(
        u8,
        &actions.mutationDigest(.rollback, target, .{ .rollback = .{ .target_id = "prod", .rollout_id = "rollback-42" } }),
        &actions.mutationDigest(.rollback, target, .{ .rollback = .{ .target_id = "prod", .rollout_id = "rollback-43" } }),
    ));
}

test "Cloud Deploy release rollout and recovery actions emit governed receipts" {
    const release_name = "projects/ziac-dev/locations/europe-west1/deliveryPipelines/api/releases/release-42";
    const rollout_name = release_name ++ "/rollouts/prod-42";
    const release = "{\"name\":\"" ++ release_name ++ "\",\"renderState\":\"SUCCEEDED\",\"etag\":\"release-etag\"}";
    const rollout = "{\"name\":\"" ++ rollout_name ++ "\",\"targetId\":\"prod\",\"state\":\"PENDING_APPROVAL\",\"approvalState\":\"NEEDS_APPROVAL\",\"etag\":\"rollout-etag\"}";
    const responses = [_]zstd.Http.Response{
        ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/release-create\",\"done\":false}"),
        ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/release-create\",\"done\":true,\"response\":" ++ release ++ "}"),
        ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/rollout-create\",\"done\":false}"),
        ok("{\"name\":\"projects/ziac-dev/locations/europe-west1/operations/rollout-create\",\"done\":true,\"response\":" ++ rollout ++ "}"),
        ok("{}"),
        ok("{}"),
        ok("{\"rollbackRollout\":\"" ++ rollout_name ++ "\"}"),
        ok("{}"),
        ok("{}"),
    };
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    const runner = actions.Runner{ .client = &harness.client, .operation_policy = .{ .poll_interval_millis = 0 } };
    const pipeline = pipelineTarget();

    const release_args = actions.CreateReleaseArgs{ .release_id = "release-42", .skaffold_config_uri = "gs://releases/42.tar.gz", .skaffold_config_path = "skaffold.yaml" };
    var release_receipt = try createRelease(&runner, &context, pipeline, release_args);
    defer release_receipt.deinit();
    try std.testing.expectEqual(actions.Status.succeeded, release_receipt.status);
    try std.testing.expectEqualStrings(release_name, release_receipt.resource_name);

    const promote_args = actions.PromoteArgs{ .rollout_id = "prod-42", .target_id = "prod", .starting_phase_id = "canary-10" };
    var rollout_receipt = try promote(&runner, &context, .{ .stage = "prod", .project = "ziac-dev", .resource_name = release_name, .now_millis = 1_000, .started_at_millis = 900 }, promote_args);
    defer rollout_receipt.deinit();
    try std.testing.expectEqual(actions.Status.pending_approval, rollout_receipt.status);

    const rollout_target = actions.Target{ .stage = "prod", .project = "ziac-dev", .resource_name = rollout_name, .now_millis = 1_000, .started_at_millis = 900 };
    var approve = try simpleAction(&runner, &context, .approve, rollout_target, "approved=true", .{ .approve = true });
    defer approve.deinit();
    var advance = try simpleAction(&runner, &context, .advance, rollout_target, "phase=stable", .{ .advance = "stable" });
    defer advance.deinit();
    var rollback = try simpleAction(&runner, &context, .rollback, pipeline, "target=prod;rollout=rollback-42", .{ .rollback = .{ .target_id = "prod", .rollout_id = "rollback-42" } });
    defer rollback.deinit();
    var cancel = try simpleAction(&runner, &context, .cancel, rollout_target, "cancel", .cancel);
    defer cancel.deinit();
    const release_target = actions.Target{ .stage = "prod", .project = "ziac-dev", .resource_name = release_name, .now_millis = 1_000, .started_at_millis = 900 };
    var abandon = try simpleAction(&runner, &context, .abandon, release_target, "abandon", .abandon);
    defer abandon.deinit();

    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].url, "/releases?releaseId=release-42&validateOnly=false&requestId=") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[2].url, "/rollouts?rolloutId=prod-42&startingPhaseId=canary-10&validateOnly=false&requestId=") != null);
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[4].url, ":approve"));
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[5].url, ":advance"));
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[6].url, ":rollbackTarget"));
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[7].url, ":cancel"));
    try std.testing.expect(std.mem.endsWith(u8, harness.transport.requests.items[8].url, ":abandon"));
}

fn createRelease(runner: *const actions.Runner, context: *ziac.provider.OperationContext, target: actions.Target, args: actions.CreateReleaseArgs) !actions.Receipt {
    const digest = actions.createReleaseDigest(target, args);
    return runner.createReleaseAlloc(context, capability(digest[0..]), target, args, digest[0..]);
}

fn promote(runner: *const actions.Runner, context: *ziac.provider.OperationContext, target: actions.Target, args: actions.PromoteArgs) !actions.Receipt {
    const digest = actions.promoteDigest(target, args);
    return runner.promoteAlloc(context, capability(digest[0..]), target, args, digest[0..]);
}

fn simpleAction(runner: *const actions.Runner, context: *ziac.provider.OperationContext, action: actions.Action, target: actions.Target, material: []const u8, payload: actions.SimplePayload) !actions.Receipt {
    _ = material;
    const digest = actions.mutationDigest(action, target, payload);
    return runner.mutateAlloc(context, capability(digest[0..]), action, target, payload, digest[0..]);
}

fn pipelineTarget() actions.Target {
    return .{ .stage = "prod", .project = "ziac-dev", .resource_name = "projects/ziac-dev/locations/europe-west1/deliveryPipelines/api", .now_millis = 1_000, .started_at_millis = 900 };
}

fn capability(digest: ?[]const u8) ziac.agent_contract.CapabilityEnvelope {
    return .{
        .id = "deploy-actions",
        .stages = &.{"prod"},
        .projects = &.{"ziac-dev"},
        .providers = &.{.gcp},
        .permissions = .{ .read = true, .apply = true, .delete = true },
        .budget = .{ .max_creates = 1, .max_updates = 1, .max_deletes = 1, .max_regions = 1 },
        .expires_at_millis = 10_000,
        .approved_plan_digest = digest,
    };
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
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{ .cloud_deploy = "https://clouddeploy.example.test" });
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

fn ok(body: []const u8) zstd.Http.Response {
    return .{ .status = 200, .body = body };
}
