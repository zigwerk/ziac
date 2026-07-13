const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

test "BigQuery billing results preserve decimal micros and pagination" {
    var page = try ziac.gcp.billing.parseBigQueryPageAlloc(std.testing.allocator,
        \\{"jobComplete":true,"jobReference":{"projectId":"billing-host","jobId":"job-42","location":"EU"},"pageToken":"page-2","schema":{"fields":[{"name":"resource_id","type":"STRING"},{"name":"cost_micros","type":"INTEGER"},{"name":"credit_micros","type":"INTEGER"}]},"rows":[{"f":[{"v":"//run.googleapis.com/projects/acme/locations/europe-west1/services/api"},{"v":"12000001"},{"v":"-2000000"}]}]}
    );
    defer page.deinit();
    try std.testing.expect(page.complete);
    try std.testing.expectEqualStrings("job-42", page.job_id);
    try std.testing.expectEqualStrings("page-2", page.next_page_token.?);
    try std.testing.expectEqual(@as(i64, 12_000_001), page.rows[0].cost_micros);
    try std.testing.expectEqual(@as(i64, -2_000_000), page.rows[0].credit_micros);
}

test "incomplete BigQuery jobs can be polled before a schema exists" {
    var page = try ziac.gcp.billing.parseBigQueryPageAlloc(std.testing.allocator,
        \\{"jobComplete":false,"jobReference":{"projectId":"billing-host","jobId":"job-pending","location":"EU"}}
    );
    defer page.deinit();
    try std.testing.expect(!page.complete);
    try std.testing.expectEqualStrings("job-pending", page.job_id);
    try std.testing.expectEqual(@as(usize, 0), page.rows.len);
}

test "detailed billing query emits the parser contract in integer micros" {
    const query = try ziac.cost.detailedBillingQueryAlloc(
        std.testing.allocator,
        "billing_export.gcp_billing_export_resource_v1_123",
        "ziac-cloud-prod",
    );
    defer std.testing.allocator.free(query);
    try std.testing.expect(std.mem.indexOf(u8, query, "resource_id") != null);
    try std.testing.expect(std.mem.indexOf(u8, query, "cost_micros") != null);
    try std.testing.expect(std.mem.indexOf(u8, query, "credit_micros") != null);
    try std.testing.expect(std.mem.indexOf(u8, query, "unattributed.googleapis.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, query, "actual_billed") == null);
}

test "billing adapter uses authenticated Cloud Billing and BigQuery endpoints" {
    var transport = BillingTransport{};
    var source = FixedTokenSource{};
    var cache = ziac.gcp.auth.TokenCache.init(source.tokenSource(), 300);
    defer cache.deinit(std.testing.allocator);
    var client = ziac.gcp.client.Client.init(transport.client(), &cache, .{
        .cloud_billing = "https://billing.example.test",
        .bigquery = "https://bigquery.example.test",
    });
    var context = ziac.provider.OperationContext.init(std.testing.allocator);
    var adapter = ziac.gcp.billing.Adapter.init(&client, &context);
    var catalog = try adapter.listSkusPageAlloc("6F81-5844-456A", "USD", null);
    defer catalog.deinit();
    try std.testing.expect(std.mem.startsWith(u8, transport.urls[0], "https://billing.example.test/v1/services/"));
    var page = try adapter.queryAlloc("billing-host", "SELECT 'resource_id', 0, 0");
    defer page.deinit();
    try std.testing.expectEqualStrings("https://bigquery.example.test/bigquery/v2/projects/billing-host/queries", transport.urls[1]);
    try std.testing.expectEqualStrings("Bearer billing-token", transport.authorization.?);
}

const FixedTokenSource = struct {
    fn tokenSource(self: *FixedTokenSource) ziac.gcp.auth.TokenSource {
        return .{ .ptr = self, .fetchFn = fetch };
    }
    fn fetch(_: *anyopaque, allocator: std.mem.Allocator, now: u64) ziac.gcp.auth.AuthError!ziac.gcp.auth.AccessToken {
        return ziac.gcp.auth.AccessToken.initOwned(allocator, .{ .access_token = "billing-token", .token_type = "Bearer", .expires_at_seconds = now + 3600 });
    }
};

const BillingTransport = struct {
    urls: [4][]const u8 = undefined,
    url_count: usize = 0,
    url_storage: [4][1024]u8 = undefined,
    authorization_storage: [128]u8 = undefined,
    authorization: ?[]const u8 = null,
    fn client(self: *BillingTransport) zstd.Http.Client {
        return .{ .ptr = self, .sendFn = send };
    }
    fn send(raw: *anyopaque, allocator: std.mem.Allocator, request: zstd.Http.Request, _: zstd.Http.SendOptions) zstd.Http.ClientError!zstd.Http.Response {
        const self: *BillingTransport = @ptrCast(@alignCast(raw));
        const index = self.url_count;
        @memcpy(self.url_storage[index][0..request.url.len], request.url);
        self.urls[index] = self.url_storage[index][0..request.url.len];
        self.url_count += 1;
        for (request.headers) |header| if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
            @memcpy(self.authorization_storage[0..header.value.len], header.value);
            self.authorization = self.authorization_storage[0..header.value.len];
        };
        const body = if (std.mem.indexOf(u8, request.url, "cloudbilling") != null or std.mem.indexOf(u8, request.url, "billing.example") != null)
            "{\"skus\":[]}"
        else
            "{\"jobComplete\":true,\"jobReference\":{\"projectId\":\"billing-host\",\"jobId\":\"job-1\",\"location\":\"EU\"},\"schema\":{\"fields\":[{\"name\":\"resource_id\"},{\"name\":\"cost_micros\"},{\"name\":\"credit_micros\"}]},\"rows\":[]}";
        return zstd.Http.cloneResponseAlloc(allocator, .{ .status = 200, .body = body });
    }
};

test "billing attribution exposes coverage and the exact unattributed remainder" {
    const rows = [_]ziac.cost.BillingRow{
        .{ .resource_id = "//run.googleapis.com/projects/acme/locations/europe-west1/services/api", .cost_micros = 12_000_000, .credit_micros = -2_000_000 },
        .{ .resource_id = "//storage.googleapis.com/acme-legacy", .cost_micros = 4_000_000, .credit_micros = 0 },
    };
    const resources = [_]ziac.cost.AttributionTarget{.{
        .ziac_resource_id = "gcp.run.Service.api",
        .global_name = "//run.googleapis.com/projects/acme/locations/europe-west1/services/api",
    }};
    var result = try ziac.cost.attributeActualAlloc(std.testing.allocator, &rows, &resources, "USD", 42);
    defer result.deinit();
    try std.testing.expectEqual(@as(i64, 14_000_000), result.billed_total_micros);
    try std.testing.expectEqual(@as(i64, 10_000_000), result.attributed_total_micros);
    try std.testing.expectEqual(@as(i64, 4_000_000), result.unattributed_total_micros);
    try std.testing.expectEqual(@as(u16, 7142), result.coverage_basis_points);
    try std.testing.expect(result.costs[0].provenance.is_billing_export);
}

test "catalog parsing preserves all pricing tiers currency and effective time" {
    var catalog = try ziac.cost.parseCatalogPageAlloc(std.testing.allocator,
        \\{"skus":[{"skuId":"run-requests","serviceRegions":["global"],"pricingInfo":[{"effectiveTime":"2026-07-01T00:00:00Z","pricingExpression":{"usageUnit":"request","baseUnitConversionFactor":1000000,"tieredRates":[{"startUsageAmount":0,"unitPrice":{"currencyCode":"USD","units":"0","nanos":0}},{"startUsageAmount":2000000,"unitPrice":{"currencyCode":"USD","units":"0","nanos":400000}}]}}]}]}
    );
    defer catalog.deinit();
    try std.testing.expectEqual(@as(usize, 1), catalog.prices.len);
    try std.testing.expectEqualStrings("USD", catalog.prices[0].currency);
    try std.testing.expectEqual(@as(usize, 2), catalog.prices[0].tiers.len);
    try std.testing.expectEqual(@as(u64, 2_000_000), catalog.prices[0].tiers[1].start_quantity);
    try std.testing.expectEqual(@as(i64, 400), catalog.prices[0].tiers[1].unit_price_micros);
}
