const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const auth = ziac.gcp.auth;
const gclient = ziac.gcp.client;

test "Cloud Scheduler job binds a private Cloud Run target with OIDC" {
    const provider = ziac.gcp.ProviderConfig{
        .project_id = "ziac-cloud-prod",
        .primary_region = "europe-west1",
    };
    var job = try ziac.gcp.scheduler.Job.build(std.testing.allocator, provider, .{
        .name = "ziac-billing-hourly",
        .schedule = "7 * * * *",
        .service_url = ziac.PublicOutput([]const u8).known("https://billing.example.run.app"),
        .path = "/v1/billing:ingest",
        .service_account = "ziac-billing-scheduler@ziac-cloud-prod.iam.gserviceaccount.com",
    });
    defer job.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("gcp.scheduler.Job.europe-west1.ziac-billing-hourly", job.node.id);
    try std.testing.expect(ziac.gcp.live_provider.supports(job.node));
}

test "Cloud Scheduler job models OAuth Google API targets for Cloud Run Jobs" {
    var job = try ziac.gcp.scheduler.Job.build(std.testing.allocator, providerConfig(), .{
        .name = "nightly",
        .schedule = "0 2 * * *",
        .description = "Run the nightly migration job",
        .service_url = ziac.PublicOutput([]const u8).known("https://run.googleapis.com"),
        .path = "/v2/projects/ziac-cloud-prod/locations/europe-west1/jobs/nightly:run",
        .service_account = "nightly-scheduler@ziac-cloud-prod.iam.gserviceaccount.com",
        .auth_kind = .oauth,
        .oauth_scope = "https://www.googleapis.com/auth/cloud-platform",
        .body_json = "{}",
    });
    defer job.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("oauth", stringField(job.node.inputs, "auth_kind"));
    try std.testing.expectEqualStrings("{}", stringField(job.node.inputs, "body_json"));
    try std.testing.expectError(error.InvalidOAuthScope, ziac.gcp.scheduler.Job.build(std.testing.allocator, providerConfig(), .{
        .name = "bad-scope",
        .schedule = "0 2 * * *",
        .service_url = ziac.PublicOutput([]const u8).known("https://run.googleapis.com"),
        .path = "/v2/projects/ziac-cloud-prod/locations/europe-west1/jobs/nightly:run",
        .service_account = "nightly-scheduler@ziac-cloud-prod.iam.gserviceaccount.com",
        .auth_kind = .oauth,
        .oauth_scope = "http://example.invalid/scope",
    }));
}

test "live Cloud Scheduler provider emits and observes OAuth targets" {
    const remote = "{\"name\":\"projects/ziac-cloud-prod/locations/europe-west1/jobs/nightly\",\"description\":\"Run the nightly migration job\",\"schedule\":\"0 2 * * *\",\"timeZone\":\"Etc/UTC\",\"attemptDeadline\":\"900s\",\"state\":\"ENABLED\",\"httpTarget\":{\"uri\":\"https://run.googleapis.com/v2/projects/ziac-cloud-prod/locations/europe-west1/jobs/nightly:run\",\"httpMethod\":\"POST\",\"body\":\"e30=\",\"oauthToken\":{\"serviceAccountEmail\":\"nightly-scheduler@ziac-cloud-prod.iam.gserviceaccount.com\",\"scope\":\"https://www.googleapis.com/auth/cloud-platform\"}}}";
    const responses = [_]zstd.Http.Response{.{ .status = 200, .body = remote }};
    var harness: Harness = undefined;
    harness.init(&responses);
    defer harness.deinit();
    var job = try ziac.gcp.scheduler.Job.build(std.testing.allocator, providerConfig(), .{
        .name = "nightly",
        .schedule = "0 2 * * *",
        .description = "Run the nightly migration job",
        .service_url = ziac.PublicOutput([]const u8).known("https://run.googleapis.com"),
        .path = "/v2/projects/ziac-cloud-prod/locations/europe-west1/jobs/nightly:run",
        .service_account = "nightly-scheduler@ziac-cloud-prod.iam.gserviceaccount.com",
        .auth_kind = .oauth,
    });
    defer job.deinit(std.testing.allocator);
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var created = try harness.live.provider().createWithContext(&context, job.node);
    defer created.deinit();

    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "\"oauthToken\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "\"oidcToken\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, harness.transport.requests.items[0].body, "\"body\":\"e30=\"") != null);
}

const Harness = struct {
    source: FixedTokenSource,
    cache: auth.TokenCache,
    transport: @import("gcp_client_test.zig").RecordingTransport,
    client: gclient.Client,
    live: ziac.gcp.live_provider.LiveProvider,

    fn init(self: *Harness, responses: []const zstd.Http.Response) void {
        self.source = .{};
        self.cache = auth.TokenCache.init(self.source.tokenSource(), 300);
        self.transport = @import("gcp_client_test.zig").RecordingTransport.init(std.testing.allocator, responses);
        self.client = gclient.Client.init(self.transport.client(), &self.cache, .{ .cloud_scheduler = "https://scheduler.example.test" });
        self.live = ziac.gcp.live_provider.LiveProvider.init(&self.client);
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

fn providerConfig() ziac.gcp.ProviderConfig {
    return .{ .project_id = "ziac-cloud-prod", .primary_region = "europe-west1" };
}

fn stringField(input: ziac.value.Value, name: []const u8) []const u8 {
    for (input.object) |field| if (std.mem.eql(u8, field.name, name)) return switch (field.value) {
        .string => |text| text,
        else => unreachable,
    };
    unreachable;
}
