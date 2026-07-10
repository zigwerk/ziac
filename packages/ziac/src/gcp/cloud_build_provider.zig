const std = @import("std");
const zstd = @import("zigeffect_std");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;
const zig_image_type = "gcp.cloudbuild.ZigImage";
const max_recovery_pages = 10;

pub const FailureReporter = struct {
    ptr: *anyopaque,
    reportFn: *const fn (*anyopaque, []const u8, []const u8) void,

    pub fn report(self: FailureReporter, status_name: []const u8, diagnostic: []const u8) void {
        self.reportFn(self.ptr, status_name, diagnostic);
    }
};

pub const Handler = struct {
    client: *client_mod.Client,
    poll_policy: operation.Policy = .{},
    failure_reporter: ?FailureReporter = null,

    pub fn read(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_override: ?[]const u8,
    ) ProviderError!provider_mod.ReadResult {
        if (!supports(node)) return error.InvalidConfiguration;
        if (physical_override orelse context.physical_id) |physical_id| {
            return self.pollBuild(context, node, physical_id);
        }
        const discovered = try self.discoverBuildAlloc(context, node);
        defer if (discovered) |physical_id| context.allocator.free(physical_id);
        if (discovered == null) return .absent;
        return self.pollBuild(context, node, discovered.?);
    }

    pub fn diff(
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        observed: *const provider_mod.ResourceResult,
    ) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        if (!supports(node)) return error.InvalidConfiguration;
        const diff_kind: provider_mod.DiffKind = if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash)) .noop else .replace;
        const reasons: []const []const u8 = if (diff_kind == .noop) &.{} else &.{"Cloud Build inputs are immutable and content addressed"};
        return provider_mod.DiffResult.init(context.allocator, diff_kind, reasons);
    }

    pub fn create(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        if (!supports(node)) return error.InvalidConfiguration;
        const project_id = try requiredString(node.inputs, "project_id");
        const location = try requiredString(node.inputs, "location");
        const body = try buildBodyAlloc(context, node);
        defer context.allocator.free(body);
        const path = try std.fmt.allocPrint(
            context.allocator,
            "/v1/projects/{s}/locations/{s}/builds",
            .{ project_id, location },
        );
        defer context.allocator.free(path);
        var response = try self.request(context, .{ .api = .cloud_build, .method = "POST", .path = path, .body = body });
        defer response.deinit(context.allocator);
        return pendingResultFromOperation(context, node, response.body);
    }

    pub fn update(
        _: Handler,
        _: *provider_mod.OperationContext,
        _: resource.ResourceNode,
        _: []const u8,
    ) ProviderError!provider_mod.ResourceResult {
        return error.InvalidConfiguration;
    }

    pub fn delete(
        _: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!void {
        try context.checkActive();
        if (!supports(node)) return error.InvalidConfiguration;
        try validatePhysicalId(node, physical_id);
        // Build records and immutable image digests are retained for recovery and rollback.
    }

    fn pollBuild(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!provider_mod.ReadResult {
        try validatePhysicalId(node, physical_id);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical_id});
        defer context.allocator.free(path);
        var transient_failures: usize = 0;
        while (true) {
            try context.checkActive();
            var diagnostic = client_mod.Diagnostic.init(context.allocator);
            defer diagnostic.deinit();
            var response = self.client.requestJsonAlloc(context, .{
                .api = .cloud_build,
                .method = "GET",
                .path = path,
            }, &diagnostic) catch |err| {
                if (err == error.NotFound) return .absent;
                if ((err == error.TransientFailure or err == error.RateLimited) and
                    transient_failures < self.poll_policy.max_transient_failures)
                {
                    transient_failures += 1;
                    context.sleep(diagnostic.retry_after_millis orelse self.poll_policy.poll_interval_millis);
                    continue;
                }
                return err;
            };
            defer response.deinit(context.allocator);
            transient_failures = 0;
            var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
            defer parsed.deinit();
            const build = asObject(parsed.value) orelse return error.ProviderBug;
            try validateBuild(context, node, build);
            const remote_name = try requiredJsonString(build, "name");
            if (!std.mem.eql(u8, remote_name, physical_id)) return error.InvalidConfiguration;
            const status_name = try requiredJsonString(build, "status");
            if (std.mem.eql(u8, status_name, "SUCCESS")) {
                return .{ .present = try completedResult(context, node, build) };
            }
            if (isPendingStatus(status_name)) {
                context.sleep(self.poll_policy.poll_interval_millis);
                continue;
            }
            if (isFailureStatus(status_name)) {
                reportBuildFailure(self.failure_reporter, context.allocator, build, status_name);
                return switch (std.meta.stringToEnum(FailureStatus, status_name).?) {
                    .TIMEOUT, .EXPIRED => error.ProviderTimeout,
                    .CANCELLED => error.ProviderCancelled,
                    .FAILURE, .INTERNAL_ERROR => error.RemoteOperationFailed,
                };
            }
            return error.ProviderBug;
        }
    }

    fn discoverBuildAlloc(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!?[]const u8 {
        const project_id = try requiredString(node.inputs, "project_id");
        const location = try requiredString(node.inputs, "location");
        const tag = try buildTagAlloc(context.allocator, node);
        defer context.allocator.free(tag);
        const filter = try std.fmt.allocPrint(context.allocator, "tags='{s}'", .{tag});
        defer context.allocator.free(filter);
        const encoded_filter = try percentEncodeAlloc(context.allocator, filter);
        defer context.allocator.free(encoded_filter);
        var page_token: ?[]const u8 = null;
        defer if (page_token) |token| context.allocator.free(token);
        var match: ?[]const u8 = null;
        errdefer if (match) |physical_id| context.allocator.free(physical_id);

        for (0..max_recovery_pages) |_| {
            const path = if (page_token) |token| blk: {
                const encoded_token = try percentEncodeAlloc(context.allocator, token);
                defer context.allocator.free(encoded_token);
                break :blk try std.fmt.allocPrint(
                    context.allocator,
                    "/v1/projects/{s}/locations/{s}/builds?filter={s}&pageSize=20&pageToken={s}",
                    .{ project_id, location, encoded_filter, encoded_token },
                );
            } else try std.fmt.allocPrint(
                context.allocator,
                "/v1/projects/{s}/locations/{s}/builds?filter={s}&pageSize=20",
                .{ project_id, location, encoded_filter },
            );
            defer context.allocator.free(path);
            var response = try self.request(context, .{ .api = .cloud_build, .method = "GET", .path = path });
            defer response.deinit(context.allocator);
            var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
            defer parsed.deinit();
            const root = asObject(parsed.value) orelse return error.ProviderBug;
            if (root.get("builds")) |builds_value| {
                const builds = asArray(builds_value) orelse return error.ProviderBug;
                for (builds.items) |build_value| {
                    const build = asObject(build_value) orelse return error.ProviderBug;
                    if (!hasTag(build, tag)) continue;
                    validateBuild(context, node, build) catch |err| return switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                        else => error.Conflict,
                    };
                    const physical_id = try requiredJsonString(build, "name");
                    try validatePhysicalId(node, physical_id);
                    if (match != null) return error.Conflict;
                    match = context.allocator.dupe(u8, physical_id) catch return error.OutOfMemory;
                }
            }
            const next = jsonString(root.get("nextPageToken"));
            if (next == null or next.?.len == 0) return match;
            if (page_token) |old| {
                context.allocator.free(old);
                page_token = null;
            }
            page_token = context.allocator.dupe(u8, next.?) catch return error.OutOfMemory;
        }
        return error.Conflict;
    }

    fn request(
        self: Handler,
        context: *provider_mod.OperationContext,
        request_value: client_mod.Request,
    ) ProviderError!zstd.Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, request_value, &diagnostic);
    }
};

pub fn supports(node: resource.ResourceNode) bool {
    return std.mem.eql(u8, node.type_name, zig_image_type);
}

const FailureStatus = enum { FAILURE, INTERNAL_ERROR, TIMEOUT, CANCELLED, EXPIRED };

fn buildBodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError![]const u8 {
    const allocator = context.allocator;
    const project_id = try requiredString(node.inputs, "project_id");
    const location = try requiredString(node.inputs, "location");
    const repository = try resolveString(context, try requiredValue(node.inputs, "repository"));
    if (!repositoryBelongsTo(repository, project_id, location)) return error.InvalidConfiguration;
    const image = try targetImageAlloc(context, node);
    defer allocator.free(image);
    const build_tag = try buildTagAlloc(allocator, node);
    defer allocator.free(build_tag);
    const source_tag = try sourceTagAlloc(allocator, node);
    defer allocator.free(source_tag);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var storage_source: std.json.ObjectMap = .empty;
    try storage_source.put(arena, "bucket", .{ .string = try resolveString(context, try requiredValue(node.inputs, "source_bucket")) });
    try storage_source.put(arena, "object", .{ .string = try resolveString(context, try requiredValue(node.inputs, "source_object")) });
    try storage_source.put(arena, "generation", .{ .string = try resolveString(context, try requiredValue(node.inputs, "source_generation")) });
    try storage_source.put(arena, "sourceFetcher", .{ .string = "GCS_FETCHER" });
    var source: std.json.ObjectMap = .empty;
    try source.put(arena, "storageSource", .{ .object = storage_source });
    var root: std.json.ObjectMap = .empty;
    try root.put(arena, "source", .{ .object = source });
    var args = std.json.Array.init(arena);
    for ([_][]const u8{ "build", "--file", "Dockerfile.ziac", "--tag", image, "." }) |arg| try args.append(.{ .string = arg });
    var step: std.json.ObjectMap = .empty;
    try step.put(arena, "name", .{ .string = try requiredString(node.inputs, "docker_builder") });
    try step.put(arena, "args", .{ .array = args });
    var steps = std.json.Array.init(arena);
    try steps.append(.{ .object = step });
    try root.put(arena, "steps", .{ .array = steps });
    var images = std.json.Array.init(arena);
    try images.append(.{ .string = image });
    try root.put(arena, "images", .{ .array = images });
    const timeout = try std.fmt.allocPrint(arena, "{d}s", .{try requiredInteger(node.inputs, "timeout_seconds")});
    try root.put(arena, "timeout", .{ .string = timeout });
    try root.put(arena, "queueTtl", .{ .string = "3600s" });
    var options: std.json.ObjectMap = .empty;
    try options.put(arena, "logging", .{ .string = "CLOUD_LOGGING_ONLY" });
    try options.put(arena, "machineType", .{ .string = "E2_HIGHCPU_8" });
    try options.put(arena, "dynamicSubstitutions", .{ .bool = false });
    try root.put(arena, "options", .{ .object = options });
    var tags = std.json.Array.init(arena);
    for ([_][]const u8{ "ziac", build_tag, source_tag }) |tag| try tags.append(.{ .string = tag });
    try root.put(arena, "tags", .{ .array = tags });
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = root }, .{}) catch return error.OutOfMemory;
}

fn pendingResultFromOperation(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    body: []const u8,
) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = asObject(parsed.value) orelse return error.ProviderBug;
    const operation_name = try requiredJsonString(root, "name");
    if (!isOperationName(operation_name)) return error.ProviderBug;
    const metadata = asObject(root.get("metadata") orelse return error.ProviderBug) orelse return error.ProviderBug;
    const build = asObject(metadata.get("build") orelse return error.ProviderBug) orelse return error.ProviderBug;
    try validateBuild(context, node, build);
    const physical_id = try requiredJsonString(build, "name");
    try validatePhysicalId(node, physical_id);
    var result = try provider_mod.ResourceResult.init(context.allocator, physical_id, node.inputs, &.{}, operation_name);
    result.completed = false;
    return result;
}

fn completedResult(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    build: std.json.ObjectMap,
) ProviderError!provider_mod.ResourceResult {
    const physical_id = try requiredJsonString(build, "name");
    const build_id = try requiredJsonString(build, "id");
    const log_url = try requiredJsonString(build, "logUrl");
    if (!std.mem.startsWith(u8, log_url, "https://")) return error.ProviderBug;
    const target = try targetImageAlloc(context, node);
    defer context.allocator.free(target);
    const results = asObject(build.get("results") orelse return error.ProviderBug) orelse return error.ProviderBug;
    const images = asArray(results.get("images") orelse return error.ProviderBug) orelse return error.ProviderBug;
    var digest: ?[]const u8 = null;
    for (images.items) |image_value| {
        const image = asObject(image_value) orelse return error.ProviderBug;
        const name = try requiredJsonString(image, "name");
        if (!std.mem.eql(u8, name, target)) continue;
        if (digest != null) return error.ProviderBug;
        digest = try requiredJsonString(image, "digest");
    }
    const image_digest = digest orelse return error.ProviderBug;
    if (!isImageDigest(image_digest)) return error.ProviderBug;
    const separator = std.mem.lastIndexOfScalar(u8, target, ':') orelse return error.ProviderBug;
    const slash = std.mem.lastIndexOfScalar(u8, target, '/') orelse return error.ProviderBug;
    if (separator < slash) return error.ProviderBug;
    const image_ref = try std.fmt.allocPrint(context.allocator, "{s}@{s}", .{ target[0..separator], image_digest });
    defer context.allocator.free(image_ref);
    const outputs = [_]state.StateOutput{
        .{ .name = "image_ref", .value = .{ .string = image_ref } },
        .{ .name = "image_digest", .value = .{ .string = image_digest } },
        .{ .name = "build_id", .value = .{ .string = build_id } },
        .{ .name = "log_url", .value = .{ .string = log_url } },
    };
    return provider_mod.ResourceResult.init(context.allocator, physical_id, node.inputs, &outputs, null);
}

fn validateBuild(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    build: std.json.ObjectMap,
) ProviderError!void {
    const physical_id = try requiredJsonString(build, "name");
    try validatePhysicalId(node, physical_id);
    if (!std.mem.eql(u8, try requiredJsonString(build, "projectId"), try requiredString(node.inputs, "project_id"))) {
        return error.InvalidConfiguration;
    }
    const source = asObject(build.get("source") orelse return error.ProviderBug) orelse return error.ProviderBug;
    const storage_source = asObject(source.get("storageSource") orelse return error.ProviderBug) orelse return error.ProviderBug;
    if (!std.mem.eql(u8, try requiredJsonString(storage_source, "bucket"), try resolveString(context, try requiredValue(node.inputs, "source_bucket"))) or
        !std.mem.eql(u8, try requiredJsonString(storage_source, "object"), try resolveString(context, try requiredValue(node.inputs, "source_object"))) or
        !std.mem.eql(u8, try requiredJsonString(storage_source, "generation"), try resolveString(context, try requiredValue(node.inputs, "source_generation"))) or
        !std.mem.eql(u8, try requiredJsonString(storage_source, "sourceFetcher"), "GCS_FETCHER")) return error.InvalidConfiguration;
    const target = try targetImageAlloc(context, node);
    defer context.allocator.free(target);
    const steps = asArray(build.get("steps") orelse return error.ProviderBug) orelse return error.ProviderBug;
    if (steps.items.len != 1) return error.InvalidConfiguration;
    const step = asObject(steps.items[0]) orelse return error.ProviderBug;
    if (!std.mem.eql(u8, try requiredJsonString(step, "name"), try requiredString(node.inputs, "docker_builder"))) return error.InvalidConfiguration;
    const args = asArray(step.get("args") orelse return error.ProviderBug) orelse return error.ProviderBug;
    const expected_args = [_][]const u8{ "build", "--file", "Dockerfile.ziac", "--tag", target, "." };
    if (!jsonStringArrayEquals(args, &expected_args)) return error.InvalidConfiguration;
    const images = asArray(build.get("images") orelse return error.ProviderBug) orelse return error.ProviderBug;
    if (!jsonStringArrayEquals(images, &.{target})) return error.InvalidConfiguration;
    const timeout = try std.fmt.allocPrint(context.allocator, "{d}s", .{try requiredInteger(node.inputs, "timeout_seconds")});
    defer context.allocator.free(timeout);
    if (!std.mem.eql(u8, try requiredJsonString(build, "timeout"), timeout) or
        !std.mem.eql(u8, try requiredJsonString(build, "queueTtl"), "3600s")) return error.InvalidConfiguration;
    const options = asObject(build.get("options") orelse return error.ProviderBug) orelse return error.ProviderBug;
    if (!std.mem.eql(u8, try requiredJsonString(options, "logging"), "CLOUD_LOGGING_ONLY") or
        !std.mem.eql(u8, try requiredJsonString(options, "machineType"), "E2_HIGHCPU_8") or
        (jsonBoolean(options.get("dynamicSubstitutions")) orelse false)) return error.InvalidConfiguration;
    const build_tag = try buildTagAlloc(context.allocator, node);
    defer context.allocator.free(build_tag);
    const source_tag = try sourceTagAlloc(context.allocator, node);
    defer context.allocator.free(source_tag);
    if (!hasTag(build, "ziac") or !hasTag(build, build_tag) or !hasTag(build, source_tag)) return error.InvalidConfiguration;
}

fn targetImageAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError![]const u8 {
    const repository = try resolveString(context, try requiredValue(node.inputs, "repository"));
    const project_id = try requiredString(node.inputs, "project_id");
    const location = try requiredString(node.inputs, "location");
    if (!repositoryBelongsTo(repository, project_id, location)) return error.InvalidConfiguration;
    return std.fmt.allocPrint(context.allocator, "{s}/{s}:ziac-{s}", .{
        repository,
        try requiredString(node.inputs, "image_name"),
        try requiredString(node.inputs, "build_digest"),
    }) catch return error.OutOfMemory;
}

fn buildTagAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "ziac-build-{s}", .{try requiredString(node.inputs, "build_digest")}) catch return error.OutOfMemory;
}

fn sourceTagAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "ziac-source-{s}", .{try requiredString(node.inputs, "source_digest")}) catch return error.OutOfMemory;
}

fn repositoryBelongsTo(repository: []const u8, project_id: []const u8, location: []const u8) bool {
    var components = std.mem.splitScalar(u8, repository, '/');
    const host = components.next() orelse return false;
    const project = components.next() orelse return false;
    const repo = components.next() orelse return false;
    if (components.next() != null or repo.len == 0) return false;
    const suffix = "-docker.pkg.dev";
    return std.mem.endsWith(u8, host, suffix) and
        std.mem.eql(u8, host[0 .. host.len - suffix.len], location) and
        std.mem.eql(u8, project, project_id);
}

fn validatePhysicalId(node: resource.ResourceNode, physical_id: []const u8) ProviderError!void {
    var segments = std.mem.splitScalar(u8, physical_id, '/');
    if (!std.mem.eql(u8, segments.next() orelse return error.InvalidConfiguration, "projects")) return error.InvalidConfiguration;
    const project_id = segments.next() orelse return error.InvalidConfiguration;
    if (!std.mem.eql(u8, project_id, try requiredString(node.inputs, "project_id"))) return error.InvalidConfiguration;
    if (!std.mem.eql(u8, segments.next() orelse return error.InvalidConfiguration, "locations")) return error.InvalidConfiguration;
    const location = segments.next() orelse return error.InvalidConfiguration;
    if (!std.mem.eql(u8, location, try requiredString(node.inputs, "location"))) return error.InvalidConfiguration;
    if (!std.mem.eql(u8, segments.next() orelse return error.InvalidConfiguration, "builds")) return error.InvalidConfiguration;
    const build_id = segments.next() orelse return error.InvalidConfiguration;
    if (!isPathSegment(build_id) or segments.next() != null) return error.InvalidConfiguration;
}

fn isPendingStatus(status_name: []const u8) bool {
    return std.mem.eql(u8, status_name, "STATUS_UNKNOWN") or
        std.mem.eql(u8, status_name, "PENDING") or
        std.mem.eql(u8, status_name, "QUEUED") or
        std.mem.eql(u8, status_name, "WORKING");
}

fn isFailureStatus(status_name: []const u8) bool {
    return std.meta.stringToEnum(FailureStatus, status_name) != null;
}

fn reportBuildFailure(
    reporter: ?FailureReporter,
    allocator: std.mem.Allocator,
    build: std.json.ObjectMap,
    status_name: []const u8,
) void {
    const failure_info = if (build.get("failureInfo")) |value_field| asObject(value_field) else null;
    const detail = if (failure_info) |info| jsonString(info.get("detail")) orelse status_name else status_name;
    const log_url = jsonString(build.get("logUrl")) orelse "log URL unavailable";
    const bounded_detail = detail[0..@min(detail.len, 768)];
    const safe_url_end = std.mem.indexOfAny(u8, log_url, "?#") orelse log_url.len;
    const bounded_url = log_url[0..@min(safe_url_end, 256)];
    const redacted_detail = zstd.Secrets.redactAlloc(allocator, bounded_detail) catch {
        emitFailure(reporter, status_name, "diagnostic unavailable");
        return;
    };
    defer allocator.free(redacted_detail);
    const redacted_url = zstd.Secrets.redactAlloc(allocator, bounded_url) catch {
        emitFailure(reporter, status_name, "diagnostic unavailable");
        return;
    };
    defer allocator.free(redacted_url);
    const diagnostic = std.fmt.allocPrint(allocator, "{s} ({s})", .{ redacted_detail, redacted_url }) catch {
        emitFailure(reporter, status_name, "diagnostic unavailable");
        return;
    };
    defer allocator.free(diagnostic);
    emitFailure(reporter, status_name, diagnostic);
}

fn emitFailure(reporter: ?FailureReporter, status_name: []const u8, diagnostic: []const u8) void {
    if (reporter) |sink| {
        sink.report(status_name, diagnostic);
        return;
    }
    std.log.warn("Cloud Build ended with status {s}: {s}", .{ status_name, diagnostic });
}

fn hasTag(build: std.json.ObjectMap, expected: []const u8) bool {
    const tags = asArray(build.get("tags") orelse return false) orelse return false;
    for (tags.items) |tag_value| {
        const tag = jsonString(tag_value) orelse continue;
        if (std.mem.eql(u8, tag, expected)) return true;
    }
    return false;
}

fn jsonStringArrayEquals(array: std.json.Array, expected: []const []const u8) bool {
    if (array.items.len != expected.len) return false;
    for (array.items, expected) |item, expected_item| {
        const string = jsonString(item) orelse return false;
        if (!std.mem.eql(u8, string, expected_item)) return false;
    }
    return true;
}

fn percentEncodeAlloc(allocator: std.mem.Allocator, input: []const u8) ProviderError![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (input) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try result.append(allocator, byte);
        } else {
            try result.appendSlice(allocator, &.{ '%', hex[byte >> 4], hex[byte & 0x0f] });
        }
    }
    return result.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn requiredValue(input: value.Value, name: []const u8) ProviderError!value.Value {
    const fields = switch (input) {
        .object => |fields| fields,
        else => return error.InvalidConfiguration,
    };
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return error.InvalidConfiguration;
}

fn requiredString(input: value.Value, name: []const u8) ProviderError![]const u8 {
    return switch (try requiredValue(input, name)) {
        .string => |string| string,
        else => error.InvalidConfiguration,
    };
}

fn requiredInteger(input: value.Value, name: []const u8) ProviderError!i64 {
    return switch (try requiredValue(input, name)) {
        .integer => |integer| integer,
        else => error.InvalidConfiguration,
    };
}

fn resolveString(context: *provider_mod.OperationContext, input: value.Value) ProviderError![]const u8 {
    return switch (input) {
        .string => |string| string,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}

fn requiredJsonString(object: std.json.ObjectMap, name: []const u8) ProviderError![]const u8 {
    return jsonString(object.get(name)) orelse error.ProviderBug;
}

fn asObject(json_value: std.json.Value) ?std.json.ObjectMap {
    return switch (json_value) {
        .object => |object| object,
        else => null,
    };
}

fn asArray(json_value: std.json.Value) ?std.json.Array {
    return switch (json_value) {
        .array => |array| array,
        else => null,
    };
}

fn jsonString(json_value: ?std.json.Value) ?[]const u8 {
    const present = json_value orelse return null;
    return switch (present) {
        .string => |string| string,
        else => null,
    };
}

fn jsonBoolean(json_value: ?std.json.Value) ?bool {
    const present = json_value orelse return null;
    return switch (present) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn isImageDigest(digest: []const u8) bool {
    if (!std.mem.startsWith(u8, digest, "sha256:") or digest.len != "sha256:".len + 64) return false;
    for (digest["sha256:".len..]) |character| {
        if (!(std.ascii.isDigit(character) or character >= 'a' and character <= 'f')) return false;
    }
    return true;
}

fn isOperationName(name: []const u8) bool {
    return name.len <= 512 and std.mem.indexOf(u8, name, "operations/") != null and std.mem.indexOfAny(u8, name, " \t\r\n?#") == null;
}

fn isPathSegment(segment: []const u8) bool {
    if (segment.len == 0 or segment.len > 128) return false;
    for (segment) |character| {
        if (!std.ascii.isAlphanumeric(character) and character != '-' and character != '_') return false;
    }
    return true;
}
