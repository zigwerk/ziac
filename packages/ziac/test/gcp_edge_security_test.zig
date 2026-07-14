const std = @import("std");
const ziac = @import("ziac");

const edge = ziac.gcp.edge_security;
const provider = ziac.gcp.ProviderConfig{ .project_id = "ziac-dev", .primary_region = "europe-west1" };

test "edge security declarations cover CDN Armor TLS and Certificate Manager" {
    var armor = try edge.SecurityPolicy.build(std.testing.allocator, provider, .{
        .name = "cdn-edge",
        .policy_type = .edge,
        .rules = &.{
            .{ .priority = 1000, .match = .{ .src_ip_ranges = &.{"203.0.113.0/24"} }, .action = .{ .deny = .forbidden } },
            .{ .priority = 2_147_483_647, .match = .{ .src_ip_ranges = &.{"*"} }, .action = .allow },
        },
    });
    defer armor.deinit(std.testing.allocator);
    var backend = try edge.BackendBucket.build(std.testing.allocator, provider, .{
        .name = "web-assets",
        .bucket = ziac.PublicOutput([]const u8).known("ziac-web-assets"),
        .edge_security_policy = edge.SecurityPolicy.Outputs.SelfLink.fromResource(armor.node.id),
        .cache_mode = .use_origin_headers,
        .default_ttl_seconds = 3600,
        .max_ttl_seconds = 86_400,
        .serve_while_stale_seconds = 600,
        .compression = .automatic,
    });
    defer backend.deinit(std.testing.allocator);
    var tls = try edge.SslPolicy.build(std.testing.allocator, provider, .{
        .name = "modern-tls",
        .minimum_tls = .tls_1_2,
        .profile = .modern,
    });
    defer tls.deinit(std.testing.allocator);
    var auth = try edge.DnsAuthorization.build(std.testing.allocator, provider, .{
        .name = "api-example-com",
        .domain = "api.example.com",
    });
    defer auth.deinit(std.testing.allocator);
    var certificate = try edge.Certificate.build(std.testing.allocator, provider, .{
        .name = "api",
        .domains = &.{"api.example.com"},
        .dns_authorizations = &.{edge.DnsAuthorization.Outputs.Name.fromResource(auth.node.id)},
    });
    defer certificate.deinit(std.testing.allocator);
    var map = try edge.CertificateMap.build(std.testing.allocator, provider, .{ .name = "public" });
    defer map.deinit(std.testing.allocator);
    var entry = try edge.CertificateMapEntry.build(std.testing.allocator, provider, .{
        .name = "api",
        .map = edge.CertificateMap.Outputs.Name.fromResource(map.node.id),
        .matcher = .{ .hostname = "api.example.com" },
        .certificates = &.{edge.Certificate.Outputs.Name.fromResource(certificate.node.id)},
    });
    defer entry.deinit(std.testing.allocator);
    var proxy = try edge.CertificateMapTargetHttpsProxy.build(std.testing.allocator, provider, .{
        .name = "public-https",
        .url_map = ziac.PublicOutput([]const u8).known("projects/ziac-dev/global/urlMaps/public"),
        .certificate_map = edge.CertificateMap.Outputs.Name.fromResource(map.node.id),
        .ssl_policy = edge.SslPolicy.Outputs.SelfLink.fromResource(tls.node.id),
        .quic = .enable,
    });
    defer proxy.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.compute.SecurityPolicy", armor.node.type_name);
    try std.testing.expectEqualStrings("gcp.compute.BackendBucket", backend.node.type_name);
    try std.testing.expectEqualStrings("gcp.compute.SslPolicy", tls.node.type_name);
    try std.testing.expectEqualStrings("gcp.certificatemanager.DnsAuthorization", auth.node.type_name);
    try std.testing.expectEqualStrings("gcp.certificatemanager.Certificate", certificate.node.type_name);
    try std.testing.expectEqualStrings("gcp.certificatemanager.CertificateMap", map.node.type_name);
    try std.testing.expectEqualStrings("gcp.certificatemanager.CertificateMapEntry", entry.node.type_name);
    try std.testing.expectEqualStrings("gcp.compute.CertificateMapTargetHttpsProxy", proxy.node.type_name);
}

test "edge security declarations reject unsafe or contradictory policy" {
    try std.testing.expectError(error.InvalidCachePolicy, edge.BackendBucket.build(std.testing.allocator, provider, .{
        .name = "assets",
        .bucket = ziac.PublicOutput([]const u8).known("assets"),
        .default_ttl_seconds = 3600,
        .max_ttl_seconds = 60,
    }));
    try std.testing.expectError(error.InvalidSecurityPolicy, edge.SecurityPolicy.build(std.testing.allocator, provider, .{
        .name = "missing-default",
        .policy_type = .backend,
        .rules = &.{.{ .priority = 100, .match = .{ .src_ip_ranges = &.{"10.0.0.0/8"} }, .action = .allow }},
    }));
    try std.testing.expectError(error.InvalidSecurityPolicy, edge.SecurityPolicy.build(std.testing.allocator, provider, .{
        .name = "bad-throttle",
        .policy_type = .backend,
        .rules = &.{.{
            .priority = 2_147_483_647,
            .match = .{ .src_ip_ranges = &.{"*"} },
            .action = .{ .throttle = .{ .count = 0, .interval_seconds = 60 } },
        }},
    }));
    try std.testing.expectError(error.InvalidTlsPolicy, edge.SslPolicy.build(std.testing.allocator, provider, .{
        .name = "bad-tls",
        .profile = .modern,
        .custom_features = &.{"TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256"},
    }));
    try std.testing.expectError(error.InvalidDomain, edge.DnsAuthorization.build(std.testing.allocator, provider, .{
        .name = "bad-domain",
        .domain = "https://example.com",
    }));
    try std.testing.expectError(error.InvalidCertificate, edge.Certificate.build(std.testing.allocator, provider, .{
        .name = "missing-auth",
        .domains = &.{"api.example.com"},
        .dns_authorizations = &.{},
    }));
    try std.testing.expectError(error.InvalidMapEntry, edge.CertificateMapEntry.build(std.testing.allocator, provider, .{
        .name = "empty",
        .map = ziac.PublicOutput([]const u8).known("projects/ziac-dev/locations/global/certificateMaps/public"),
        .matcher = .primary,
        .certificates = &.{},
    }));
}
