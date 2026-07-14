const std = @import("std");
const aip = @import("aip.zig");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;

const Kind = enum { pipeline, target, custom_target_type, automation, deploy_policy };

pub const Handler = struct {
    client: *client_mod.Client,
    operation_policy: operation.Policy = .{},

    pub fn supports(node: resource.ResourceNode) bool {
        return kindOf(node) != null;
    }

    pub fn read(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (context.operation_handle) |handle| try self.waitOperation(context, handle);
        const expected = try physicalAlloc(context.allocator, node, kind);
        defer context.allocator.free(expected);
        const physical = physical_override orelse context.physical_id orelse expected;
        try validatePhysical(node, kind, physical);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical});
        defer context.allocator.free(path);
        var response = self.request(context, "GET", path, "") catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try resultFromJson(context, node, kind, physical, response.body) };
    }

    pub fn diff(context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(node, kind, observed.physical_id);
        if (identityChanged(node, observed, identityFields(kind)))
            return provider_mod.DiffResult.init(context.allocator, .replace, &.{"Cloud Deploy resource identity changed"});

        const desired_json = try bodyJsonAlloc(context, node, kind, null);
        defer context.allocator.free(desired_json);
        const remote_json = outputString(observed.*, "__remote_spec") orelse {
            if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash))
                return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
            return provider_mod.DiffResult.init(context.allocator, .update, &.{"Cloud Deploy configuration differs"});
        };
        var desired = value.Value.parseJsonAlloc(context.allocator, desired_json) catch return error.ProviderBug;
        defer desired.deinit(context.allocator);
        var remote = value.Value.parseJsonAlloc(context.allocator, remote_json) catch return error.ProviderBug;
        defer remote.deinit(context.allocator);

        if (kind == .target and runtimeChanged(desired, remote))
            return provider_mod.DiffResult.init(context.allocator, .replace, &.{"Cloud Deploy target runtime changed"});
        const mask = try changedMaskAlloc(context.allocator, kind, desired, remote);
        defer context.allocator.free(mask);
        if (mask.len == 0) return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        return provider_mod.DiffResult.init(context.allocator, .update, &.{"Cloud Deploy configuration differs"});
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        const path = try createPathAlloc(context.allocator, node, kind);
        defer context.allocator.free(path);
        const body = try bodyJsonAlloc(context, node, kind, null);
        defer context.allocator.free(body);
        var response = try self.request(context, "POST", path, body);
        defer response.deinit(context.allocator);
        return pendingResult(context, node, kind, response.body);
    }

    pub fn update(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(node, kind, observed.physical_id);
        var classification = try Handler.diff(context, node, observed);
        defer classification.deinit();
        if (classification.kind != .update) return error.InvalidConfiguration;
        const desired_json = try bodyJsonAlloc(context, node, kind, null);
        defer context.allocator.free(desired_json);
        const remote_json = outputString(observed.*, "__remote_spec") orelse return error.InvalidConfiguration;
        var desired = value.Value.parseJsonAlloc(context.allocator, desired_json) catch return error.ProviderBug;
        defer desired.deinit(context.allocator);
        var remote = value.Value.parseJsonAlloc(context.allocator, remote_json) catch return error.ProviderBug;
        defer remote.deinit(context.allocator);
        const mask = try changedMaskAlloc(context.allocator, kind, desired, remote);
        defer context.allocator.free(mask);
        const encoded_mask = try percentEncodeAlloc(context.allocator, mask);
        defer context.allocator.free(encoded_mask);
        var request_id: [36]u8 = undefined;
        aip.requestId("ziac", node.id, "update", &request_id);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}?updateMask={s}&requestId={s}", .{ observed.physical_id, encoded_mask, request_id[0..] });
        defer context.allocator.free(path);
        const etag = outputString(observed.*, "etag") orelse return error.Conflict;
        const body = try bodyJsonAlloc(context, node, kind, etag);
        defer context.allocator.free(body);
        var response = try self.request(context, "PATCH", path, body);
        defer response.deinit(context.allocator);
        return pendingResult(context, node, kind, response.body);
    }

    pub fn delete(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical: []const u8) ProviderError!void {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(node, kind, physical);
        var current = try self.read(context, node, physical);
        defer current.deinit();
        const etag = switch (current) {
            .absent => return,
            .present => |present| outputString(present, "etag") orelse return error.Conflict,
        };
        const encoded_etag = try percentEncodeAlloc(context.allocator, etag);
        defer context.allocator.free(encoded_etag);
        var request_id: [36]u8 = undefined;
        aip.requestId("ziac", node.id, "delete", &request_id);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}?etag={s}&validateOnly=false&requestId={s}", .{ physical, encoded_etag, request_id[0..] });
        defer context.allocator.free(path);
        var response = self.request(context, "DELETE", path, "") catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer response.deinit(context.allocator);
        const handle = try operationNameAlloc(context.allocator, response.body);
        defer context.allocator.free(handle);
        try self.waitOperation(context, handle);
    }

    pub fn importResource(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical: []const u8) ProviderError!provider_mod.ResourceResult {
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(node, kind, physical);
        var result = try self.read(context, node, physical);
        defer result.deinit();
        return switch (result) {
            .absent => error.NotFound,
            .present => |present| present.clone(context.allocator),
        };
    }

    fn waitOperation(self: Handler, context: *provider_mod.OperationContext, handle: []const u8) ProviderError!void {
        const base = try std.fmt.allocPrint(context.allocator, "{s}/v1", .{std.mem.trimEnd(u8, self.client.endpoints.cloud_deploy, "/")});
        defer context.allocator.free(base);
        var target = operation.Target.genericAlloc(context.allocator, base, handle) catch return error.OutOfMemory;
        defer target.deinit(context.allocator);
        var completed = try operation.waitAlloc(self.client, context, target, self.operation_policy);
        completed.deinit(context.allocator);
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, method: []const u8, path: []const u8, body: []const u8) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, .{ .api = .cloud_deploy, .method = method, .path = path, .body = body }, &diagnostic);
    }
};

fn kindOf(node: resource.ResourceNode) ?Kind {
    const mappings = [_]struct { type_name: []const u8, kind: Kind }{
        .{ .type_name = "gcp.deploy.DeliveryPipeline", .kind = .pipeline },
        .{ .type_name = "gcp.deploy.Target", .kind = .target },
        .{ .type_name = "gcp.deploy.CustomTargetType", .kind = .custom_target_type },
        .{ .type_name = "gcp.deploy.Automation", .kind = .automation },
        .{ .type_name = "gcp.deploy.DeployPolicy", .kind = .deploy_policy },
    };
    for (mappings) |mapping| if (std.mem.eql(u8, node.type_name, mapping.type_name)) return mapping.kind;
    return null;
}

fn collection(kind: Kind) []const u8 {
    return switch (kind) {
        .pipeline => "deliveryPipelines",
        .target => "targets",
        .custom_target_type => "customTargetTypes",
        .automation => "automations",
        .deploy_policy => "deployPolicies",
    };
}

fn idParameter(kind: Kind) []const u8 {
    return switch (kind) {
        .pipeline => "deliveryPipelineId",
        .target => "targetId",
        .custom_target_type => "customTargetTypeId",
        .automation => "automationId",
        .deploy_policy => "deployPolicyId",
    };
}

fn physicalAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    const project = try requiredString(node.inputs, "project_id");
    const location = try requiredString(node.inputs, "location");
    const name = try requiredString(node.inputs, "name");
    if (kind == .automation) return std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}/deliveryPipelines/{s}/automations/{s}", .{ project, location, try requiredString(node.inputs, "pipeline_name"), name }) catch error.OutOfMemory;
    return std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}/{s}/{s}", .{ project, location, collection(kind), name }) catch error.OutOfMemory;
}

fn validatePhysical(node: resource.ResourceNode, kind: Kind, physical: []const u8) ProviderError!void {
    if (std.mem.indexOfAny(u8, physical, "?# \t\r\n") != null) return error.InvalidConfiguration;
    const expected = try physicalAlloc(std.heap.page_allocator, node, kind);
    defer std.heap.page_allocator.free(expected);
    if (!std.mem.eql(u8, expected, physical)) return error.InvalidConfiguration;
}

fn createPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    const project = try requiredString(node.inputs, "project_id");
    const location = try requiredString(node.inputs, "location");
    const name = try requiredString(node.inputs, "name");
    var request_id: [36]u8 = undefined;
    aip.requestId("ziac", node.id, "create", &request_id);
    if (kind == .automation) return std.fmt.allocPrint(allocator, "/v1/projects/{s}/locations/{s}/deliveryPipelines/{s}/automations?{s}={s}&requestId={s}", .{ project, location, try requiredString(node.inputs, "pipeline_name"), idParameter(kind), name, request_id[0..] }) catch error.OutOfMemory;
    return std.fmt.allocPrint(allocator, "/v1/projects/{s}/locations/{s}/{s}?{s}={s}&requestId={s}", .{ project, location, collection(kind), idParameter(kind), name, request_id[0..] }) catch error.OutOfMemory;
}

fn pendingResult(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, body: []const u8) ProviderError!provider_mod.ResourceResult {
    const handle = try operationNameAlloc(context.allocator, body);
    defer context.allocator.free(handle);
    const physical = try physicalAlloc(context.allocator, node, kind);
    defer context.allocator.free(physical);
    const outputs = [_]state.StateOutput{.{ .name = "name", .value = .{ .unknown_reason = "Cloud Deploy operation pending" } }};
    var result = try provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &outputs, handle);
    result.completed = false;
    return result;
}

fn operationNameAlloc(allocator: std.mem.Allocator, body: []const u8) ProviderError![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const name = jsonString(root.get("name")) orelse return error.ProviderBug;
    if (std.mem.indexOf(u8, name, "/operations/") == null) return error.ProviderBug;
    return allocator.dupe(u8, name) catch error.OutOfMemory;
}

fn bodyJsonAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, etag: ?[]const u8) ProviderError![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = std.json.ObjectMap.empty;
    try root.put(arena, "annotations", try valueJson(context, arena, try requiredValue(node.inputs, "annotations")));
    try root.put(arena, "description", .{ .string = try requiredString(node.inputs, "description") });
    try root.put(arena, "labels", try valueJson(context, arena, try requiredValue(node.inputs, "labels")));
    switch (kind) {
        .pipeline => {
            var serial = std.json.ObjectMap.empty;
            try serial.put(arena, "stages", try stagesJson(context, arena, try requiredValue(node.inputs, "stages")));
            try root.put(arena, "serialPipeline", .{ .object = serial });
            try root.put(arena, "suspended", .{ .bool = try requiredBoolean(node.inputs, "suspended") });
        },
        .target => {
            try root.put(arena, "deployParameters", try valueJson(context, arena, try requiredValue(node.inputs, "deploy_parameters")));
            try root.put(arena, "executionConfigs", try executionJson(context, arena, try requiredValue(node.inputs, "execution")));
            try root.put(arena, "requireApproval", .{ .bool = try requiredBoolean(node.inputs, "require_approval") });
            try targetRuntimeJson(context, arena, &root, try requiredValue(node.inputs, "runtime"));
        },
        .custom_target_type => {
            var actions = std.json.ObjectMap.empty;
            try actions.put(arena, "deployAction", .{ .string = try requiredString(node.inputs, "deploy_action") });
            const render = try requiredString(node.inputs, "render_action");
            if (render.len != 0) try actions.put(arena, "renderAction", .{ .string = render });
            const modules = try requiredValue(node.inputs, "include_modules");
            if (listLen(modules) != 0) {
                var module = std.json.ObjectMap.empty;
                try module.put(arena, "configs", try valueJson(context, arena, modules));
                var list = std.json.Array.init(arena);
                try list.append(.{ .object = module });
                try actions.put(arena, "includeSkaffoldModules", .{ .array = list });
            }
            try root.put(arena, "customActions", .{ .object = actions });
        },
        .automation => {
            try root.put(arena, "rules", try automationRulesJson(context, arena, try requiredValue(node.inputs, "rules")));
            var selector = std.json.ObjectMap.empty;
            var targets = std.json.Array.init(arena);
            const target_ids = valueList(try requiredValue(node.inputs, "target_ids")) orelse return error.InvalidConfiguration;
            for (target_ids) |target_id| {
                var attribute = std.json.ObjectMap.empty;
                try attribute.put(arena, "id", .{ .string = valueString(target_id) orelse return error.InvalidConfiguration });
                try targets.append(.{ .object = attribute });
            }
            try selector.put(arena, "targets", .{ .array = targets });
            try root.put(arena, "selector", .{ .object = selector });
            try root.put(arena, "serviceAccount", .{ .string = try requiredString(node.inputs, "service_account") });
            try root.put(arena, "suspended", .{ .bool = try requiredBoolean(node.inputs, "suspended") });
        },
        .deploy_policy => {
            try root.put(arena, "rules", try policyRulesJson(context, arena, try requiredValue(node.inputs, "rules")));
            try root.put(arena, "selectors", try policySelectorsJson(context, arena, try requiredValue(node.inputs, "selectors")));
            try root.put(arena, "suspended", .{ .bool = try requiredBoolean(node.inputs, "suspended") });
        },
    }
    if (etag) |present| try root.put(arena, "etag", .{ .string = present });
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch error.OutOfMemory;
}

fn stagesJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    var output = std.json.Array.init(arena);
    for (valueList(input) orelse return error.InvalidConfiguration) |item| {
        const fields = valueObject(item) orelse return error.InvalidConfiguration;
        var stage = std.json.ObjectMap.empty;
        const target = try resolveString(context, try requiredObjectValue(fields, "target"));
        try stage.put(arena, "targetId", .{ .string = resourceBasename(target) });
        try stage.put(arena, "profiles", try valueJson(context, arena, try requiredObjectValue(fields, "profiles")));
        var deploy_parameters = std.json.Array.init(arena);
        const parameters = try requiredObjectValue(fields, "deploy_parameters");
        if (objectLen(parameters) != 0) {
            var entry = std.json.ObjectMap.empty;
            try entry.put(arena, "values", try valueJson(context, arena, parameters));
            try deploy_parameters.append(.{ .object = entry });
        }
        try stage.put(arena, "deployParameters", .{ .array = deploy_parameters });
        try stage.put(arena, "strategy", try strategyJson(context, arena, try requiredObjectValue(fields, "strategy")));
        try output.append(.{ .object = stage });
    }
    return .{ .array = output };
}

fn strategyJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    const fields = valueObject(input) orelse return error.InvalidConfiguration;
    const kind = try requiredObjectString(fields, "kind");
    var strategy = std.json.ObjectMap.empty;
    if (std.mem.eql(u8, kind, "standard")) {
        var standard = std.json.ObjectMap.empty;
        try standard.put(arena, "verify", .{ .bool = try requiredObjectBoolean(fields, "verify") });
        try addActions(arena, &standard, "predeploy", try requiredObjectValue(fields, "predeploy_actions"));
        try addActions(arena, &standard, "postdeploy", try requiredObjectValue(fields, "postdeploy_actions"));
        try strategy.put(arena, "standard", .{ .object = standard });
    } else if (std.mem.eql(u8, kind, "canary")) {
        var deployment = std.json.ObjectMap.empty;
        try deployment.put(arena, "percentages", try valueJson(context, arena, try requiredObjectValue(fields, "percentages")));
        try deployment.put(arena, "verify", .{ .bool = try requiredObjectBoolean(fields, "verify") });
        try addActions(arena, &deployment, "predeploy", try requiredObjectValue(fields, "predeploy_actions"));
        try addActions(arena, &deployment, "postdeploy", try requiredObjectValue(fields, "postdeploy_actions"));
        var canary = std.json.ObjectMap.empty;
        try canary.put(arena, "canaryDeployment", .{ .object = deployment });
        try strategy.put(arena, "canary", .{ .object = canary });
    } else if (std.mem.eql(u8, kind, "custom_canary")) {
        var phases = std.json.Array.init(arena);
        for (valueList(try requiredObjectValue(fields, "phases")) orelse return error.InvalidConfiguration) |phase_value| {
            const phase_fields = valueObject(phase_value) orelse return error.InvalidConfiguration;
            var phase = std.json.ObjectMap.empty;
            try phase.put(arena, "phaseId", .{ .string = try requiredObjectString(phase_fields, "id") });
            try phase.put(arena, "percentage", .{ .integer = try requiredObjectInteger(phase_fields, "percentage") });
            try phase.put(arena, "profiles", try valueJson(context, arena, try requiredObjectValue(phase_fields, "profiles")));
            try phase.put(arena, "verify", .{ .bool = try requiredObjectBoolean(phase_fields, "verify") });
            try phases.append(.{ .object = phase });
        }
        var custom = std.json.ObjectMap.empty;
        try custom.put(arena, "phaseConfigs", .{ .array = phases });
        var canary = std.json.ObjectMap.empty;
        try canary.put(arena, "customCanaryDeployment", .{ .object = custom });
        try strategy.put(arena, "canary", .{ .object = canary });
    } else return error.InvalidConfiguration;
    return .{ .object = strategy };
}

fn addActions(arena: std.mem.Allocator, parent: *std.json.ObjectMap, name: []const u8, actions: value.Value) ProviderError!void {
    if (listLen(actions) == 0) return;
    var job = std.json.ObjectMap.empty;
    try job.put(arena, "actions", try valueJsonNoContext(arena, actions));
    try parent.put(arena, name, .{ .object = job });
}

fn executionJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    var output = std.json.Array.init(arena);
    for (valueList(input) orelse return error.InvalidConfiguration) |item| {
        const fields = valueObject(item) orelse return error.InvalidConfiguration;
        var config = std.json.ObjectMap.empty;
        try config.put(arena, "usages", try valueJson(context, arena, try requiredObjectValue(fields, "usages")));
        const service_account = try requiredObjectString(fields, "service_account");
        if (service_account.len != 0) try config.put(arena, "serviceAccount", .{ .string = service_account });
        const artifact_storage = try requiredObjectString(fields, "artifact_storage");
        if (artifact_storage.len != 0) try config.put(arena, "artifactStorage", .{ .string = artifact_storage });
        const pool = try resolveString(context, try requiredObjectValue(fields, "worker_pool"));
        if (pool.len != 0) try config.put(arena, "workerPool", .{ .string = pool }) else try config.put(arena, "defaultPool", .{ .object = std.json.ObjectMap.empty });
        const timeout = try requiredObjectInteger(fields, "timeout_seconds");
        try config.put(arena, "executionTimeout", .{ .string = try std.fmt.allocPrint(arena, "{d}s", .{timeout}) });
        try config.put(arena, "verbose", .{ .bool = try requiredObjectBoolean(fields, "verbose") });
        try output.append(.{ .object = config });
    }
    return .{ .array = output };
}

fn targetRuntimeJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, root: *std.json.ObjectMap, input: value.Value) ProviderError!void {
    const fields = valueObject(input) orelse return error.InvalidConfiguration;
    const kind = try requiredObjectString(fields, "kind");
    var runtime = std.json.ObjectMap.empty;
    if (std.mem.eql(u8, kind, "cloud_run")) {
        try runtime.put(arena, "location", .{ .string = try requiredObjectString(fields, "location") });
        try root.put(arena, "run", .{ .object = runtime });
    } else if (std.mem.eql(u8, kind, "gke")) {
        try runtime.put(arena, "cluster", .{ .string = try resolveString(context, try requiredObjectValue(fields, "cluster")) });
        try runtime.put(arena, "internalIp", .{ .bool = try requiredObjectBoolean(fields, "internal_ip") });
        try runtime.put(arena, "dnsEndpoint", .{ .bool = try requiredObjectBoolean(fields, "dns_endpoint") });
        const proxy = try requiredObjectString(fields, "proxy_url");
        if (proxy.len != 0) try runtime.put(arena, "proxyUrl", .{ .string = proxy });
        try root.put(arena, "gke", .{ .object = runtime });
    } else if (std.mem.eql(u8, kind, "anthos")) {
        try runtime.put(arena, "membership", .{ .string = try resolveString(context, try requiredObjectValue(fields, "membership")) });
        try root.put(arena, "anthosCluster", .{ .object = runtime });
    } else if (std.mem.eql(u8, kind, "multi")) {
        var ids = std.json.Array.init(arena);
        for (valueList(try requiredObjectValue(fields, "targets")) orelse return error.InvalidConfiguration) |target| try ids.append(.{ .string = resourceBasename(try resolveString(context, target)) });
        try runtime.put(arena, "targetIds", .{ .array = ids });
        try root.put(arena, "multiTarget", .{ .object = runtime });
    } else if (std.mem.eql(u8, kind, "custom")) {
        try runtime.put(arena, "customTargetType", .{ .string = try resolveString(context, try requiredObjectValue(fields, "target_type")) });
        try root.put(arena, "customTarget", .{ .object = runtime });
    } else return error.InvalidConfiguration;
}

fn automationRulesJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    var output = std.json.Array.init(arena);
    for (valueList(input) orelse return error.InvalidConfiguration) |item| {
        const fields = valueObject(item) orelse return error.InvalidConfiguration;
        const kind = try requiredObjectString(fields, "kind");
        var rule = std.json.ObjectMap.empty;
        var config = std.json.ObjectMap.empty;
        try config.put(arena, "id", .{ .string = try requiredObjectString(fields, "id") });
        if (std.mem.eql(u8, kind, "promote") or std.mem.eql(u8, kind, "timed_promote")) {
            try config.put(arena, "destinationTargetId", .{ .string = try requiredObjectString(fields, "destination_target_id") });
            const phase = try requiredObjectString(fields, "destination_phase");
            if (phase.len != 0) try config.put(arena, "destinationPhase", .{ .string = phase });
            if (std.mem.eql(u8, kind, "promote")) {
                try addDuration(arena, &config, "wait", try requiredObjectInteger(fields, "wait_seconds"));
                try rule.put(arena, "promoteReleaseRule", .{ .object = config });
            } else {
                try config.put(arena, "schedule", .{ .string = try requiredObjectString(fields, "schedule") });
                try config.put(arena, "timeZone", .{ .string = try requiredObjectString(fields, "time_zone") });
                try rule.put(arena, "timedPromoteReleaseRule", .{ .object = config });
            }
        } else if (std.mem.eql(u8, kind, "advance")) {
            try config.put(arena, "sourcePhases", try valueJson(context, arena, try requiredObjectValue(fields, "source_phases")));
            try addDuration(arena, &config, "wait", try requiredObjectInteger(fields, "wait_seconds"));
            try rule.put(arena, "advanceRolloutRule", .{ .object = config });
        } else if (std.mem.eql(u8, kind, "repair")) {
            try config.put(arena, "phases", try valueJson(context, arena, try requiredObjectValue(fields, "phases")));
            try config.put(arena, "jobs", try valueJson(context, arena, try requiredObjectValue(fields, "jobs")));
            var repair_phases = std.json.Array.init(arena);
            const attempts = try requiredObjectInteger(fields, "retry_attempts");
            if (attempts != 0) {
                var phase = std.json.ObjectMap.empty;
                var retry = std.json.ObjectMap.empty;
                try retry.put(arena, "attempts", .{ .string = try std.fmt.allocPrint(arena, "{d}", .{attempts}) });
                try addDuration(arena, &retry, "wait", try requiredObjectInteger(fields, "retry_wait_seconds"));
                const backoff = try requiredObjectString(fields, "backoff");
                try retry.put(arena, "backoffMode", .{ .string = if (std.mem.eql(u8, backoff, "exponential")) "BACKOFF_MODE_EXPONENTIAL" else "BACKOFF_MODE_LINEAR" });
                try phase.put(arena, "retry", .{ .object = retry });
                try repair_phases.append(.{ .object = phase });
            }
            if (try requiredObjectBoolean(fields, "rollback")) {
                var phase = std.json.ObjectMap.empty;
                var rollback = std.json.ObjectMap.empty;
                try rollback.put(arena, "destinationPhase", .{ .string = try requiredObjectString(fields, "rollback_phase") });
                try rollback.put(arena, "disableRollbackIfRolloutPending", .{ .bool = try requiredObjectBoolean(fields, "disable_rollback_if_pending") });
                try phase.put(arena, "rollback", .{ .object = rollback });
                try repair_phases.append(.{ .object = phase });
            }
            try config.put(arena, "repairPhases", .{ .array = repair_phases });
            try rule.put(arena, "repairRolloutRule", .{ .object = config });
        } else return error.InvalidConfiguration;
        try output.append(.{ .object = rule });
    }
    return .{ .array = output };
}

fn policySelectorsJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    var output = std.json.Array.init(arena);
    for (valueList(input) orelse return error.InvalidConfiguration) |item| {
        const fields = valueObject(item) orelse return error.InvalidConfiguration;
        var selector = std.json.ObjectMap.empty;
        const pipeline_id = try requiredObjectString(fields, "pipeline_id");
        const pipeline_labels = try requiredObjectValue(fields, "pipeline_labels");
        if (pipeline_id.len != 0 or objectLen(pipeline_labels) != 0) {
            var attr = std.json.ObjectMap.empty;
            if (pipeline_id.len != 0) try attr.put(arena, "id", .{ .string = pipeline_id });
            if (objectLen(pipeline_labels) != 0) try attr.put(arena, "labels", try valueJson(context, arena, pipeline_labels));
            try selector.put(arena, "deliveryPipeline", .{ .object = attr });
        }
        const target_id = try requiredObjectString(fields, "target_id");
        const target_labels = try requiredObjectValue(fields, "target_labels");
        if (target_id.len != 0 or objectLen(target_labels) != 0) {
            var attr = std.json.ObjectMap.empty;
            if (target_id.len != 0) try attr.put(arena, "id", .{ .string = target_id });
            if (objectLen(target_labels) != 0) try attr.put(arena, "labels", try valueJson(context, arena, target_labels));
            try selector.put(arena, "target", .{ .object = attr });
        }
        try output.append(.{ .object = selector });
    }
    return .{ .array = output };
}

fn policyRulesJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    var output = std.json.Array.init(arena);
    for (valueList(input) orelse return error.InvalidConfiguration) |item| {
        const fields = valueObject(item) orelse return error.InvalidConfiguration;
        var restriction = std.json.ObjectMap.empty;
        try restriction.put(arena, "id", .{ .string = try requiredObjectString(fields, "id") });
        try restriction.put(arena, "invokers", try valueJson(context, arena, try requiredObjectValue(fields, "invokers")));
        try restriction.put(arena, "actions", try valueJson(context, arena, try requiredObjectValue(fields, "actions")));
        var windows = std.json.ObjectMap.empty;
        try windows.put(arena, "timeZone", .{ .string = try requiredObjectString(fields, "time_zone") });
        try windows.put(arena, "weeklyWindows", try weeklyWindowsJson(context, arena, try requiredObjectValue(fields, "weekly_windows")));
        try windows.put(arena, "oneTimeWindows", try oneTimeWindowsJson(context, arena, try requiredObjectValue(fields, "one_time_windows")));
        try restriction.put(arena, "timeWindows", .{ .object = windows });
        var rule = std.json.ObjectMap.empty;
        try rule.put(arena, "rolloutRestriction", .{ .object = restriction });
        try output.append(.{ .object = rule });
    }
    return .{ .array = output };
}

fn weeklyWindowsJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    var output = std.json.Array.init(arena);
    for (valueList(input) orelse return error.InvalidConfiguration) |item| {
        const fields = valueObject(item) orelse return error.InvalidConfiguration;
        var window = std.json.ObjectMap.empty;
        try window.put(arena, "daysOfWeek", try valueJson(context, arena, try requiredObjectValue(fields, "days")));
        try optionalTimeJson(arena, &window, "startTime", try requiredObjectValue(fields, "start"));
        try optionalTimeJson(arena, &window, "endTime", try requiredObjectValue(fields, "end"));
        try output.append(.{ .object = window });
    }
    return .{ .array = output };
}

fn oneTimeWindowsJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    var output = std.json.Array.init(arena);
    for (valueList(input) orelse return error.InvalidConfiguration) |item| {
        const fields = valueObject(item) orelse return error.InvalidConfiguration;
        var window = std.json.ObjectMap.empty;
        try window.put(arena, "startDate", try valueJson(context, arena, try requiredObjectValue(fields, "start_date")));
        try window.put(arena, "endDate", try valueJson(context, arena, try requiredObjectValue(fields, "end_date")));
        try window.put(arena, "startTime", try valueJson(context, arena, try requiredObjectValue(fields, "start")));
        try window.put(arena, "endTime", try valueJson(context, arena, try requiredObjectValue(fields, "end")));
        try output.append(.{ .object = window });
    }
    return .{ .array = output };
}

fn optionalTimeJson(arena: std.mem.Allocator, parent: *std.json.ObjectMap, name: []const u8, input: value.Value) ProviderError!void {
    if (objectLen(input) != 0) try parent.put(arena, name, try valueJsonNoContext(arena, input));
}

fn addDuration(arena: std.mem.Allocator, parent: *std.json.ObjectMap, name: []const u8, seconds: i64) ProviderError!void {
    if (seconds != 0) try parent.put(arena, name, .{ .string = try std.fmt.allocPrint(arena, "{d}s", .{seconds}) });
}

fn resultFromJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, physical: []const u8, body: []const u8) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    if (!std.mem.eql(u8, jsonString(root.get("name")) orelse return error.ProviderBug, physical)) return error.InvalidConfiguration;
    const desired_body = try bodyJsonAlloc(context, node, kind, null);
    defer context.allocator.free(desired_body);
    var desired_parsed = std.json.parseFromSlice(std.json.Value, context.allocator, desired_body, .{}) catch return error.ProviderBug;
    defer desired_parsed.deinit();
    const desired_root = jsonObject(desired_parsed.value) orelse return error.ProviderBug;
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var spec = std.json.ObjectMap.empty;
    for (managedFields(kind)) |field| {
        const desired_value = desired_root.get(field);
        const observed_value = root.get(field);
        if (desired_value == null and observed_value == null) continue;
        const remote_value = observed_value orelse zeroLike(desired_value.?, arena);
        try spec.put(arena, field, remote_value);
    }
    var spec_value = value.Value.fromJsonValueAlloc(context.allocator, .{ .object = spec }) catch return error.ProviderBug;
    defer spec_value.deinit(context.allocator);
    const canonical_spec = spec_value.canonicalJsonAlloc(context.allocator) catch return error.OutOfMemory;
    defer context.allocator.free(canonical_spec);
    const etag = jsonString(root.get("etag")) orelse "";
    const ready = if (kind == .pipeline) pipelineReady(root) else true;
    const outputs = [_]state.StateOutput{
        .{ .name = "name", .value = .{ .string = physical } },
        .{ .name = "etag", .value = .{ .string = etag } },
        .{ .name = "ready", .value = .{ .boolean = ready } },
        .{ .name = "__remote_spec", .value = .{ .string = canonical_spec } },
    };
    return provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &outputs, null);
}

fn pipelineReady(root: std.json.ObjectMap) bool {
    const condition = jsonObject(root.get("condition") orelse return true) orelse return true;
    const ready = jsonObject(condition.get("pipelineReadyCondition") orelse return true) orelse return true;
    return jsonBoolean(ready.get("status")) orelse true;
}

fn managedFields(kind: Kind) []const []const u8 {
    return switch (kind) {
        .pipeline => &.{ "annotations", "description", "labels", "serialPipeline", "suspended" },
        .target => &.{ "annotations", "deployParameters", "description", "executionConfigs", "labels", "requireApproval", "anthosCluster", "customTarget", "gke", "multiTarget", "run" },
        .custom_target_type => &.{ "annotations", "customActions", "description", "labels" },
        .automation => &.{ "annotations", "description", "labels", "rules", "selector", "serviceAccount", "suspended" },
        .deploy_policy => &.{ "annotations", "description", "labels", "rules", "selectors", "suspended" },
    };
}

fn identityFields(kind: Kind) []const []const u8 {
    return if (kind == .automation) &.{ "project_id", "location", "pipeline_name", "name" } else &.{ "project_id", "location", "name" };
}

fn runtimeChanged(desired: value.Value, remote: value.Value) bool {
    for ([_][]const u8{ "anthosCluster", "customTarget", "gke", "multiTarget", "run" }) |field| {
        const left = optionalField(desired, field);
        const right = optionalField(remote, field);
        if (!valuesEqual(left, right)) return true;
    }
    return false;
}

fn changedMaskAlloc(allocator: std.mem.Allocator, kind: Kind, desired: value.Value, remote: value.Value) ProviderError![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    for (managedFields(kind)) |field| {
        if (valuesEqual(optionalField(desired, field), optionalField(remote, field))) continue;
        if (output.items.len != 0) try output.append(allocator, ',');
        try output.appendSlice(allocator, field);
    }
    return output.toOwnedSlice(allocator) catch error.OutOfMemory;
}

fn valuesEqual(left: ?value.Value, right: ?value.Value) bool {
    if ((left == null) != (right == null)) return false;
    if (left == null) return true;
    const left_json = left.?.canonicalJsonAlloc(std.heap.page_allocator) catch return false;
    defer std.heap.page_allocator.free(left_json);
    const right_json = right.?.canonicalJsonAlloc(std.heap.page_allocator) catch return false;
    defer std.heap.page_allocator.free(right_json);
    return std.mem.eql(u8, left_json, right_json);
}

fn identityChanged(node: resource.ResourceNode, observed: *const provider_mod.ResourceResult, fields: []const []const u8) bool {
    for (fields) |field| if (!valuesEqual(optionalField(node.inputs, field), optionalField(observed.observed_inputs, field))) return true;
    return false;
}

fn optionalField(input: value.Value, name: []const u8) ?value.Value {
    const fields = valueObject(input) orelse return null;
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return null;
}

fn zeroLike(input: std.json.Value, arena: std.mem.Allocator) std.json.Value {
    return switch (input) {
        .string => .{ .string = "" },
        .integer, .float, .number_string => .{ .integer = 0 },
        .bool => .{ .bool = false },
        .array => .{ .array = std.json.Array.init(arena) },
        .object => .{ .object = std.json.ObjectMap.empty },
        .null => .null,
    };
}

fn valueJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    return switch (input) {
        .string => |text| .{ .string = text },
        .integer => |number| .{ .integer = number },
        .boolean => |flag| .{ .bool = flag },
        .output_ref => |reference| .{ .string = try context.resolveOutputString(reference) },
        .list => |items| blk: {
            var list = std.json.Array.init(arena);
            for (items) |item| try list.append(try valueJson(context, arena, item));
            break :blk .{ .array = list };
        },
        .object => |fields| blk: {
            var object = std.json.ObjectMap.empty;
            for (fields) |field| try object.put(arena, field.name, try valueJson(context, arena, field.value));
            break :blk .{ .object = object };
        },
        .secret_ref, .unknown_reason => error.InvalidConfiguration,
    };
}

fn valueJsonNoContext(arena: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    return switch (input) {
        .string => |text| .{ .string = text },
        .integer => |number| .{ .integer = number },
        .boolean => |flag| .{ .bool = flag },
        .list => |items| blk: {
            var list = std.json.Array.init(arena);
            for (items) |item| try list.append(try valueJsonNoContext(arena, item));
            break :blk .{ .array = list };
        },
        .object => |fields| blk: {
            var object = std.json.ObjectMap.empty;
            for (fields) |field| try object.put(arena, field.name, try valueJsonNoContext(arena, field.value));
            break :blk .{ .object = object };
        },
        .output_ref, .secret_ref, .unknown_reason => error.InvalidConfiguration,
    };
}

fn resolveString(context: *provider_mod.OperationContext, input: value.Value) ProviderError![]const u8 {
    return switch (input) {
        .string => |text| text,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}

fn resourceBasename(name: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, name, '/')) |index| name[index + 1 ..] else name;
}

fn percentEncodeAlloc(allocator: std.mem.Allocator, input: []const u8) ProviderError![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    for (input) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try output.append(allocator, byte);
        } else {
            var encoded: [3]u8 = undefined;
            _ = std.fmt.bufPrint(&encoded, "%{X:0>2}", .{byte}) catch unreachable;
            try output.appendSlice(allocator, &encoded);
        }
    }
    return output.toOwnedSlice(allocator) catch error.OutOfMemory;
}

fn requiredValue(inputs: value.Value, name: []const u8) ProviderError!value.Value {
    return requiredObjectValue(valueObject(inputs) orelse return error.InvalidConfiguration, name);
}
fn requiredString(inputs: value.Value, name: []const u8) ProviderError![]const u8 {
    return valueString(try requiredValue(inputs, name)) orelse error.InvalidConfiguration;
}
fn requiredBoolean(inputs: value.Value, name: []const u8) ProviderError!bool {
    return switch (try requiredValue(inputs, name)) {
        .boolean => |flag| flag,
        else => error.InvalidConfiguration,
    };
}
fn requiredObjectValue(fields: []const value.Field, name: []const u8) ProviderError!value.Value {
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return error.InvalidConfiguration;
}
fn requiredObjectString(fields: []const value.Field, name: []const u8) ProviderError![]const u8 {
    return valueString(try requiredObjectValue(fields, name)) orelse error.InvalidConfiguration;
}
fn requiredObjectBoolean(fields: []const value.Field, name: []const u8) ProviderError!bool {
    return switch (try requiredObjectValue(fields, name)) {
        .boolean => |flag| flag,
        else => error.InvalidConfiguration,
    };
}
fn requiredObjectInteger(fields: []const value.Field, name: []const u8) ProviderError!i64 {
    return switch (try requiredObjectValue(fields, name)) {
        .integer => |number| number,
        else => error.InvalidConfiguration,
    };
}
fn valueObject(input: value.Value) ?[]const value.Field {
    return switch (input) {
        .object => |fields| fields,
        else => null,
    };
}
fn valueList(input: value.Value) ?[]const value.Value {
    return switch (input) {
        .list => |items| items,
        else => null,
    };
}
fn valueString(input: value.Value) ?[]const u8 {
    return switch (input) {
        .string => |text| text,
        else => null,
    };
}
fn objectLen(input: value.Value) usize {
    return if (valueObject(input)) |fields| fields.len else 0;
}
fn listLen(input: value.Value) usize {
    return if (valueList(input)) |items| items.len else 0;
}
fn outputString(result: provider_mod.ResourceResult, name: []const u8) ?[]const u8 {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name)) return switch (item.value) {
        .string => |text| text,
        else => null,
    };
    return null;
}
fn jsonObject(input: std.json.Value) ?std.json.ObjectMap {
    return switch (input) {
        .object => |object| object,
        else => null,
    };
}
fn jsonString(input: ?std.json.Value) ?[]const u8 {
    return if (input) |present| switch (present) {
        .string => |text| text,
        else => null,
    } else null;
}
fn jsonBoolean(input: ?std.json.Value) ?bool {
    return if (input) |present| switch (present) {
        .bool => |flag| flag,
        else => null,
    } else null;
}
