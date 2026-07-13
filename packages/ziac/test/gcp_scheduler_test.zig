const std = @import("std");
const ziac = @import("ziac");

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
