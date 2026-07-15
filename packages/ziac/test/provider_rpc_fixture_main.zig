const std = @import("std");
const ziac = @import("ziac");

pub fn main(init: std.process.Init) !void {
    var fake = ziac.provider.FakeProvider.init(init.gpa);
    defer fake.deinit();
    var session = ziac.provider_rpc.ServerSession.init(init.gpa, .{
        .package_name = "ziac/provider-fixture",
        .package_version = "1.2.3",
        .provider = .gcp,
        .resource_type_prefixes = &.{"gcp.fixture."},
        .capabilities = .all,
        .max_inflight = 1,
    }, fake.provider());
    try ziac.provider_rpc.serveStdio(init.io, init.gpa, &session);
}
