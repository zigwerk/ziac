const std = @import("std");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
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
        const path = try std.fmt.allocPrint(context.allocator, "/v2/{s}", .{physical_id});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .run, .method = "GET", .path = path }) catch |err| {
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
        const body = try serviceBodyAlloc(context, node);
        defer context.allocator.free(body);
        const path = try std.fmt.allocPrint(
            context.allocator,
            "/v2/projects/{s}/locations/{s}/services?serviceId={s}",
            .{ project_id, region, name },
        );
        defer context.allocator.free(path);
        const handle = try self.startOperation(context, path, "POST", body);
        defer context.allocator.free(handle);
        return pendingResult(context.allocator, node, handle);
    }

    pub fn update(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!provider_mod.ResourceResult {
        const body = try serviceBodyAlloc(context, node);
        defer context.allocator.free(body);
        const path = try std.fmt.allocPrint(
            context.allocator,
            "/v2/{s}?updateMask=labels,ingress,invokerIamDisabled,template",
            .{physical_id},
        );
        defer context.allocator.free(path);
        const handle = try self.startOperation(context, path, "PATCH", body);
        defer context.allocator.free(handle);
        return pendingResult(context.allocator, node, handle);
    }

    pub fn delete(
        self: Handler,
        context: *provider_mod.OperationContext,
        physical_id: []const u8,
    ) ProviderError!void {
        const path = try std.fmt.allocPrint(context.allocator, "/v2/{s}", .{physical_id});
        defer context.allocator.free(path);
        const handle = self.startOperation(context, path, "DELETE", "") catch |err| {
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

fn pendingResult(
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    handle: []const u8,
) ProviderError!provider_mod.ResourceResult {
    const physical_id = try serviceNameAlloc(allocator, node);
    defer allocator.free(physical_id);
    const service_account = try requiredString(node.inputs, "service_account");
    const outputs = [_]state.StateOutput{
        .{ .name = "service_url", .value = .{ .unknown_reason = "Cloud Run operation pending" } },
        .{ .name = "service_account", .value = .{ .string = service_account } },
        .{ .name = "latest_revision", .value = .{ .unknown_reason = "Cloud Run operation pending" } },
    };
    var result = try provider_mod.ResourceResult.init(allocator, physical_id, node.inputs, &outputs, handle);
    result.completed = false;
    return result;
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
    const physical_id = asString(root.get("name")) orelse return error.ProviderBug;
    const uri = asString(root.get("uri")) orelse return error.ProviderBug;
    const revision = asString(root.get("latestReadyRevision")) orelse return error.ProviderBug;
    const template = try requiredObject(root, "template");
    const service_account = try requiredJsonString(template, "serviceAccount");
    var observed = try normalizedInputsAlloc(context, node, root);
    defer observed.deinit(allocator);
    const outputs = [_]state.StateOutput{
        .{ .name = "service_url", .value = .{ .string = uri } },
        .{ .name = "service_account", .value = .{ .string = service_account } },
        .{ .name = "latest_revision", .value = .{ .string = revision } },
    };
    return provider_mod.ResourceResult.init(allocator, physical_id, observed, &outputs, null);
}

fn serviceBodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError![]const u8 {
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
