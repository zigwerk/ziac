const std = @import("std");
const ziac = @import("ziac");

test "GCP provider catalog is valid and covers every managed live type" {
    try ziac.gcp.coverage.validate();

    var managed_count: usize = 0;
    for (ziac.gcp.coverage.resources) |entry| {
        if (entry.stage != .managed and entry.stage != .qualified) continue;
        managed_count += 1;
        const node = ziac.ResourceNode{
            .id = entry.type_name,
            .provider = .gcp,
            .type_name = entry.type_name,
            .logical_id = "coverage-check",
        };
        try std.testing.expect(ziac.gcp.live_provider.supports(node));
    }

    try std.testing.expectEqual(@as(usize, 34), managed_count);
}

test "GCP provider catalog exposes current and next-tranche coverage honestly" {
    const cloud_run = ziac.gcp.coverage.find("gcp.run.Service") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(ziac.gcp.coverage.Stage.managed, cloud_run.stage);
    try std.testing.expect(cloud_run.capabilities.create);
    try std.testing.expect(cloud_run.capabilities.import_resource);

    const bucket = ziac.gcp.coverage.find("gcp.storage.Bucket") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(ziac.gcp.coverage.Stage.managed, bucket.stage);
    try std.testing.expectEqualStrings("M57", bucket.milestone);
    try std.testing.expect(bucket.capabilities.create);

    const topic = ziac.gcp.coverage.find("gcp.pubsub.Topic") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(ziac.gcp.coverage.Stage.planned, topic.stage);
    try std.testing.expectEqualStrings("M58", topic.milestone);

    try std.testing.expect(ziac.gcp.coverage.find("gcp.not.a.Resource") == null);
}
