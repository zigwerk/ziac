const std = @import("std");
const ziac = @import("ziac");

const regions = [_][]const u8{ "europe-west1", "us-central1" };
const provider = ziac.gcp.config.ProviderConfig{
    .project_id = "ziac-dev",
    .primary_region = "europe-west1",
    .service_regions = &regions,
    .network_tier = .premium,
};

test "managed certificate and HTTP redirect resources build stable declarations" {
    var certificate = try ziac.gcp.compute.ManagedSslCertificate.build(std.testing.allocator, provider, .{
        .name = "api-cert",
        .domains = &.{ "api.example.com", "*.edge.example.com" },
    });
    defer certificate.deinit(std.testing.allocator);
    var redirect = try ziac.gcp.compute.HttpRedirectUrlMap.build(std.testing.allocator, provider, .{
        .name = "api-http-redirect",
        .strip_query = true,
    });
    defer redirect.deinit(std.testing.allocator);
    var proxy = try ziac.gcp.compute.TargetHttpProxy.build(std.testing.allocator, provider, .{
        .name = "api-http",
        .url_map = "projects/ziac-dev/global/urlMaps/api-http-redirect",
    });
    defer proxy.deinit(std.testing.allocator);
    var forwarding = try ziac.gcp.compute.GlobalForwardingRule.build(std.testing.allocator, provider, .{
        .name = "api-http",
        .address = "projects/ziac-dev/global/addresses/api-ip",
        .target = "projects/ziac-dev/global/targetHttpProxies/api-http",
        .port = 80,
    });
    defer forwarding.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.compute.ManagedSslCertificate.api-cert", certificate.node.id);
    try std.testing.expectEqualStrings("status", certificate.status.resource_ref.field);
    try std.testing.expectEqualStrings("domains_ready", certificate.domains_ready.resource_ref.field);
    try std.testing.expectEqualStrings("gcp.compute.HttpRedirectUrlMap.api-http-redirect", redirect.node.id);
    try std.testing.expectEqualStrings("gcp.compute.TargetHttpProxy.api-http", proxy.node.id);

    const certificate_json = try certificate.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(certificate_json);
    try std.testing.expectEqualStrings(
        "{\"domains\":[\"api.example.com\",\"*.edge.example.com\"],\"name\":\"api-cert\",\"project_id\":\"ziac-dev\"}",
        certificate_json,
    );
    const redirect_json = try redirect.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(redirect_json);
    try std.testing.expect(std.mem.indexOf(u8, redirect_json, "\"https_redirect\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, redirect_json, "\"redirect_response_code\":\"MOVED_PERMANENTLY_DEFAULT\"") != null);
}

test "managed certificate rejects invalid and duplicate domains" {
    try std.testing.expectError(
        error.InvalidDomain,
        ziac.gcp.compute.ManagedSslCertificate.build(std.testing.allocator, provider, .{
            .name = "api-cert",
            .domains = &.{"API.example.com"},
        }),
    );
    try std.testing.expectError(
        error.DuplicateDomain,
        ziac.gcp.compute.ManagedSslCertificate.build(std.testing.allocator, provider, .{
            .name = "api-cert",
            .domains = &.{ "api.example.com", "api.example.com" },
        }),
    );
}

test "Cloud DNS record set declaration retains existing zone identity" {
    var record = try ziac.gcp.dns.RecordSet.build(std.testing.allocator, provider, .{
        .zone = "example-com",
        .name = "api.example.com.",
        .record_type = .a,
        .ttl = 60,
        .rrdatas = &.{"203.0.113.10"},
    });
    defer record.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.dns.RecordSet.example-com.A.api.example.com.", record.node.id);
    try std.testing.expectEqualStrings("fqdn", record.fqdn.resource_ref.field);
    try std.testing.expectEqualStrings("record_type", record.record_type.resource_ref.field);
    const json = try record.node.inputs.canonicalJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings(
        "{\"name\":\"api.example.com.\",\"project_id\":\"ziac-dev\",\"rrdatas\":[\"203.0.113.10\"],\"ttl\":60,\"type\":\"A\",\"zone\":\"example-com\"}",
        json,
    );
}

test "Cloud DNS record set validates FQDN and record cardinality" {
    try std.testing.expectError(
        error.InvalidRecordName,
        ziac.gcp.dns.RecordSet.build(std.testing.allocator, provider, .{
            .zone = "example-com",
            .name = "api.example.com",
            .record_type = .a,
            .rrdatas = &.{"203.0.113.10"},
        }),
    );
    try std.testing.expectError(
        error.InvalidRecordName,
        ziac.gcp.dns.RecordSet.build(std.testing.allocator, provider, .{
            .zone = "example-com",
            .name = "api..example.com.",
            .record_type = .a,
            .rrdatas = &.{"203.0.113.10"},
        }),
    );
    try std.testing.expectError(
        error.InvalidRecordData,
        ziac.gcp.dns.RecordSet.build(std.testing.allocator, provider, .{
            .zone = "example-com",
            .name = "api.example.com.",
            .record_type = .cname,
            .rrdatas = &.{ "one.example.com.", "two.example.com." },
        }),
    );
}
