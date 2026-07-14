const std = @import("std");
const client_mod = @import("client.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const secret_mod = @import("../secret.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;

const Kind = enum {
    alert_policy,
    uptime_check,
    notification_channel,
    dashboard,
    service,
    service_level_objective,
};

pub fn supports(node: resource.ResourceNode) bool {
    return kindOf(node) != null;
}

pub const Handler = struct {
    client: *client_mod.Client,
    secret_source: ?secret_mod.SecretSource = null,
    conflict_retries: usize = 2,

    pub fn read(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        const physical = try physicalForReadAlloc(context.allocator, node, kind, physical_override);
        defer context.allocator.free(physical);
        const path = try readPathAlloc(context.allocator, kind, physical);
        defer context.allocator.free(path);
        var response = self.request(context, "GET", path, "") catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try self.resultFromJson(context, node, kind, response.body) };
    }

    pub fn diff(context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash)) return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        const replace = switch (kind) {
            .notification_channel => inputChanged(node.inputs, observed.observed_inputs, "type"),
            .service => inputChanged(node.inputs, observed.observed_inputs, "kind"),
            .service_level_objective => inputChanged(node.inputs, observed.observed_inputs, "service_name") or inputChanged(node.inputs, observed.observed_inputs, "service"),
            .alert_policy, .uptime_check, .dashboard => false,
        };
        return provider_mod.DiffResult.init(context.allocator, if (replace) .replace else .update, &.{if (replace) "immutable Monitoring identity changed" else "Monitoring configuration differs"});
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        const body = try self.bodyAlloc(context, node, kind, null, null, true);
        defer context.allocator.free(body);
        const path = try createPathAlloc(context.allocator, node, kind);
        defer context.allocator.free(path);
        var response = try self.request(context, "POST", path, body);
        defer response.deinit(context.allocator);
        return self.resultFromJson(context, node, kind, response.body);
    }

    pub fn update(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(context.allocator, node, kind, observed.physical_id);
        if (kind == .dashboard) return self.updateDashboard(context, node, observed.physical_id);
        const body = try self.bodyAlloc(context, node, kind, observed.physical_id, null, true);
        defer context.allocator.free(body);
        const path = try updatePathAlloc(context.allocator, kind, observed.physical_id);
        defer context.allocator.free(path);
        var response = try self.request(context, "PATCH", path, body);
        defer response.deinit(context.allocator);
        return self.resultFromJson(context, node, kind, response.body);
    }

    pub fn delete(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!void {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(context.allocator, node, kind, physical_id);
        var path = try readPathAlloc(context.allocator, kind, physical_id);
        defer context.allocator.free(path);
        if (kind == .notification_channel and requiredBoolean(node.inputs, "force_delete")) {
            const forced = try std.fmt.allocPrint(context.allocator, "{s}?force=true", .{path});
            context.allocator.free(path);
            path = forced;
        }
        var response = self.request(context, "DELETE", path, "") catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        response.deinit(context.allocator);
    }

    pub fn importResource(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!provider_mod.ResourceResult {
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(context.allocator, node, kind, physical_id);
        var read_result = try self.read(context, node, physical_id);
        defer read_result.deinit();
        return switch (read_result) {
            .absent => error.NotFound,
            .present => |present| present.clone(context.allocator) catch error.OutOfMemory,
        };
    }

    fn updateDashboard(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical: []const u8) ProviderError!provider_mod.ResourceResult {
        const read_path = try readPathAlloc(context.allocator, .dashboard, physical);
        defer context.allocator.free(read_path);
        const update_path = try updatePathAlloc(context.allocator, .dashboard, physical);
        defer context.allocator.free(update_path);
        var conflicts: usize = 0;
        while (true) {
            var current = try self.request(context, "GET", read_path, "");
            defer current.deinit(context.allocator);
            const etag = try jsonStringFieldAlloc(context.allocator, current.body, "etag");
            defer context.allocator.free(etag);
            const body = try self.bodyAlloc(context, node, .dashboard, physical, etag, true);
            defer context.allocator.free(body);
            var response = self.request(context, "PATCH", update_path, body) catch |err| {
                if (err == error.Conflict and conflicts < self.conflict_retries) {
                    conflicts += 1;
                    continue;
                }
                return err;
            };
            defer response.deinit(context.allocator);
            return self.resultFromJson(context, node, .dashboard, response.body);
        }
    }

    fn resultFromJson(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, body: []const u8) ProviderError!provider_mod.ResourceResult {
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const remote = jsonObject(parsed.value) orelse return error.ProviderBug;
        const physical = jsonString(remote.get("name")) orelse return error.ProviderBug;
        try validatePhysical(context.allocator, node, kind, physical);

        const desired_body = try self.bodyAlloc(context, node, kind, physical, null, false);
        defer context.allocator.free(desired_body);
        var desired = std.json.parseFromSlice(std.json.Value, context.allocator, desired_body, .{}) catch return error.ProviderBug;
        defer desired.deinit();
        var observed = if (jsonSubset(parsed.value, desired.value))
            node.inputs.clone(context.allocator) catch return error.OutOfMemory
        else
            driftedInputsAlloc(context.allocator, node.inputs) catch return error.OutOfMemory;
        defer observed.deinit(context.allocator);

        var outputs: [3]state.StateOutput = undefined;
        var count: usize = 0;
        outputs[count] = .{ .name = "name", .value = .{ .string = physical } };
        count += 1;
        switch (kind) {
            .notification_channel => {
                outputs[count] = .{ .name = "verification_status", .value = .{ .string = jsonString(remote.get("verificationStatus")) orelse "UNSPECIFIED" } };
                count += 1;
            },
            .alert_policy => {
                const validity = if (jsonObject(remote.get("validity") orelse .{ .object = .empty })) |status_object| jsonString(status_object.get("message")) orelse "OK" else "OK";
                outputs[count] = .{ .name = "validity", .value = .{ .string = validity } };
                count += 1;
            },
            .dashboard => {
                outputs[count] = .{ .name = "etag", .value = .{ .string = jsonString(remote.get("etag")) orelse "" } };
                count += 1;
            },
            .uptime_check, .service, .service_level_objective => {},
        }
        return provider_mod.ResourceResult.init(context.allocator, physical, observed, outputs[0..count], null);
    }

    fn bodyAlloc(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, physical: ?[]const u8, etag: ?[]const u8, include_secrets: bool) ProviderError![]const u8 {
        var arena_state = std.heap.ArenaAllocator.init(context.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var root = std.json.ObjectMap.empty;
        switch (kind) {
            .notification_channel => try self.channelBody(context, arena, &root, node, include_secrets),
            .uptime_check => try self.uptimeBody(context, arena, &root, node, include_secrets),
            .alert_policy => try alertPolicyBody(context, arena, &root, node),
            .dashboard => try dashboardBody(context, arena, &root, node),
            .service => try serviceBody(context, arena, &root, node),
            .service_level_objective => try sloBody(context, arena, &root, node),
        }
        if (physical) |name| try root.put(arena, "name", .{ .string = name });
        if (etag) |current| try root.put(arena, "etag", .{ .string = current });
        return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch return error.OutOfMemory;
    }

    fn channelBody(self: Handler, context: *provider_mod.OperationContext, arena: std.mem.Allocator, root: *std.json.ObjectMap, node: resource.ResourceNode, include_secrets: bool) ProviderError!void {
        try root.put(arena, "displayName", .{ .string = try requiredString(node.inputs, "display_name") });
        try root.put(arena, "type", .{ .string = try requiredString(node.inputs, "type") });
        try root.put(arena, "description", .{ .string = try requiredString(node.inputs, "description") });
        try root.put(arena, "enabled", .{ .bool = requiredBoolean(node.inputs, "enabled") });
        var labels = try stringMapAlloc(arena, try requiredObject(node.inputs, "labels"));
        if (include_secrets) try self.mergeSecrets(context, arena, &labels, try requiredObject(node.inputs, "secret_labels"));
        try root.put(arena, "labels", .{ .object = labels });
        try root.put(arena, "userLabels", .{ .object = try stringMapAlloc(arena, try requiredObject(node.inputs, "user_labels")) });
    }

    fn uptimeBody(self: Handler, context: *provider_mod.OperationContext, arena: std.mem.Allocator, root: *std.json.ObjectMap, node: resource.ResourceNode, include_secrets: bool) ProviderError!void {
        try root.put(arena, "displayName", .{ .string = try requiredString(node.inputs, "display_name") });
        try root.put(arena, "period", .{ .string = try durationAlloc(arena, try requiredInteger(node.inputs, "period_seconds")) });
        try root.put(arena, "timeout", .{ .string = try durationAlloc(arena, try requiredInteger(node.inputs, "timeout_seconds")) });
        try root.put(arena, "checkerType", .{ .string = try requiredString(node.inputs, "checker_type") });
        try root.put(arena, "selectedRegions", .{ .array = try stringArrayAlloc(context, arena, try requiredList(node.inputs, "selected_regions")) });
        try root.put(arena, "disabled", .{ .bool = requiredBoolean(node.inputs, "disabled") });
        try root.put(arena, "logCheckFailures", .{ .bool = requiredBoolean(node.inputs, "log_check_failures") });
        try root.put(arena, "userLabels", .{ .object = try stringMapAlloc(arena, try requiredObject(node.inputs, "user_labels")) });
        try root.put(arena, "contentMatchers", .{ .array = try contentMatchersAlloc(arena, try requiredList(node.inputs, "content_matchers")) });
        const target = try requiredObject(node.inputs, "target");
        const host = requiredObjectString(target, "host");
        var monitored_labels = std.json.ObjectMap.empty;
        try monitored_labels.put(arena, "project_id", .{ .string = try requiredString(node.inputs, "project_id") });
        try monitored_labels.put(arena, "host", .{ .string = host });
        var monitored = std.json.ObjectMap.empty;
        try monitored.put(arena, "type", .{ .string = "uptime_url" });
        try monitored.put(arena, "labels", .{ .object = monitored_labels });
        try root.put(arena, "monitoredResource", .{ .object = monitored });
        if (std.mem.eql(u8, try requiredString(node.inputs, "protocol"), "TCP")) {
            var check = std.json.ObjectMap.empty;
            try check.put(arena, "port", .{ .integer = requiredObjectInteger(target, "port") });
            try root.put(arena, "tcpCheck", .{ .object = check });
            return;
        }
        var check = std.json.ObjectMap.empty;
        try check.put(arena, "path", .{ .string = requiredObjectString(target, "path") });
        try check.put(arena, "port", .{ .integer = requiredObjectInteger(target, "port") });
        try check.put(arena, "requestMethod", .{ .string = requiredObjectString(target, "method") });
        try check.put(arena, "useSsl", .{ .bool = requiredObjectBoolean(target, "use_ssl") });
        try check.put(arena, "validateSsl", .{ .bool = requiredObjectBoolean(target, "validate_ssl") });
        try check.put(arena, "body", .{ .string = requiredObjectString(target, "body") });
        var headers = try stringMapAlloc(arena, requiredObjectValue(target, "headers").object);
        if (include_secrets) try self.mergeSecrets(context, arena, &headers, requiredObjectValue(target, "secret_headers").object);
        try check.put(arena, "headers", .{ .object = headers });
        try check.put(arena, "maskHeaders", .{ .bool = requiredObjectValue(target, "secret_headers").object.len != 0 });
        try check.put(arena, "acceptedResponseStatusCodes", .{ .array = try statusClassesAlloc(arena, requiredObjectValue(target, "accepted_status_classes").list) });
        const authentication = requiredObjectValue(target, "basic_authentication").object;
        if (authentication.len != 0) {
            var auth_info = std.json.ObjectMap.empty;
            try auth_info.put(arena, "username", .{ .string = requiredObjectString(authentication, "username") });
            if (include_secrets) {
                const secret = try self.resolveSecretAlloc(context, arena, requiredObjectValue(authentication, "password"));
                try auth_info.put(arena, "password", .{ .string = secret });
            }
            try check.put(arena, "authInfo", .{ .object = auth_info });
        }
        try root.put(arena, "httpCheck", .{ .object = check });
    }

    fn mergeSecrets(self: Handler, context: *provider_mod.OperationContext, arena: std.mem.Allocator, destination: *std.json.ObjectMap, fields: []const value.Field) ProviderError!void {
        for (fields) |field| {
            const secret = try self.resolveSecretAlloc(context, arena, field.value);
            try destination.put(arena, field.name, .{ .string = secret });
        }
    }

    fn resolveSecretAlloc(self: Handler, context: *provider_mod.OperationContext, allocator: std.mem.Allocator, candidate: value.Value) ProviderError![]const u8 {
        const reference = switch (candidate) {
            .secret_ref => |present| present,
            .output_ref => |output_reference| try context.resolveOutputSecret(output_reference),
            else => return error.InvalidConfiguration,
        };
        const source = self.secret_source orelse return error.AuthorizationFailed;
        var payload = try source.resolve(context, context.allocator, reference);
        defer payload.deinit();
        return allocator.dupe(u8, payload.bytes) catch return error.OutOfMemory;
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, method: []const u8, path: []const u8, body: []const u8) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, .{ .api = .monitoring, .method = method, .path = path, .body = body }, &diagnostic);
    }
};

fn alertPolicyBody(context: *provider_mod.OperationContext, arena: std.mem.Allocator, root: *std.json.ObjectMap, node: resource.ResourceNode) ProviderError!void {
    try root.put(arena, "displayName", .{ .string = try requiredString(node.inputs, "display_name") });
    try root.put(arena, "combiner", .{ .string = try requiredString(node.inputs, "combiner") });
    try root.put(arena, "severity", .{ .string = try requiredString(node.inputs, "severity") });
    try root.put(arena, "enabled", .{ .bool = requiredBoolean(node.inputs, "enabled") });
    try root.put(arena, "userLabels", .{ .object = try stringMapAlloc(arena, try requiredObject(node.inputs, "user_labels")) });
    try root.put(arena, "notificationChannels", .{ .array = try stringArrayAlloc(context, arena, try requiredList(node.inputs, "notification_channels")) });
    var documentation = std.json.ObjectMap.empty;
    try documentation.put(arena, "content", .{ .string = try requiredString(node.inputs, "documentation_content") });
    try documentation.put(arena, "mimeType", .{ .string = try requiredString(node.inputs, "documentation_mime_type") });
    try documentation.put(arena, "subject", .{ .string = try requiredString(node.inputs, "documentation_subject") });
    try root.put(arena, "documentation", .{ .object = documentation });
    var strategy = std.json.ObjectMap.empty;
    const auto_close = try requiredInteger(node.inputs, "auto_close_seconds");
    if (auto_close != 0) try strategy.put(arena, "autoClose", .{ .string = try durationAlloc(arena, auto_close) });
    const rate = try requiredInteger(node.inputs, "notification_rate_limit_seconds");
    if (rate != 0) {
        var limit = std.json.ObjectMap.empty;
        try limit.put(arena, "period", .{ .string = try durationAlloc(arena, rate) });
        try strategy.put(arena, "notificationRateLimit", .{ .object = limit });
    }
    try root.put(arena, "alertStrategy", .{ .object = strategy });
    try root.put(arena, "conditions", .{ .array = try conditionsAlloc(arena, try requiredList(node.inputs, "conditions")) });
}

fn dashboardBody(context: *provider_mod.OperationContext, arena: std.mem.Allocator, root: *std.json.ObjectMap, node: resource.ResourceNode) ProviderError!void {
    try root.put(arena, "displayName", .{ .string = try requiredString(node.inputs, "display_name") });
    try root.put(arena, "labels", .{ .object = try stringMapAlloc(arena, try requiredObject(node.inputs, "labels")) });
    var layout = std.json.ObjectMap.empty;
    try layout.put(arena, "columns", .{ .integer = try requiredInteger(node.inputs, "columns") });
    try layout.put(arena, "tiles", .{ .array = try dashboardTilesAlloc(context, arena, try requiredList(node.inputs, "tiles")) });
    try root.put(arena, "mosaicLayout", .{ .object = layout });
}

fn serviceBody(context: *provider_mod.OperationContext, arena: std.mem.Allocator, root: *std.json.ObjectMap, node: resource.ResourceNode) ProviderError!void {
    _ = context;
    try root.put(arena, "displayName", .{ .string = try requiredString(node.inputs, "display_name") });
    try root.put(arena, "userLabels", .{ .object = try stringMapAlloc(arena, try requiredObject(node.inputs, "user_labels")) });
    const kind = try requiredObject(node.inputs, "kind");
    const name = requiredObjectString(kind, "kind");
    if (std.mem.eql(u8, name, "CUSTOM")) {
        try root.put(arena, "custom", .{ .object = std.json.ObjectMap.empty });
    } else if (std.mem.eql(u8, name, "BASIC")) {
        var basic = std.json.ObjectMap.empty;
        try basic.put(arena, "serviceType", .{ .string = requiredObjectString(kind, "service_type") });
        try basic.put(arena, "serviceLabels", .{ .object = try stringMapAlloc(arena, requiredObjectValue(kind, "service_labels").object) });
        try root.put(arena, "basicService", .{ .object = basic });
    } else if (std.mem.eql(u8, name, "CLOUD_RUN")) {
        var run = std.json.ObjectMap.empty;
        try run.put(arena, "serviceName", .{ .string = requiredObjectString(kind, "service_name") });
        try run.put(arena, "location", .{ .string = requiredObjectString(kind, "location") });
        try root.put(arena, "cloudRun", .{ .object = run });
    } else if (std.mem.eql(u8, name, "GKE_WORKLOAD")) {
        var gke = std.json.ObjectMap.empty;
        try gke.put(arena, "projectId", .{ .string = requiredObjectString(kind, "project_id") });
        try gke.put(arena, "location", .{ .string = requiredObjectString(kind, "location") });
        try gke.put(arena, "clusterName", .{ .string = requiredObjectString(kind, "cluster_name") });
        try gke.put(arena, "namespaceName", .{ .string = requiredObjectString(kind, "namespace_name") });
        try gke.put(arena, "topLevelControllerType", .{ .string = requiredObjectString(kind, "top_level_controller_type") });
        try gke.put(arena, "topLevelControllerName", .{ .string = requiredObjectString(kind, "top_level_controller_name") });
        try root.put(arena, "gkeWorkload", .{ .object = gke });
    } else return error.InvalidConfiguration;
}

fn sloBody(context: *provider_mod.OperationContext, arena: std.mem.Allocator, root: *std.json.ObjectMap, node: resource.ResourceNode) ProviderError!void {
    _ = context;
    try root.put(arena, "displayName", .{ .string = try requiredString(node.inputs, "display_name") });
    try root.put(arena, "goal", .{ .float = @as(f64, @floatFromInt(try requiredInteger(node.inputs, "goal_micros"))) / 1_000_000.0 });
    try root.put(arena, "userLabels", .{ .object = try stringMapAlloc(arena, try requiredObject(node.inputs, "user_labels")) });
    const period = try requiredObject(node.inputs, "period");
    if (std.mem.eql(u8, requiredObjectString(period, "kind"), "ROLLING"))
        try root.put(arena, "rollingPeriod", .{ .string = try durationAlloc(arena, requiredObjectInteger(period, "seconds")) })
    else
        try root.put(arena, "calendarPeriod", .{ .string = requiredObjectString(period, "value") });
    try root.put(arena, "serviceLevelIndicator", .{ .object = try sliAlloc(arena, try requiredObject(node.inputs, "indicator")) });
}

fn conditionsAlloc(arena: std.mem.Allocator, conditions: []const value.Value) ProviderError!std.json.Array {
    var result = std.json.Array.init(arena);
    for (conditions) |candidate| {
        const condition = valueObject(candidate) orelse return error.InvalidConfiguration;
        var encoded = std.json.ObjectMap.empty;
        try encoded.put(arena, "displayName", .{ .string = requiredObjectString(condition, "display_name") });
        const kind = requiredObjectString(condition, "kind");
        if (std.mem.eql(u8, kind, "THRESHOLD")) {
            var threshold = std.json.ObjectMap.empty;
            try threshold.put(arena, "filter", .{ .string = requiredObjectString(condition, "filter") });
            try threshold.put(arena, "comparison", .{ .string = requiredObjectString(condition, "comparison") });
            try threshold.put(arena, "thresholdValue", .{ .float = @as(f64, @floatFromInt(requiredObjectInteger(condition, "threshold_micros"))) / 1_000_000.0 });
            try threshold.put(arena, "duration", .{ .string = try durationAlloc(arena, requiredObjectInteger(condition, "duration_seconds")) });
            try threshold.put(arena, "aggregations", .{ .array = try aggregationArrayAlloc(arena, condition) });
            try addTrigger(arena, &threshold, condition);
            try encoded.put(arena, "conditionThreshold", .{ .object = threshold });
        } else if (std.mem.eql(u8, kind, "ABSENCE")) {
            var absence = std.json.ObjectMap.empty;
            try absence.put(arena, "filter", .{ .string = requiredObjectString(condition, "filter") });
            try absence.put(arena, "duration", .{ .string = try durationAlloc(arena, requiredObjectInteger(condition, "duration_seconds")) });
            try absence.put(arena, "aggregations", .{ .array = try aggregationArrayAlloc(arena, condition) });
            try addTrigger(arena, &absence, condition);
            try encoded.put(arena, "conditionAbsent", .{ .object = absence });
        } else if (std.mem.eql(u8, kind, "PROMQL")) {
            var promql = std.json.ObjectMap.empty;
            try promql.put(arena, "query", .{ .string = requiredObjectString(condition, "query") });
            try promql.put(arena, "duration", .{ .string = try durationAlloc(arena, requiredObjectInteger(condition, "duration_seconds")) });
            try promql.put(arena, "evaluationInterval", .{ .string = try durationAlloc(arena, requiredObjectInteger(condition, "evaluation_interval_seconds")) });
            try promql.put(arena, "disableMetricValidation", .{ .bool = requiredObjectBoolean(condition, "disable_metric_validation") });
            try encoded.put(arena, "conditionPrometheusQueryLanguage", .{ .object = promql });
        } else if (std.mem.eql(u8, kind, "LOG_MATCH")) {
            var match = std.json.ObjectMap.empty;
            try match.put(arena, "filter", .{ .string = requiredObjectString(condition, "filter") });
            try match.put(arena, "labelExtractors", .{ .object = try stringMapAlloc(arena, requiredObjectValue(condition, "label_extractors").object) });
            try encoded.put(arena, "conditionMatchedLog", .{ .object = match });
        } else return error.InvalidConfiguration;
        try result.append(.{ .object = encoded });
    }
    return result;
}

fn aggregationArrayAlloc(arena: std.mem.Allocator, condition: []const value.Field) ProviderError!std.json.Array {
    var aggregation = std.json.ObjectMap.empty;
    try aggregation.put(arena, "alignmentPeriod", .{ .string = try durationAlloc(arena, requiredObjectInteger(condition, "alignment_period_seconds")) });
    try aggregation.put(arena, "perSeriesAligner", .{ .string = requiredObjectString(condition, "per_series_aligner") });
    if (objectField(condition, "cross_series_reducer")) |reducer| {
        const text = valueString(reducer) orelse return error.InvalidConfiguration;
        try aggregation.put(arena, "crossSeriesReducer", .{ .string = text });
        if (objectField(condition, "group_by_fields")) |groups| try aggregation.put(arena, "groupByFields", .{ .array = try stringArrayAllocNoContext(arena, valueList(groups) orelse return error.InvalidConfiguration) });
    }
    var array = std.json.Array.init(arena);
    try array.append(.{ .object = aggregation });
    return array;
}

fn addTrigger(arena: std.mem.Allocator, destination: *std.json.ObjectMap, condition: []const value.Field) ProviderError!void {
    const count = requiredObjectInteger(condition, "trigger_count");
    const percent = requiredObjectInteger(condition, "trigger_percent_micros");
    if (count == 0 and percent == 0) return;
    var trigger = std.json.ObjectMap.empty;
    if (count != 0) try trigger.put(arena, "count", .{ .integer = count });
    if (percent != 0) try trigger.put(arena, "percent", .{ .float = @as(f64, @floatFromInt(percent)) / 1_000_000.0 });
    try destination.put(arena, "trigger", .{ .object = trigger });
}

fn dashboardTilesAlloc(context: *provider_mod.OperationContext, arena: std.mem.Allocator, tiles: []const value.Value) ProviderError!std.json.Array {
    var result = std.json.Array.init(arena);
    for (tiles) |candidate| {
        const tile = valueObject(candidate) orelse return error.InvalidConfiguration;
        var encoded = std.json.ObjectMap.empty;
        try encoded.put(arena, "xPos", .{ .integer = requiredObjectInteger(tile, "x") });
        try encoded.put(arena, "yPos", .{ .integer = requiredObjectInteger(tile, "y") });
        try encoded.put(arena, "width", .{ .integer = requiredObjectInteger(tile, "width") });
        try encoded.put(arena, "height", .{ .integer = requiredObjectInteger(tile, "height") });
        try encoded.put(arena, "widget", .{ .object = try widgetAlloc(context, arena, requiredObjectValue(tile, "widget").object) });
        try result.append(.{ .object = encoded });
    }
    return result;
}

fn widgetAlloc(context: *provider_mod.OperationContext, arena: std.mem.Allocator, widget: []const value.Field) ProviderError!std.json.ObjectMap {
    var result = std.json.ObjectMap.empty;
    const kind = requiredObjectString(widget, "kind");
    try result.put(arena, "title", .{ .string = requiredObjectString(widget, "title") });
    if (std.mem.eql(u8, kind, "TEXT")) {
        var text = std.json.ObjectMap.empty;
        try text.put(arena, "content", .{ .string = requiredObjectString(widget, "content") });
        try text.put(arena, "format", .{ .string = "MARKDOWN" });
        try result.put(arena, "text", .{ .object = text });
    } else if (std.mem.eql(u8, kind, "XY_CHART")) {
        var chart = std.json.ObjectMap.empty;
        try chart.put(arena, "dataSets", .{ .array = try dataSetsAlloc(arena, requiredObjectValue(widget, "series").list) });
        try result.put(arena, "xyChart", .{ .object = chart });
    } else if (std.mem.eql(u8, kind, "SCORECARD")) {
        const series = requiredObjectValue(widget, "series").list;
        if (series.len != 1) return error.InvalidConfiguration;
        var scorecard = std.json.ObjectMap.empty;
        try scorecard.put(arena, "timeSeriesQuery", .{ .object = try timeSeriesQueryAlloc(arena, valueObject(series[0]) orelse return error.InvalidConfiguration) });
        try result.put(arena, "scorecard", .{ .object = scorecard });
    } else if (std.mem.eql(u8, kind, "LOGS_PANEL")) {
        var logs = std.json.ObjectMap.empty;
        try logs.put(arena, "filter", .{ .string = requiredObjectString(widget, "filter") });
        try result.put(arena, "logsPanel", .{ .object = logs });
    } else if (std.mem.eql(u8, kind, "ALERT_CHART")) {
        var chart = std.json.ObjectMap.empty;
        try chart.put(arena, "name", .{ .string = try resolveString(context, requiredObjectValue(widget, "alert_policy")) });
        try result.put(arena, "alertChart", .{ .object = chart });
    } else if (std.mem.eql(u8, kind, "INCIDENT_LIST")) {
        var incidents = std.json.ObjectMap.empty;
        try incidents.put(arena, "policyNames", .{ .array = try stringArrayAlloc(context, arena, requiredObjectValue(widget, "alert_policies").list) });
        try result.put(arena, "incidentList", .{ .object = incidents });
    } else return error.InvalidConfiguration;
    return result;
}

fn dataSetsAlloc(arena: std.mem.Allocator, series: []const value.Value) ProviderError!std.json.Array {
    var result = std.json.Array.init(arena);
    for (series) |candidate| {
        const item = valueObject(candidate) orelse return error.InvalidConfiguration;
        var data_set = std.json.ObjectMap.empty;
        try data_set.put(arena, "timeSeriesQuery", .{ .object = try timeSeriesQueryAlloc(arena, item) });
        try data_set.put(arena, "plotType", .{ .string = requiredObjectString(item, "plot_type") });
        try data_set.put(arena, "legendTemplate", .{ .string = requiredObjectString(item, "legend") });
        try result.append(.{ .object = data_set });
    }
    return result;
}

fn timeSeriesQueryAlloc(arena: std.mem.Allocator, series: []const value.Field) ProviderError!std.json.ObjectMap {
    var aggregation = std.json.ObjectMap.empty;
    try aggregation.put(arena, "alignmentPeriod", .{ .string = try durationAlloc(arena, requiredObjectInteger(series, "alignment_period_seconds")) });
    try aggregation.put(arena, "perSeriesAligner", .{ .string = requiredObjectString(series, "per_series_aligner") });
    try aggregation.put(arena, "crossSeriesReducer", .{ .string = requiredObjectString(series, "cross_series_reducer") });
    var filter = std.json.ObjectMap.empty;
    try filter.put(arena, "filter", .{ .string = requiredObjectString(series, "filter") });
    try filter.put(arena, "aggregation", .{ .object = aggregation });
    var query = std.json.ObjectMap.empty;
    try query.put(arena, "timeSeriesFilter", .{ .object = filter });
    return query;
}

fn sliAlloc(arena: std.mem.Allocator, indicator: []const value.Field) ProviderError!std.json.ObjectMap {
    var result = std.json.ObjectMap.empty;
    const kind = requiredObjectString(indicator, "kind");
    if (std.mem.eql(u8, kind, "BASIC_AVAILABILITY")) {
        var basic = std.json.ObjectMap.empty;
        try basic.put(arena, "availability", .{ .object = std.json.ObjectMap.empty });
        try result.put(arena, "basicSli", .{ .object = basic });
    } else if (std.mem.eql(u8, kind, "BASIC_LATENCY")) {
        var threshold = std.json.ObjectMap.empty;
        try threshold.put(arena, "threshold", .{ .string = try durationMicrosAlloc(arena, requiredObjectInteger(indicator, "threshold_micros")) });
        var latency = std.json.ObjectMap.empty;
        try latency.put(arena, "latency", .{ .array = blk: {
            var array = std.json.Array.init(arena);
            try array.append(.{ .object = threshold });
            break :blk array;
        } });
        try result.put(arena, "basicSli", .{ .object = latency });
    } else if (std.mem.eql(u8, kind, "REQUEST_RATIO")) {
        var ratio = std.json.ObjectMap.empty;
        const good = requiredObjectString(indicator, "good_service_filter");
        const bad = requiredObjectString(indicator, "bad_service_filter");
        if (good.len != 0) try ratio.put(arena, "goodServiceFilter", .{ .string = good });
        if (bad.len != 0) try ratio.put(arena, "badServiceFilter", .{ .string = bad });
        try ratio.put(arena, "totalServiceFilter", .{ .string = requiredObjectString(indicator, "total_service_filter") });
        var request_based = std.json.ObjectMap.empty;
        try request_based.put(arena, "goodTotalRatio", .{ .object = ratio });
        try result.put(arena, "requestBased", .{ .object = request_based });
    } else if (std.mem.eql(u8, kind, "DISTRIBUTION_CUT")) {
        var range = std.json.ObjectMap.empty;
        const minimum = requiredObjectInteger(indicator, "minimum_micros");
        const maximum = requiredObjectInteger(indicator, "maximum_micros");
        if (minimum != std.math.minInt(i64)) try range.put(arena, "min", .{ .float = @as(f64, @floatFromInt(minimum)) / 1_000_000.0 });
        if (maximum != std.math.maxInt(i64)) try range.put(arena, "max", .{ .float = @as(f64, @floatFromInt(maximum)) / 1_000_000.0 });
        var cut = std.json.ObjectMap.empty;
        try cut.put(arena, "distributionFilter", .{ .string = requiredObjectString(indicator, "distribution_filter") });
        try cut.put(arena, "range", .{ .object = range });
        var request_based = std.json.ObjectMap.empty;
        try request_based.put(arena, "distributionCut", .{ .object = cut });
        try result.put(arena, "requestBased", .{ .object = request_based });
    } else if (std.mem.eql(u8, kind, "WINDOWS")) {
        var windows = std.json.ObjectMap.empty;
        try windows.put(arena, "goodBadMetricFilter", .{ .string = requiredObjectString(indicator, "good_bad_metric_filter") });
        try windows.put(arena, "windowPeriod", .{ .string = try durationAlloc(arena, requiredObjectInteger(indicator, "window_period_seconds")) });
        try result.put(arena, "windowsBased", .{ .object = windows });
    } else return error.InvalidConfiguration;
    return result;
}

fn kindOf(node: resource.ResourceNode) ?Kind {
    if (std.mem.eql(u8, node.type_name, "gcp.monitoring.AlertPolicy")) return .alert_policy;
    if (std.mem.eql(u8, node.type_name, "gcp.monitoring.UptimeCheck")) return .uptime_check;
    if (std.mem.eql(u8, node.type_name, "gcp.monitoring.NotificationChannel")) return .notification_channel;
    if (std.mem.eql(u8, node.type_name, "gcp.monitoring.Dashboard")) return .dashboard;
    if (std.mem.eql(u8, node.type_name, "gcp.monitoring.Service")) return .service;
    if (std.mem.eql(u8, node.type_name, "gcp.monitoring.ServiceLevelObjective")) return .service_level_objective;
    return null;
}

fn createPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    const project = try requiredString(node.inputs, "project_id");
    const name = try requiredString(node.inputs, "name");
    return switch (kind) {
        .alert_policy => std.fmt.allocPrint(allocator, "/v3/projects/{s}/alertPolicies", .{project}),
        .uptime_check => std.fmt.allocPrint(allocator, "/v3/projects/{s}/uptimeCheckConfigs", .{project}),
        .notification_channel => std.fmt.allocPrint(allocator, "/v3/projects/{s}/notificationChannels", .{project}),
        .dashboard => std.fmt.allocPrint(allocator, "/v1/projects/{s}/dashboards", .{project}),
        .service => std.fmt.allocPrint(allocator, "/v3/projects/{s}/services?serviceId={s}", .{ project, name }),
        .service_level_objective => std.fmt.allocPrint(allocator, "/v3/projects/{s}/services/{s}/serviceLevelObjectives?serviceLevelObjectiveId={s}", .{ project, try requiredString(node.inputs, "service_name"), name }),
    } catch return error.OutOfMemory;
}

fn readPathAlloc(allocator: std.mem.Allocator, kind: Kind, physical: []const u8) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "/{s}/{s}", .{ if (kind == .dashboard) "v1" else "v3", physical }) catch return error.OutOfMemory;
}

fn updatePathAlloc(allocator: std.mem.Allocator, kind: Kind, physical: []const u8) ProviderError![]const u8 {
    const mask = switch (kind) {
        .alert_policy => "alertStrategy%2Ccombiner%2Cconditions%2CdisplayName%2Cdocumentation%2Cenabled%2CnotificationChannels%2Cseverity%2CuserLabels",
        .uptime_check => "checkerType%2CcontentMatchers%2Cdisabled%2CdisplayName%2ChttpCheck%2ClogCheckFailures%2CmonitoredResource%2Cperiod%2CselectedRegions%2CtcpCheck%2Ctimeout%2CuserLabels",
        .notification_channel => "description%2CdisplayName%2Cenabled%2Clabels%2Ctype%2CuserLabels",
        .dashboard => "displayName%2Clabels%2CmosaicLayout",
        .service => "displayName%2CuserLabels",
        .service_level_objective => "displayName%2Cgoal%2CserviceLevelIndicator%2CrollingPeriod%2CcalendarPeriod%2CuserLabels",
    };
    return std.fmt.allocPrint(allocator, "/{s}/{s}?updateMask={s}", .{ if (kind == .dashboard) "v1" else "v3", physical, mask }) catch return error.OutOfMemory;
}

fn physicalForReadAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind, physical_override: ?[]const u8) ProviderError![]const u8 {
    if (physical_override) |physical| {
        try validatePhysical(allocator, node, kind, physical);
        return allocator.dupe(u8, physical) catch return error.OutOfMemory;
    }
    return switch (kind) {
        .service, .service_level_objective => stablePhysicalAlloc(allocator, node, kind),
        .alert_policy, .uptime_check, .notification_channel, .dashboard => error.InvalidConfiguration,
    };
}

fn stablePhysicalAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    const project = try requiredString(node.inputs, "project_id");
    const name = try requiredString(node.inputs, "name");
    return switch (kind) {
        .service => std.fmt.allocPrint(allocator, "projects/{s}/services/{s}", .{ project, name }),
        .service_level_objective => std.fmt.allocPrint(allocator, "projects/{s}/services/{s}/serviceLevelObjectives/{s}", .{ project, try requiredString(node.inputs, "service_name"), name }),
        else => error.InvalidConfiguration,
    } catch return error.OutOfMemory;
}

fn validatePhysical(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind, physical: []const u8) ProviderError!void {
    if (kind == .service or kind == .service_level_objective) {
        const expected = try stablePhysicalAlloc(allocator, node, kind);
        defer allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical)) return error.InvalidConfiguration;
        return;
    }
    const project = try requiredString(node.inputs, "project_id");
    const collection = switch (kind) {
        .alert_policy => "alertPolicies",
        .uptime_check => "uptimeCheckConfigs",
        .notification_channel => "notificationChannels",
        .dashboard => "dashboards",
        else => unreachable,
    };
    const prefix = try std.fmt.allocPrint(allocator, "projects/{s}/{s}/", .{ project, collection });
    defer allocator.free(prefix);
    if (!std.mem.startsWith(u8, physical, prefix) or physical.len == prefix.len or std.mem.indexOfScalar(u8, physical[prefix.len..], '/') != null) return error.InvalidConfiguration;
}

fn driftedInputsAlloc(allocator: std.mem.Allocator, inputs: value.Value) !value.Value {
    const source = switch (inputs) {
        .object => |fields| fields,
        else => return error.InvalidConfiguration,
    };
    const fields = try allocator.alloc(value.Field, source.len + 1);
    defer allocator.free(fields);
    @memcpy(fields[0..source.len], source);
    fields[source.len] = .{ .name = "_remote_drift", .value = .{ .boolean = true } };
    return value.Value.initOwned(allocator, .{ .object = fields });
}

fn jsonSubset(remote: std.json.Value, desired: std.json.Value) bool {
    return switch (desired) {
        .null => remote == .null,
        .bool => |expected| remote == .bool and remote.bool == expected,
        .integer => |expected| switch (remote) {
            .integer => |actual| actual == expected,
            .float => |actual| actual == @as(f64, @floatFromInt(expected)),
            else => false,
        },
        .float => |expected| switch (remote) {
            .integer => |actual| @as(f64, @floatFromInt(actual)) == expected,
            .float => |actual| @abs(actual - expected) < 0.0000001,
            else => false,
        },
        .number_string => |expected| remote == .number_string and std.mem.eql(u8, remote.number_string, expected),
        .string => |expected| remote == .string and std.mem.eql(u8, remote.string, expected),
        .array => |expected| blk: {
            if (remote != .array or remote.array.items.len != expected.items.len) break :blk false;
            for (remote.array.items, expected.items) |actual, wanted| if (!jsonSubset(actual, wanted)) break :blk false;
            break :blk true;
        },
        .object => |expected| blk: {
            if (remote != .object) break :blk false;
            var iterator = expected.iterator();
            while (iterator.next()) |entry| {
                const actual = remote.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!jsonSubset(actual, entry.value_ptr.*)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn stringMapAlloc(allocator: std.mem.Allocator, fields: []const value.Field) ProviderError!std.json.ObjectMap {
    var result = std.json.ObjectMap.empty;
    for (fields) |field| try result.put(allocator, field.name, .{ .string = valueString(field.value) orelse return error.InvalidConfiguration });
    return result;
}

fn stringArrayAlloc(context: *provider_mod.OperationContext, allocator: std.mem.Allocator, values: []const value.Value) ProviderError!std.json.Array {
    var result = std.json.Array.init(allocator);
    for (values) |candidate| try result.append(.{ .string = try resolveString(context, candidate) });
    return result;
}

fn stringArrayAllocNoContext(allocator: std.mem.Allocator, values: []const value.Value) ProviderError!std.json.Array {
    var result = std.json.Array.init(allocator);
    for (values) |candidate| try result.append(.{ .string = valueString(candidate) orelse return error.InvalidConfiguration });
    return result;
}

fn contentMatchersAlloc(allocator: std.mem.Allocator, matchers: []const value.Value) ProviderError!std.json.Array {
    var result = std.json.Array.init(allocator);
    for (matchers) |candidate| {
        const matcher = valueObject(candidate) orelse return error.InvalidConfiguration;
        var encoded = std.json.ObjectMap.empty;
        try encoded.put(allocator, "content", .{ .string = requiredObjectString(matcher, "content") });
        try encoded.put(allocator, "matcher", .{ .string = requiredObjectString(matcher, "matcher") });
        const path = requiredObjectString(matcher, "json_path");
        if (path.len != 0) try encoded.put(allocator, "jsonPath", .{ .string = path });
        try result.append(.{ .object = encoded });
    }
    return result;
}

fn statusClassesAlloc(allocator: std.mem.Allocator, classes: []const value.Value) ProviderError!std.json.Array {
    var result = std.json.Array.init(allocator);
    for (classes) |candidate| {
        const number = valueInteger(candidate) orelse return error.InvalidConfiguration;
        const text = try std.fmt.allocPrint(allocator, "STATUS_CLASS_{d}XX", .{number});
        var encoded = std.json.ObjectMap.empty;
        try encoded.put(allocator, "statusClass", .{ .string = text });
        try result.append(.{ .object = encoded });
    }
    return result;
}

fn durationAlloc(allocator: std.mem.Allocator, seconds: i64) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}s", .{seconds}) catch return error.OutOfMemory;
}

fn durationMicrosAlloc(allocator: std.mem.Allocator, micros: i64) ProviderError![]const u8 {
    const seconds = @as(f64, @floatFromInt(micros)) / 1_000_000.0;
    return std.fmt.allocPrint(allocator, "{d:.6}s", .{seconds}) catch return error.OutOfMemory;
}

fn jsonStringFieldAlloc(allocator: std.mem.Allocator, body: []const u8, name: []const u8) ProviderError![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    return allocator.dupe(u8, jsonString(root.get(name)) orelse return error.ProviderBug) catch return error.OutOfMemory;
}

fn resolveString(context: *provider_mod.OperationContext, candidate: value.Value) ProviderError![]const u8 {
    return switch (candidate) {
        .string => |text| text,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}

fn requiredValue(inputs: value.Value, name: []const u8) ProviderError!value.Value {
    const fields = valueObject(inputs) orelse return error.InvalidConfiguration;
    return objectField(fields, name) orelse error.InvalidConfiguration;
}

fn requiredString(inputs: value.Value, name: []const u8) ProviderError![]const u8 {
    return valueString(try requiredValue(inputs, name)) orelse error.InvalidConfiguration;
}

fn requiredInteger(inputs: value.Value, name: []const u8) ProviderError!i64 {
    return valueInteger(try requiredValue(inputs, name)) orelse error.InvalidConfiguration;
}

fn requiredBoolean(inputs: value.Value, name: []const u8) bool {
    return valueBoolean(requiredValue(inputs, name) catch return false) orelse false;
}

fn requiredObject(inputs: value.Value, name: []const u8) ProviderError![]const value.Field {
    return valueObject(try requiredValue(inputs, name)) orelse error.InvalidConfiguration;
}

fn requiredList(inputs: value.Value, name: []const u8) ProviderError![]const value.Value {
    return valueList(try requiredValue(inputs, name)) orelse error.InvalidConfiguration;
}

fn requiredObjectValue(fields: []const value.Field, name: []const u8) value.Value {
    return objectField(fields, name) orelse unreachable;
}

fn requiredObjectString(fields: []const value.Field, name: []const u8) []const u8 {
    return valueString(requiredObjectValue(fields, name)) orelse unreachable;
}

fn requiredObjectInteger(fields: []const value.Field, name: []const u8) i64 {
    return valueInteger(requiredObjectValue(fields, name)) orelse unreachable;
}

fn requiredObjectBoolean(fields: []const value.Field, name: []const u8) bool {
    return valueBoolean(requiredObjectValue(fields, name)) orelse unreachable;
}

fn objectField(fields: []const value.Field, name: []const u8) ?value.Value {
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return null;
}

fn valueObject(candidate: value.Value) ?[]const value.Field {
    return switch (candidate) {
        .object => |fields| fields,
        else => null,
    };
}

fn valueList(candidate: value.Value) ?[]const value.Value {
    return switch (candidate) {
        .list => |items| items,
        else => null,
    };
}

fn valueString(candidate: value.Value) ?[]const u8 {
    return switch (candidate) {
        .string => |text| text,
        else => null,
    };
}

fn valueInteger(candidate: value.Value) ?i64 {
    return switch (candidate) {
        .integer => |number| number,
        else => null,
    };
}

fn valueBoolean(candidate: value.Value) ?bool {
    return switch (candidate) {
        .boolean => |flag| flag,
        else => null,
    };
}

fn inputChanged(desired: value.Value, observed: value.Value, name: []const u8) bool {
    const left = requiredValue(desired, name) catch return true;
    const right = requiredValue(observed, name) catch return true;
    const left_json = left.canonicalJsonAlloc(std.heap.page_allocator) catch return true;
    defer std.heap.page_allocator.free(left_json);
    const right_json = right.canonicalJsonAlloc(std.heap.page_allocator) catch return true;
    defer std.heap.page_allocator.free(right_json);
    return !std.mem.eql(u8, left_json, right_json);
}

fn jsonObject(candidate: std.json.Value) ?std.json.ObjectMap {
    return switch (candidate) {
        .object => |object| object,
        else => null,
    };
}

fn jsonString(candidate: ?std.json.Value) ?[]const u8 {
    const present = candidate orelse return null;
    return switch (present) {
        .string => |text| text,
        else => null,
    };
}
