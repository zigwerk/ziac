const std = @import("std");
const client_mod = @import("client.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;
const Kind = enum { policy, attestor, attestor_iam };

pub const Handler = struct {
    client: *client_mod.Client,

    pub fn supports(node: resource.ResourceNode) bool {
        return kindOf(node) != null;
    }

    pub fn read(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (kind == .attestor_iam) return self.readIam(context, node);
        const physical = try physicalForReadAlloc(context, node, kind, physical_override);
        defer context.allocator.free(physical);
        try validatePhysical(kind, physical);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical});
        defer context.allocator.free(path);
        var response = self.request(context, "GET", path, "") catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try resultFromJson(context, node, kind, response.body) };
    }

    pub fn diff(context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (kind == .attestor_iam) return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        const remote_json = outputString(observed.*, "__remote_spec") orelse return error.ProviderBug;
        var remote = std.json.parseFromSlice(std.json.Value, context.allocator, remote_json, .{}) catch return error.ProviderBug;
        defer remote.deinit();
        const desired_body = try bodyAlloc(context, node, kind, "");
        defer context.allocator.free(desired_body);
        var desired = std.json.parseFromSlice(std.json.Value, context.allocator, desired_body, .{}) catch return error.ProviderBug;
        defer desired.deinit();
        const desired_root = jsonObject(desired.value) orelse return error.ProviderBug;
        const remote_root = jsonObject(remote.value) orelse return error.ProviderBug;
        if (jsonContains(desired_root, remote_root)) return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        if (kind == .attestor) {
            const desired_note = nestedString(desired_root, "userOwnedGrafeasNote", "noteReference") orelse "";
            const remote_note = nestedString(remote_root, "userOwnedGrafeasNote", "noteReference") orelse "";
            if (!std.mem.eql(u8, desired_note, remote_note)) return provider_mod.DiffResult.init(context.allocator, .replace, &.{"attestor note identity differs"});
        }
        return provider_mod.DiffResult.init(context.allocator, .update, &.{"Binary Authorization configuration differs"});
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (kind == .attestor_iam) return self.mutateIam(context, node, true);
        const physical = try physicalForReadAlloc(context, node, kind, null);
        defer context.allocator.free(physical);
        const path = switch (kind) {
            .policy => try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical}),
            .attestor => try std.fmt.allocPrint(context.allocator, "/v1/{s}/attestors?attestorId={s}", .{ try requiredString(context, node.inputs, "project"), node.logical_id }),
            .attestor_iam => unreachable,
        };
        defer context.allocator.free(path);
        const body = try bodyAlloc(context, node, kind, "");
        defer context.allocator.free(body);
        var response = try self.request(context, if (kind == .policy) "PUT" else "POST", path, body);
        defer response.deinit(context.allocator);
        return resultFromJson(context, node, kind, response.body);
    }

    pub fn update(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (kind == .attestor_iam) return self.mutateIam(context, node, true);
        try validatePhysical(kind, observed.physical_id);
        const etag = outputString(observed.*, "etag") orelse "";
        const body = try bodyAlloc(context, node, kind, etag);
        defer context.allocator.free(body);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{observed.physical_id});
        defer context.allocator.free(path);
        var response = try self.request(context, "PUT", path, body);
        defer response.deinit(context.allocator);
        return resultFromJson(context, node, kind, response.body);
    }

    pub fn delete(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical: []const u8) ProviderError!void {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (kind == .policy) return error.InvalidConfiguration;
        if (kind == .attestor_iam) {
            var removed = try self.mutateIam(context, node, false);
            removed.deinit();
            return;
        }
        try validatePhysical(kind, physical);
        if (!std.mem.eql(u8, try requiredLiteralString(node.inputs, "removal_policy"), "delete") or !context.destructive_confirmation) return error.DestructiveConfirmationRequired;
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical});
        defer context.allocator.free(path);
        var response = self.request(context, "DELETE", path, "") catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        response.deinit(context.allocator);
    }

    pub fn importResource(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical: []const u8) ProviderError!provider_mod.ResourceResult {
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (kind != .attestor_iam) try validatePhysical(kind, physical);
        var found = try self.read(context, node, if (kind == .attestor_iam) null else physical);
        defer found.deinit();
        return switch (found) {
            .absent => error.NotFound,
            .present => |present| present.clone(context.allocator),
        };
    }

    fn readIam(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ReadResult {
        const target = try requiredString(context, node.inputs, "attestor");
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}:getIamPolicy?options.requestedPolicyVersion=3", .{target});
        defer context.allocator.free(path);
        var response = self.request(context, "GET", path, "") catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        if (!policyHasExactMember(parsed.value, node)) return .absent;
        return .{ .present = try iamResult(context, node, target) };
    }

    fn mutateIam(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, should_exist: bool) ProviderError!provider_mod.ResourceResult {
        const target = try requiredString(context, node.inputs, "attestor");
        const get_path = try std.fmt.allocPrint(context.allocator, "/v1/{s}:getIamPolicy?options.requestedPolicyVersion=3", .{target});
        defer context.allocator.free(get_path);
        var get_response = try self.request(context, "GET", get_path, "");
        defer get_response.deinit(context.allocator);
        var policy = std.json.parseFromSlice(std.json.Value, context.allocator, get_response.body, .{}) catch return error.ProviderBug;
        defer policy.deinit();
        const changed = try mutatePolicy(&policy, node, should_exist);
        if (changed) {
            const body = try policyBodyAlloc(context.allocator, policy.value);
            defer context.allocator.free(body);
            const set_path = try std.fmt.allocPrint(context.allocator, "/v1/{s}:setIamPolicy", .{target});
            defer context.allocator.free(set_path);
            var response = try self.request(context, "POST", set_path, body);
            response.deinit(context.allocator);
        }
        return iamResult(context, node, target);
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, method: []const u8, path: []const u8, body: []const u8) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, .{ .api = .binary_authorization, .method = method, .path = path, .body = body }, &diagnostic);
    }
};

fn kindOf(node: resource.ResourceNode) ?Kind {
    if (std.mem.eql(u8, node.type_name, "gcp.binaryauthorization.Policy")) return .policy;
    if (std.mem.eql(u8, node.type_name, "gcp.binaryauthorization.Attestor")) return .attestor;
    if (std.mem.eql(u8, node.type_name, "gcp.binaryauthorization.AttestorIamMember")) return .attestor_iam;
    return null;
}

fn physicalForReadAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, override: ?[]const u8) ProviderError![]const u8 {
    if (override orelse context.physical_id) |physical| return context.allocator.dupe(u8, physical) catch error.OutOfMemory;
    return switch (kind) {
        .policy => std.fmt.allocPrint(context.allocator, "{s}/policy", .{try requiredString(context, node.inputs, "project")}) catch error.OutOfMemory,
        .attestor => std.fmt.allocPrint(context.allocator, "{s}/attestors/{s}", .{ try requiredString(context, node.inputs, "project"), node.logical_id }) catch error.OutOfMemory,
        .attestor_iam => error.InvalidConfiguration,
    };
}

fn validatePhysical(kind: Kind, physical: []const u8) ProviderError!void {
    if (!std.mem.startsWith(u8, physical, "projects/") or std.mem.indexOfAny(u8, physical, "?# \t\r\n") != null) return error.InvalidConfiguration;
    if (kind == .policy and !std.mem.endsWith(u8, physical, "/policy")) return error.InvalidConfiguration;
    if (kind == .attestor and std.mem.indexOf(u8, physical, "/attestors/") == null) return error.InvalidConfiguration;
}

fn bodyAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, etag: []const u8) ProviderError![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = std.json.ObjectMap.empty;
    if (etag.len != 0) try root.put(arena, "etag", .{ .string = etag });
    switch (kind) {
        .policy => try policyBody(context, arena, node, &root),
        .attestor => try attestorBody(context, arena, node, &root),
        .attestor_iam => return error.InvalidConfiguration,
    }
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch error.OutOfMemory;
}

fn policyBody(context: *provider_mod.OperationContext, arena: std.mem.Allocator, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    try root.put(arena, "name", .{ .string = try std.fmt.allocPrint(arena, "{s}/policy", .{try requiredString(context, node.inputs, "project")}) });
    try putOptionalString(arena, root, "description", try requiredLiteralString(node.inputs, "description"));
    try root.put(arena, "globalPolicyEvaluationMode", .{ .string = if (try requiredBoolean(node.inputs, "global_policy_evaluation")) "ENABLE" else "DISABLE" });
    var patterns = std.json.Array.init(arena);
    for (valueList(try requiredValue(node.inputs, "allowlist_patterns")) orelse return error.InvalidConfiguration) |item| {
        var pattern = std.json.ObjectMap.empty;
        try pattern.put(arena, "namePattern", .{ .string = valueString(item) orelse return error.InvalidConfiguration });
        try patterns.append(.{ .object = pattern });
    }
    try root.put(arena, "admissionWhitelistPatterns", .{ .array = patterns });
    try root.put(arena, "defaultAdmissionRule", try admissionRuleJson(context, arena, try requiredValue(node.inputs, "default_rule")));
    try root.put(arena, "clusterAdmissionRules", try namedRulesJson(context, arena, try requiredValue(node.inputs, "cluster_rules")));
    try root.put(arena, "kubernetesNamespaceAdmissionRules", try namedRulesJson(context, arena, try requiredValue(node.inputs, "namespace_rules")));
    try root.put(arena, "kubernetesServiceAccountAdmissionRules", try namedRulesJson(context, arena, try requiredValue(node.inputs, "service_account_rules")));
    try root.put(arena, "istioServiceIdentityAdmissionRules", try namedRulesJson(context, arena, try requiredValue(node.inputs, "istio_identity_rules")));
}

fn admissionRuleJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    const fields = valueObject(source) orelse return error.InvalidConfiguration;
    var result = std.json.ObjectMap.empty;
    try result.put(arena, "evaluationMode", .{ .string = try requiredObjectString(fields, "evaluation") });
    try result.put(arena, "enforcementMode", .{ .string = try requiredObjectString(fields, "enforcement") });
    try result.put(arena, "requireAttestationsBy", try resolvedValueJson(context, arena, try requiredObjectValue(fields, "attestors")));
    return .{ .object = result };
}

fn namedRulesJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    const fields = valueObject(source) orelse return error.InvalidConfiguration;
    var result = std.json.ObjectMap.empty;
    for (fields) |field| try result.put(arena, field.name, try admissionRuleJson(context, arena, field.value));
    return .{ .object = result };
}

fn attestorBody(context: *provider_mod.OperationContext, arena: std.mem.Allocator, node: resource.ResourceNode, root: *std.json.ObjectMap) ProviderError!void {
    const name = try std.fmt.allocPrint(arena, "{s}/attestors/{s}", .{ try requiredString(context, node.inputs, "project"), node.logical_id });
    try root.put(arena, "name", .{ .string = name });
    try putOptionalString(arena, root, "description", try requiredLiteralString(node.inputs, "description"));
    var note = std.json.ObjectMap.empty;
    try note.put(arena, "noteReference", .{ .string = try requiredString(context, node.inputs, "note_reference") });
    var public_keys = std.json.Array.init(arena);
    for (valueList(try requiredValue(node.inputs, "public_keys")) orelse return error.InvalidConfiguration) |item| {
        const fields = valueObject(item) orelse return error.InvalidConfiguration;
        var key = std.json.ObjectMap.empty;
        try putOptionalString(arena, &key, "id", try requiredObjectString(fields, "id"));
        try putOptionalString(arena, &key, "comment", try requiredObjectString(fields, "comment"));
        const key_type = try requiredObjectString(fields, "key_type");
        if (std.mem.eql(u8, key_type, "pgp")) {
            try key.put(arena, "asciiArmoredPgpPublicKey", .{ .string = try requiredObjectString(fields, "public_key") });
        } else {
            var pkix = std.json.ObjectMap.empty;
            try pkix.put(arena, "publicKeyPem", .{ .string = try requiredObjectString(fields, "public_key") });
            try pkix.put(arena, "signatureAlgorithm", .{ .string = try requiredObjectString(fields, "signature_algorithm") });
            try key.put(arena, "pkixPublicKey", .{ .object = pkix });
        }
        try public_keys.append(.{ .object = key });
    }
    try note.put(arena, "publicKeys", .{ .array = public_keys });
    try root.put(arena, "userOwnedGrafeasNote", .{ .object = note });
}

fn resultFromJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, body: []const u8) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const physical = jsonString(root.get("name")) orelse return error.ProviderBug;
    try validatePhysical(kind, physical);
    const observed: value.Value = if (try remoteMatches(context, node, kind, root)) node.inputs else .{ .unknown_reason = "remote Binary Authorization configuration drifted" };
    var outputs: [5]state.StateOutput = undefined;
    var count: usize = 0;
    outputs[count] = .{ .name = "name", .value = .{ .string = physical } };
    count += 1;
    outputs[count] = .{ .name = "etag", .value = .{ .string = jsonString(root.get("etag")) orelse "" } };
    count += 1;
    if (kind == .attestor) {
        const note = jsonObject(root.get("userOwnedGrafeasNote") orelse .{ .object = .empty });
        outputs[count] = .{ .name = "delegation_service_account", .value = .{ .string = if (note) |object| jsonString(object.get("delegationServiceAccountEmail")) orelse "" else "" } };
        count += 1;
    }
    outputs[count] = .{ .name = "__remote_spec", .value = .{ .string = body } };
    count += 1;
    return provider_mod.ResourceResult.init(context.allocator, physical, observed, outputs[0..count], null);
}

fn remoteMatches(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, remote: std.json.ObjectMap) ProviderError!bool {
    const body = try bodyAlloc(context, node, kind, "");
    defer context.allocator.free(body);
    var desired = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer desired.deinit();
    return jsonContains(jsonObject(desired.value) orelse return error.ProviderBug, remote);
}

fn iamResult(context: *provider_mod.OperationContext, node: resource.ResourceNode, target: []const u8) ProviderError!provider_mod.ResourceResult {
    const physical = try std.fmt.allocPrint(context.allocator, "{s}/iam/{s}", .{ target, node.logical_id });
    defer context.allocator.free(physical);
    const outputs = [_]state.StateOutput{.{ .name = "binding_id", .value = .{ .string = physical } }};
    return provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &outputs, null);
}

fn policyBodyAlloc(allocator: std.mem.Allocator, policy: std.json.Value) ProviderError![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    var wrapper = std.json.ObjectMap.empty;
    try wrapper.put(arena_state.allocator(), "policy", try cloneJson(arena_state.allocator(), policy));
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = wrapper }, .{}) catch error.OutOfMemory;
}

fn policyHasExactMember(policy: std.json.Value, node: resource.ResourceNode) bool {
    const root = jsonObject(policy) orelse return false;
    const bindings = jsonArray(root.get("bindings") orelse return false) orelse return false;
    for (bindings.items) |candidate| {
        const binding = jsonObject(candidate) orelse continue;
        if (!bindingIdentityMatches(binding, node)) continue;
        const members = jsonArray(binding.get("members") orelse continue) orelse continue;
        for (members.items) |member| if (stringEquals(member, inputString(node.inputs, "member") orelse return false)) return true;
    }
    return false;
}

fn mutatePolicy(parsed: *std.json.Parsed(std.json.Value), node: resource.ResourceNode, should_exist: bool) ProviderError!bool {
    const allocator = parsed.arena.allocator();
    const root = switch (parsed.value) {
        .object => |*object| object,
        else => return error.ProviderBug,
    };
    try root.put(allocator, "version", .{ .integer = 3 });
    var bindings_value = root.getPtr("bindings");
    if (bindings_value == null) {
        if (!should_exist) return false;
        try root.put(allocator, "bindings", .{ .array = std.json.Array.init(allocator) });
        bindings_value = root.getPtr("bindings");
    }
    const bindings = switch (bindings_value.?.*) {
        .array => |*array| array,
        else => return error.ProviderBug,
    };
    for (bindings.items, 0..) |*binding_value, binding_index| {
        const binding = switch (binding_value.*) {
            .object => |*object| object,
            else => continue,
        };
        if (!bindingIdentityMatches(binding.*, node)) continue;
        const members_value = binding.getPtr("members") orelse return error.ProviderBug;
        const members = switch (members_value.*) {
            .array => |*array| array,
            else => return error.ProviderBug,
        };
        const member = try requiredLiteralString(node.inputs, "member");
        for (members.items, 0..) |candidate, member_index| if (stringEquals(candidate, member)) {
            if (should_exist) return false;
            _ = members.orderedRemove(member_index);
            if (members.items.len == 0) _ = bindings.orderedRemove(binding_index);
            return true;
        };
        if (!should_exist) return false;
        try members.append(.{ .string = member });
        return true;
    }
    if (!should_exist) return false;
    var members = std.json.Array.init(allocator);
    try members.append(.{ .string = try requiredLiteralString(node.inputs, "member") });
    var binding = std.json.ObjectMap.empty;
    try binding.put(allocator, "role", .{ .string = try requiredLiteralString(node.inputs, "role") });
    try binding.put(allocator, "members", .{ .array = members });
    const condition = try requiredValue(node.inputs, "condition");
    if (!valueIsEmpty(condition)) try binding.put(allocator, "condition", try resolvedValueJsonLiteral(allocator, condition));
    try bindings.append(.{ .object = binding });
    return true;
}

fn bindingIdentityMatches(binding: std.json.ObjectMap, node: resource.ResourceNode) bool {
    if (!stringEquals(binding.get("role"), inputString(node.inputs, "role") orelse return false)) return false;
    const desired = requiredValue(node.inputs, "condition") catch return false;
    if (valueIsEmpty(desired)) return binding.get("condition") == null;
    const actual = binding.get("condition") orelse return false;
    return jsonMatchesValue(desired, actual);
}

fn requiredValue(source: value.Value, name: []const u8) ProviderError!value.Value {
    const fields = valueObject(source) orelse return error.InvalidConfiguration;
    return requiredObjectValue(fields, name);
}

fn requiredLiteralString(source: value.Value, name: []const u8) ProviderError![]const u8 {
    return valueString(try requiredValue(source, name)) orelse error.InvalidConfiguration;
}

fn requiredString(context: *provider_mod.OperationContext, source: value.Value, name: []const u8) ProviderError![]const u8 {
    return resolveString(context, try requiredValue(source, name));
}

fn resolveString(context: *provider_mod.OperationContext, source: value.Value) ProviderError![]const u8 {
    return switch (source) {
        .string => |text| text,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}

fn requiredBoolean(source: value.Value, name: []const u8) ProviderError!bool {
    return switch (try requiredValue(source, name)) {
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

fn valueObject(source: value.Value) ?[]const value.Field {
    return if (source == .object) source.object else null;
}

fn valueList(source: value.Value) ?[]const value.Value {
    return if (source == .list) source.list else null;
}

fn valueString(source: value.Value) ?[]const u8 {
    return if (source == .string) source.string else null;
}

fn resolvedValueJson(context: *provider_mod.OperationContext, arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    return switch (source) {
        .string => |text| .{ .string = text },
        .integer => |number| .{ .integer = number },
        .boolean => |flag| .{ .bool = flag },
        .list => |items| blk: {
            var array = std.json.Array.init(arena);
            for (items) |item| try array.append(try resolvedValueJson(context, arena, item));
            break :blk .{ .array = array };
        },
        .object => |fields| blk: {
            var object = std.json.ObjectMap.empty;
            for (fields) |field| try object.put(arena, field.name, try resolvedValueJson(context, arena, field.value));
            break :blk .{ .object = object };
        },
        .output_ref => |reference| .{ .string = try context.resolveOutputString(reference) },
        .secret_ref, .unknown_reason => error.InvalidConfiguration,
    };
}

fn resolvedValueJsonLiteral(arena: std.mem.Allocator, source: value.Value) ProviderError!std.json.Value {
    return switch (source) {
        .string => |text| .{ .string = text },
        .integer => |number| .{ .integer = number },
        .boolean => |flag| .{ .bool = flag },
        .list => |items| blk: {
            var array = std.json.Array.init(arena);
            for (items) |item| try array.append(try resolvedValueJsonLiteral(arena, item));
            break :blk .{ .array = array };
        },
        .object => |fields| blk: {
            var object = std.json.ObjectMap.empty;
            for (fields) |field| try object.put(arena, field.name, try resolvedValueJsonLiteral(arena, field.value));
            break :blk .{ .object = object };
        },
        .output_ref, .secret_ref, .unknown_reason => error.InvalidConfiguration,
    };
}

fn jsonMatchesValue(desired: value.Value, actual: std.json.Value) bool {
    return switch (desired) {
        .string => |text| actual == .string and std.mem.eql(u8, text, actual.string),
        .integer => |number| actual == .integer and number == actual.integer,
        .boolean => |flag| actual == .bool and flag == actual.bool,
        .object => |fields| blk: {
            const object = jsonObject(actual) orelse break :blk false;
            for (fields) |field| if (!jsonMatchesValue(field.value, object.get(field.name) orelse break :blk false)) break :blk false;
            break :blk true;
        },
        .list => |items| blk: {
            const array = jsonArray(actual) orelse break :blk false;
            if (items.len != array.items.len) break :blk false;
            for (items, array.items) |left, right| if (!jsonMatchesValue(left, right)) break :blk false;
            break :blk true;
        },
        .output_ref, .secret_ref, .unknown_reason => false,
    };
}

fn cloneJson(arena: std.mem.Allocator, source: std.json.Value) ProviderError!std.json.Value {
    return switch (source) {
        .null, .bool, .integer, .float, .number_string, .string => source,
        .array => |items| blk: {
            var result = std.json.Array.init(arena);
            for (items.items) |item| try result.append(try cloneJson(arena, item));
            break :blk .{ .array = result };
        },
        .object => |object| blk: {
            var result = std.json.ObjectMap.empty;
            var iterator = object.iterator();
            while (iterator.next()) |entry| try result.put(arena, entry.key_ptr.*, try cloneJson(arena, entry.value_ptr.*));
            break :blk .{ .object = result };
        },
    };
}

fn jsonContains(desired: std.json.ObjectMap, remote: std.json.ObjectMap) bool {
    var iterator = desired.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "etag")) continue;
        if (!jsonValueEquivalent(entry.value_ptr.*, remote.get(entry.key_ptr.*))) return false;
    }
    return true;
}

fn jsonValueEquivalent(desired_optional: ?std.json.Value, remote_optional: ?std.json.Value) bool {
    const desired = desired_optional orelse return remote_optional == null;
    const remote = remote_optional orelse return jsonValueEmpty(desired);
    return switch (desired) {
        .null => remote == .null,
        .bool => |flag| remote == .bool and remote.bool == flag,
        .integer => |number| remote == .integer and remote.integer == number,
        .float => |number| remote == .float and remote.float == number,
        .number_string => |number| remote == .number_string and std.mem.eql(u8, remote.number_string, number),
        .string => |text| remote == .string and std.mem.eql(u8, remote.string, text),
        .array => |items| blk: {
            if (remote != .array or remote.array.items.len != items.items.len) break :blk false;
            for (items.items, remote.array.items) |left, right| if (!jsonValueEquivalent(left, right)) break :blk false;
            break :blk true;
        },
        .object => |object| remote == .object and jsonContains(object, remote.object),
    };
}

fn jsonValueEmpty(candidate: std.json.Value) bool {
    return switch (candidate) {
        .string => |text| text.len == 0,
        .array => |items| items.items.len == 0,
        .object => |object| object.count() == 0,
        .bool => |flag| !flag,
        else => false,
    };
}
fn valueIsEmpty(candidate: value.Value) bool {
    return candidate == .object and candidate.object.len == 0;
}
fn nestedString(root: std.json.ObjectMap, outer: []const u8, inner: []const u8) ?[]const u8 {
    const object = jsonObject(root.get(outer) orelse return null) orelse return null;
    return jsonString(object.get(inner));
}
fn putOptionalString(arena: std.mem.Allocator, object: *std.json.ObjectMap, name: []const u8, text: []const u8) ProviderError!void {
    if (text.len != 0) try object.put(arena, name, .{ .string = text });
}
fn outputString(result: provider_mod.ResourceResult, name: []const u8) ?[]const u8 {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name)) return if (item.value == .string) item.value.string else null;
    return null;
}
fn inputString(input: value.Value, name: []const u8) ?[]const u8 {
    const selected = requiredValue(input, name) catch return null;
    return if (selected == .string) selected.string else null;
}
fn stringEquals(input: ?std.json.Value, expected: []const u8) bool {
    const actual = jsonString(input) orelse return expected.len == 0;
    return std.mem.eql(u8, actual, expected);
}
fn jsonObject(candidate: std.json.Value) ?std.json.ObjectMap {
    return if (candidate == .object) candidate.object else null;
}
fn jsonArray(candidate: std.json.Value) ?std.json.Array {
    return if (candidate == .array) candidate.array else null;
}
fn jsonString(candidate: ?std.json.Value) ?[]const u8 {
    const selected = candidate orelse return null;
    return if (selected == .string) selected.string else null;
}
