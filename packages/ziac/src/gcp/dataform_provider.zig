const std = @import("std");
const client_mod = @import("client.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;
const Kind = enum { repository, workspace, release_config, workflow_config };

pub const Handler = struct {
    client: *client_mod.Client,

    pub fn supports(node: resource.ResourceNode) bool {
        return kindOf(node) != null;
    }

    pub fn read(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        const expected = try physicalAlloc(context.allocator, node, kind);
        defer context.allocator.free(expected);
        const physical = physical_override orelse context.physical_id orelse expected;
        try validatePhysical(node, kind, physical);
        const path = try std.fmt.allocPrint(context.allocator, "/v1beta1/{s}", .{physical});
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
            return provider_mod.DiffResult.init(context.allocator, .replace, &.{"Dataform resource identity changed"});
        const desired_json = try bodyAlloc(context, node, kind);
        defer context.allocator.free(desired_json);
        const remote_json = outputString(observed.*, "__remote_spec") orelse return provider_mod.DiffResult.init(context.allocator, .update, &.{"Dataform configuration differs"});
        const mask = try changedMaskAlloc(context.allocator, desired_json, remote_json);
        defer context.allocator.free(mask);
        if (mask.len == 0) return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        return provider_mod.DiffResult.init(context.allocator, .update, &.{"Dataform configuration differs"});
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        const path = try createPathAlloc(context.allocator, node, kind);
        defer context.allocator.free(path);
        const body = try bodyAlloc(context, node, kind);
        defer context.allocator.free(body);
        var response = try self.request(context, "POST", path, body);
        defer response.deinit(context.allocator);
        const physical = try physicalAlloc(context.allocator, node, kind);
        defer context.allocator.free(physical);
        return resultFromJson(context, node, kind, physical, response.body);
    }

    pub fn update(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(node, kind, observed.physical_id);
        const desired_json = try bodyAlloc(context, node, kind);
        defer context.allocator.free(desired_json);
        const remote_json = outputString(observed.*, "__remote_spec") orelse return error.ProviderBug;
        const mask = try changedMaskAlloc(context.allocator, desired_json, remote_json);
        defer context.allocator.free(mask);
        if (mask.len == 0) return observed.clone(context.allocator);
        const encoded = try percentEncodeAlloc(context.allocator, mask);
        defer context.allocator.free(encoded);
        const path = try std.fmt.allocPrint(context.allocator, "/v1beta1/{s}?updateMask={s}", .{ observed.physical_id, encoded });
        defer context.allocator.free(path);
        var response = try self.request(context, "PATCH", path, desired_json);
        defer response.deinit(context.allocator);
        return resultFromJson(context, node, kind, observed.physical_id, response.body);
    }

    pub fn delete(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical: []const u8) ProviderError!void {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(node, kind, physical);
        if (!std.mem.eql(u8, try requiredString(node.inputs, "removal_policy"), "delete") or !context.destructive_confirmation)
            return error.DestructiveConfirmationRequired;
        const path = try std.fmt.allocPrint(context.allocator, "/v1beta1/{s}", .{physical});
        defer context.allocator.free(path);
        var response = self.request(context, "DELETE", path, "") catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        response.deinit(context.allocator);
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

    fn request(self: Handler, context: *provider_mod.OperationContext, method: []const u8, path: []const u8, body: []const u8) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, .{ .api = .dataform, .method = method, .path = path, .body = body }, &diagnostic);
    }
};

fn kindOf(node: resource.ResourceNode) ?Kind {
    const mappings = [_]struct { []const u8, Kind }{
        .{ "gcp.dataform.Repository", .repository },
        .{ "gcp.dataform.Workspace", .workspace },
        .{ "gcp.dataform.ReleaseConfig", .release_config },
        .{ "gcp.dataform.WorkflowConfig", .workflow_config },
    };
    for (mappings) |mapping| if (std.mem.eql(u8, node.type_name, mapping[0])) return mapping[1];
    return null;
}

fn collection(kind: Kind) []const u8 {
    return switch (kind) {
        .repository => "repositories",
        .workspace => "workspaces",
        .release_config => "releaseConfigs",
        .workflow_config => "workflowConfigs",
    };
}

fn idParameter(kind: Kind) []const u8 {
    return switch (kind) {
        .repository => "repositoryId",
        .workspace => "workspaceId",
        .release_config => "releaseConfigId",
        .workflow_config => "workflowConfigId",
    };
}

fn parentAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]u8 {
    const project = try requiredString(node.inputs, "project_id");
    const location = try requiredString(node.inputs, "location");
    if (kind == .repository) return std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}", .{ project, location }) catch error.OutOfMemory;
    return std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}/repositories/{s}", .{ project, location, try requiredString(node.inputs, "repository_name") }) catch error.OutOfMemory;
}

fn physicalAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]u8 {
    const parent = try parentAlloc(allocator, node, kind);
    defer allocator.free(parent);
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ parent, collection(kind), try requiredString(node.inputs, "name") }) catch error.OutOfMemory;
}

fn validatePhysical(node: resource.ResourceNode, kind: Kind, physical: []const u8) ProviderError!void {
    if (std.mem.indexOfAny(u8, physical, "?# \t\r\n") != null) return error.InvalidConfiguration;
    const expected = try physicalAlloc(std.heap.page_allocator, node, kind);
    defer std.heap.page_allocator.free(expected);
    if (!std.mem.eql(u8, expected, physical)) return error.InvalidConfiguration;
}

fn createPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]u8 {
    const parent = try parentAlloc(allocator, node, kind);
    defer allocator.free(parent);
    return std.fmt.allocPrint(allocator, "/v1beta1/{s}/{s}?{s}={s}", .{ parent, collection(kind), idParameter(kind), try requiredString(node.inputs, "name") }) catch error.OutOfMemory;
}

fn bodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind) ProviderError![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = std.json.ObjectMap.empty;
    switch (kind) {
        .repository => try repositoryBody(context, arena, node.inputs, &root),
        .workspace => {},
        .release_config => try releaseBody(context, arena, node.inputs, &root),
        .workflow_config => try workflowBody(context, arena, node.inputs, &root),
    }
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch error.OutOfMemory;
}

fn repositoryBody(context: *provider_mod.OperationContext, arena: std.mem.Allocator, inputs: value.Value, root: *std.json.ObjectMap) ProviderError!void {
    inline for (.{ .{ "display_name", "displayName" }, .{ "service_account", "serviceAccount" } }) |mapping| {
        const text = try requiredString(inputs, mapping[0]);
        if (text.len != 0) try root.put(arena, mapping[1], .{ .string = text });
    }
    const kms = try resolvedString(context, inputs, "kms_key_name");
    if (kms.len != 0) try root.put(arena, "kmsKeyName", .{ .string = kms });
    const labels = try requiredValue(inputs, "labels");
    if (!valueEmpty(labels)) try root.put(arena, "labels", try renameJson(context, arena, labels));
    const overrides = try requiredValue(inputs, "workspace_compilation_overrides");
    if (!valueEmpty(overrides)) try root.put(arena, "workspaceCompilationOverrides", try compactRenameJson(context, arena, overrides));
    const git = try requiredValue(inputs, "git_remote");
    if (valueObject(git)) |fields| if (fields.len != 0) {
        var remote = std.json.ObjectMap.empty;
        try remote.put(arena, "url", .{ .string = try objectString(fields, "url") });
        try remote.put(arena, "defaultBranch", .{ .string = try objectString(fields, "default_branch") });
        const authentication = valueObject(try objectValue(fields, "authentication")) orelse return error.InvalidConfiguration;
        const auth_kind = try objectString(authentication, "kind");
        if (std.mem.eql(u8, auth_kind, "token")) {
            try remote.put(arena, "authenticationTokenSecretVersion", .{ .string = try objectString(authentication, "token_secret_version") });
        } else if (std.mem.eql(u8, auth_kind, "ssh")) {
            var ssh = std.json.ObjectMap.empty;
            try ssh.put(arena, "userPrivateKeySecretVersion", .{ .string = try objectString(authentication, "private_key_secret_version") });
            try ssh.put(arena, "hostPublicKey", .{ .string = try objectString(authentication, "host_public_key") });
            try remote.put(arena, "sshAuthenticationConfig", .{ .object = ssh });
        } else return error.InvalidConfiguration;
        try root.put(arena, "gitRemoteSettings", .{ .object = remote });
    };
}

fn releaseBody(context: *provider_mod.OperationContext, arena: std.mem.Allocator, inputs: value.Value, root: *std.json.ObjectMap) ProviderError!void {
    try root.put(arena, "gitCommitish", .{ .string = try requiredString(inputs, "git_commitish") });
    try root.put(arena, "disabled", .{ .bool = try requiredBoolean(inputs, "disabled") });
    inline for (.{ .{ "cron_schedule", "cronSchedule" }, .{ "time_zone", "timeZone" } }) |mapping| {
        const text = try requiredString(inputs, mapping[0]);
        if (text.len != 0) try root.put(arena, mapping[1], .{ .string = text });
    }
    const compilation = try requiredValue(inputs, "code_compilation_config");
    if (!valueEmpty(compilation)) try root.put(arena, "codeCompilationConfig", try compactRenameJson(context, arena, compilation));
}

fn workflowBody(context: *provider_mod.OperationContext, arena: std.mem.Allocator, inputs: value.Value, root: *std.json.ObjectMap) ProviderError!void {
    try root.put(arena, "releaseConfig", .{ .string = try resolvedString(context, inputs, "release_config") });
    try root.put(arena, "disabled", .{ .bool = try requiredBoolean(inputs, "disabled") });
    inline for (.{ .{ "cron_schedule", "cronSchedule" }, .{ "time_zone", "timeZone" }, .{ "service_account", "serviceAccount" } }) |mapping| {
        const text = try requiredString(inputs, mapping[0]);
        if (text.len != 0) try root.put(arena, mapping[1], .{ .string = text });
    }
    var invocation = std.json.ObjectMap.empty;
    inline for (.{ "included_tags", "included_targets" }) |name| {
        const selected = try requiredValue(inputs, name);
        if (!valueEmpty(selected)) try invocation.put(arena, try camelAlloc(arena, name), try renameJson(context, arena, selected));
    }
    inline for (.{ "transitive_dependencies_included", "transitive_dependents_included", "fully_refresh_incremental_tables_enabled" }) |name| {
        const selected = try requiredBoolean(inputs, name);
        if (selected) try invocation.put(arena, try camelAlloc(arena, name), .{ .bool = true });
    }
    if (invocation.count() != 0) try root.put(arena, "invocationConfig", .{ .object = invocation });
}

fn resultFromJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, expected: []const u8, body: []const u8) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const physical = jsonString(root.get("name")) orelse expected;
    try validatePhysical(node, kind, physical);
    const remote = std.json.Stringify.valueAlloc(context.allocator, parsed.value, .{}) catch return error.OutOfMemory;
    defer context.allocator.free(remote);
    const outputs = [_]state.StateOutput{
        .{ .name = "__remote_spec", .value = .{ .string = remote } },
        .{ .name = "dataform_service_account", .value = .{ .string = jsonString(root.get("dataformCoreServiceAccount")) orelse "" } },
        .{ .name = "name", .value = .{ .string = physical } },
        .{ .name = "release_compilation_result", .value = .{ .string = jsonString(root.get("releaseCompilationResult")) orelse "" } },
    };
    return provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &outputs, null);
}

fn changedMaskAlloc(allocator: std.mem.Allocator, desired_json: []const u8, remote_json: []const u8) ProviderError![]u8 {
    var desired = std.json.parseFromSlice(std.json.Value, allocator, desired_json, .{}) catch return error.ProviderBug;
    defer desired.deinit();
    var remote = std.json.parseFromSlice(std.json.Value, allocator, remote_json, .{}) catch return error.ProviderBug;
    defer remote.deinit();
    const desired_root = jsonObject(desired.value) orelse return error.ProviderBug;
    const remote_root = jsonObject(remote.value) orelse return error.ProviderBug;
    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(allocator);
    for (desired_root.keys()) |name| {
        if (!jsonEquivalent(desired_root.get(name).?, remote_root.get(name))) try names.append(allocator, name);
    }
    std.mem.sort([]const u8, names.items, {}, lessString);
    return std.mem.join(allocator, ",", names.items) catch error.OutOfMemory;
}

fn compactRenameJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    const fields = valueObject(source) orelse return renameJson(context, arena, source);
    var result = std.json.ObjectMap.empty;
    for (fields) |field| if (!valueEmpty(field.value)) try result.put(arena, try camelAlloc(arena, field.name), try renameJson(context, arena, field.value));
    return .{ .object = result };
}

fn renameJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    return switch (source) {
        .string => |text| .{ .string = text },
        .integer => |number| .{ .integer = number },
        .boolean => |flag| .{ .bool = flag },
        .output_ref => |reference| .{ .string = try context.resolveOutputString(reference) },
        .list => |items| blk: {
            var result = std.json.Array.init(arena);
            for (items) |item| try result.append(try renameJson(context, arena, item));
            break :blk .{ .array = result };
        },
        .object => |fields| blk: {
            var result = std.json.ObjectMap.empty;
            for (fields) |field| try result.put(arena, try camelAlloc(arena, field.name), try renameJson(context, arena, field.value));
            break :blk .{ .object = result };
        },
        .secret_ref, .unknown_reason => error.InvalidConfiguration,
    };
}

fn identityFields(kind: Kind) []const []const u8 {
    return switch (kind) {
        .repository => &.{ "project_id", "location", "name", "kms_key_name" },
        .workspace, .release_config, .workflow_config => &.{ "project_id", "location", "repository_name", "name" },
    };
}

fn identityChanged(node: resource.ResourceNode, observed: *const provider_mod.ResourceResult, fields: []const []const u8) bool {
    for (fields) |name| if (!valuesEqual(findField(node.inputs, name), findField(observed.observed_inputs, name))) return true;
    return false;
}
fn valuesEqual(left: ?value.Value, right: ?value.Value) bool {
    if (left == null or right == null) return left == null and right == null;
    const left_json = left.?.canonicalJsonAlloc(std.heap.page_allocator) catch return false;
    defer std.heap.page_allocator.free(left_json);
    const right_json = right.?.canonicalJsonAlloc(std.heap.page_allocator) catch return false;
    defer std.heap.page_allocator.free(right_json);
    return std.mem.eql(u8, left_json, right_json);
}
fn jsonEquivalent(desired: std.json.Value, remote_optional: ?std.json.Value) bool {
    const remote = remote_optional orelse return jsonEmpty(desired);
    if (std.meta.activeTag(desired) != std.meta.activeTag(remote)) return false;
    return switch (desired) {
        .null => true,
        .bool => desired.bool == remote.bool,
        .integer => desired.integer == remote.integer,
        .float => desired.float == remote.float,
        .number_string => std.mem.eql(u8, desired.number_string, remote.number_string),
        .string => std.mem.eql(u8, desired.string, remote.string),
        .array => |array| blk: {
            if (array.items.len != remote.array.items.len) break :blk false;
            for (array.items, remote.array.items) |left, right| if (!jsonEquivalent(left, right)) break :blk false;
            break :blk true;
        },
        .object => |object| blk: {
            for (object.keys()) |key| if (!jsonEquivalent(object.get(key).?, remote.object.get(key))) break :blk false;
            break :blk true;
        },
    };
}
fn jsonEmpty(source: std.json.Value) bool {
    return switch (source) {
        .string => |text| text.len == 0,
        .array => |items| items.items.len == 0,
        .object => |object| object.count() == 0,
        .bool => |flag| !flag,
        else => false,
    };
}
fn valueEmpty(source: value.Value) bool {
    return switch (source) {
        .string => |text| text.len == 0,
        .list => |items| items.len == 0,
        .object => |fields| blk: {
            for (fields) |field| if (!valueEmpty(field.value)) break :blk false;
            break :blk true;
        },
        .boolean => |flag| !flag,
        .integer => |number| number == 0,
        else => false,
    };
}
fn findField(source: value.Value, name: []const u8) ?value.Value {
    const fields = valueObject(source) orelse return null;
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return null;
}
fn requiredValue(source: value.Value, name: []const u8) ProviderError!value.Value {
    return findField(source, name) orelse error.InvalidConfiguration;
}
fn requiredString(source: value.Value, name: []const u8) ProviderError![]const u8 {
    const selected = try requiredValue(source, name);
    return if (selected == .string) selected.string else error.InvalidConfiguration;
}
fn requiredBoolean(source: value.Value, name: []const u8) ProviderError!bool {
    const selected = try requiredValue(source, name);
    return if (selected == .boolean) selected.boolean else error.InvalidConfiguration;
}
fn resolvedString(context: *provider_mod.OperationContext, source: value.Value, name: []const u8) ProviderError![]const u8 {
    return switch (try requiredValue(source, name)) {
        .string => |text| text,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}
fn objectValue(fields: []const value.Field, name: []const u8) ProviderError!value.Value {
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return error.InvalidConfiguration;
}
fn objectString(fields: []const value.Field, name: []const u8) ProviderError![]const u8 {
    const selected = try objectValue(fields, name);
    return if (selected == .string) selected.string else error.InvalidConfiguration;
}
fn valueObject(source: value.Value) ?[]const value.Field {
    return if (source == .object) source.object else null;
}
fn outputString(result: provider_mod.ResourceResult, name: []const u8) ?[]const u8 {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name) and item.value == .string) return item.value.string;
    return null;
}
fn jsonObject(source: std.json.Value) ?std.json.ObjectMap {
    return if (source == .object) source.object else null;
}
fn jsonString(source: ?std.json.Value) ?[]const u8 {
    const selected = source orelse return null;
    return if (selected == .string) selected.string else null;
}
fn lessString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn camelAlloc(allocator: std.mem.Allocator, source: []const u8) ProviderError![]u8 {
    var result = std.ArrayList(u8).empty;
    var upper = false;
    for (source) |character| {
        if (character == '_') {
            upper = true;
            continue;
        }
        try result.append(allocator, if (upper) std.ascii.toUpper(character) else character);
        upper = false;
    }
    return result.toOwnedSlice(allocator) catch error.OutOfMemory;
}
fn percentEncodeAlloc(allocator: std.mem.Allocator, source: []const u8) ProviderError![]u8 {
    var result = std.ArrayList(u8).empty;
    for (source) |character| if (character == ',') try result.appendSlice(allocator, "%2C") else try result.append(allocator, character);
    return result.toOwnedSlice(allocator) catch error.OutOfMemory;
}
