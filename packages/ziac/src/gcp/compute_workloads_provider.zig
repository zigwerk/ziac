const std = @import("std");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const secret_mod = @import("../secret.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;

const Kind = enum {
    disk,
    region_disk,
    image,
    instance,
    instance_template,
    instance_group_manager,
    region_instance_group_manager,
    autoscaler,
    region_autoscaler,
};

const supported_types = [_][]const u8{
    "gcp.compute.Autoscaler",
    "gcp.compute.Disk",
    "gcp.compute.Image",
    "gcp.compute.Instance",
    "gcp.compute.InstanceGroupManager",
    "gcp.compute.InstanceTemplate",
    "gcp.compute.RegionAutoscaler",
    "gcp.compute.RegionDisk",
    "gcp.compute.RegionInstanceGroupManager",
};

pub const Handler = struct {
    client: *client_mod.Client,
    operation_policy: operation.Policy = .{},
    conflict_retries: usize = 2,
    secret_source: ?secret_mod.SecretSource = null,

    pub fn read(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_override: ?[]const u8,
    ) ProviderError!provider_mod.ReadResult {
        const resource_kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (context.operation_handle) |handle| try self.waitOperation(context, node, resource_kind, handle);
        const expected = try physicalIdAlloc(context.allocator, node, resource_kind);
        defer context.allocator.free(expected);
        const physical_id = physical_override orelse expected;
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        const path = try resourcePathAlloc(context.allocator, physical_id);
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .compute, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try resultFromJson(context, node, resource_kind, response.body) };
    }

    pub fn importResource(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!provider_mod.ResourceResult {
        const result = try self.read(context, node, physical_id);
        return switch (result) {
            .absent => error.NotFound,
            .present => |present| present,
        };
    }

    pub fn diff(
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        observed: *const provider_mod.ResourceResult,
    ) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        const resource_kind = kindOf(node) orelse return error.InvalidConfiguration;
        var diff_kind: provider_mod.DiffKind = .replace;
        if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash)) {
            diff_kind = .noop;
        } else if (sameIdentity(node.inputs, observed.observed_inputs, resource_kind)) switch (resource_kind) {
            .disk, .region_disk => {
                const desired_size = try requiredInteger(node.inputs, "size_gb");
                const observed_size = try requiredInteger(observed.observed_inputs, "size_gb");
                diff_kind = if (try onlySizeChanged(context.allocator, node.inputs, observed.observed_inputs) and desired_size > observed_size) .update else .replace;
            },
            .instance_group_manager, .region_instance_group_manager, .autoscaler, .region_autoscaler => diff_kind = .update,
            .image, .instance, .instance_template => diff_kind = .replace,
        };
        const reasons: []const []const u8 = if (diff_kind == .noop)
            &.{}
        else if ((resource_kind == .disk or resource_kind == .region_disk) and diff_kind == .update)
            &.{"Persistent disk capacity will grow in place"}
        else if ((resource_kind == .disk or resource_kind == .region_disk) and sameIdentity(node.inputs, observed.observed_inputs, resource_kind) and try requiredInteger(node.inputs, "size_gb") < try requiredInteger(observed.observed_inputs, "size_gb"))
            &.{"Google Compute disks cannot shrink in place"}
        else
            &.{"Compute workload desired state differs from observed resource"};
        return provider_mod.DiffResult.init(context.allocator, diff_kind, reasons);
    }

    pub fn create(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        const resource_kind = kindOf(node) orelse return error.InvalidConfiguration;
        var body = try self.desiredBodyAlloc(context, node, resource_kind, null);
        defer body.deinit(context.allocator);
        const path = try collectionPathAlloc(context.allocator, node, resource_kind);
        defer context.allocator.free(path);
        const handle = try self.startOperation(context, path, "POST", body.bytes);
        defer context.allocator.free(handle);
        return pendingResult(context.allocator, node, resource_kind, handle);
    }

    pub fn update(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        observed: *const provider_mod.ResourceResult,
    ) ProviderError!provider_mod.ResourceResult {
        const resource_kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysicalId(context.allocator, node, resource_kind, observed.physical_id);
        const path = try resourcePathAlloc(context.allocator, observed.physical_id);
        defer context.allocator.free(path);
        switch (resource_kind) {
            .disk, .region_disk => {
                const desired_size = try requiredInteger(node.inputs, "size_gb");
                const observed_size = try requiredInteger(observed.observed_inputs, "size_gb");
                if (desired_size <= observed_size or !try onlySizeChanged(context.allocator, node.inputs, observed.observed_inputs)) return error.InvalidConfiguration;
                const resize_path = try std.fmt.allocPrint(context.allocator, "{s}/resize", .{path});
                defer context.allocator.free(resize_path);
                const size_string = try std.fmt.allocPrint(context.allocator, "{d}", .{desired_size});
                defer context.allocator.free(size_string);
                const body = std.json.Stringify.valueAlloc(context.allocator, .{ .sizeGb = size_string }, .{}) catch return error.OutOfMemory;
                defer context.allocator.free(body);
                const handle = try self.startOperation(context, resize_path, "POST", body);
                defer context.allocator.free(handle);
                return pendingResult(context.allocator, node, resource_kind, handle);
            },
            .instance_group_manager, .region_instance_group_manager => return self.updateMutable(context, node, resource_kind, observed.physical_id, path, true),
            .autoscaler, .region_autoscaler => return self.updateMutable(context, node, resource_kind, observed.physical_id, path, false),
            .image, .instance, .instance_template => return error.InvalidConfiguration,
        }
    }

    pub fn delete(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!void {
        const resource_kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysicalId(context.allocator, node, resource_kind, physical_id);
        const path = try resourcePathAlloc(context.allocator, physical_id);
        defer context.allocator.free(path);
        if (resource_kind == .instance and try requiredBoolean(node.inputs, "deletion_protection")) {
            const unprotect_path = try std.fmt.allocPrint(context.allocator, "{s}/setDeletionProtection?deletionProtection=false", .{path});
            defer context.allocator.free(unprotect_path);
            const handle = try self.startOperation(context, unprotect_path, "POST", "");
            defer context.allocator.free(handle);
            try self.waitOperation(context, node, resource_kind, handle);
        }
        const handle = self.startOperation(context, path, "DELETE", "") catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer context.allocator.free(handle);
        try self.waitOperation(context, node, resource_kind, handle);
    }

    fn updateMutable(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        resource_kind: Kind,
        physical_id: []const u8,
        path: []const u8,
        fingerprinted: bool,
    ) ProviderError!provider_mod.ResourceResult {
        var conflicts: usize = 0;
        while (true) {
            var remote_response = try self.request(context, .{ .api = .compute, .method = "GET", .path = path });
            defer remote_response.deinit(context.allocator);
            var body = try self.desiredBodyAlloc(context, node, resource_kind, if (fingerprinted) remote_response.body else null);
            defer body.deinit(context.allocator);
            const handle = self.startOperation(context, path, "PATCH", body.bytes) catch |err| {
                if ((err == error.Conflict or err == error.PreconditionFailed) and conflicts < self.conflict_retries) {
                    conflicts += 1;
                    continue;
                }
                return err;
            };
            defer context.allocator.free(handle);
            _ = physical_id;
            return pendingResult(context.allocator, node, resource_kind, handle);
        }
    }

    fn startOperation(
        self: Handler,
        context: *provider_mod.OperationContext,
        path: []const u8,
        method: []const u8,
        body: []const u8,
    ) ProviderError![]const u8 {
        var response = try self.request(context, .{ .api = .compute, .method = method, .path = path, .body = body });
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const object = asObject(parsed.value) orelse return error.ProviderBug;
        return context.allocator.dupe(u8, try requiredJsonString(object, "name")) catch return error.OutOfMemory;
    }

    fn waitOperation(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        resource_kind: Kind,
        handle: []const u8,
    ) ProviderError!void {
        const base = try std.fmt.allocPrint(context.allocator, "{s}/compute/v1", .{std.mem.trimEnd(u8, self.client.endpoints.compute, "/")});
        defer context.allocator.free(base);
        const project_id = try requiredString(node.inputs, "project_id");
        var target = switch (scopeOf(resource_kind)) {
            .global => operation.Target.computeGlobalAlloc(context.allocator, base, project_id, handle),
            .region => operation.Target.computeRegionalAlloc(context.allocator, base, project_id, try requiredString(node.inputs, "region"), handle),
            .zone => operation.Target.computeZonalAlloc(context.allocator, base, project_id, try requiredString(node.inputs, "zone"), handle),
        } catch return error.OutOfMemory;
        defer target.deinit(context.allocator);
        var completed = try operation.waitAlloc(self.client, context, target, self.operation_policy);
        completed.deinit(context.allocator);
    }

    fn desiredBodyAlloc(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        resource_kind: Kind,
        remote_json: ?[]const u8,
    ) ProviderError!SensitiveBody {
        var arena_state = std.heap.ArenaAllocator.init(context.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var root: std.json.ObjectMap = .empty;
        var sensitive = false;
        try root.put(arena, "name", .{ .string = try requiredString(node.inputs, "name") });
        switch (resource_kind) {
            .disk, .region_disk => try diskBody(arena, context, node, resource_kind, &root),
            .image => try imageBody(arena, context, node, &root),
            .instance => sensitive = try self.instanceBody(arena, context, node, &root, false),
            .instance_template => sensitive = try self.instanceBody(arena, context, node, &root, true),
            .instance_group_manager, .region_instance_group_manager => try groupBody(arena, context, node, resource_kind, remote_json, &root),
            .autoscaler, .region_autoscaler => try autoscalerBody(arena, context, node, &root),
        }
        const bytes = std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch return error.OutOfMemory;
        return .{ .bytes = bytes, .sensitive = sensitive };
    }

    fn instanceBody(
        self: Handler,
        allocator: std.mem.Allocator,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        root: *std.json.ObjectMap,
        template: bool,
    ) ProviderError!bool {
        var properties: std.json.ObjectMap = .empty;
        const destination = if (template) &properties else root;
        try destination.put(allocator, "machineType", .{ .string = try requiredString(node.inputs, "machine_type") });
        try destination.put(allocator, "canIpForward", .{ .bool = try requiredBoolean(node.inputs, "can_ip_forward") });
        try destination.put(allocator, "labels", try labelsJson(allocator, try requiredValue(node.inputs, "labels")));
        try destination.put(allocator, "tags", try tagsJson(allocator, try requiredValue(node.inputs, "tags")));
        try destination.put(allocator, "networkInterfaces", try networkInterfacesJson(allocator, context, try requiredValue(node.inputs, "network_interfaces")));
        try destination.put(allocator, "serviceAccounts", try serviceAccountsJson(allocator, context, node.inputs));
        try destination.put(allocator, "scheduling", try schedulingJson(allocator, node.inputs));
        try destination.put(allocator, "shieldedInstanceConfig", try shieldedJson(allocator, try requiredValue(node.inputs, "shielded_vm")));
        if (try requiredBoolean(node.inputs, "confidential_compute")) {
            var confidential: std.json.ObjectMap = .empty;
            try confidential.put(allocator, "enableConfidentialCompute", .{ .bool = true });
            try destination.put(allocator, "confidentialInstanceConfig", .{ .object = confidential });
        }

        var disks = std.json.Array.init(allocator);
        var boot: std.json.ObjectMap = .empty;
        try boot.put(allocator, "boot", .{ .bool = true });
        try boot.put(allocator, "autoDelete", .{ .bool = try requiredBoolean(node.inputs, "boot_disk_auto_delete") });
        if (template) {
            var init: std.json.ObjectMap = .empty;
            try init.put(allocator, "sourceImage", .{ .string = try resolveString(context, try requiredValue(node.inputs, "source_image")) });
            try init.put(allocator, "diskSizeGb", .{ .string = try integerString(allocator, try requiredInteger(node.inputs, "boot_disk_size_gb")) });
            try init.put(allocator, "diskType", .{ .string = try requiredString(node.inputs, "boot_disk_type") });
            try boot.put(allocator, "initializeParams", .{ .object = init });
        } else {
            try boot.put(allocator, "source", .{ .string = try resolveString(context, try requiredValue(node.inputs, "boot_disk")) });
            try root.put(allocator, "deletionProtection", .{ .bool = try requiredBoolean(node.inputs, "deletion_protection") });
        }
        try disks.append(.{ .object = boot });
        try destination.put(allocator, "disks", .{ .array = disks });

        var metadata = try metadataJson(allocator, try requiredValue(node.inputs, "metadata"));
        const startup = try requiredValue(node.inputs, "startup_script");
        var sensitive = false;
        if (startup != .string or startup.string.len != 0) {
            const source = self.secret_source orelse return error.AuthorizationFailed;
            const reference = try resolveSecret(context, startup);
            var payload = try source.resolve(context, context.allocator, reference);
            defer payload.deinit();
            try verifyPayloadDigest(payload.bytes, try requiredString(node.inputs, "startup_script_sha256"));
            const script = allocator.dupe(u8, payload.bytes) catch return error.OutOfMemory;
            var item: std.json.ObjectMap = .empty;
            try item.put(allocator, "key", .{ .string = "startup-script" });
            try item.put(allocator, "value", .{ .string = script });
            try metadata.object.getPtr("items").?.array.append(.{ .object = item });
            sensitive = true;
        }
        try destination.put(allocator, "metadata", metadata);
        if (template) try root.put(allocator, "properties", .{ .object = properties });
        return sensitive;
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, request_value: client_mod.Request) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, request_value, &diagnostic);
    }
};

const SensitiveBody = struct {
    bytes: []u8,
    sensitive: bool,

    fn deinit(self: *SensitiveBody, allocator: std.mem.Allocator) void {
        if (self.sensitive) std.crypto.secureZero(u8, self.bytes);
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

const Scope = enum { global, region, zone };

pub fn supports(node: resource.ResourceNode) bool {
    for (supported_types) |candidate| if (std.mem.eql(u8, candidate, node.type_name)) return true;
    return false;
}

fn kindOf(node: resource.ResourceNode) ?Kind {
    const mappings = .{
        .{ "gcp.compute.Disk", Kind.disk },
        .{ "gcp.compute.RegionDisk", Kind.region_disk },
        .{ "gcp.compute.Image", Kind.image },
        .{ "gcp.compute.Instance", Kind.instance },
        .{ "gcp.compute.InstanceTemplate", Kind.instance_template },
        .{ "gcp.compute.InstanceGroupManager", Kind.instance_group_manager },
        .{ "gcp.compute.RegionInstanceGroupManager", Kind.region_instance_group_manager },
        .{ "gcp.compute.Autoscaler", Kind.autoscaler },
        .{ "gcp.compute.RegionAutoscaler", Kind.region_autoscaler },
    };
    inline for (mappings) |mapping| if (std.mem.eql(u8, node.type_name, mapping[0])) return mapping[1];
    return null;
}

fn scopeOf(resource_kind: Kind) Scope {
    return switch (resource_kind) {
        .image, .instance_template => .global,
        .region_disk, .region_instance_group_manager, .region_autoscaler => .region,
        .disk, .instance, .instance_group_manager, .autoscaler => .zone,
    };
}

fn collectionName(resource_kind: Kind) []const u8 {
    return switch (resource_kind) {
        .disk, .region_disk => "disks",
        .image => "images",
        .instance => "instances",
        .instance_template => "instanceTemplates",
        .instance_group_manager, .region_instance_group_manager => "instanceGroupManagers",
        .autoscaler, .region_autoscaler => "autoscalers",
    };
}

fn collectionPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, resource_kind: Kind) ProviderError![]const u8 {
    const project = try requiredString(node.inputs, "project_id");
    return switch (scopeOf(resource_kind)) {
        .global => std.fmt.allocPrint(allocator, "/compute/v1/projects/{s}/global/{s}", .{ project, collectionName(resource_kind) }),
        .region => std.fmt.allocPrint(allocator, "/compute/v1/projects/{s}/regions/{s}/{s}", .{ project, try requiredString(node.inputs, "region"), collectionName(resource_kind) }),
        .zone => std.fmt.allocPrint(allocator, "/compute/v1/projects/{s}/zones/{s}/{s}", .{ project, try requiredString(node.inputs, "zone"), collectionName(resource_kind) }),
    } catch return error.OutOfMemory;
}

fn physicalIdAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, resource_kind: Kind) ProviderError![]const u8 {
    const project = try requiredString(node.inputs, "project_id");
    const name = try requiredString(node.inputs, "name");
    return switch (scopeOf(resource_kind)) {
        .global => std.fmt.allocPrint(allocator, "projects/{s}/global/{s}/{s}", .{ project, collectionName(resource_kind), name }),
        .region => std.fmt.allocPrint(allocator, "projects/{s}/regions/{s}/{s}/{s}", .{ project, try requiredString(node.inputs, "region"), collectionName(resource_kind), name }),
        .zone => std.fmt.allocPrint(allocator, "projects/{s}/zones/{s}/{s}/{s}", .{ project, try requiredString(node.inputs, "zone"), collectionName(resource_kind), name }),
    } catch return error.OutOfMemory;
}

fn validatePhysicalId(allocator: std.mem.Allocator, node: resource.ResourceNode, resource_kind: Kind, physical_id: []const u8) ProviderError!void {
    const expected = try physicalIdAlloc(allocator, node, resource_kind);
    defer allocator.free(expected);
    if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
}

fn resourcePathAlloc(allocator: std.mem.Allocator, physical_id: []const u8) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "/compute/v1/{s}", .{std.mem.trimStart(u8, physical_id, "/")}) catch return error.OutOfMemory;
}

fn pendingResult(allocator: std.mem.Allocator, node: resource.ResourceNode, resource_kind: Kind, handle: []const u8) ProviderError!provider_mod.ResourceResult {
    const physical_id = try physicalIdAlloc(allocator, node, resource_kind);
    defer allocator.free(physical_id);
    const outputs = switch (resource_kind) {
        .disk, .region_disk => &[_]state.StateOutput{
            .{ .name = "self_link", .value = .{ .unknown_reason = "Compute operation pending" } },
            .{ .name = "status", .value = .{ .unknown_reason = "Compute operation pending" } },
            .{ .name = "size_gb", .value = .{ .unknown_reason = "Compute operation pending" } },
        },
        .image => &[_]state.StateOutput{
            .{ .name = "self_link", .value = .{ .unknown_reason = "Compute operation pending" } },
            .{ .name = "status", .value = .{ .unknown_reason = "Compute operation pending" } },
            .{ .name = "source_disk_id", .value = .{ .unknown_reason = "Compute operation pending" } },
        },
        .instance => &[_]state.StateOutput{
            .{ .name = "self_link", .value = .{ .unknown_reason = "Compute operation pending" } },
            .{ .name = "status", .value = .{ .unknown_reason = "Compute operation pending" } },
            .{ .name = "internal_ip", .value = .{ .unknown_reason = "Compute operation pending" } },
            .{ .name = "external_ip", .value = .{ .unknown_reason = "Compute operation pending" } },
            .{ .name = "zone", .value = .{ .unknown_reason = "Compute operation pending" } },
        },
        .instance_template => &[_]state.StateOutput{
            .{ .name = "self_link", .value = .{ .unknown_reason = "Compute operation pending" } },
        },
        .instance_group_manager, .region_instance_group_manager => &[_]state.StateOutput{
            .{ .name = "self_link", .value = .{ .unknown_reason = "Compute operation pending" } },
            .{ .name = "instance_group", .value = .{ .unknown_reason = "Compute operation pending" } },
            .{ .name = "status", .value = .{ .unknown_reason = "Compute operation pending" } },
            .{ .name = "target_size", .value = .{ .unknown_reason = "Compute operation pending" } },
            .{ .name = "fingerprint", .value = .{ .unknown_reason = "Compute operation pending" } },
        },
        .autoscaler, .region_autoscaler => &[_]state.StateOutput{
            .{ .name = "self_link", .value = .{ .unknown_reason = "Compute operation pending" } },
            .{ .name = "status", .value = .{ .unknown_reason = "Compute operation pending" } },
            .{ .name = "recommended_size", .value = .{ .unknown_reason = "Compute operation pending" } },
        },
    };
    var result = try provider_mod.ResourceResult.init(allocator, physical_id, node.inputs, outputs, handle);
    result.completed = false;
    return result;
}

fn resultFromJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, resource_kind: Kind, body: []const u8) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const remote = asObject(parsed.value) orelse return error.ProviderBug;
    const expected_name = try requiredString(node.inputs, "name");
    if (!std.mem.eql(u8, expected_name, try requiredJsonString(remote, "name"))) return error.InvalidConfiguration;
    const physical_id = try physicalIdAlloc(context.allocator, node, resource_kind);
    defer context.allocator.free(physical_id);
    var observed = try normalizedInputsAlloc(context, node, resource_kind, remote);
    defer observed.deinit(context.allocator);
    var outputs: [5]state.StateOutput = undefined;
    var count: usize = 0;
    outputs[count] = .{ .name = "self_link", .value = .{ .string = try requiredJsonString(remote, "selfLink") } };
    count += 1;
    switch (resource_kind) {
        .disk, .region_disk => {
            outputs[count] = .{ .name = "status", .value = .{ .string = jsonString(remote.get("status")) orelse "UNKNOWN" } };
            count += 1;
            outputs[count] = .{ .name = "size_gb", .value = .{ .integer = try jsonIntegerOrString(remote.get("sizeGb")) } };
            count += 1;
        },
        .image => {
            outputs[count] = .{ .name = "status", .value = .{ .string = jsonString(remote.get("status")) orelse "UNKNOWN" } };
            count += 1;
            outputs[count] = .{ .name = "source_disk_id", .value = .{ .string = jsonString(remote.get("sourceDiskId")) orelse "" } };
            count += 1;
        },
        .instance => {
            outputs[count] = .{ .name = "status", .value = .{ .string = jsonString(remote.get("status")) orelse "UNKNOWN" } };
            count += 1;
            const ips = instanceIps(remote);
            outputs[count] = .{ .name = "internal_ip", .value = .{ .string = ips.internal } };
            count += 1;
            outputs[count] = .{ .name = "external_ip", .value = .{ .string = ips.external } };
            count += 1;
            outputs[count] = .{ .name = "zone", .value = .{ .string = lastSegment(jsonString(remote.get("zone")) orelse try requiredString(node.inputs, "zone")) } };
            count += 1;
        },
        .instance_template => {},
        .instance_group_manager, .region_instance_group_manager => {
            outputs[count] = .{ .name = "instance_group", .value = .{ .string = jsonString(remote.get("instanceGroup")) orelse "" } };
            count += 1;
            outputs[count] = .{ .name = "status", .value = .{ .string = groupStatus(remote) } };
            count += 1;
            outputs[count] = .{ .name = "target_size", .value = .{ .integer = jsonInteger(remote.get("targetSize")) orelse 0 } };
            count += 1;
            outputs[count] = .{ .name = "fingerprint", .value = .{ .string = jsonString(remote.get("fingerprint")) orelse "" } };
            count += 1;
        },
        .autoscaler, .region_autoscaler => {
            outputs[count] = .{ .name = "status", .value = .{ .string = jsonString(remote.get("status")) orelse "UNKNOWN" } };
            count += 1;
            outputs[count] = .{ .name = "recommended_size", .value = .{ .integer = jsonInteger(remote.get("recommendedSize")) orelse 0 } };
            count += 1;
        },
    }
    return provider_mod.ResourceResult.init(context.allocator, physical_id, observed, outputs[0..count], null);
}

fn normalizedInputsAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, resource_kind: Kind, remote: std.json.ObjectMap) ProviderError!value.Value {
    var result = node.inputs.clone(context.allocator) catch |err| return mapValueError(err);
    errdefer result.deinit(context.allocator);
    switch (resource_kind) {
        .disk, .region_disk => {
            try replaceInteger(context.allocator, &result, "size_gb", try jsonIntegerOrString(remote.get("sizeGb")));
            if (jsonString(remote.get("type"))) |disk_type| try replaceString(context.allocator, &result, "disk_type", lastSegment(disk_type));
            try replaceLabelsFromJson(context.allocator, &result, remote.get("labels"));
        },
        .image => {
            if (jsonString(remote.get("family"))) |family| try replaceString(context.allocator, &result, "family", family);
            if (jsonString(remote.get("description"))) |description| try replaceString(context.allocator, &result, "description", description);
            if (jsonString(remote.get("sourceDisk"))) |source| try replaceResolvedString(context, &result, "source_disk", source);
            try replaceLabelsFromJson(context.allocator, &result, remote.get("labels"));
        },
        .instance => {
            if (jsonString(remote.get("machineType"))) |machine_type| try replaceString(context.allocator, &result, "machine_type", lastSegment(machine_type));
            if (jsonBool(remote.get("deletionProtection"))) |present| try replaceBoolean(context.allocator, &result, "deletion_protection", present);
            if (jsonBool(remote.get("canIpForward"))) |present| try replaceBoolean(context.allocator, &result, "can_ip_forward", present);
            try replaceLabelsFromJson(context.allocator, &result, remote.get("labels"));
        },
        .instance_template => {
            if (remote.get("properties")) |properties_value| if (asObject(properties_value)) |properties| {
                if (jsonString(properties.get("machineType"))) |machine_type| try replaceString(context.allocator, &result, "machine_type", lastSegment(machine_type));
                try replaceLabelsFromJson(context.allocator, &result, properties.get("labels"));
            };
        },
        .instance_group_manager, .region_instance_group_manager => {
            if (jsonInteger(remote.get("targetSize"))) |target_size| try replaceInteger(context.allocator, &result, "target_size", target_size);
            if (jsonString(remote.get("baseInstanceName"))) |base| try replaceString(context.allocator, &result, "base_instance_name", base);
            if (remote.get("versions")) |versions_value| if (asArray(versions_value)) |versions| if (versions.items.len > 0) if (asObject(versions.items[0])) |version_object| if (jsonString(version_object.get("instanceTemplate"))) |template| try replaceResolvedString(context, &result, "instance_template", template);
        },
        .autoscaler, .region_autoscaler => if (remote.get("autoscalingPolicy")) |policy_value| if (asObject(policy_value)) |policy| {
            if (jsonInteger(policy.get("minNumReplicas"))) |minimum| try replaceInteger(context.allocator, &result, "min_replicas", minimum);
            if (jsonInteger(policy.get("maxNumReplicas"))) |maximum| try replaceInteger(context.allocator, &result, "max_replicas", maximum);
            if (jsonInteger(policy.get("coolDownPeriodSec"))) |cooldown| try replaceInteger(context.allocator, &result, "cooldown_seconds", cooldown);
            if (jsonString(policy.get("mode"))) |mode| try replaceString(context.allocator, &result, "mode", mode);
        },
    }
    return result;
}

fn diskBody(allocator: std.mem.Allocator, context: *provider_mod.OperationContext, node: resource.ResourceNode, resource_kind: Kind, root: *std.json.ObjectMap) ProviderError!void {
    const project = try requiredString(node.inputs, "project_id");
    const scope = if (resource_kind == .region_disk) try requiredString(node.inputs, "region") else try requiredString(node.inputs, "zone");
    const scope_name = if (resource_kind == .region_disk) "regions" else "zones";
    try root.put(allocator, "sizeGb", .{ .string = try integerString(allocator, try requiredInteger(node.inputs, "size_gb")) });
    try root.put(allocator, "type", .{ .string = try std.fmt.allocPrint(allocator, "projects/{s}/{s}/{s}/diskTypes/{s}", .{ project, scope_name, scope, try requiredString(node.inputs, "disk_type") }) });
    try root.put(allocator, "physicalBlockSizeBytes", .{ .integer = try requiredInteger(node.inputs, "physical_block_size_bytes") });
    const iops = try requiredInteger(node.inputs, "provisioned_iops");
    if (iops > 0) try root.put(allocator, "provisionedIops", .{ .string = try integerString(allocator, iops) });
    try root.put(allocator, "labels", try labelsJson(allocator, try requiredValue(node.inputs, "labels")));
    if (resource_kind == .disk) {
        const source_image = try requiredValue(node.inputs, "source_image");
        if (source_image != .string or source_image.string.len > 0) try root.put(allocator, "sourceImage", .{ .string = try resolveString(context, source_image) });
    }
    const source_snapshot = try requiredValue(node.inputs, "source_snapshot");
    if (source_snapshot != .string or source_snapshot.string.len > 0) try root.put(allocator, "sourceSnapshot", .{ .string = try resolveString(context, source_snapshot) });
    const kms = try requiredValue(node.inputs, "kms_key");
    if (kms != .string or kms.string.len > 0) {
        var encryption: std.json.ObjectMap = .empty;
        try encryption.put(allocator, "kmsKeyName", .{ .string = try resolveString(context, kms) });
        try root.put(allocator, "diskEncryptionKey", .{ .object = encryption });
    }
    if (resource_kind == .region_disk) {
        var zones = std.json.Array.init(allocator);
        for (try requiredList(node.inputs, "replica_zones")) |zone_value| {
            const zone = try valueString(zone_value);
            try zones.append(.{ .string = try std.fmt.allocPrint(allocator, "projects/{s}/zones/{s}", .{ project, zone }) });
        }
        try root.put(allocator, "replicaZones", .{ .array = zones });
    }
}

fn imageBody(allocator: std.mem.Allocator, context: *provider_mod.OperationContext, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    try root.put(allocator, "sourceDisk", .{ .string = try resolveString(context, try requiredValue(node.inputs, "source_disk")) });
    const family = try requiredString(node.inputs, "family");
    if (family.len > 0) try root.put(allocator, "family", .{ .string = family });
    const description = try requiredString(node.inputs, "description");
    if (description.len > 0) try root.put(allocator, "description", .{ .string = description });
    try root.put(allocator, "storageLocations", try stringListJson(allocator, try requiredValue(node.inputs, "storage_locations")));
    try root.put(allocator, "labels", try labelsJson(allocator, try requiredValue(node.inputs, "labels")));
    var features = std.json.Array.init(allocator);
    for (try requiredList(node.inputs, "guest_os_features")) |feature| {
        var item: std.json.ObjectMap = .empty;
        try item.put(allocator, "type", .{ .string = try valueString(feature) });
        try features.append(.{ .object = item });
    }
    try root.put(allocator, "guestOsFeatures", .{ .array = features });
}

fn groupBody(allocator: std.mem.Allocator, context: *provider_mod.OperationContext, node: resource.ResourceNode, resource_kind: Kind, remote_json: ?[]const u8, root: *std.json.ObjectMap) ProviderError!void {
    try root.put(allocator, "baseInstanceName", .{ .string = try requiredString(node.inputs, "base_instance_name") });
    try root.put(allocator, "targetSize", .{ .integer = try requiredInteger(node.inputs, "target_size") });
    var versions = std.json.Array.init(allocator);
    var version_object: std.json.ObjectMap = .empty;
    try version_object.put(allocator, "instanceTemplate", .{ .string = try resolveString(context, try requiredValue(node.inputs, "instance_template")) });
    try versions.append(.{ .object = version_object });
    try root.put(allocator, "versions", .{ .array = versions });
    try root.put(allocator, "namedPorts", try namedPortsJson(allocator, try requiredValue(node.inputs, "named_ports")));
    var update_policy: std.json.ObjectMap = .empty;
    try update_policy.put(allocator, "type", .{ .string = try upperAlloc(allocator, try requiredString(node.inputs, "update_type")) });
    try update_policy.put(allocator, "replacementMethod", .{ .string = try upperAlloc(allocator, try requiredString(node.inputs, "replacement_method")) });
    var surge: std.json.ObjectMap = .empty;
    try surge.put(allocator, "fixed", .{ .integer = try requiredInteger(node.inputs, "max_surge") });
    try update_policy.put(allocator, "maxSurge", .{ .object = surge });
    var unavailable: std.json.ObjectMap = .empty;
    try unavailable.put(allocator, "fixed", .{ .integer = try requiredInteger(node.inputs, "max_unavailable") });
    try update_policy.put(allocator, "maxUnavailable", .{ .object = unavailable });
    try root.put(allocator, "updatePolicy", .{ .object = update_policy });
    if (resource_kind == .region_instance_group_manager) {
        const project = try requiredString(node.inputs, "project_id");
        var zones = std.json.Array.init(allocator);
        for (try requiredList(node.inputs, "distribution_zones")) |zone_value| {
            var zone: std.json.ObjectMap = .empty;
            try zone.put(allocator, "zone", .{ .string = try std.fmt.allocPrint(allocator, "projects/{s}/zones/{s}", .{ project, try valueString(zone_value) }) });
            try zones.append(.{ .object = zone });
        }
        var policy: std.json.ObjectMap = .empty;
        try policy.put(allocator, "zones", .{ .array = zones });
        try root.put(allocator, "distributionPolicy", .{ .object = policy });
    }
    if (remote_json) |bytes| {
        const fingerprint = try fingerprintFromJson(allocator, bytes);
        try root.put(allocator, "fingerprint", .{ .string = fingerprint });
    }
}

fn autoscalerBody(allocator: std.mem.Allocator, context: *provider_mod.OperationContext, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    try root.put(allocator, "target", .{ .string = try resolveString(context, try requiredValue(node.inputs, "target")) });
    var policy: std.json.ObjectMap = .empty;
    try policy.put(allocator, "minNumReplicas", .{ .integer = try requiredInteger(node.inputs, "min_replicas") });
    try policy.put(allocator, "maxNumReplicas", .{ .integer = try requiredInteger(node.inputs, "max_replicas") });
    try policy.put(allocator, "coolDownPeriodSec", .{ .integer = try requiredInteger(node.inputs, "cooldown_seconds") });
    try policy.put(allocator, "mode", .{ .string = try requiredString(node.inputs, "mode") });
    var cpu: std.json.ObjectMap = .empty;
    try cpu.put(allocator, "utilizationTarget", .{ .float = @as(f64, @floatFromInt(try requiredInteger(node.inputs, "cpu_utilization_target_micros"))) / 1_000_000.0 });
    try policy.put(allocator, "cpuUtilization", .{ .object = cpu });
    var scale_in: std.json.ObjectMap = .empty;
    try scale_in.put(allocator, "timeWindowSec", .{ .integer = try requiredInteger(node.inputs, "scale_in_control_seconds") });
    try policy.put(allocator, "scaleInControl", .{ .object = scale_in });
    try root.put(allocator, "autoscalingPolicy", .{ .object = policy });
}

fn networkInterfacesJson(allocator: std.mem.Allocator, context: *provider_mod.OperationContext, input: value.Value) ProviderError!std.json.Value {
    var array = std.json.Array.init(allocator);
    for (try asValueList(input)) |candidate| {
        var item: std.json.ObjectMap = .empty;
        try item.put(allocator, "network", .{ .string = try resolveString(context, try requiredValue(candidate, "network")) });
        const subnetwork = try requiredValue(candidate, "subnetwork");
        if (subnetwork != .string or subnetwork.string.len > 0) try item.put(allocator, "subnetwork", .{ .string = try resolveString(context, subnetwork) });
        const private_ip = try requiredString(candidate, "private_ip");
        if (private_ip.len > 0) try item.put(allocator, "networkIP", .{ .string = private_ip });
        try item.put(allocator, "nicType", .{ .string = try requiredString(candidate, "nic_type") });
        try item.put(allocator, "stackType", .{ .string = try requiredString(candidate, "stack_type") });
        if (try requiredBoolean(candidate, "external_access")) {
            var configs = std.json.Array.init(allocator);
            var access: std.json.ObjectMap = .empty;
            try access.put(allocator, "name", .{ .string = "External NAT" });
            try access.put(allocator, "type", .{ .string = "ONE_TO_ONE_NAT" });
            try access.put(allocator, "networkTier", .{ .string = "PREMIUM" });
            const external_ip = try requiredValue(candidate, "external_ip");
            if (external_ip != .string or external_ip.string.len > 0) {
                try access.put(allocator, "natIP", .{ .string = try resolveString(context, external_ip) });
            }
            try configs.append(.{ .object = access });
            try item.put(allocator, "accessConfigs", .{ .array = configs });
        }
        try array.append(.{ .object = item });
    }
    return .{ .array = array };
}

fn serviceAccountsJson(allocator: std.mem.Allocator, context: *provider_mod.OperationContext, inputs: value.Value) ProviderError!std.json.Value {
    var array = std.json.Array.init(allocator);
    var account: std.json.ObjectMap = .empty;
    try account.put(allocator, "email", .{ .string = try resolveString(context, try requiredValue(inputs, "service_account")) });
    try account.put(allocator, "scopes", try stringListJson(allocator, try requiredValue(inputs, "oauth_scopes")));
    try array.append(.{ .object = account });
    return .{ .array = array };
}

fn schedulingJson(allocator: std.mem.Allocator, inputs: value.Value) ProviderError!std.json.Value {
    var scheduling: std.json.ObjectMap = .empty;
    try scheduling.put(allocator, "automaticRestart", .{ .bool = try requiredBoolean(inputs, "automatic_restart") });
    try scheduling.put(allocator, "onHostMaintenance", .{ .string = try requiredString(inputs, "on_host_maintenance") });
    try scheduling.put(allocator, "provisioningModel", .{ .string = try requiredString(inputs, "provisioning_model") });
    return .{ .object = scheduling };
}

fn shieldedJson(allocator: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    var shielded: std.json.ObjectMap = .empty;
    try shielded.put(allocator, "enableSecureBoot", .{ .bool = try requiredBoolean(input, "secure_boot") });
    try shielded.put(allocator, "enableVtpm", .{ .bool = try requiredBoolean(input, "vtpm") });
    try shielded.put(allocator, "enableIntegrityMonitoring", .{ .bool = try requiredBoolean(input, "integrity_monitoring") });
    return .{ .object = shielded };
}

fn metadataJson(allocator: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    var items = std.json.Array.init(allocator);
    for (try asValueList(input)) |entry| {
        var item: std.json.ObjectMap = .empty;
        try item.put(allocator, "key", .{ .string = try requiredString(entry, "key") });
        try item.put(allocator, "value", .{ .string = try requiredString(entry, "value") });
        try items.append(.{ .object = item });
    }
    var metadata: std.json.ObjectMap = .empty;
    try metadata.put(allocator, "items", .{ .array = items });
    return .{ .object = metadata };
}

fn labelsJson(allocator: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    var labels: std.json.ObjectMap = .empty;
    for (try asValueList(input)) |entry| try labels.put(allocator, try requiredString(entry, "key"), .{ .string = try requiredString(entry, "value") });
    return .{ .object = labels };
}

fn tagsJson(allocator: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    var tags: std.json.ObjectMap = .empty;
    try tags.put(allocator, "items", try stringListJson(allocator, input));
    return .{ .object = tags };
}

fn namedPortsJson(allocator: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    var ports = std.json.Array.init(allocator);
    for (try asValueList(input)) |entry| {
        var port: std.json.ObjectMap = .empty;
        try port.put(allocator, "name", .{ .string = try requiredString(entry, "name") });
        try port.put(allocator, "port", .{ .integer = try requiredInteger(entry, "port") });
        try ports.append(.{ .object = port });
    }
    return .{ .array = ports };
}

fn stringListJson(allocator: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    var array = std.json.Array.init(allocator);
    for (try asValueList(input)) |item| try array.append(.{ .string = try valueString(item) });
    return .{ .array = array };
}

fn fingerprintFromJson(allocator: std.mem.Allocator, body: []const u8) ProviderError![]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    return try requiredJsonString(asObject(parsed) orelse return error.ProviderBug, "fingerprint");
}

fn verifyPayloadDigest(bytes: []const u8, expected: []const u8) ProviderError!void {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &actual, expected)) return error.InvalidConfiguration;
}

fn sameIdentity(desired: value.Value, observed: value.Value, resource_kind: Kind) bool {
    const fields = switch (scopeOf(resource_kind)) {
        .global => &[_][]const u8{ "project_id", "name" },
        .region => &[_][]const u8{ "project_id", "region", "name" },
        .zone => &[_][]const u8{ "project_id", "zone", "name" },
    };
    for (fields) |field| if (!std.mem.eql(u8, requiredString(desired, field) catch return false, requiredString(observed, field) catch return false)) return false;
    return true;
}

fn onlySizeChanged(allocator: std.mem.Allocator, desired: value.Value, observed: value.Value) ProviderError!bool {
    var comparable = desired.clone(allocator) catch |err| return mapValueError(err);
    defer comparable.deinit(allocator);
    try replaceInteger(allocator, &comparable, "size_gb", try requiredInteger(observed, "size_gb"));
    const desired_json = comparable.canonicalJsonAlloc(allocator) catch |err| return mapValueError(err);
    defer allocator.free(desired_json);
    const observed_json = observed.canonicalJsonAlloc(allocator) catch |err| return mapValueError(err);
    defer allocator.free(observed_json);
    return std.mem.eql(u8, desired_json, observed_json);
}

fn replaceResolvedString(context: *provider_mod.OperationContext, inputs: *value.Value, name: []const u8, remote: []const u8) ProviderError!void {
    const desired = try requiredValue(inputs.*, name);
    const resolved = resolveString(context, desired) catch "";
    if (!std.mem.eql(u8, resolved, remote)) try replaceString(context.allocator, inputs, name, remote);
}

fn replaceString(allocator: std.mem.Allocator, inputs: *value.Value, name: []const u8, replacement: []const u8) ProviderError!void {
    try replaceValue(allocator, inputs, name, .{ .string = replacement });
}

fn replaceInteger(allocator: std.mem.Allocator, inputs: *value.Value, name: []const u8, replacement: i64) ProviderError!void {
    try replaceValue(allocator, inputs, name, .{ .integer = replacement });
}

fn replaceBoolean(allocator: std.mem.Allocator, inputs: *value.Value, name: []const u8, replacement: bool) ProviderError!void {
    try replaceValue(allocator, inputs, name, .{ .boolean = replacement });
}

fn replaceLabelsFromJson(allocator: std.mem.Allocator, inputs: *value.Value, candidate: ?std.json.Value) ProviderError!void {
    const label_object = if (candidate) |present| asObject(present) orelse return error.ProviderBug else std.json.ObjectMap.empty;
    const labels = allocator.alloc(LabelEntry, label_object.count()) catch return error.OutOfMemory;
    defer allocator.free(labels);
    var iterator = label_object.iterator();
    var label_count: usize = 0;
    while (iterator.next()) |entry| : (label_count += 1) {
        labels[label_count] = .{
            .key = entry.key_ptr.*,
            .value = jsonString(entry.value_ptr.*) orelse return error.ProviderBug,
        };
    }
    std.mem.sort(LabelEntry, labels, {}, LabelEntry.lessThan);

    const items = allocator.alloc(value.Value, labels.len) catch return error.OutOfMemory;
    defer allocator.free(items);
    var initialized: usize = 0;
    defer for (items[0..initialized]) |*item| item.deinit(allocator);
    for (labels, 0..) |label, index| {
        const fields = [_]value.Field{
            .{ .name = "key", .value = .{ .string = label.key } },
            .{ .name = "value", .value = .{ .string = label.value } },
        };
        items[index] = value.Value.initOwned(allocator, .{ .object = &fields }) catch |err| return mapValueError(err);
        initialized += 1;
    }
    var normalized = value.Value.initOwned(allocator, .{ .list = items }) catch |err| return mapValueError(err);
    defer normalized.deinit(allocator);
    try replaceValue(allocator, inputs, "labels", normalized);
}

const LabelEntry = struct {
    key: []const u8,
    value: []const u8,

    fn lessThan(_: void, left: LabelEntry, right: LabelEntry) bool {
        return std.mem.order(u8, left.key, right.key) == .lt;
    }
};

fn replaceValue(allocator: std.mem.Allocator, inputs: *value.Value, name: []const u8, replacement: value.Value) ProviderError!void {
    if (inputs.* != .object) return error.ProviderBug;
    const fields: []value.Field = @constCast(inputs.object);
    for (fields) |*field| {
        if (!std.mem.eql(u8, field.name, name)) continue;
        const owned = replacement.clone(allocator) catch |err| return mapValueError(err);
        field.value.deinit(allocator);
        field.value = owned;
        return;
    }
    return error.ProviderBug;
}

fn requiredValue(input: value.Value, name: []const u8) ProviderError!value.Value {
    if (input != .object) return error.InvalidConfiguration;
    for (input.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return error.InvalidConfiguration;
}

fn requiredString(input: value.Value, name: []const u8) ProviderError![]const u8 {
    return valueString(try requiredValue(input, name));
}

fn requiredInteger(input: value.Value, name: []const u8) ProviderError!i64 {
    return switch (try requiredValue(input, name)) {
        .integer => |integer| integer,
        else => error.InvalidConfiguration,
    };
}

fn requiredBoolean(input: value.Value, name: []const u8) ProviderError!bool {
    return switch (try requiredValue(input, name)) {
        .boolean => |boolean| boolean,
        else => error.InvalidConfiguration,
    };
}

fn requiredList(input: value.Value, name: []const u8) ProviderError![]const value.Value {
    return asValueList(try requiredValue(input, name));
}

fn asValueList(input: value.Value) ProviderError![]const value.Value {
    return switch (input) {
        .list => |items| items,
        else => error.InvalidConfiguration,
    };
}

fn valueString(input: value.Value) ProviderError![]const u8 {
    return switch (input) {
        .string => |string| string,
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

fn resolveSecret(context: *provider_mod.OperationContext, input: value.Value) ProviderError!value.SecretReference {
    return switch (input) {
        .secret_ref => |reference| reference,
        .output_ref => |reference| context.resolveOutputSecret(reference),
        else => error.InvalidConfiguration,
    };
}

fn integerString(allocator: std.mem.Allocator, integer: i64) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{integer}) catch return error.OutOfMemory;
}

fn upperAlloc(allocator: std.mem.Allocator, input: []const u8) ProviderError![]const u8 {
    const result = allocator.dupe(u8, input) catch return error.OutOfMemory;
    for (result) |*character| character.* = std.ascii.toUpper(character.*);
    return result;
}

fn asObject(candidate: std.json.Value) ?std.json.ObjectMap {
    return switch (candidate) {
        .object => |object| object,
        else => null,
    };
}

fn asArray(candidate: std.json.Value) ?std.json.Array {
    return switch (candidate) {
        .array => |array| array,
        else => null,
    };
}

fn jsonString(candidate: ?std.json.Value) ?[]const u8 {
    const present = candidate orelse return null;
    return switch (present) {
        .string => |string| string,
        else => null,
    };
}

fn jsonInteger(candidate: ?std.json.Value) ?i64 {
    const present = candidate orelse return null;
    return switch (present) {
        .integer => |integer| integer,
        else => null,
    };
}

fn jsonBool(candidate: ?std.json.Value) ?bool {
    const present = candidate orelse return null;
    return switch (present) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn jsonIntegerOrString(candidate: ?std.json.Value) ProviderError!i64 {
    const present = candidate orelse return error.ProviderBug;
    return switch (present) {
        .integer => |integer| integer,
        .string => |string| std.fmt.parseInt(i64, string, 10) catch return error.ProviderBug,
        else => error.ProviderBug,
    };
}

fn requiredJsonString(object: std.json.ObjectMap, name: []const u8) ProviderError![]const u8 {
    return jsonString(object.get(name)) orelse error.ProviderBug;
}

fn lastSegment(input: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, input, '/')) |index| input[index + 1 ..] else input;
}

const InstanceIps = struct { internal: []const u8 = "", external: []const u8 = "" };

fn instanceIps(remote: std.json.ObjectMap) InstanceIps {
    const interfaces = asArray(remote.get("networkInterfaces") orelse return .{}) orelse return .{};
    if (interfaces.items.len == 0) return .{};
    const interface = asObject(interfaces.items[0]) orelse return .{};
    const internal = jsonString(interface.get("networkIP")) orelse "";
    const configs = asArray(interface.get("accessConfigs") orelse return .{ .internal = internal }) orelse return .{ .internal = internal };
    if (configs.items.len == 0) return .{ .internal = internal };
    const access = asObject(configs.items[0]) orelse return .{ .internal = internal };
    return .{ .internal = internal, .external = jsonString(access.get("natIP")) orelse "" };
}

fn groupStatus(remote: std.json.ObjectMap) []const u8 {
    const status = asObject(remote.get("status") orelse return "UNKNOWN") orelse return "UNKNOWN";
    return if (jsonBool(status.get("isStable")) orelse false) "STABLE" else "UPDATING";
}

fn mapValueError(err: anyerror) ProviderError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ProviderBug,
    };
}
