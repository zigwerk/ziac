const std = @import("std");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;

const Kind = enum { folder, project, lien, billing, service_identity };

pub const Handler = struct {
    client: *client_mod.Client,
    operation_policy: operation.Policy = .{},

    pub fn supports(node: resource.ResourceNode) bool {
        return kindOf(node) != null;
    }

    pub fn read(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (context.operation_handle) |handle| {
            const payload = try self.waitOperationAlloc(context, kind, handle);
            defer context.allocator.free(payload);
            const response = try operationResponseAlloc(context.allocator, payload);
            defer context.allocator.free(response);
            if (std.mem.eql(u8, response, "{}")) return .absent;
            return .{ .present = try resultFromJson(context, node, kind, response) };
        }

        const owned_physical = try physicalForReadAlloc(context, node, kind, physical_override);
        defer if (owned_physical.owned) context.allocator.free(owned_physical.value);
        const physical = owned_physical.value;
        if (physical.len == 0) return .absent;
        try validatePhysical(kind, physical);
        const path = try readPathAlloc(context.allocator, kind, physical);
        defer context.allocator.free(path);
        var response = self.request(context, readApiFor(kind), "GET", path, "") catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try resultFromJson(context, node, kind, response.body) };
    }

    pub fn diff(context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(kind, observed.physical_id);
        if (kind == .lien or kind == .service_identity) {
            return provider_mod.DiffResult.init(context.allocator, if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash)) .noop else .replace, &.{if (kind == .lien) "immutable lien differs" else "service identity target differs"});
        }
        const remote_json = outputString(observed.*, "__remote_spec") orelse return error.ProviderBug;
        var remote = std.json.parseFromSlice(std.json.Value, context.allocator, remote_json, .{}) catch return error.ProviderBug;
        defer remote.deinit();
        const object = jsonObject(remote.value) orelse return error.ProviderBug;
        if (kind == .project) {
            const remote_project_id = jsonString(object.get("projectId")) orelse return error.ProviderBug;
            if (!std.mem.eql(u8, remote_project_id, try requiredString(context, node.inputs, "project_id")))
                return provider_mod.DiffResult.init(context.allocator, .replace, &.{"immutable project ID differs"});
        }
        return provider_mod.DiffResult.init(context.allocator, if (try remoteMatches(context, node, kind, object)) .noop else .update, &.{"organization foundation configuration differs"});
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        const path = try createPathAlloc(context, node, kind);
        defer context.allocator.free(path);
        const body = try createBodyAlloc(context, node, kind);
        defer context.allocator.free(body);
        var response = try self.request(context, apiFor(kind), mutationMethod(kind), path, body);
        defer response.deinit(context.allocator);
        return switch (kind) {
            .folder, .project, .service_identity => pendingResult(context, node, kind, response.body),
            .lien, .billing => resultFromJson(context, node, kind, response.body),
        };
    }

    pub fn update(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(kind, observed.physical_id);
        if (kind == .lien or kind == .service_identity) return error.InvalidConfiguration;
        if (kind == .billing) {
            const body = try billingBodyAlloc(context, node, false);
            defer context.allocator.free(body);
            const path = try readPathAlloc(context.allocator, kind, observed.physical_id);
            defer context.allocator.free(path);
            var response = try self.request(context, .cloud_billing, "PUT", path, body);
            defer response.deinit(context.allocator);
            return resultFromJson(context, node, kind, response.body);
        }

        const remote_json = outputString(observed.*, "__remote_spec") orelse return error.ProviderBug;
        var remote = std.json.parseFromSlice(std.json.Value, context.allocator, remote_json, .{}) catch return error.ProviderBug;
        defer remote.deinit();
        const object = jsonObject(remote.value) orelse return error.ProviderBug;
        const desired_parent = try requiredString(context, node.inputs, "parent");
        const remote_parent = jsonString(object.get("parent")) orelse return error.ProviderBug;
        if (!std.mem.eql(u8, desired_parent, remote_parent)) {
            const path = try std.fmt.allocPrint(context.allocator, "/v3/{s}:move", .{observed.physical_id});
            defer context.allocator.free(path);
            const body = std.json.Stringify.valueAlloc(context.allocator, .{ .destinationParent = desired_parent }, .{}) catch return error.OutOfMemory;
            defer context.allocator.free(body);
            var response = try self.request(context, .resource_manager, "POST", path, body);
            defer response.deinit(context.allocator);
            return pendingResultWithPhysical(context, node, kind, observed.physical_id, response.body);
        }

        const mask = try changedMaskAlloc(context, node, kind, object);
        defer context.allocator.free(mask);
        if (mask.len == 0) return error.InvalidConfiguration;
        const etag = jsonString(object.get("etag")) orelse return error.Conflict;
        const body = try patchBodyAlloc(context, node, kind, observed.physical_id, etag, mask);
        defer context.allocator.free(body);
        const path = try std.fmt.allocPrint(context.allocator, "/v3/{s}?updateMask={s}", .{ observed.physical_id, mask });
        defer context.allocator.free(path);
        var response = try self.request(context, .resource_manager, "PATCH", path, body);
        defer response.deinit(context.allocator);
        return pendingResultWithPhysical(context, node, kind, observed.physical_id, response.body);
    }

    pub fn delete(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical: []const u8) ProviderError!void {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(kind, physical);
        switch (kind) {
            .folder, .project => {
                if (!try requiredBoolean(node.inputs, "request_delete") or !context.destructive_confirmation) return error.DestructiveConfirmationRequired;
                const path = try std.fmt.allocPrint(context.allocator, "/v3/{s}", .{physical});
                defer context.allocator.free(path);
                var response = self.request(context, .resource_manager, "DELETE", path, "") catch |err| {
                    if (err == error.NotFound) return;
                    return err;
                };
                defer response.deinit(context.allocator);
                const handle = try operationNameAlloc(context.allocator, response.body);
                defer context.allocator.free(handle);
                const payload = try self.waitOperationAlloc(context, kind, handle);
                context.allocator.free(payload);
            },
            .lien => {
                if (!std.mem.eql(u8, try requiredLiteralString(node.inputs, "removal_policy"), "delete") or !context.destructive_confirmation) return error.DestructiveConfirmationRequired;
                const path = try std.fmt.allocPrint(context.allocator, "/v3/{s}", .{physical});
                defer context.allocator.free(path);
                var response = self.request(context, .resource_manager, "DELETE", path, "") catch |err| {
                    if (err == error.NotFound) return;
                    return err;
                };
                response.deinit(context.allocator);
            },
            .billing => {
                if (!std.mem.eql(u8, try requiredLiteralString(node.inputs, "removal_policy"), "detach") or !context.destructive_confirmation) return error.DestructiveConfirmationRequired;
                const path = try readPathAlloc(context.allocator, kind, physical);
                defer context.allocator.free(path);
                const body = try billingBodyAlloc(context, node, true);
                defer context.allocator.free(body);
                var response = try self.request(context, .cloud_billing, "PUT", path, body);
                response.deinit(context.allocator);
            },
            .service_identity => return error.InvalidConfiguration,
        }
    }

    pub fn importResource(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical: []const u8) ProviderError!provider_mod.ResourceResult {
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(kind, physical);
        var found = try self.read(context, node, physical);
        defer found.deinit();
        return switch (found) {
            .absent => error.NotFound,
            .present => |present| present.clone(context.allocator),
        };
    }

    fn waitOperationAlloc(self: Handler, context: *provider_mod.OperationContext, kind: Kind, handle: []const u8) ProviderError![]const u8 {
        const endpoint = switch (kind) {
            .folder, .project => self.client.endpoints.resource_manager,
            .service_identity => self.client.endpoints.service_usage,
            .lien, .billing => return error.InvalidConfiguration,
        };
        const version = if (kind == .service_identity) "v1beta1" else "v3";
        const base = try std.fmt.allocPrint(context.allocator, "{s}/{s}", .{ std.mem.trimEnd(u8, endpoint, "/"), version });
        defer context.allocator.free(base);
        var target = operation.Target.genericAlloc(context.allocator, base, handle) catch return error.OutOfMemory;
        defer target.deinit(context.allocator);
        var completed = try operation.waitAlloc(self.client, context, target, self.operation_policy);
        defer completed.deinit(context.allocator);
        return context.allocator.dupe(u8, completed.payload) catch error.OutOfMemory;
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, api: client_mod.Api, method: []const u8, path: []const u8, body: []const u8) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, .{ .api = api, .method = method, .path = path, .body = body }, &diagnostic);
    }
};

const Physical = struct { value: []const u8, owned: bool };

fn kindOf(node: resource.ResourceNode) ?Kind {
    const mappings = [_]struct { []const u8, Kind }{
        .{ "gcp.resourcemanager.Folder", .folder },
        .{ "gcp.resourcemanager.Project", .project },
        .{ "gcp.resourcemanager.Lien", .lien },
        .{ "gcp.billing.ProjectBillingAssociation", .billing },
        .{ "gcp.serviceusage.ServiceIdentity", .service_identity },
    };
    for (mappings) |mapping| if (std.mem.eql(u8, node.type_name, mapping[0])) return mapping[1];
    return null;
}

fn apiFor(kind: Kind) client_mod.Api {
    return switch (kind) {
        .folder, .project, .lien => .resource_manager,
        .billing => .cloud_billing,
        .service_identity => .service_usage,
    };
}

fn readApiFor(kind: Kind) client_mod.Api {
    return if (kind == .service_identity) .iam else apiFor(kind);
}

fn mutationMethod(kind: Kind) []const u8 {
    return if (kind == .billing) "PUT" else "POST";
}

fn physicalForReadAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, override: ?[]const u8) ProviderError!Physical {
    if (override orelse context.physical_id) |physical| return .{ .value = physical, .owned = false };
    return switch (kind) {
        .project => .{ .value = try std.fmt.allocPrint(context.allocator, "projects/{s}", .{try requiredLiteralString(node.inputs, "project_id")}), .owned = true },
        .billing => .{ .value = try requiredString(context, node.inputs, "project"), .owned = false },
        .folder, .lien, .service_identity => .{ .value = "", .owned = false },
    };
}

fn validatePhysical(kind: Kind, physical: []const u8) ProviderError!void {
    if (physical.len == 0 or std.mem.indexOfAny(u8, physical, "?# \t\r\n") != null) return error.InvalidConfiguration;
    const valid = switch (kind) {
        .folder => canonicalName(physical, "folders/"),
        .project => canonicalProject(physical),
        .lien => canonicalName(physical, "liens/"),
        .billing => canonicalProject(physical) or (std.mem.startsWith(u8, physical, "projects/") and std.mem.endsWith(u8, physical, "/billingInfo")),
        .service_identity => std.mem.indexOfScalar(u8, physical, '@') != null,
    };
    if (!valid) return error.InvalidConfiguration;
}

fn readPathAlloc(allocator: std.mem.Allocator, kind: Kind, physical: []const u8) ProviderError![]const u8 {
    return switch (kind) {
        .folder, .project, .lien => std.fmt.allocPrint(allocator, "/v3/{s}", .{physical}) catch error.OutOfMemory,
        .billing => if (std.mem.endsWith(u8, physical, "/billingInfo"))
            std.fmt.allocPrint(allocator, "/v1/{s}", .{physical}) catch error.OutOfMemory
        else
            std.fmt.allocPrint(allocator, "/v1/{s}/billingInfo", .{physical}) catch error.OutOfMemory,
        .service_identity => std.fmt.allocPrint(allocator, "/v1/projects/-/serviceAccounts/{s}", .{physical}) catch error.OutOfMemory,
    };
}

fn createPathAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    return switch (kind) {
        .folder => context.allocator.dupe(u8, "/v3/folders") catch error.OutOfMemory,
        .project => context.allocator.dupe(u8, "/v3/projects") catch error.OutOfMemory,
        .lien => context.allocator.dupe(u8, "/v3/liens") catch error.OutOfMemory,
        .billing => blk: {
            const project = try requiredString(context, node.inputs, "project");
            break :blk std.fmt.allocPrint(context.allocator, "/v1/{s}/billingInfo", .{project}) catch error.OutOfMemory;
        },
        .service_identity => blk: {
            const number = try requiredString(context, node.inputs, "project_number");
            const project = if (std.mem.startsWith(u8, number, "projects/")) number else try std.fmt.allocPrint(context.allocator, "projects/{s}", .{number});
            defer if (!std.mem.startsWith(u8, number, "projects/")) context.allocator.free(project);
            break :blk std.fmt.allocPrint(context.allocator, "/v1beta1/{s}/services/{s}:generateServiceIdentity", .{ project, try requiredLiteralString(node.inputs, "service") }) catch error.OutOfMemory;
        },
    };
}

fn createBodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    if (kind == .billing) return billingBodyAlloc(context, node, false);
    if (kind == .service_identity) return context.allocator.dupe(u8, "{}") catch error.OutOfMemory;
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = std.json.ObjectMap.empty;
    switch (kind) {
        .folder => {
            try root.put(arena, "parent", .{ .string = try requiredString(context, node.inputs, "parent") });
            try root.put(arena, "displayName", .{ .string = try requiredLiteralString(node.inputs, "display_name") });
        },
        .project => {
            try root.put(arena, "parent", .{ .string = try requiredString(context, node.inputs, "parent") });
            try root.put(arena, "projectId", .{ .string = try requiredLiteralString(node.inputs, "project_id") });
            const display = try requiredLiteralString(node.inputs, "display_name");
            if (display.len != 0) try root.put(arena, "displayName", .{ .string = display });
            try root.put(arena, "labels", try valueJson(arena, try requiredValue(node.inputs, "labels")));
        },
        .lien => {
            try root.put(arena, "parent", .{ .string = try requiredString(context, node.inputs, "parent") });
            try root.put(arena, "reason", .{ .string = try requiredLiteralString(node.inputs, "reason") });
            try root.put(arena, "origin", .{ .string = try requiredLiteralString(node.inputs, "origin") });
            try root.put(arena, "restrictions", try valueJson(arena, try requiredValue(node.inputs, "restrictions")));
        },
        .billing, .service_identity => unreachable,
    }
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch error.OutOfMemory;
}

fn billingBodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, detach: bool) ProviderError![]const u8 {
    return std.json.Stringify.valueAlloc(context.allocator, .{ .billingAccountName = if (detach) "" else try requiredLiteralString(node.inputs, "billing_account") }, .{}) catch error.OutOfMemory;
}

fn patchBodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, physical: []const u8, etag: []const u8, mask: []const u8) ProviderError![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = std.json.ObjectMap.empty;
    try root.put(arena, "name", .{ .string = physical });
    try root.put(arena, "etag", .{ .string = etag });
    if (std.mem.indexOf(u8, mask, "displayName") != null) try root.put(arena, "displayName", .{ .string = try requiredLiteralString(node.inputs, "display_name") });
    if (kind == .project and std.mem.indexOf(u8, mask, "labels") != null) try root.put(arena, "labels", try valueJson(arena, try requiredValue(node.inputs, "labels")));
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch error.OutOfMemory;
}

fn pendingResult(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, body: []const u8) ProviderError!provider_mod.ResourceResult {
    const physical = switch (kind) {
        .project => try std.fmt.allocPrint(context.allocator, "projects/{s}", .{try requiredLiteralString(node.inputs, "project_id")}),
        .folder, .service_identity => try operationNameAlloc(context.allocator, body),
        .lien, .billing => unreachable,
    };
    defer context.allocator.free(physical);
    return pendingResultWithPhysical(context, node, kind, physical, body);
}

fn pendingResultWithPhysical(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, physical: []const u8, body: []const u8) ProviderError!provider_mod.ResourceResult {
    const handle = try operationNameAlloc(context.allocator, body);
    defer context.allocator.free(handle);
    const outputs = [_]state.StateOutput{.{ .name = primaryOutput(kind), .value = .{ .unknown_reason = "Google operation pending" } }};
    var result = try provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &outputs, handle);
    result.completed = false;
    return result;
}

fn resultFromJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, body: []const u8) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const physical = switch (kind) {
        .folder, .project, .lien, .billing => jsonString(root.get("name")) orelse return error.ProviderBug,
        .service_identity => jsonString(root.get("email")) orelse return error.ProviderBug,
    };
    try validatePhysical(kind, physical);
    const matches = if (kind == .service_identity) true else try remoteMatches(context, node, kind, root);
    const observed: value.Value = if (matches) node.inputs else .{ .unknown_reason = "remote organization foundation resource drifted" };
    var outputs: [8]state.StateOutput = undefined;
    var count: usize = 0;
    switch (kind) {
        .folder => {
            outputs[count] = .{ .name = "name", .value = .{ .string = physical } };
            count += 1;
            outputs[count] = .{ .name = "folder_id", .value = .{ .string = physical["folders/".len..] } };
            count += 1;
            outputs[count] = .{ .name = "state", .value = .{ .string = jsonString(root.get("state")) orelse "STATE_UNSPECIFIED" } };
            count += 1;
            outputs[count] = .{ .name = "etag", .value = .{ .string = jsonString(root.get("etag")) orelse "" } };
            count += 1;
        },
        .project => {
            outputs[count] = .{ .name = "name", .value = .{ .string = physical } };
            count += 1;
            outputs[count] = .{ .name = "project_id", .value = .{ .string = jsonString(root.get("projectId")) orelse return error.ProviderBug } };
            count += 1;
            outputs[count] = .{ .name = "project_number", .value = .{ .string = physical["projects/".len..] } };
            count += 1;
            outputs[count] = .{ .name = "state", .value = .{ .string = jsonString(root.get("state")) orelse "STATE_UNSPECIFIED" } };
            count += 1;
            outputs[count] = .{ .name = "etag", .value = .{ .string = jsonString(root.get("etag")) orelse "" } };
            count += 1;
        },
        .lien => {
            outputs[count] = .{ .name = "name", .value = .{ .string = physical } };
            count += 1;
            outputs[count] = .{ .name = "create_time", .value = .{ .string = jsonString(root.get("createTime")) orelse "" } };
            count += 1;
        },
        .billing => {
            outputs[count] = .{ .name = "name", .value = .{ .string = physical } };
            count += 1;
            outputs[count] = .{ .name = "billing_account", .value = .{ .string = jsonString(root.get("billingAccountName")) orelse "" } };
            count += 1;
            outputs[count] = .{ .name = "billing_enabled", .value = .{ .boolean = jsonBool(root.get("billingEnabled")) orelse false } };
            count += 1;
        },
        .service_identity => {
            outputs[count] = .{ .name = "email", .value = .{ .string = physical } };
            count += 1;
            outputs[count] = .{ .name = "unique_id", .value = .{ .string = jsonString(root.get("uniqueId")) orelse "" } };
            count += 1;
        },
    }
    outputs[count] = .{ .name = "__remote_spec", .value = .{ .string = body } };
    count += 1;
    return provider_mod.ResourceResult.init(context.allocator, physical, observed, outputs[0..count], null);
}

fn remoteMatches(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, remote: std.json.ObjectMap) ProviderError!bool {
    return switch (kind) {
        .folder => std.mem.eql(u8, try requiredString(context, node.inputs, "parent"), jsonString(remote.get("parent")) orelse "") and std.mem.eql(u8, try requiredLiteralString(node.inputs, "display_name"), jsonString(remote.get("displayName")) orelse ""),
        .project => projectMatches(context, node, remote),
        .lien => std.mem.eql(u8, try requiredString(context, node.inputs, "parent"), jsonString(remote.get("parent")) orelse "") and std.mem.eql(u8, try requiredLiteralString(node.inputs, "reason"), jsonString(remote.get("reason")) orelse "") and std.mem.eql(u8, try requiredLiteralString(node.inputs, "origin"), jsonString(remote.get("origin")) orelse "") and try listMatches(try requiredValue(node.inputs, "restrictions"), remote.get("restrictions")),
        .billing => std.mem.eql(u8, try requiredLiteralString(node.inputs, "billing_account"), jsonString(remote.get("billingAccountName")) orelse ""),
        .service_identity => true,
    };
}

fn projectMatches(context: *provider_mod.OperationContext, node: resource.ResourceNode, remote: std.json.ObjectMap) ProviderError!bool {
    const display = try requiredLiteralString(node.inputs, "display_name");
    const remote_display = jsonString(remote.get("displayName")) orelse "";
    return std.mem.eql(u8, try requiredString(context, node.inputs, "parent"), jsonString(remote.get("parent")) orelse "") and
        std.mem.eql(u8, try requiredLiteralString(node.inputs, "project_id"), jsonString(remote.get("projectId")) orelse "") and
        (display.len == 0 or std.mem.eql(u8, display, remote_display)) and
        try objectMatches(try requiredValue(node.inputs, "labels"), remote.get("labels"));
}

fn changedMaskAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, remote: std.json.ObjectMap) ProviderError![]const u8 {
    var fields = std.ArrayList([]const u8).empty;
    defer fields.deinit(context.allocator);
    const desired_display = try requiredLiteralString(node.inputs, "display_name");
    if ((kind == .folder or desired_display.len != 0) and !std.mem.eql(u8, desired_display, jsonString(remote.get("displayName")) orelse "")) try fields.append(context.allocator, "displayName");
    if (kind == .project and !try objectMatches(try requiredValue(node.inputs, "labels"), remote.get("labels"))) try fields.append(context.allocator, "labels");
    var bytes = std.ArrayList(u8).empty;
    errdefer bytes.deinit(context.allocator);
    for (fields.items, 0..) |field, index| {
        if (index != 0) try bytes.appendSlice(context.allocator, "%2C");
        try bytes.appendSlice(context.allocator, field);
    }
    return bytes.toOwnedSlice(context.allocator) catch error.OutOfMemory;
}

fn operationNameAlloc(allocator: std.mem.Allocator, body: []const u8) ProviderError![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const name = jsonString(root.get("name")) orelse return error.ProviderBug;
    if (std.mem.indexOf(u8, name, "operations/") == null) return error.ProviderBug;
    return allocator.dupe(u8, name) catch error.OutOfMemory;
}

fn operationResponseAlloc(allocator: std.mem.Allocator, body: []const u8) ProviderError![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const response = root.get("response") orelse return error.ProviderBug;
    return std.json.Stringify.valueAlloc(allocator, response, .{}) catch error.OutOfMemory;
}

fn primaryOutput(kind: Kind) []const u8 {
    return switch (kind) {
        .folder, .project, .lien, .billing => "name",
        .service_identity => "email",
    };
}

fn requiredValue(source: value.Value, name: []const u8) ProviderError!value.Value {
    if (source != .object) return error.InvalidConfiguration;
    for (source.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return error.InvalidConfiguration;
}

fn requiredLiteralString(source: value.Value, name: []const u8) ProviderError![]const u8 {
    return switch (try requiredValue(source, name)) {
        .string => |text| text,
        else => error.InvalidConfiguration,
    };
}

fn requiredString(context: *provider_mod.OperationContext, source: value.Value, name: []const u8) ProviderError![]const u8 {
    return switch (try requiredValue(source, name)) {
        .string => |text| text,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}

fn requiredBoolean(source: value.Value, name: []const u8) ProviderError!bool {
    return switch (try requiredValue(source, name)) {
        .boolean => |present| present,
        else => error.InvalidConfiguration,
    };
}

fn valueJson(arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    return switch (source) {
        .string => |text| .{ .string = text },
        .integer => |number| .{ .integer = number },
        .boolean => |present| .{ .bool = present },
        .list => |items| blk: {
            var array = std.json.Array.init(arena);
            for (items) |item| array.append(try valueJson(arena, item)) catch return error.OutOfMemory;
            break :blk .{ .array = array };
        },
        .object => |fields| blk: {
            var object = std.json.ObjectMap.empty;
            for (fields) |field| object.put(arena, field.name, try valueJson(arena, field.value)) catch return error.OutOfMemory;
            break :blk .{ .object = object };
        },
        .output_ref, .secret_ref, .unknown_reason => error.InvalidConfiguration,
    };
}

fn objectMatches(desired: value.Value, remote_value: ?std.json.Value) ProviderError!bool {
    if (desired != .object) return error.InvalidConfiguration;
    const remote = jsonObject(remote_value orelse .{ .object = .empty }) orelse return false;
    if (desired.object.len != remote.count()) return false;
    for (desired.object) |field| {
        const wanted = switch (field.value) {
            .string => |text| text,
            else => return error.InvalidConfiguration,
        };
        if (!std.mem.eql(u8, wanted, jsonString(remote.get(field.name)) orelse "")) return false;
    }
    return true;
}

fn listMatches(desired: value.Value, remote_value: ?std.json.Value) ProviderError!bool {
    if (desired != .list) return error.InvalidConfiguration;
    const remote = jsonArray(remote_value orelse return false) orelse return false;
    if (desired.list.len != remote.items.len) return false;
    for (desired.list, remote.items) |wanted, found| {
        if (wanted != .string or found != .string or !std.mem.eql(u8, wanted.string, found.string)) return false;
    }
    return true;
}

fn outputString(result: provider_mod.ResourceResult, name: []const u8) ?[]const u8 {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name)) return switch (item.value) {
        .string => |text| text,
        else => null,
    };
    return null;
}

fn jsonObject(candidate: std.json.Value) ?std.json.ObjectMap {
    return switch (candidate) {
        .object => |object| object,
        else => null,
    };
}

fn jsonArray(candidate: std.json.Value) ?std.json.Array {
    return switch (candidate) {
        .array => |array| array,
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

fn jsonBool(candidate: ?std.json.Value) ?bool {
    const present = candidate orelse return null;
    return switch (present) {
        .bool => |value_bool| value_bool,
        else => null,
    };
}

fn canonicalName(candidate: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, candidate, prefix)) return false;
    const suffix = candidate[prefix.len..];
    if (suffix.len == 0) return false;
    for (suffix) |char| if (!std.ascii.isDigit(char)) return false;
    return true;
}

fn canonicalProject(candidate: []const u8) bool {
    if (!std.mem.startsWith(u8, candidate, "projects/")) return false;
    const suffix = candidate["projects/".len..];
    if (suffix.len == 0 or std.mem.indexOfScalar(u8, suffix, '/') != null) return false;
    for (suffix) |char| if (!std.ascii.isAlphanumeric(char) and char != '-') return false;
    return true;
}
