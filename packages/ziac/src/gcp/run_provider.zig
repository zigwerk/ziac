const std = @import("std");
const aip = @import("aip.zig");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const rpc = @import("rpc.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;

pub const Handler = struct {
    client: *client_mod.Client,
    operation_policy: operation.Policy,

    pub fn read(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_override: ?[]const u8,
    ) ProviderError!provider_mod.ReadResult {
        if (context.operation_handle) |handle| {
            if (try self.waitForServiceAlloc(context, node, handle)) |result| return .{ .present = result };
        }
        const generated = if (physical_override == null) try serviceNameAlloc(context.allocator, node) else null;
        defer if (generated) |name| context.allocator.free(name);
        const physical_id = physical_override orelse generated.?;
        const path = try rpcPathAlloc(context, rpc.cloud_run_v2.get_service, &.{.{
            .field = "name",
            .value = physical_id,
        }}, &.{});
        defer context.allocator.free(path);
        var response = self.request(context, .{
            .api = .run,
            .method = rpc.cloud_run_v2.get_service.rest.?.method.text(),
            .path = path,
        }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try resultFromServiceJson(context, node, response.body) };
    }

    pub fn diff(
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        observed: *const provider_mod.ResourceResult,
    ) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        const kind: provider_mod.DiffKind = if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash))
            .noop
        else immutable: {
            for ([_][]const u8{ "project_id", "region", "name" }) |field| {
                const desired = inputString(node.inputs, field) orelse break :immutable .replace;
                const remote = inputString(observed.observed_inputs, field) orelse break :immutable .replace;
                if (!std.mem.eql(u8, desired, remote)) break :immutable .replace;
            }
            break :immutable .update;
        };
        const reasons: []const []const u8 = if (kind == .noop) &.{} else &.{"Cloud Run desired state differs from observed service"};
        return provider_mod.DiffResult.init(context.allocator, kind, reasons);
    }

    pub fn create(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        const project_id = try requiredString(node.inputs, "project_id");
        const region = try requiredString(node.inputs, "region");
        const name = try requiredString(node.inputs, "name");
        const body = try serviceBodyAlloc(context, node, null);
        defer context.allocator.free(body);
        const parent = try std.fmt.allocPrint(context.allocator, "projects/{s}/locations/{s}", .{ project_id, region });
        defer context.allocator.free(parent);
        const path = try rpcPathAlloc(context, rpc.cloud_run_v2.create_service, &.{.{
            .field = "parent",
            .value = parent,
        }}, &.{.{
            .field = "service_id",
            .value = name,
        }});
        defer context.allocator.free(path);
        const handle = try self.startOperation(
            context,
            path,
            rpc.cloud_run_v2.create_service.rest.?.method.text(),
            body,
        );
        defer context.allocator.free(handle);
        return pendingResult(context, node, handle, null);
    }

    pub fn update(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        observed: *const provider_mod.ResourceResult,
    ) ProviderError!provider_mod.ResourceResult {
        const etag = stateOutputString(observed.outputs, "etag");
        const body = try serviceBodyAlloc(context, node, etag);
        defer context.allocator.free(body);
        const update_mask = try serviceUpdateMaskAlloc(context, node, observed);
        defer context.allocator.free(update_mask);
        const path = try rpcPathAlloc(context, rpc.cloud_run_v2.update_service, &.{.{
            .field = "service.name",
            .value = observed.physical_id,
        }}, &.{.{
            .field = "update_mask",
            .value = update_mask,
        }});
        defer context.allocator.free(path);
        const handle = try self.startOperation(
            context,
            path,
            rpc.cloud_run_v2.update_service.rest.?.method.text(),
            body,
        );
        defer context.allocator.free(handle);
        return pendingResult(context, node, handle, observed);
    }

    pub fn delete(
        self: Handler,
        context: *provider_mod.OperationContext,
        physical_id: []const u8,
    ) ProviderError!void {
        const path = try rpcPathAlloc(context, rpc.cloud_run_v2.delete_service, &.{.{
            .field = "name",
            .value = physical_id,
        }}, &.{});
        defer context.allocator.free(path);
        const handle = self.startOperation(
            context,
            path,
            rpc.cloud_run_v2.delete_service.rest.?.method.text(),
            "",
        ) catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer context.allocator.free(handle);
        _ = try self.waitForServiceAlloc(context, null, handle);
    }

    fn startOperation(
        self: Handler,
        context: *provider_mod.OperationContext,
        path: []const u8,
        method: []const u8,
        body: []const u8,
    ) ProviderError![]const u8 {
        var response = try self.request(context, .{ .api = .run, .method = method, .path = path, .body = body });
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const object = asObject(parsed.value) orelse return error.ProviderBug;
        const name = asString(object.get("name")) orelse return error.ProviderBug;
        return context.allocator.dupe(u8, name) catch return error.OutOfMemory;
    }

    fn waitForServiceAlloc(
        self: Handler,
        context: *provider_mod.OperationContext,
        maybe_node: ?resource.ResourceNode,
        handle: []const u8,
    ) ProviderError!?provider_mod.ResourceResult {
        const base = try std.fmt.allocPrint(
            context.allocator,
            "{s}/v2",
            .{std.mem.trimEnd(u8, self.client.endpoints.run, "/")},
        );
        defer context.allocator.free(base);
        var target = operation.Target.genericAlloc(context.allocator, base, handle) catch return error.OutOfMemory;
        defer target.deinit(context.allocator);
        var completed = try operation.waitAlloc(self.client, context, target, self.operation_policy);
        defer completed.deinit(context.allocator);
        const node = maybe_node orelse return null;
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, completed.payload, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const operation_object = asObject(parsed.value) orelse return error.ProviderBug;
        const response_value = operation_object.get("response") orelse return null;
        const service_json = std.json.Stringify.valueAlloc(context.allocator, response_value, .{}) catch return error.OutOfMemory;
        defer context.allocator.free(service_json);
        return try resultFromServiceJson(context, node, service_json);
    }

    fn request(
        self: Handler,
        context: *provider_mod.OperationContext,
        request_value: client_mod.Request,
    ) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, request_value, &diagnostic);
    }
};

fn rpcPathAlloc(
    context: *provider_mod.OperationContext,
    method: rpc.Method,
    path_parameters: []const rpc.Parameter,
    query_parameters: []const rpc.Parameter,
) ProviderError![]u8 {
    return rpc.restPathAlloc(context.allocator, method, path_parameters, query_parameters) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidPathTemplate,
        error.InvalidResourceName,
        error.MissingPathParameter,
        error.UnknownQueryParameter,
        error.MissingRestBinding,
        => error.ProviderBug,
    };
}

fn pendingResult(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    handle: []const u8,
    observed: ?*const provider_mod.ResourceResult,
) ProviderError!provider_mod.ResourceResult {
    const allocator = context.allocator;
    const physical_id = try serviceNameAlloc(allocator, node);
    defer allocator.free(physical_id);
    const service_account = try requiredString(node.inputs, "service_account");
    const current_image_text = if (observed) |current|
        try resolveStringValue(context, try requiredValue(current.observed_inputs, "image"))
    else
        null;
    const current_image: value.Value = if (current_image_text) |image|
        .{ .string = image }
    else
        .{ .unknown_reason = "Cloud Run operation pending" };
    const previous_image = try pendingPreviousImageAlloc(context, node, current_image_text);
    defer if (previous_image == .string) allocator.free(previous_image.string);
    const outputs = [_]state.StateOutput{
        .{ .name = "service_url", .value = .{ .unknown_reason = "Cloud Run operation pending" } },
        .{ .name = "service_account", .value = .{ .string = service_account } },
        .{ .name = "latest_revision", .value = .{ .unknown_reason = "Cloud Run operation pending" } },
        .{ .name = "latest_created_revision", .value = .{ .unknown_reason = "Cloud Run operation pending" } },
        .{ .name = "image_ref", .value = current_image },
        .{ .name = "previous_image_ref", .value = previous_image },
        .{ .name = "ready", .value = .{ .boolean = false } },
        .{ .name = "etag", .value = .{ .unknown_reason = "Cloud Run operation pending" } },
        .{ .name = "name", .value = .{ .string = physical_id } },
    };
    var result = try provider_mod.ResourceResult.init(allocator, physical_id, node.inputs, &outputs, handle);
    result.completed = false;
    return result;
}

fn pendingPreviousImageAlloc(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    current_image: ?[]const u8,
) ProviderError!value.Value {
    const current = current_image orelse return .{ .unknown_reason = "No previous Cloud Run image" };
    const desired = try resolveStringValue(context, try requiredValue(node.inputs, "image"));
    if (!std.mem.eql(u8, current, desired)) {
        return .{ .string = try context.allocator.dupe(u8, current) };
    }
    return previousImageValueAlloc(context, node.id, current);
}

fn resultFromServiceJson(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    body: []const u8,
) ProviderError!provider_mod.ResourceResult {
    const allocator = context.allocator;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = asObject(parsed.value) orelse return error.ProviderBug;
    try validateServiceReady(root);
    const physical_id = asString(root.get("name")) orelse return error.ProviderBug;
    const uri = asString(root.get("uri")) orelse return error.ProviderBug;
    const revision = asString(root.get("latestReadyRevision")) orelse return error.ProviderBug;
    const created_revision = asString(root.get("latestCreatedRevision")) orelse return error.ProviderBug;
    const template = try requiredObject(root, "template");
    const service_account = try requiredJsonString(template, "serviceAccount");
    const containers_value = template.get("containers") orelse return error.ProviderBug;
    const containers = asArray(containers_value) orelse return error.ProviderBug;
    if (containers.items.len == 0) return error.ProviderBug;
    const container = asObject(containers.items[0]) orelse return error.ProviderBug;
    const image_ref = try requiredJsonString(container, "image");
    const etag = asString(root.get("etag"));
    const previous_image = try previousImageValueAlloc(context, node.id, image_ref);
    defer if (previous_image == .string) allocator.free(previous_image.string);
    var observed = try normalizedInputsAlloc(context, node, root);
    defer observed.deinit(allocator);
    const outputs = [_]state.StateOutput{
        .{ .name = "service_url", .value = .{ .string = uri } },
        .{ .name = "service_account", .value = .{ .string = service_account } },
        .{ .name = "latest_revision", .value = .{ .string = revision } },
        .{ .name = "latest_created_revision", .value = .{ .string = created_revision } },
        .{ .name = "image_ref", .value = .{ .string = image_ref } },
        .{ .name = "previous_image_ref", .value = previous_image },
        .{ .name = "ready", .value = .{ .boolean = true } },
        .{ .name = "etag", .value = if (etag) |present| .{ .string = present } else .{ .unknown_reason = "Cloud Run response omitted etag" } },
        .{ .name = "name", .value = .{ .string = physical_id } },
    };
    return provider_mod.ResourceResult.init(allocator, physical_id, observed, &outputs, null);
}

fn validateServiceReady(root: std.json.ObjectMap) ProviderError!void {
    const reconciling = jsonBool(root.get("reconciling")) orelse return error.ProviderBug;
    const terminal = try requiredObject(root, "terminalCondition");
    const condition = try requiredJsonString(terminal, "state");
    const created = try requiredJsonString(root, "latestCreatedRevision");
    const ready = try requiredJsonString(root, "latestReadyRevision");
    const generation = jsonI64(root.get("generation")) orelse 0;
    const observed_generation = jsonI64(root.get("observedGeneration")) orelse generation;
    const readiness = aip.serviceReadiness(.{
        .generation = generation,
        .observed_generation = observed_generation,
        .reconciling = reconciling,
        .terminal_state = condition,
        .latest_created_revision = created,
        .latest_ready_revision = ready,
    }) catch return error.RemoteOperationFailed;
    if (readiness == .reconciling) return error.TransientFailure;
}

fn previousImageValueAlloc(
    context: *provider_mod.OperationContext,
    resource_id: []const u8,
    current_image: []const u8,
) ProviderError!value.Value {
    const store = context.state orelse return .{ .unknown_reason = "No previous Cloud Run image" };
    const maybe_record = store.getOwned(context.allocator, resource_id) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateField, error.MissingRecord => error.ProviderBug,
    };
    var record = maybe_record orelse return .{ .unknown_reason = "No previous Cloud Run image" };
    defer record.deinit(context.allocator);
    const observed_image = stateOutputString(record.outputs, "image_ref");
    if (observed_image) |image| {
        if (!std.mem.eql(u8, image, current_image)) {
            return .{ .string = try context.allocator.dupe(u8, image) };
        }
    }
    const previous = stateOutputString(record.outputs, "previous_image_ref") orelse
        return .{ .unknown_reason = "No previous Cloud Run image" };
    return .{ .string = try context.allocator.dupe(u8, previous) };
}

fn stateOutputString(outputs: []const state.StateOutput, name: []const u8) ?[]const u8 {
    for (outputs) |provider_output| {
        if (!std.mem.eql(u8, provider_output.name, name)) continue;
        return switch (provider_output.value) {
            .string => |text| text,
            else => null,
        };
    }
    return null;
}

fn serviceUpdateMaskAlloc(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    observed: *const provider_mod.ResourceResult,
) ProviderError![]const u8 {
    const template_fields = [_][]const u8{
        "args",
        "command",
        "concurrency",
        "cpu",
        "env",
        "image",
        "liveness_probe",
        "max_instances",
        "memory",
        "min_instances",
        "port",
        "readiness_probe",
        "secret_volumes",
        "service_account",
        "startup_probe",
        "timeout_seconds",
        "vpc_access",
    };
    var template_changed = false;
    for (template_fields) |field| {
        if (try inputChanged(context, node.inputs, observed.observed_inputs, field)) {
            template_changed = true;
            break;
        }
    }
    const changes = [_]aip.FieldChange{
        .{ .path = "labels", .behavior = .optional, .changed = try inputChanged(context, node.inputs, observed.observed_inputs, "labels") },
        .{ .path = "ingress", .behavior = .optional, .changed = try inputChanged(context, node.inputs, observed.observed_inputs, "ingress") },
        .{ .path = "invokerIamDisabled", .behavior = .optional, .changed = try inputChanged(context, node.inputs, observed.observed_inputs, "allow_unauthenticated") },
        .{ .path = "multiRegionSettings", .behavior = .optional, .changed = try inputChanged(context, node.inputs, observed.observed_inputs, "multi_region_settings") },
        .{ .path = "template", .behavior = .optional, .changed = template_changed },
    };
    var plan = try aip.planChanges(context.allocator, &changes);
    defer plan.deinit(context.allocator);
    if (plan.kind != .update or plan.update_mask.len == 0) return error.ProviderBug;
    return context.allocator.dupe(u8, plan.update_mask) catch return error.OutOfMemory;
}

fn inputChanged(
    context: *provider_mod.OperationContext,
    desired: value.Value,
    observed: value.Value,
    name: []const u8,
) ProviderError!bool {
    const desired_value = try requiredValue(desired, name);
    const observed_value = try requiredValue(observed, name);
    const desired_json = desired_value.canonicalJsonAlloc(context.allocator) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateField => error.ProviderBug,
    };
    defer context.allocator.free(desired_json);
    const observed_json = observed_value.canonicalJsonAlloc(context.allocator) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateField => error.ProviderBug,
    };
    defer context.allocator.free(observed_json);
    return !std.mem.eql(u8, desired_json, observed_json);
}

fn serviceBodyAlloc(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    etag: ?[]const u8,
) ProviderError![]const u8 {
    const allocator = context.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root: std.json.ObjectMap = .empty;
    const physical_id = try serviceNameAlloc(arena, node);
    try root.put(arena, "name", .{ .string = physical_id });
    try root.put(arena, "labels", try plainValueToJson(arena, try requiredValue(node.inputs, "labels")));
    try root.put(arena, "ingress", .{ .string = try requiredString(node.inputs, "ingress") });
    try root.put(arena, "invokerIamDisabled", .{ .bool = try requiredBool(node.inputs, "allow_unauthenticated") });
    if (etag) |present| try root.put(arena, "etag", .{ .string = present });
    const multi_regions = try requiredValue(node.inputs, "multi_region_settings");
    const region_values = switch (multi_regions) {
        .list => |items| items,
        else => return error.InvalidConfiguration,
    };
    if (region_values.len > 0) {
        var multi_region_settings: std.json.ObjectMap = .empty;
        try multi_region_settings.put(arena, "regions", try stringListJson(arena, multi_regions));
        try root.put(arena, "multiRegionSettings", .{ .object = multi_region_settings });
    }

    var template: std.json.ObjectMap = .empty;
    try template.put(arena, "serviceAccount", .{ .string = try requiredString(node.inputs, "service_account") });
    const timeout = try std.fmt.allocPrint(arena, "{d}s", .{try requiredInteger(node.inputs, "timeout_seconds")});
    try template.put(arena, "timeout", .{ .string = timeout });
    try template.put(arena, "maxInstanceRequestConcurrency", .{ .integer = try requiredInteger(node.inputs, "concurrency") });
    var scaling: std.json.ObjectMap = .empty;
    try scaling.put(arena, "minInstanceCount", .{ .integer = try requiredInteger(node.inputs, "min_instances") });
    try scaling.put(arena, "maxInstanceCount", .{ .integer = try requiredInteger(node.inputs, "max_instances") });
    try template.put(arena, "scaling", .{ .object = scaling });

    var container: std.json.ObjectMap = .empty;
    try container.put(arena, "image", .{ .string = try resolveStringValue(context, try requiredValue(node.inputs, "image")) });
    try container.put(arena, "command", try stringListJson(arena, try requiredValue(node.inputs, "command")));
    try container.put(arena, "args", try stringListJson(arena, try requiredValue(node.inputs, "args")));
    try container.put(arena, "env", try envRequestJson(context, arena, try requiredValue(node.inputs, "env")));
    var limits: std.json.ObjectMap = .empty;
    try limits.put(arena, "cpu", .{ .string = try requiredString(node.inputs, "cpu") });
    try limits.put(arena, "memory", .{ .string = try requiredString(node.inputs, "memory") });
    var resources: std.json.ObjectMap = .empty;
    try resources.put(arena, "limits", .{ .object = limits });
    try container.put(arena, "resources", .{ .object = resources });
    var port: std.json.ObjectMap = .empty;
    try port.put(arena, "containerPort", .{ .integer = try requiredInteger(node.inputs, "port") });
    var ports = std.json.Array.init(arena);
    try ports.append(.{ .object = port });
    try container.put(arena, "ports", .{ .array = ports });
    try putProbe(arena, &container, "startupProbe", try requiredValue(node.inputs, "startup_probe"), try requiredInteger(node.inputs, "port"));
    try putProbe(arena, &container, "livenessProbe", try requiredValue(node.inputs, "liveness_probe"), try requiredInteger(node.inputs, "port"));
    try putProbe(arena, &container, "readinessProbe", try requiredValue(node.inputs, "readiness_probe"), try requiredInteger(node.inputs, "port"));

    const volume_config = try volumeRequestJson(arena, try requiredValue(node.inputs, "secret_volumes"));
    try container.put(arena, "volumeMounts", volume_config.mounts);
    var containers = std.json.Array.init(arena);
    try containers.append(.{ .object = container });
    try template.put(arena, "containers", .{ .array = containers });
    try template.put(arena, "volumes", volume_config.volumes);
    if (try vpcRequestJson(context, arena, try requiredValue(node.inputs, "vpc_access"))) |vpc| {
        try template.put(arena, "vpcAccess", vpc);
    }
    try root.put(arena, "template", .{ .object = template });
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = root }, .{}) catch return error.OutOfMemory;
}

fn normalizedInputsAlloc(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    remote: std.json.ObjectMap,
) ProviderError!value.Value {
    const allocator = context.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const template = try requiredObject(remote, "template");
    const containers_value = template.get("containers") orelse return error.ProviderBug;
    const containers = asArray(containers_value) orelse return error.ProviderBug;
    if (containers.items.len == 0) return error.ProviderBug;
    const container = asObject(containers.items[0]) orelse return error.ProviderBug;
    const scaling = try requiredObject(template, "scaling");
    const resources = try requiredObject(container, "resources");
    const limits = try requiredObject(resources, "limits");
    const ports_value = container.get("ports") orelse return error.ProviderBug;
    const ports = asArray(ports_value) orelse return error.ProviderBug;
    if (ports.items.len == 0) return error.ProviderBug;
    const port = asObject(ports.items[0]) orelse return error.ProviderBug;

    var normalized: std.json.ObjectMap = .empty;
    try normalized.put(arena, "allow_unauthenticated", .{ .bool = jsonBool(remote.get("invokerIamDisabled")) orelse false });
    try normalized.put(arena, "args", container.get("args") orelse emptyJsonArray(arena));
    try normalized.put(arena, "command", container.get("command") orelse emptyJsonArray(arena));
    try normalized.put(arena, "concurrency", .{ .integer = try requiredJsonInteger(template, "maxInstanceRequestConcurrency") });
    try normalized.put(arena, "cpu", .{ .string = try requiredJsonString(limits, "cpu") });
    try normalized.put(arena, "env", try normalizedEnvJson(
        context,
        arena,
        container.get("env") orelse emptyJsonArray(arena),
        try requiredValue(node.inputs, "env"),
    ));
    const desired_image = try requiredValue(node.inputs, "image");
    const remote_image = try requiredJsonString(container, "image");
    try normalized.put(arena, "image", if (std.mem.eql(u8, try resolveStringValue(context, desired_image), remote_image))
        try canonicalValueToJson(arena, desired_image)
    else
        .{ .string = remote_image });
    try normalized.put(arena, "ingress", .{ .string = try requiredJsonString(remote, "ingress") });
    try normalized.put(arena, "labels", remote.get("labels") orelse emptyJsonObject());
    try normalized.put(arena, "liveness_probe", try normalizedProbeJson(arena, container.get("livenessProbe")));
    try normalized.put(arena, "max_instances", .{ .integer = try requiredJsonInteger(scaling, "maxInstanceCount") });
    try normalized.put(arena, "memory", .{ .string = try requiredJsonString(limits, "memory") });
    try normalized.put(arena, "min_instances", .{ .integer = try requiredJsonInteger(scaling, "minInstanceCount") });
    const multi_region_settings = if (remote.get("multiRegionSettings")) |settings_value| settings: {
        const settings = asObject(settings_value) orelse return error.ProviderBug;
        break :settings settings.get("regions") orelse emptyJsonArray(arena);
    } else emptyJsonArray(arena);
    try normalized.put(arena, "multi_region_settings", multi_region_settings);
    try normalized.put(arena, "name", .{ .string = try requiredString(node.inputs, "name") });
    try normalized.put(arena, "port", .{ .integer = try requiredJsonInteger(port, "containerPort") });
    try normalized.put(arena, "project_id", .{ .string = try requiredString(node.inputs, "project_id") });
    try normalized.put(arena, "readiness_probe", try normalizedProbeJson(arena, container.get("readinessProbe")));
    try normalized.put(arena, "region", .{ .string = try requiredString(node.inputs, "region") });
    try normalized.put(arena, "secret_volumes", try normalizedVolumesJson(
        arena,
        template.get("volumes") orelse emptyJsonArray(arena),
        container.get("volumeMounts") orelse emptyJsonArray(arena),
    ));
    try normalized.put(arena, "service_account", .{ .string = try requiredJsonString(template, "serviceAccount") });
    try normalized.put(arena, "startup_probe", try normalizedProbeJson(arena, container.get("startupProbe")));
    try normalized.put(arena, "timeout_seconds", .{ .integer = try durationSeconds(template.get("timeout")) });
    try normalized.put(arena, "vpc_access", try normalizedVpcJson(
        context,
        arena,
        template.get("vpcAccess"),
        try requiredValue(node.inputs, "vpc_access"),
    ));

    const json = std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = normalized }, .{}) catch return error.OutOfMemory;
    defer allocator.free(json);
    return value.Value.parseJsonAlloc(allocator, json) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ProviderBug,
    };
}

fn envRequestJson(
    context: *provider_mod.OperationContext,
    arena: std.mem.Allocator,
    input: value.Value,
) ProviderError!std.json.Value {
    const items = switch (input) {
        .list => |items| items,
        else => return error.InvalidConfiguration,
    };
    var env = std.json.Array.init(arena);
    for (items) |item| {
        var entry: std.json.ObjectMap = .empty;
        try entry.put(arena, "name", .{ .string = try requiredString(item, "name") });
        if (try requiredBool(item, "secret")) {
            const reference = try resolveSecretValue(context, try requiredValue(item, "value"));
            var selector: std.json.ObjectMap = .empty;
            try selector.put(arena, "secret", .{ .string = reference.resource });
            try selector.put(arena, "version", .{ .string = reference.version orelse "latest" });
            var source: std.json.ObjectMap = .empty;
            try source.put(arena, "secretKeyRef", .{ .object = selector });
            try entry.put(arena, "valueSource", .{ .object = source });
        } else {
            try entry.put(arena, "value", .{ .string = try resolveStringValue(context, try requiredValue(item, "value")) });
        }
        try env.append(.{ .object = entry });
    }
    return .{ .array = env };
}

const VolumeJson = struct { volumes: std.json.Value, mounts: std.json.Value };

fn volumeRequestJson(arena: std.mem.Allocator, input: value.Value) ProviderError!VolumeJson {
    const items = switch (input) {
        .list => |items| items,
        else => return error.InvalidConfiguration,
    };
    var volumes = std.json.Array.init(arena);
    var mounts = std.json.Array.init(arena);
    for (items) |item| {
        const name = try requiredString(item, "name");
        const reference = try requiredSecret(item, "secret");
        var key_path: std.json.ObjectMap = .empty;
        try key_path.put(arena, "version", .{ .string = reference.version orelse "latest" });
        try key_path.put(arena, "path", .{ .string = try requiredString(item, "path") });
        var key_paths = std.json.Array.init(arena);
        try key_paths.append(.{ .object = key_path });
        var secret: std.json.ObjectMap = .empty;
        try secret.put(arena, "secret", .{ .string = reference.resource });
        try secret.put(arena, "items", .{ .array = key_paths });
        var volume_object: std.json.ObjectMap = .empty;
        try volume_object.put(arena, "name", .{ .string = name });
        try volume_object.put(arena, "secret", .{ .object = secret });
        try volumes.append(.{ .object = volume_object });
        var mount: std.json.ObjectMap = .empty;
        try mount.put(arena, "name", .{ .string = name });
        try mount.put(arena, "mountPath", .{ .string = try requiredString(item, "mount_path") });
        try mounts.append(.{ .object = mount });
    }
    return .{ .volumes = .{ .array = volumes }, .mounts = .{ .array = mounts } };
}

fn putProbe(
    arena: std.mem.Allocator,
    container: *std.json.ObjectMap,
    api_name: []const u8,
    input: value.Value,
    port: i64,
) ProviderError!void {
    const fields = switch (input) {
        .object => |fields| fields,
        else => return error.InvalidConfiguration,
    };
    if (fields.len == 0) return;
    var get: std.json.ObjectMap = .empty;
    try get.put(arena, "path", .{ .string = try requiredString(input, "path") });
    try get.put(arena, "port", .{ .integer = port });
    var probe: std.json.ObjectMap = .empty;
    try probe.put(arena, "httpGet", .{ .object = get });
    try probe.put(arena, "initialDelaySeconds", .{ .integer = try requiredInteger(input, "initial_delay_seconds") });
    try probe.put(arena, "timeoutSeconds", .{ .integer = try requiredInteger(input, "timeout_seconds") });
    try probe.put(arena, "periodSeconds", .{ .integer = try requiredInteger(input, "period_seconds") });
    try probe.put(arena, "failureThreshold", .{ .integer = try requiredInteger(input, "failure_threshold") });
    try container.put(arena, api_name, .{ .object = probe });
}

fn vpcRequestJson(
    context: *provider_mod.OperationContext,
    arena: std.mem.Allocator,
    input: value.Value,
) ProviderError!?std.json.Value {
    const fields = switch (input) {
        .object => |fields| fields,
        else => return error.InvalidConfiguration,
    };
    if (fields.len == 0) return null;
    var interface: std.json.ObjectMap = .empty;
    const network = try resolveStringValue(context, try requiredValue(input, "network"));
    const subnetwork = try resolveStringValue(context, try requiredValue(input, "subnetwork"));
    if (network.len != 0) try interface.put(arena, "network", .{ .string = network });
    if (subnetwork.len != 0) try interface.put(arena, "subnetwork", .{ .string = subnetwork });
    try interface.put(arena, "tags", try stringListJson(arena, try requiredValue(input, "tags")));
    var interfaces = std.json.Array.init(arena);
    try interfaces.append(.{ .object = interface });
    var vpc: std.json.ObjectMap = .empty;
    try vpc.put(arena, "egress", .{ .string = try requiredString(input, "egress") });
    try vpc.put(arena, "networkInterfaces", .{ .array = interfaces });
    return .{ .object = vpc };
}

fn normalizedEnvJson(
    context: *provider_mod.OperationContext,
    arena: std.mem.Allocator,
    remote_value: std.json.Value,
    desired_value: value.Value,
) ProviderError!std.json.Value {
    const remote = asArray(remote_value) orelse return error.ProviderBug;
    var normalized = std.json.Array.init(arena);
    for (remote.items) |item| {
        const env = asObject(item) orelse return error.ProviderBug;
        var entry: std.json.ObjectMap = .empty;
        const name = try requiredJsonString(env, "name");
        try entry.put(arena, "name", .{ .string = name });
        const desired = findEnvByName(desired_value, name);
        if (env.get("valueSource")) |source_value| {
            const source = asObject(source_value) orelse return error.ProviderBug;
            const selector = try requiredObject(source, "secretKeyRef");
            try entry.put(arena, "secret", .{ .bool = true });
            const remote_reference = value.SecretReference{
                .provider = "gcp-secret-manager",
                .resource = try requiredJsonString(selector, "secret"),
                .version = try requiredJsonString(selector, "version"),
            };
            const normalized_value = if (desired) |desired_entry| preserve: {
                if (!(requiredBool(desired_entry, "secret") catch false)) break :preserve null;
                const desired_binding = requiredValue(desired_entry, "value") catch break :preserve null;
                const resolved = resolveSecretValue(context, desired_binding) catch break :preserve null;
                if (!secretReferencesEqual(resolved, remote_reference)) break :preserve null;
                break :preserve try canonicalValueToJson(arena, desired_binding);
            } else null;
            try entry.put(arena, "value", normalized_value orelse try secretReferenceJson(
                arena,
                remote_reference.resource,
                remote_reference.version.?,
            ));
        } else {
            try entry.put(arena, "secret", .{ .bool = false });
            const remote_text = try requiredJsonString(env, "value");
            const normalized_value = if (desired) |desired_entry| preserve: {
                if (requiredBool(desired_entry, "secret") catch true) break :preserve null;
                const desired_binding = requiredValue(desired_entry, "value") catch break :preserve null;
                const resolved = resolveStringValue(context, desired_binding) catch break :preserve null;
                if (!std.mem.eql(u8, resolved, remote_text)) break :preserve null;
                break :preserve try canonicalValueToJson(arena, desired_binding);
            } else null;
            try entry.put(arena, "value", normalized_value orelse .{ .string = remote_text });
        }
        try normalized.append(.{ .object = entry });
    }
    return .{ .array = normalized };
}

fn normalizedProbeJson(arena: std.mem.Allocator, maybe_probe: ?std.json.Value) ProviderError!std.json.Value {
    const probe_value = maybe_probe orelse return emptyJsonObject();
    const probe = asObject(probe_value) orelse return error.ProviderBug;
    const get = try requiredObject(probe, "httpGet");
    var normalized: std.json.ObjectMap = .empty;
    try normalized.put(arena, "failure_threshold", .{ .integer = jsonInteger(probe.get("failureThreshold")) orelse 3 });
    try normalized.put(arena, "initial_delay_seconds", .{ .integer = jsonInteger(probe.get("initialDelaySeconds")) orelse 0 });
    try normalized.put(arena, "path", .{ .string = try requiredJsonString(get, "path") });
    try normalized.put(arena, "period_seconds", .{ .integer = jsonInteger(probe.get("periodSeconds")) orelse 10 });
    try normalized.put(arena, "timeout_seconds", .{ .integer = jsonInteger(probe.get("timeoutSeconds")) orelse 1 });
    return .{ .object = normalized };
}

fn normalizedVolumesJson(
    arena: std.mem.Allocator,
    volumes_value: std.json.Value,
    mounts_value: std.json.Value,
) ProviderError!std.json.Value {
    const volumes = asArray(volumes_value) orelse return error.ProviderBug;
    const mounts = asArray(mounts_value) orelse return error.ProviderBug;
    var normalized = std.json.Array.init(arena);
    for (volumes.items) |volume_value| {
        const volume_object = asObject(volume_value) orelse return error.ProviderBug;
        const name = try requiredJsonString(volume_object, "name");
        const secret = try requiredObject(volume_object, "secret");
        const items_value = secret.get("items") orelse return error.ProviderBug;
        const items = asArray(items_value) orelse return error.ProviderBug;
        if (items.items.len == 0) return error.ProviderBug;
        const item = asObject(items.items[0]) orelse return error.ProviderBug;
        var mount_path: ?[]const u8 = null;
        for (mounts.items) |mount_value| {
            const mount = asObject(mount_value) orelse return error.ProviderBug;
            if (std.mem.eql(u8, try requiredJsonString(mount, "name"), name)) {
                mount_path = try requiredJsonString(mount, "mountPath");
                break;
            }
        }
        const found_mount = mount_path orelse return error.ProviderBug;
        var entry: std.json.ObjectMap = .empty;
        try entry.put(arena, "mount_path", .{ .string = found_mount });
        try entry.put(arena, "name", .{ .string = name });
        try entry.put(arena, "path", .{ .string = try requiredJsonString(item, "path") });
        try entry.put(arena, "secret", try secretReferenceJson(
            arena,
            try requiredJsonString(secret, "secret"),
            try requiredJsonString(item, "version"),
        ));
        try normalized.append(.{ .object = entry });
    }
    return .{ .array = normalized };
}

fn normalizedVpcJson(
    context: *provider_mod.OperationContext,
    arena: std.mem.Allocator,
    maybe_vpc: ?std.json.Value,
    desired: value.Value,
) ProviderError!std.json.Value {
    const desired_fields = switch (desired) {
        .object => |fields| fields,
        else => return error.InvalidConfiguration,
    };
    const vpc_value = maybe_vpc orelse {
        if (desired_fields.len == 0) return emptyJsonObject();
        return error.ProviderBug;
    };
    const vpc = asObject(vpc_value) orelse return error.ProviderBug;
    const interfaces_value = vpc.get("networkInterfaces") orelse return error.ProviderBug;
    const interfaces = asArray(interfaces_value) orelse return error.ProviderBug;
    if (interfaces.items.len == 0) return error.ProviderBug;
    const interface = asObject(interfaces.items[0]) orelse return error.ProviderBug;
    const desired_network = try requiredValue(desired, "network");
    const desired_subnetwork = try requiredValue(desired, "subnetwork");
    const remote_network = asString(interface.get("network")) orelse "";
    const remote_subnetwork = asString(interface.get("subnetwork")) orelse "";
    var normalized: std.json.ObjectMap = .empty;
    try normalized.put(arena, "egress", .{ .string = try requiredJsonString(vpc, "egress") });
    try normalized.put(arena, "network", if (std.mem.eql(u8, try resolveStringValue(context, desired_network), remote_network))
        try canonicalValueToJson(arena, desired_network)
    else
        .{ .string = remote_network });
    try normalized.put(arena, "subnetwork", if (std.mem.eql(u8, try resolveStringValue(context, desired_subnetwork), remote_subnetwork))
        try canonicalValueToJson(arena, desired_subnetwork)
    else
        .{ .string = remote_subnetwork });
    try normalized.put(arena, "tags", interface.get("tags") orelse emptyJsonArray(arena));
    return .{ .object = normalized };
}

fn secretReferenceJson(
    arena: std.mem.Allocator,
    secret: []const u8,
    version: []const u8,
) ProviderError!std.json.Value {
    var reference: std.json.ObjectMap = .empty;
    try reference.put(arena, "provider", .{ .string = "gcp-secret-manager" });
    try reference.put(arena, "resource", .{ .string = secret });
    try reference.put(arena, "version", .{ .string = version });
    var wrapper: std.json.ObjectMap = .empty;
    try wrapper.put(arena, "$secret", .{ .object = reference });
    return .{ .object = wrapper };
}

fn stringListJson(arena: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    const values = switch (input) {
        .list => |values| values,
        else => return error.InvalidConfiguration,
    };
    var strings = std.json.Array.init(arena);
    for (values) |item| switch (item) {
        .string => |string| try strings.append(.{ .string = string }),
        else => return error.InvalidConfiguration,
    };
    return .{ .array = strings };
}

fn plainValueToJson(arena: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    return switch (input) {
        .string => |string| .{ .string = string },
        .integer => |integer| .{ .integer = integer },
        .boolean => |boolean| .{ .bool = boolean },
        .list => |items| list: {
            var array = std.json.Array.init(arena);
            for (items) |item| try array.append(try plainValueToJson(arena, item));
            break :list .{ .array = array };
        },
        .object => |fields| object: {
            var map: std.json.ObjectMap = .empty;
            for (fields) |field| try map.put(arena, field.name, try plainValueToJson(arena, field.value));
            break :object .{ .object = map };
        },
        .secret_ref, .output_ref, .unknown_reason => error.InvalidConfiguration,
    };
}

fn resolveStringValue(
    context: *provider_mod.OperationContext,
    input: value.Value,
) ProviderError![]const u8 {
    return switch (input) {
        .string => |string| string,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => return error.InvalidConfiguration,
    };
}

fn resolveSecretValue(
    context: *provider_mod.OperationContext,
    input: value.Value,
) ProviderError!value.SecretReference {
    const reference = switch (input) {
        .secret_ref => |reference| reference,
        .output_ref => |reference| try context.resolveOutputSecret(reference),
        else => return error.InvalidConfiguration,
    };
    if (!std.mem.eql(u8, reference.provider, "gcp-secret-manager") or
        reference.resource.len == 0 or
        reference.field != null)
    {
        return error.InvalidConfiguration;
    }
    return reference;
}

fn findEnvByName(input: value.Value, name: []const u8) ?value.Value {
    const items = switch (input) {
        .list => |items| items,
        else => return null,
    };
    for (items) |item| {
        const candidate = requiredString(item, "name") catch continue;
        if (std.mem.eql(u8, candidate, name)) return item;
    }
    return null;
}

fn secretReferencesEqual(left: value.SecretReference, right: value.SecretReference) bool {
    return std.mem.eql(u8, left.provider, right.provider) and
        std.mem.eql(u8, left.resource, right.resource) and
        optionalStringEquals(left.field, right.field) and
        optionalStringEquals(left.version, right.version);
}

fn optionalStringEquals(left: ?[]const u8, right: ?[]const u8) bool {
    if ((left == null) != (right == null)) return false;
    return if (left) |present| std.mem.eql(u8, present, right.?) else true;
}

fn canonicalValueToJson(arena: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    const json = input.canonicalJsonAlloc(arena) catch |err| switch (err) {
        error.DuplicateField => return error.InvalidConfiguration,
        error.OutOfMemory => return error.OutOfMemory,
    };
    return std.json.parseFromSliceLeaky(std.json.Value, arena, json, .{}) catch return error.ProviderBug;
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
    const found = try requiredValue(input, name);
    return switch (found) {
        .string => |string| string,
        else => error.InvalidConfiguration,
    };
}

fn requiredInteger(input: value.Value, name: []const u8) ProviderError!i64 {
    const found = try requiredValue(input, name);
    return switch (found) {
        .integer => |integer| integer,
        else => error.InvalidConfiguration,
    };
}

fn requiredBool(input: value.Value, name: []const u8) ProviderError!bool {
    const found = try requiredValue(input, name);
    return switch (found) {
        .boolean => |boolean| boolean,
        else => error.InvalidConfiguration,
    };
}

fn requiredSecret(input: value.Value, name: []const u8) ProviderError!value.SecretReference {
    const found = try requiredValue(input, name);
    return switch (found) {
        .secret_ref => |reference| reference,
        else => error.InvalidConfiguration,
    };
}

fn inputString(input: value.Value, name: []const u8) ?[]const u8 {
    return requiredString(input, name) catch null;
}

fn serviceNameAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "projects/{s}/locations/{s}/services/{s}",
        .{
            try requiredString(node.inputs, "project_id"),
            try requiredString(node.inputs, "region"),
            try requiredString(node.inputs, "name"),
        },
    ) catch return error.OutOfMemory;
}

fn requiredObject(object: std.json.ObjectMap, name: []const u8) ProviderError!std.json.ObjectMap {
    const found = object.get(name) orelse return error.ProviderBug;
    return asObject(found) orelse error.ProviderBug;
}

fn requiredJsonString(object: std.json.ObjectMap, name: []const u8) ProviderError![]const u8 {
    return asString(object.get(name)) orelse error.ProviderBug;
}

fn requiredJsonInteger(object: std.json.ObjectMap, name: []const u8) ProviderError!i64 {
    return jsonInteger(object.get(name)) orelse error.ProviderBug;
}

fn durationSeconds(maybe_value: ?std.json.Value) ProviderError!i64 {
    const text = asString(maybe_value) orelse return error.ProviderBug;
    if (!std.mem.endsWith(u8, text, "s")) return error.ProviderBug;
    return std.fmt.parseInt(i64, text[0 .. text.len - 1], 10) catch return error.ProviderBug;
}

fn asObject(input: std.json.Value) ?std.json.ObjectMap {
    return switch (input) {
        .object => |object| object,
        else => null,
    };
}

fn asArray(input: std.json.Value) ?std.json.Array {
    return switch (input) {
        .array => |array| array,
        else => null,
    };
}

fn asString(maybe_input: ?std.json.Value) ?[]const u8 {
    const input = maybe_input orelse return null;
    return switch (input) {
        .string => |string| string,
        else => null,
    };
}

fn jsonInteger(maybe_input: ?std.json.Value) ?i64 {
    const input = maybe_input orelse return null;
    return switch (input) {
        .integer => |integer| integer,
        else => null,
    };
}

fn jsonI64(maybe_input: ?std.json.Value) ?i64 {
    const input = maybe_input orelse return null;
    return switch (input) {
        .integer => |integer| integer,
        .string => |string| std.fmt.parseInt(i64, string, 10) catch null,
        else => null,
    };
}

fn jsonBool(maybe_input: ?std.json.Value) ?bool {
    const input = maybe_input orelse return null;
    return switch (input) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn emptyJsonArray(arena: std.mem.Allocator) std.json.Value {
    return .{ .array = std.json.Array.init(arena) };
}

fn emptyJsonObject() std.json.Value {
    return .{ .object = .empty };
}
