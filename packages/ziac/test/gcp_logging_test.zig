const std = @import("std");
const ziac = @import("ziac");

const logging = ziac.gcp.logging;

test "log buckets preserve lifecycle and output-backed CMEK intent" {
    var bucket = try logging.Bucket.build(std.testing.allocator, config(), .{
        .name = "application-logs",
        .location = "europe-west1",
        .description = "Application logs retained for incident response",
        .retention_days = 90,
        .analytics_enabled = true,
        .kms_key_name = referenced("gcp.kms.CryptoKey.application-logs", "name"),
        .restricted_fields = &.{"jsonPayload.customer_id"},
        .indexes = &.{.{ .field_path = "jsonPayload.request_id", .type = .string }},
    });
    defer bucket.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.logging.Bucket", bucket.node.type_name);
    try std.testing.expectEqual(@as(i64, 90), input(bucket.node.inputs, "retention_days").integer);
    try std.testing.expect(input(bucket.node.inputs, "kms_key_name") == .output_ref);
    try std.testing.expect(bucket.node.lifecycle.protect);
    try std.testing.expectError(error.InvalidRetention, logging.Bucket.build(std.testing.allocator, config(), .{
        .name = "too-long",
        .location = "global",
        .retention_days = 3651,
    }));
}

test "log views require an output-backed bucket and conjunction filter" {
    var bucket = try logging.Bucket.build(std.testing.allocator, config(), .{ .name = "application-logs", .location = "global" });
    defer bucket.deinit(std.testing.allocator);
    var view = try logging.View.build(std.testing.allocator, config(), .{
        .name = "production-errors",
        .location = "global",
        .bucket_name = "application-logs",
        .bucket = bucket.name,
        .description = "Production errors",
        .filter = "severity>=ERROR AND resource.type=\"cloud_run_revision\"",
    });
    defer view.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.logging.View", view.node.type_name);
    try std.testing.expect(input(view.node.inputs, "bucket") == .output_ref);
    try std.testing.expectError(error.InvalidFilter, logging.View.build(std.testing.allocator, config(), .{
        .name = "invalid",
        .location = "global",
        .bucket_name = "application-logs",
        .bucket = bucket.name,
        .filter = "severity=ERROR OR severity=CRITICAL",
    }));
}

test "log sinks expose generated writer identity and typed destinations" {
    var bucket = try logging.Bucket.build(std.testing.allocator, config(), .{ .name = "security-archive", .location = "global" });
    defer bucket.deinit(std.testing.allocator);
    var sink = try logging.Sink.build(std.testing.allocator, config(), .{
        .name = "security-archive",
        .destination = .{ .logging_bucket = bucket.name },
        .filter = "logName:\"cloudaudit.googleapis.com\"",
        .unique_writer_identity = true,
        .exclusions = &.{.{
            .name = "health-checks",
            .filter = "httpRequest.userAgent=\"GoogleHC/1.0\"",
            .description = "Discard load-balancer probes",
        }},
    });
    defer sink.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.logging.Sink", sink.node.type_name);
    try std.testing.expect(input(sink.node.inputs, "destination") == .object);
    try std.testing.expectEqualStrings("writer_identity", logging.Sink.Outputs.WriterIdentity.field_name);
}

test "project exclusions are explicit cost and volume policy" {
    var exclusion = try logging.Exclusion.build(std.testing.allocator, config(), .{
        .name = "sample-debug",
        .description = "Exclude low-value debug traffic",
        .filter = "severity=DEBUG AND sample(insertId, 0.9)",
    });
    defer exclusion.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.logging.Exclusion", exclusion.node.type_name);
    try std.testing.expectEqualStrings("sample-debug", input(exclusion.node.inputs, "name").string);
    try std.testing.expectError(error.InvalidFilter, logging.Exclusion.build(std.testing.allocator, config(), .{
        .name = "empty",
        .filter = "",
    }));
}

test "distribution log metrics validate immutable schema and boundaries" {
    var metric = try logging.Metric.build(std.testing.allocator, config(), .{
        .name = "request-latency",
        .description = "Application request latency",
        .filter = "resource.type=\"cloud_run_revision\" jsonPayload.latency_ms:*",
        .mode = .{ .distribution = .{
            .value_extractor = "EXTRACT(jsonPayload.latency_ms)",
            .buckets = .{ .explicit_micros = &.{ 100_000, 250_000, 500_000, 1_000_000 } },
        } },
        .labels = &.{.{ .key = "region", .description = "Serving region", .value_type = .string }},
        .label_extractors = &.{.{ .key = "region", .extractor = "EXTRACT(resource.labels.location)" }},
    });
    defer metric.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("gcp.logging.Metric", metric.node.type_name);
    try std.testing.expectEqualStrings("DISTRIBUTION", input(metric.node.inputs, "value_type").string);
    try std.testing.expectEqualStrings("DELTA", input(metric.node.inputs, "metric_kind").string);

    try std.testing.expectError(error.InvalidHistogram, logging.Metric.build(std.testing.allocator, config(), .{
        .name = "invalid-buckets",
        .filter = "severity>=ERROR",
        .mode = .{ .distribution = .{
            .value_extractor = "EXTRACT(jsonPayload.latency_ms)",
            .buckets = .{ .explicit_micros = &.{ 500_000, 100_000 } },
        } },
    }));
    try std.testing.expectError(error.DuplicateLabel, logging.Metric.build(std.testing.allocator, config(), .{
        .name = "duplicate-label",
        .filter = "severity>=ERROR",
        .labels = &.{
            .{ .key = "region", .value_type = .string },
            .{ .key = "region", .value_type = .string },
        },
    }));
}

fn config() ziac.gcp.ProviderConfig {
    return .{ .project_id = "ziac-dev", .primary_region = "europe-west1" };
}

fn known(text: []const u8) ziac.PublicOutput([]const u8) {
    return .known(text);
}

fn referenced(resource_id: []const u8, field: []const u8) ziac.PublicOutput([]const u8) {
    return .fromResource(resource_id, field);
}

fn input(inputs: ziac.value.Value, name: []const u8) ziac.value.Value {
    for (inputs.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    unreachable;
}
