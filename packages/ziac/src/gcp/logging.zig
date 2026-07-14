const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    DuplicateLabel,
    InvalidFilter,
    InvalidHistogram,
    InvalidLabel,
    InvalidLocation,
    InvalidName,
    InvalidRetention,
    InvalidValue,
    OutputNotKnown,
};

pub const IndexType = enum {
    string,
    integer,

    pub fn apiName(self: IndexType) []const u8 {
        return if (self == .integer) "INTEGER" else "STRING";
    }
};

pub const IndexConfig = struct {
    field_path: []const u8,
    type: IndexType = .string,
};

pub const BucketArgs = struct {
    name: []const u8,
    location: []const u8,
    description: []const u8 = "",
    retention_days: u16 = 30,
    analytics_enabled: bool = false,
    locked: bool = false,
    kms_key_name: ?output.Output([]const u8, .public) = null,
    restricted_fields: []const []const u8 = &.{},
    indexes: []const IndexConfig = &.{},
    protect: bool = true,
    retain_on_delete: bool = false,
};

pub const Bucket = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const LifecycleState = output.Descriptor("lifecycle_state", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    lifecycle_state: Outputs.LifecycleState.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: BucketArgs) BuildError!Bucket {
        try provider.validate();
        try validateIdentifier(args.name, 100);
        try validateLocation(args.location);
        if (args.description.len > 8_000) return error.InvalidValue;
        if (args.retention_days == 0 or args.retention_days > 3650) return error.InvalidRetention;
        var restricted_fields = try stringsValueOwned(allocator, args.restricted_fields);
        defer restricted_fields.deinit(allocator);
        var indexes = try indexesValueOwned(allocator, args.indexes);
        defer indexes.deinit(allocator);
        const kms_key_name = if (args.kms_key_name) |candidate| try publicOutputValue(candidate) else value.Value{ .string = "" };
        const fields = [_]value.Field{
            .{ .name = "analytics_enabled", .value = .{ .boolean = args.analytics_enabled } },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "indexes", .value = indexes },
            .{ .name = "kms_key_name", .value = kms_key_name },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "locked", .value = .{ .boolean = args.locked } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "restricted_fields", .value = restricted_fields },
            .{ .name = "retention_days", .value = .{ .integer = args.retention_days } },
        };
        const node = try nodeOwned(allocator, "gcp.logging.Bucket", args.name, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
        });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .lifecycle_state = Outputs.LifecycleState.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Bucket, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const ViewArgs = struct {
    name: []const u8,
    location: []const u8,
    bucket_name: []const u8,
    bucket: output.Output([]const u8, .public),
    description: []const u8 = "",
    filter: []const u8,
    protect: bool = false,
};

pub const View = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ViewArgs) BuildError!View {
        try provider.validate();
        try validateIdentifier(args.name, 100);
        try validateIdentifier(args.bucket_name, 100);
        try validateLocation(args.location);
        try validateFilter(args.filter, true);
        if (args.description.len > 8_000) return error.InvalidValue;
        const fields = [_]value.Field{
            .{ .name = "bucket", .value = try publicOutputValue(args.bucket) },
            .{ .name = "bucket_name", .value = .{ .string = args.bucket_name } },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "filter", .value = .{ .string = args.filter } },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        };
        const node = try nodeOwned(allocator, "gcp.logging.View", args.name, &fields, .{ .protect = args.protect });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const SinkDestination = union(enum) {
    logging_bucket: output.Output([]const u8, .public),
    storage_bucket: output.Output([]const u8, .public),
    bigquery_dataset: output.Output([]const u8, .public),
    pubsub_topic: output.Output([]const u8, .public),
};

pub const SinkExclusion = struct {
    name: []const u8,
    description: []const u8 = "",
    filter: []const u8,
    disabled: bool = false,
};

pub const SinkArgs = struct {
    name: []const u8,
    destination: SinkDestination,
    filter: []const u8,
    description: []const u8 = "",
    disabled: bool = false,
    unique_writer_identity: bool = true,
    partitioned_tables: bool = false,
    exclusions: []const SinkExclusion = &.{},
    protect: bool = false,
};

pub const Sink = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const WriterIdentity = output.Descriptor("writer_identity", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    writer_identity: Outputs.WriterIdentity.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: SinkArgs) BuildError!Sink {
        try provider.validate();
        try validateIdentifier(args.name, 100);
        try validateFilter(args.filter, false);
        if (args.description.len > 8_000) return error.InvalidValue;
        var destination = try sinkDestinationValueOwned(allocator, args.destination);
        defer destination.deinit(allocator);
        var exclusions = try sinkExclusionsValueOwned(allocator, args.exclusions);
        defer exclusions.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "destination", .value = destination },
            .{ .name = "disabled", .value = .{ .boolean = args.disabled } },
            .{ .name = "exclusions", .value = exclusions },
            .{ .name = "filter", .value = .{ .string = args.filter } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "partitioned_tables", .value = .{ .boolean = args.partitioned_tables } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "unique_writer_identity", .value = .{ .boolean = args.unique_writer_identity } },
        };
        const node = try nodeOwned(allocator, "gcp.logging.Sink", args.name, &fields, .{ .protect = args.protect });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .writer_identity = Outputs.WriterIdentity.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Sink, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const ExclusionArgs = struct {
    name: []const u8,
    filter: []const u8,
    description: []const u8 = "",
    disabled: bool = false,
    protect: bool = false,
};

pub const Exclusion = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ExclusionArgs) BuildError!Exclusion {
        try provider.validate();
        try validateIdentifier(args.name, 100);
        try validateFilter(args.filter, false);
        if (args.description.len > 8_000) return error.InvalidValue;
        const fields = [_]value.Field{
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "disabled", .value = .{ .boolean = args.disabled } },
            .{ .name = "filter", .value = .{ .string = args.filter } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
        };
        const node = try nodeOwned(allocator, "gcp.logging.Exclusion", args.name, &fields, .{ .protect = args.protect });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
    }

    pub fn deinit(self: *Exclusion, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const MetricLabelType = enum {
    boolean,
    integer,
    string,

    pub fn apiName(self: MetricLabelType) []const u8 {
        return switch (self) {
            .boolean => "BOOL",
            .integer => "INT64",
            .string => "STRING",
        };
    }
};

pub const MetricLabel = struct {
    key: []const u8,
    description: []const u8 = "",
    value_type: MetricLabelType = .string,
};

pub const LabelExtractor = struct {
    key: []const u8,
    extractor: []const u8,
};

pub const HistogramBuckets = union(enum) {
    linear: struct { count: u32, width_micros: i64, offset_micros: i64 = 0 },
    exponential: struct { count: u32, growth_factor_micros: i64, scale_micros: i64 },
    explicit_micros: []const i64,
};

pub const DistributionMetric = struct {
    value_extractor: []const u8,
    buckets: HistogramBuckets,
};

pub const MetricMode = union(enum) {
    counter,
    distribution: DistributionMetric,
};

pub const MetricArgs = struct {
    name: []const u8,
    filter: []const u8,
    description: []const u8 = "",
    disabled: bool = false,
    mode: MetricMode = .counter,
    labels: []const MetricLabel = &.{},
    label_extractors: []const LabelExtractor = &.{},
    bucket_name: ?output.Output([]const u8, .public) = null,
    protect: bool = false,
};

pub const Metric = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: MetricArgs) BuildError!Metric {
        try provider.validate();
        try validateIdentifier(args.name, 100);
        try validateFilter(args.filter, false);
        if (args.description.len > 8_000 or args.labels.len > 10) return error.InvalidLabel;
        try validateMetricLabels(args.labels, args.label_extractors);
        var labels = try metricLabelsValueOwned(allocator, args.labels);
        defer labels.deinit(allocator);
        var extractors = try labelExtractorsValueOwned(allocator, args.label_extractors);
        defer extractors.deinit(allocator);
        var mode = try metricModeValueOwned(allocator, args.mode);
        defer mode.deinit(allocator);
        const bucket_name = if (args.bucket_name) |candidate| try publicOutputValue(candidate) else value.Value{ .string = "" };
        const fields = [_]value.Field{
            .{ .name = "bucket_name", .value = bucket_name },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "disabled", .value = .{ .boolean = args.disabled } },
            .{ .name = "filter", .value = .{ .string = args.filter } },
            .{ .name = "label_extractors", .value = extractors },
            .{ .name = "labels", .value = labels },
            .{ .name = "metric_kind", .value = .{ .string = "DELTA" } },
            .{ .name = "mode", .value = mode },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "value_type", .value = .{ .string = if (args.mode == .distribution) "DISTRIBUTION" else "INT64" } },
        };
        const node = try nodeOwned(allocator, "gcp.logging.Metric", args.name, &fields, .{ .protect = args.protect });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
    }

    pub fn deinit(self: *Metric, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn indexesValueOwned(allocator: std.mem.Allocator, indexes: []const IndexConfig) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, indexes.len);
    defer allocator.free(items);
    for (indexes, 0..) |index_config, index| {
        if (index_config.field_path.len == 0 or index_config.field_path.len > 800) return error.InvalidValue;
        const fields = [_]value.Field{
            .{ .name = "field_path", .value = .{ .string = index_config.field_path } },
            .{ .name = "type", .value = .{ .string = index_config.type.apiName() } },
        };
        items[index] = .{ .object = &fields };
    }
    return ownedValue(allocator, .{ .list = items });
}

fn sinkDestinationValueOwned(allocator: std.mem.Allocator, destination: SinkDestination) BuildError!value.Value {
    const kind: []const u8, const target = switch (destination) {
        .logging_bucket => |candidate| .{ "LOGGING_BUCKET", try publicOutputValue(candidate) },
        .storage_bucket => |candidate| .{ "STORAGE_BUCKET", try publicOutputValue(candidate) },
        .bigquery_dataset => |candidate| .{ "BIGQUERY_DATASET", try publicOutputValue(candidate) },
        .pubsub_topic => |candidate| .{ "PUBSUB_TOPIC", try publicOutputValue(candidate) },
    };
    const fields = [_]value.Field{
        .{ .name = "kind", .value = .{ .string = kind } },
        .{ .name = "target", .value = target },
    };
    return ownedValue(allocator, .{ .object = &fields });
}

fn sinkExclusionsValueOwned(allocator: std.mem.Allocator, exclusions: []const SinkExclusion) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, exclusions.len);
    defer allocator.free(items);
    for (exclusions, 0..) |exclusion, index| {
        try validateIdentifier(exclusion.name, 100);
        try validateFilter(exclusion.filter, false);
        const fields = [_]value.Field{
            .{ .name = "description", .value = .{ .string = exclusion.description } },
            .{ .name = "disabled", .value = .{ .boolean = exclusion.disabled } },
            .{ .name = "filter", .value = .{ .string = exclusion.filter } },
            .{ .name = "name", .value = .{ .string = exclusion.name } },
        };
        items[index] = .{ .object = &fields };
    }
    return ownedValue(allocator, .{ .list = items });
}

fn metricModeValueOwned(allocator: std.mem.Allocator, mode: MetricMode) BuildError!value.Value {
    return switch (mode) {
        .counter => ownedValue(allocator, .{ .object = &.{.{ .name = "kind", .value = .{ .string = "COUNTER" } }} }),
        .distribution => |distribution| blk: {
            if (distribution.value_extractor.len == 0) return error.InvalidValue;
            var buckets = try histogramValueOwned(allocator, distribution.buckets);
            defer buckets.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "buckets", .value = buckets },
                .{ .name = "kind", .value = .{ .string = "DISTRIBUTION" } },
                .{ .name = "value_extractor", .value = .{ .string = distribution.value_extractor } },
            };
            break :blk ownedValue(allocator, .{ .object = &fields });
        },
    };
}

fn histogramValueOwned(allocator: std.mem.Allocator, buckets: HistogramBuckets) BuildError!value.Value {
    return switch (buckets) {
        .linear => |linear| blk: {
            if (linear.count == 0 or linear.width_micros <= 0) return error.InvalidHistogram;
            const fields = [_]value.Field{
                .{ .name = "count", .value = .{ .integer = linear.count } },
                .{ .name = "kind", .value = .{ .string = "LINEAR" } },
                .{ .name = "offset_micros", .value = .{ .integer = linear.offset_micros } },
                .{ .name = "width_micros", .value = .{ .integer = linear.width_micros } },
            };
            break :blk ownedValue(allocator, .{ .object = &fields });
        },
        .exponential => |exponential| blk: {
            if (exponential.count == 0 or exponential.growth_factor_micros <= 1_000_000 or exponential.scale_micros <= 0) return error.InvalidHistogram;
            const fields = [_]value.Field{
                .{ .name = "count", .value = .{ .integer = exponential.count } },
                .{ .name = "growth_factor_micros", .value = .{ .integer = exponential.growth_factor_micros } },
                .{ .name = "kind", .value = .{ .string = "EXPONENTIAL" } },
                .{ .name = "scale_micros", .value = .{ .integer = exponential.scale_micros } },
            };
            break :blk ownedValue(allocator, .{ .object = &fields });
        },
        .explicit_micros => |bounds| blk: {
            if (bounds.len == 0) return error.InvalidHistogram;
            const items = try allocator.alloc(value.Value, bounds.len);
            defer allocator.free(items);
            var previous: i64 = -1;
            for (bounds, 0..) |bound, index| {
                if (bound <= previous) return error.InvalidHistogram;
                previous = bound;
                items[index] = .{ .integer = bound };
            }
            var values = try ownedValue(allocator, .{ .list = items });
            defer values.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "bounds_micros", .value = values },
                .{ .name = "kind", .value = .{ .string = "EXPLICIT" } },
            };
            break :blk ownedValue(allocator, .{ .object = &fields });
        },
    };
}

fn metricLabelsValueOwned(allocator: std.mem.Allocator, labels: []const MetricLabel) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, labels.len);
    defer allocator.free(items);
    for (labels, 0..) |label, index| {
        const fields = [_]value.Field{
            .{ .name = "description", .value = .{ .string = label.description } },
            .{ .name = "key", .value = .{ .string = label.key } },
            .{ .name = "value_type", .value = .{ .string = label.value_type.apiName() } },
        };
        items[index] = .{ .object = &fields };
    }
    return ownedValue(allocator, .{ .list = items });
}

fn labelExtractorsValueOwned(allocator: std.mem.Allocator, extractors: []const LabelExtractor) BuildError!value.Value {
    const fields = try allocator.alloc(value.Field, extractors.len);
    defer allocator.free(fields);
    for (extractors, 0..) |extractor, index| fields[index] = .{ .name = extractor.key, .value = .{ .string = extractor.extractor } };
    return ownedValue(allocator, .{ .object = fields }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateLabel,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn validateMetricLabels(labels: []const MetricLabel, extractors: []const LabelExtractor) BuildError!void {
    for (labels, 0..) |label, index| {
        try validateLabelKey(label.key);
        if (label.description.len > 1_024) return error.InvalidLabel;
        for (labels[0..index]) |previous| if (std.mem.eql(u8, previous.key, label.key)) return error.DuplicateLabel;
    }
    for (extractors, 0..) |extractor, index| {
        try validateLabelKey(extractor.key);
        if (extractor.extractor.len == 0 or extractor.extractor.len > 1_024) return error.InvalidLabel;
        var declared = false;
        for (labels) |label| if (std.mem.eql(u8, label.key, extractor.key)) {
            declared = true;
            break;
        };
        if (!declared) return error.InvalidLabel;
        for (extractors[0..index]) |previous| if (std.mem.eql(u8, previous.key, extractor.key)) return error.DuplicateLabel;
    }
}

fn stringsValueOwned(allocator: std.mem.Allocator, strings: []const []const u8) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, strings.len);
    defer allocator.free(items);
    for (strings, 0..) |text, index| {
        if (text.len == 0 or text.len > 800) return error.InvalidValue;
        items[index] = .{ .string = text };
    }
    return ownedValue(allocator, .{ .list = items });
}

fn nodeOwned(allocator: std.mem.Allocator, type_name: []const u8, logical_id: []const u8, fields: []const value.Field, lifecycle: resource.Lifecycle) BuildError!resource.ResourceNode {
    const id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_name, logical_id });
    defer allocator.free(id);
    return resource.ResourceNode.initOwned(allocator, .{
        .id = id,
        .provider = .gcp,
        .type_name = type_name,
        .logical_id = logical_id,
        .inputs = .{ .object = fields },
        .lifecycle = lifecycle,
    }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
    };
}

fn ownedValue(allocator: std.mem.Allocator, source: value.Value) (std.mem.Allocator.Error || error{DuplicateField})!value.Value {
    return value.Value.initOwned(allocator, source);
}

fn publicOutputValue(candidate: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (candidate) {
        .value => |text| .{ .string = text },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn validateIdentifier(name: []const u8, max: usize) BuildError!void {
    if (name.len == 0 or name.len > max or !std.ascii.isAlphanumeric(name[0]) or !std.ascii.isAlphanumeric(name[name.len - 1])) return error.InvalidName;
    for (name) |character| if (!std.ascii.isAlphanumeric(character) and character != '-' and character != '_' and character != '.') return error.InvalidName;
}

fn validateLocation(location: []const u8) BuildError!void {
    if (location.len == 0 or location.len > 63 or std.mem.indexOfAny(u8, location, "\x00\r\n /?#") != null) return error.InvalidLocation;
}

fn validateFilter(filter: []const u8, conjunction_only: bool) BuildError!void {
    if (filter.len == 0 or filter.len > 20_000 or std.mem.indexOfAny(u8, filter, "\x00\r") != null) return error.InvalidFilter;
    if (conjunction_only and containsWordIgnoreCase(filter, "or")) return error.InvalidFilter;
}

fn containsWordIgnoreCase(text: []const u8, word: []const u8) bool {
    if (word.len == 0 or text.len < word.len) return false;
    for (0..text.len - word.len + 1) |index| {
        if (!std.ascii.eqlIgnoreCase(text[index .. index + word.len], word)) continue;
        const before_word = index == 0 or std.ascii.isWhitespace(text[index - 1]);
        const after_word = index + word.len == text.len or std.ascii.isWhitespace(text[index + word.len]);
        if (before_word and after_word) return true;
    }
    return false;
}

fn validateLabelKey(key: []const u8) BuildError!void {
    if (key.len == 0 or key.len > 100 or (!std.ascii.isLower(key[0]) and key[0] != '_')) return error.InvalidLabel;
    for (key) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '_') return error.InvalidLabel;
}
