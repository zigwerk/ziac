const std = @import("std");
const client_mod = @import("client.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;

const schema_type = "gcp.pubsub.Schema";
const snapshot_type = "gcp.pubsub.Snapshot";
const subscription_type = "gcp.pubsub.Subscription";
const subscription_iam_type = "gcp.pubsub.SubscriptionIamMember";
const topic_type = "gcp.pubsub.Topic";
const topic_iam_type = "gcp.pubsub.TopicIamMember";

pub const Handler = struct {
    client: *client_mod.Client,
    iam_conflict_retries: usize = 3,

    pub fn read(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_override: ?[]const u8,
    ) ProviderError!provider_mod.ReadResult {
        if (isIam(node)) return self.readIam(context, node);
        const expected = try physicalIdAlloc(context, node);
        defer context.allocator.free(expected);
        const physical = physical_override orelse expected;
        if (!std.mem.eql(u8, expected, physical)) return error.InvalidConfiguration;
        const path = try readPathAlloc(context.allocator, node, physical);
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .pubsub, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try resultFromJson(context, node, physical, response.body) };
    }

    pub fn diff(
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        observed: *const provider_mod.ResourceResult,
    ) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash)) {
            return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        }
        if (isIam(node)) {
            return provider_mod.DiffResult.init(context.allocator, .replace, &.{"Pub/Sub IAM resource identity changed"});
        }
        if (isType(node, schema_type) and immutableStringChanged(context, node, observed, "schema_type")) {
            return provider_mod.DiffResult.init(context.allocator, .replace, &.{"Pub/Sub schema type is immutable"});
        }
        if (isType(node, subscription_type) and immutableStringChanged(context, node, observed, "topic")) {
            return provider_mod.DiffResult.init(context.allocator, .replace, &.{"Pub/Sub subscription topic is immutable"});
        }
        if (isType(node, snapshot_type) and desiredHashChangedSinceState(context, node)) {
            return provider_mod.DiffResult.init(context.allocator, .replace, &.{"Pub/Sub snapshot source is not recoverable and changes require replacement"});
        }
        return provider_mod.DiffResult.init(context.allocator, .update, &.{"Pub/Sub remote configuration differs"});
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        if (isIam(node)) return self.ensureIam(context, node, true);
        const physical = try physicalIdAlloc(context, node);
        defer context.allocator.free(physical);
        const path = try createPathAlloc(context.allocator, node, physical);
        defer context.allocator.free(path);
        const body = try bodyAlloc(context, node, physical, false);
        defer context.allocator.free(body);
        var response = try self.request(context, .{
            .api = .pubsub,
            .method = if (isType(node, schema_type)) "POST" else "PUT",
            .path = path,
            .body = body,
        });
        defer response.deinit(context.allocator);
        return resultFromJson(context, node, physical, response.body);
    }

    pub fn update(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!provider_mod.ResourceResult {
        if (isIam(node)) return self.ensureIam(context, node, true);
        const expected = try physicalIdAlloc(context, node);
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        const path = try updatePathAlloc(context.allocator, node, physical_id);
        defer context.allocator.free(path);
        const body = try bodyAlloc(context, node, physical_id, true);
        defer context.allocator.free(body);
        var response = try self.request(context, .{
            .api = .pubsub,
            .method = if (isType(node, schema_type)) "POST" else "PATCH",
            .path = path,
            .body = body,
        });
        defer response.deinit(context.allocator);
        return resultFromJson(context, node, physical_id, response.body);
    }

    pub fn delete(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!void {
        if (isIam(node)) {
            var removed = try self.ensureIam(context, node, false);
            removed.deinit();
            return;
        }
        const expected = try physicalIdAlloc(context, node);
        defer context.allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical_id)) return error.InvalidConfiguration;
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical_id});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .pubsub, .method = "DELETE", .path = path }) catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        response.deinit(context.allocator);
    }

    fn readIam(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ReadResult {
        const target = try resolveString(context, try requiredValue(node.inputs, "resource"));
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}:getIamPolicy?options.requestedPolicyVersion=3", .{target});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .pubsub, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        if (!policyHasExactMember(parsed.value, node)) return .absent;
        return .{ .present = try iamResult(context, node, target) };
    }

    fn ensureIam(
        self: Handler,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        should_exist: bool,
    ) ProviderError!provider_mod.ResourceResult {
        const target = try resolveString(context, try requiredValue(node.inputs, "resource"));
        var attempt: usize = 0;
        while (true) : (attempt += 1) {
            const get_path = try std.fmt.allocPrint(context.allocator, "/v1/{s}:getIamPolicy?options.requestedPolicyVersion=3", .{target});
            defer context.allocator.free(get_path);
            var current = try self.request(context, .{ .api = .pubsub, .method = "GET", .path = get_path });
            defer current.deinit(context.allocator);
            var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, current.body, .{}) catch return error.ProviderBug;
            defer parsed.deinit();
            const changed = try mutatePolicy(&parsed, node, should_exist);
            if (!changed) return iamResult(context, node, target);
            const body = try policyBodyAlloc(context.allocator, parsed.value);
            defer context.allocator.free(body);
            const set_path = try std.fmt.allocPrint(context.allocator, "/v1/{s}:setIamPolicy", .{target});
            defer context.allocator.free(set_path);
            var response = self.request(context, .{ .api = .pubsub, .method = "POST", .path = set_path, .body = body }) catch |err| {
                if (err == error.Conflict and attempt < self.iam_conflict_retries) continue;
                return err;
            };
            response.deinit(context.allocator);
            return iamResult(context, node, target);
        }
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

pub fn supports(node: resource.ResourceNode) bool {
    return isType(node, schema_type) or isType(node, snapshot_type) or
        isType(node, subscription_type) or isType(node, subscription_iam_type) or
        isType(node, topic_type) or isType(node, topic_iam_type);
}

fn physicalIdAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError![]const u8 {
    if (isIam(node)) {
        const target = try resolveString(context, try requiredValue(node.inputs, "resource"));
        return std.fmt.allocPrint(context.allocator, "{s}/iam/{s}", .{ target, try requiredString(node.inputs, "name") }) catch error.OutOfMemory;
    }
    const collection = if (isType(node, schema_type))
        "schemas"
    else if (isType(node, snapshot_type))
        "snapshots"
    else if (isType(node, subscription_type))
        "subscriptions"
    else if (isType(node, topic_type))
        "topics"
    else
        return error.InvalidConfiguration;
    return std.fmt.allocPrint(
        context.allocator,
        "projects/{s}/{s}/{s}",
        .{ try requiredString(node.inputs, "project_id"), collection, try requiredString(node.inputs, "name") },
    ) catch error.OutOfMemory;
}

fn readPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, physical: []const u8) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "/v1/{s}{s}", .{ physical, if (isType(node, schema_type)) "?view=FULL" else "" }) catch error.OutOfMemory;
}

fn createPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, physical: []const u8) ProviderError![]const u8 {
    if (isType(node, schema_type)) {
        return std.fmt.allocPrint(allocator, "/v1/projects/{s}/schemas?schemaId={s}", .{
            try requiredString(node.inputs, "project_id"),
            try requiredString(node.inputs, "name"),
        }) catch error.OutOfMemory;
    }
    return std.fmt.allocPrint(allocator, "/v1/{s}", .{physical}) catch error.OutOfMemory;
}

fn updatePathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, physical: []const u8) ProviderError![]const u8 {
    if (isType(node, schema_type)) return std.fmt.allocPrint(allocator, "/v1/{s}:commit", .{physical}) catch error.OutOfMemory;
    const mask = if (isType(node, topic_type))
        "labels%2CkmsKeyName%2CmessageRetentionDuration%2CmessageStoragePolicy%2CschemaSettings"
    else if (isType(node, subscription_type))
        "pushConfig%2CackDeadlineSeconds%2CretainAckedMessages%2CmessageRetentionDuration%2CexpirationPolicy%2Clabels%2CenableMessageOrdering%2Cfilter%2CdeadLetterPolicy%2CretryPolicy%2CenableExactlyOnceDelivery"
    else if (isType(node, snapshot_type))
        "labels"
    else
        return error.InvalidConfiguration;
    return std.fmt.allocPrint(allocator, "/v1/{s}?updateMask={s}", .{ physical, mask }) catch error.OutOfMemory;
}

fn bodyAlloc(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    physical: []const u8,
    is_update: bool,
) ProviderError![]u8 {
    var arena = std.heap.ArenaAllocator.init(context.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const message = if (isType(node, topic_type))
        try topicJsonValue(allocator, context, node, physical)
    else if (isType(node, schema_type))
        try schemaJsonValue(allocator, node, physical)
    else if (isType(node, subscription_type))
        try subscriptionJsonValue(allocator, context, node, physical)
    else if (isType(node, snapshot_type))
        try snapshotJsonValue(allocator, context, node, physical)
    else
        return error.InvalidConfiguration;
    if (is_update and isType(node, schema_type)) {
        var wrapper: std.json.ObjectMap = .empty;
        try wrapper.put(allocator, "schema", message);
        return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = wrapper }, .{}) catch error.OutOfMemory;
    }
    return std.json.Stringify.valueAlloc(context.allocator, message, .{}) catch error.OutOfMemory;
}

fn topicJsonValue(
    allocator: std.mem.Allocator,
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    physical: []const u8,
) ProviderError!std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "name", .{ .string = physical });
    try object.put(allocator, "labels", try jsonFromValue(allocator, context, try requiredValue(node.inputs, "labels")));
    const kms = try requiredString(node.inputs, "kms_key_name");
    if (kms.len > 0) try object.put(allocator, "kmsKeyName", .{ .string = kms });
    const retention = try requiredInteger(node.inputs, "message_retention_seconds");
    if (retention > 0) try object.put(allocator, "messageRetentionDuration", .{ .string = try durationAlloc(allocator, retention) });
    var policy: std.json.ObjectMap = .empty;
    try policy.put(allocator, "allowedPersistenceRegions", try jsonFromValue(allocator, context, try requiredValue(node.inputs, "allowed_persistence_regions")));
    try policy.put(allocator, "enforceInTransit", .{ .bool = try requiredBool(node.inputs, "enforce_in_transit") });
    if (jsonArrayLength(policy.get("allowedPersistenceRegions")) > 0) try object.put(allocator, "messageStoragePolicy", .{ .object = policy });
    const schema_name = try resolveString(context, try requiredValue(node.inputs, "schema_name"));
    if (schema_name.len > 0) {
        var settings: std.json.ObjectMap = .empty;
        try settings.put(allocator, "schema", .{ .string = schema_name });
        try settings.put(allocator, "encoding", .{ .string = try requiredString(node.inputs, "schema_encoding") });
        try object.put(allocator, "schemaSettings", .{ .object = settings });
    }
    return .{ .object = object };
}

fn schemaJsonValue(allocator: std.mem.Allocator, node: resource.ResourceNode, physical: []const u8) ProviderError!std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "name", .{ .string = physical });
    try object.put(allocator, "type", .{ .string = try requiredString(node.inputs, "schema_type") });
    try object.put(allocator, "definition", .{ .string = try requiredString(node.inputs, "definition") });
    return .{ .object = object };
}

fn subscriptionJsonValue(
    allocator: std.mem.Allocator,
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    physical: []const u8,
) ProviderError!std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "name", .{ .string = physical });
    try object.put(allocator, "topic", .{ .string = try resolveString(context, try requiredValue(node.inputs, "topic")) });
    try object.put(allocator, "labels", try jsonFromValue(allocator, context, try requiredValue(node.inputs, "labels")));
    try object.put(allocator, "ackDeadlineSeconds", .{ .integer = try requiredInteger(node.inputs, "ack_deadline_seconds") });
    try object.put(allocator, "retainAckedMessages", .{ .bool = try requiredBool(node.inputs, "retain_acked_messages") });
    try object.put(allocator, "messageRetentionDuration", .{ .string = try durationAlloc(allocator, try requiredInteger(node.inputs, "message_retention_seconds")) });
    const expiration = try requiredInteger(node.inputs, "expiration_ttl_seconds");
    var expiration_policy: std.json.ObjectMap = .empty;
    if (expiration > 0) try expiration_policy.put(allocator, "ttl", .{ .string = try durationAlloc(allocator, expiration) });
    try object.put(allocator, "expirationPolicy", .{ .object = expiration_policy });
    try object.put(allocator, "enableMessageOrdering", .{ .bool = try requiredBool(node.inputs, "enable_message_ordering") });
    try object.put(allocator, "enableExactlyOnceDelivery", .{ .bool = try requiredBool(node.inputs, "enable_exactly_once_delivery") });
    const filter = try requiredString(node.inputs, "filter");
    if (filter.len > 0) try object.put(allocator, "filter", .{ .string = filter });
    if (std.mem.eql(u8, try requiredString(node.inputs, "delivery_kind"), "push")) {
        var push: std.json.ObjectMap = .empty;
        try push.put(allocator, "pushEndpoint", .{ .string = try requiredString(node.inputs, "push_endpoint") });
        const service_account = try requiredString(node.inputs, "push_service_account");
        if (service_account.len > 0) {
            var oidc: std.json.ObjectMap = .empty;
            try oidc.put(allocator, "serviceAccountEmail", .{ .string = service_account });
            const audience = try requiredString(node.inputs, "push_audience");
            if (audience.len > 0) try oidc.put(allocator, "audience", .{ .string = audience });
            try push.put(allocator, "oidcToken", .{ .object = oidc });
        }
        try object.put(allocator, "pushConfig", .{ .object = push });
    } else {
        try object.put(allocator, "pushConfig", .{ .object = .empty });
    }
    const dead_letter = try resolveString(context, try requiredValue(node.inputs, "dead_letter_topic"));
    if (dead_letter.len > 0) {
        var policy: std.json.ObjectMap = .empty;
        try policy.put(allocator, "deadLetterTopic", .{ .string = dead_letter });
        try policy.put(allocator, "maxDeliveryAttempts", .{ .integer = try requiredInteger(node.inputs, "max_delivery_attempts") });
        try object.put(allocator, "deadLetterPolicy", .{ .object = policy });
    }
    const retry_min = try requiredInteger(node.inputs, "retry_minimum_backoff_seconds");
    const retry_max = try requiredInteger(node.inputs, "retry_maximum_backoff_seconds");
    if (retry_min > 0 or retry_max > 0) {
        var retry: std.json.ObjectMap = .empty;
        try retry.put(allocator, "minimumBackoff", .{ .string = try durationAlloc(allocator, retry_min) });
        try retry.put(allocator, "maximumBackoff", .{ .string = try durationAlloc(allocator, retry_max) });
        try object.put(allocator, "retryPolicy", .{ .object = retry });
    }
    return .{ .object = object };
}

fn snapshotJsonValue(
    allocator: std.mem.Allocator,
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    physical: []const u8,
) ProviderError!std.json.Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(allocator, "name", .{ .string = physical });
    try object.put(allocator, "subscription", .{ .string = try resolveString(context, try requiredValue(node.inputs, "subscription")) });
    try object.put(allocator, "labels", try jsonFromValue(allocator, context, try requiredValue(node.inputs, "labels")));
    return .{ .object = object };
}

fn resultFromJson(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    physical: []const u8,
    body: []const u8,
) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const object = jsonObject(parsed.value) orelse return error.ProviderBug;
    if (!std.mem.eql(u8, jsonString(object.get("name")) orelse return error.ProviderBug, physical)) return error.InvalidConfiguration;
    const matches = try remoteMatches(context, node, object);
    const drift_fields = [_]value.Field{
        .{ .name = "__remote_json", .value = .{ .string = body } },
        .{ .name = "schema_type", .value = .{ .string = jsonString(object.get("type")) orelse "" } },
        .{ .name = "topic", .value = .{ .string = jsonString(object.get("topic")) orelse "" } },
    };
    const observed = if (matches) node.inputs else value.Value{ .object = &drift_fields };
    var outputs: [4]state.StateOutput = undefined;
    var count: usize = 0;
    outputs[count] = .{ .name = "name", .value = .{ .string = physical } };
    count += 1;
    if (isType(node, topic_type)) {
        outputs[count] = .{ .name = "kms_key_name", .value = .{ .string = jsonString(object.get("kmsKeyName")) orelse "" } };
        count += 1;
    } else if (isType(node, schema_type)) {
        outputs[count] = .{ .name = "revision_id", .value = .{ .string = jsonString(object.get("revisionId")) orelse "" } };
        count += 1;
        outputs[count] = .{ .name = "revision_create_time", .value = .{ .string = jsonString(object.get("revisionCreateTime")) orelse "" } };
        count += 1;
    } else if (isType(node, subscription_type)) {
        outputs[count] = .{ .name = "topic", .value = .{ .string = jsonString(object.get("topic")) orelse return error.ProviderBug } };
        count += 1;
        outputs[count] = .{ .name = "state", .value = .{ .string = jsonString(object.get("state")) orelse "STATE_UNSPECIFIED" } };
        count += 1;
    } else if (isType(node, snapshot_type)) {
        outputs[count] = .{ .name = "topic", .value = .{ .string = jsonString(object.get("topic")) orelse return error.ProviderBug } };
        count += 1;
        outputs[count] = .{ .name = "expire_time", .value = .{ .string = jsonString(object.get("expireTime")) orelse "" } };
        count += 1;
    }
    return provider_mod.ResourceResult.init(context.allocator, physical, observed, outputs[0..count], null);
}

fn remoteMatches(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    object: std.json.ObjectMap,
) ProviderError!bool {
    if (isType(node, schema_type)) {
        return stringEquals(object.get("type"), try requiredString(node.inputs, "schema_type")) and
            stringEquals(object.get("definition"), try requiredString(node.inputs, "definition"));
    }
    if (!jsonValueMatches(context, try requiredValue(node.inputs, "labels"), object.get("labels") orelse .{ .object = .empty })) return false;
    if (isType(node, topic_type)) {
        if (!stringEquals(object.get("kmsKeyName"), try requiredString(node.inputs, "kms_key_name"))) return false;
        if (durationSeconds(object.get("messageRetentionDuration")) != try requiredInteger(node.inputs, "message_retention_seconds")) return false;
        const policy = jsonObject(object.get("messageStoragePolicy") orelse .{ .object = .empty }) orelse return false;
        if (!jsonValueMatches(context, try requiredValue(node.inputs, "allowed_persistence_regions"), policy.get("allowedPersistenceRegions") orelse .{ .array = std.json.Array.init(context.allocator) })) return false;
        if (jsonBool(policy.get("enforceInTransit")) != try requiredBool(node.inputs, "enforce_in_transit")) return false;
        const desired_schema = try resolveString(context, try requiredValue(node.inputs, "schema_name"));
        const settings = jsonObject(object.get("schemaSettings") orelse .{ .object = .empty }) orelse return false;
        return stringEquals(settings.get("schema"), desired_schema) and
            stringEquals(settings.get("encoding"), try requiredString(node.inputs, "schema_encoding"));
    }
    if (isType(node, subscription_type)) {
        if (!stringEquals(object.get("topic"), try resolveString(context, try requiredValue(node.inputs, "topic")))) return false;
        if (jsonInteger(object.get("ackDeadlineSeconds")) != try requiredInteger(node.inputs, "ack_deadline_seconds")) return false;
        if (jsonBool(object.get("retainAckedMessages")) != try requiredBool(node.inputs, "retain_acked_messages")) return false;
        if (durationSeconds(object.get("messageRetentionDuration")) != try requiredInteger(node.inputs, "message_retention_seconds")) return false;
        if (jsonBool(object.get("enableMessageOrdering")) != try requiredBool(node.inputs, "enable_message_ordering")) return false;
        if (jsonBool(object.get("enableExactlyOnceDelivery")) != try requiredBool(node.inputs, "enable_exactly_once_delivery")) return false;
        if (!stringEquals(object.get("filter"), try requiredString(node.inputs, "filter"))) return false;
        const expiration = jsonObject(object.get("expirationPolicy") orelse .{ .object = .empty }) orelse return false;
        if (durationSeconds(expiration.get("ttl")) != try requiredInteger(node.inputs, "expiration_ttl_seconds")) return false;
        const push = jsonObject(object.get("pushConfig") orelse .{ .object = .empty }) orelse return false;
        const delivery_kind = try requiredString(node.inputs, "delivery_kind");
        if (std.mem.eql(u8, delivery_kind, "push")) {
            if (!stringEquals(push.get("pushEndpoint"), try requiredString(node.inputs, "push_endpoint"))) return false;
            const oidc = jsonObject(push.get("oidcToken") orelse .{ .object = .empty }) orelse return false;
            if (!stringEquals(oidc.get("serviceAccountEmail"), try requiredString(node.inputs, "push_service_account"))) return false;
            if (!stringEquals(oidc.get("audience"), try requiredString(node.inputs, "push_audience"))) return false;
        } else if (jsonString(push.get("pushEndpoint")) != null) return false;
        const dead_letter = jsonObject(object.get("deadLetterPolicy") orelse .{ .object = .empty }) orelse return false;
        if (!stringEquals(dead_letter.get("deadLetterTopic"), try resolveString(context, try requiredValue(node.inputs, "dead_letter_topic")))) return false;
        if (jsonInteger(dead_letter.get("maxDeliveryAttempts")) != try requiredInteger(node.inputs, "max_delivery_attempts")) return false;
        const retry = jsonObject(object.get("retryPolicy") orelse .{ .object = .empty }) orelse return false;
        return durationSeconds(retry.get("minimumBackoff")) == try requiredInteger(node.inputs, "retry_minimum_backoff_seconds") and
            durationSeconds(retry.get("maximumBackoff")) == try requiredInteger(node.inputs, "retry_maximum_backoff_seconds");
    }
    if (isType(node, snapshot_type)) return true;
    return false;
}

fn jsonFromValue(
    allocator: std.mem.Allocator,
    context: *provider_mod.OperationContext,
    input: value.Value,
) ProviderError!std.json.Value {
    return switch (input) {
        .string => |text| .{ .string = text },
        .integer => |number| .{ .integer = number },
        .boolean => |boolean| .{ .bool = boolean },
        .output_ref => |reference| .{ .string = try context.resolveOutputString(reference) },
        .list => |items| block: {
            var array = std.json.Array.init(allocator);
            for (items) |item| try array.append(try jsonFromValue(allocator, context, item));
            break :block .{ .array = array };
        },
        .object => |fields| block: {
            var object: std.json.ObjectMap = .empty;
            for (fields) |field| try object.put(allocator, field.name, try jsonFromValue(allocator, context, field.value));
            break :block .{ .object = object };
        },
        .secret_ref, .unknown_reason => error.InvalidConfiguration,
    };
}

fn jsonValueMatches(context: *provider_mod.OperationContext, expected: value.Value, actual: std.json.Value) bool {
    return switch (expected) {
        .string => |text| stringEquals(actual, text),
        .integer => |number| jsonInteger(actual) == number,
        .boolean => |boolean| jsonBool(actual) == boolean,
        .output_ref => |reference| stringEquals(actual, context.resolveOutputString(reference) catch return false),
        .list => |items| block: {
            const array = jsonArray(actual) orelse break :block false;
            if (items.len != array.items.len) break :block false;
            for (items, array.items) |item, candidate| if (!jsonValueMatches(context, item, candidate)) break :block false;
            break :block true;
        },
        .object => |fields| block: {
            const object = jsonObject(actual) orelse break :block false;
            if (fields.len != object.count()) break :block false;
            for (fields) |field| if (!jsonValueMatches(context, field.value, object.get(field.name) orelse break :block false)) break :block false;
            break :block true;
        },
        .secret_ref, .unknown_reason => false,
    };
}

fn iamResult(context: *provider_mod.OperationContext, node: resource.ResourceNode, target: []const u8) ProviderError!provider_mod.ResourceResult {
    const physical = try std.fmt.allocPrint(context.allocator, "{s}/iam/{s}", .{ target, try requiredString(node.inputs, "name") });
    defer context.allocator.free(physical);
    const outputs = [_]state.StateOutput{.{ .name = "binding_id", .value = .{ .string = physical } }};
    return provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &outputs, null);
}

fn policyBodyAlloc(allocator: std.mem.Allocator, policy: std.json.Value) ProviderError![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var wrapper: std.json.ObjectMap = .empty;
    try wrapper.put(arena.allocator(), "policy", policy);
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
        const member = try requiredString(node.inputs, "member");
        for (members.items, 0..) |candidate, member_index| {
            if (!stringEquals(candidate, member)) continue;
            if (should_exist) return false;
            _ = members.orderedRemove(member_index);
            if (members.items.len == 0) _ = bindings.orderedRemove(binding_index);
            return true;
        }
        if (!should_exist) return false;
        try members.append(.{ .string = member });
        return true;
    }
    if (!should_exist) return false;
    var members = std.json.Array.init(allocator);
    try members.append(.{ .string = try requiredString(node.inputs, "member") });
    var binding: std.json.ObjectMap = .empty;
    try binding.put(allocator, "role", .{ .string = try requiredString(node.inputs, "role") });
    try binding.put(allocator, "members", .{ .array = members });
    const condition_title = try requiredString(node.inputs, "condition_title");
    if (condition_title.len > 0) {
        var condition: std.json.ObjectMap = .empty;
        try condition.put(allocator, "title", .{ .string = condition_title });
        const description = try requiredString(node.inputs, "condition_description");
        if (description.len > 0) try condition.put(allocator, "description", .{ .string = description });
        try condition.put(allocator, "expression", .{ .string = try requiredString(node.inputs, "condition_expression") });
        try binding.put(allocator, "condition", .{ .object = condition });
    }
    try bindings.append(.{ .object = binding });
    return true;
}

fn bindingIdentityMatches(binding: std.json.ObjectMap, node: resource.ResourceNode) bool {
    if (!stringEquals(binding.get("role"), inputString(node.inputs, "role") orelse return false)) return false;
    const desired_title = inputString(node.inputs, "condition_title") orelse return false;
    const desired_description = inputString(node.inputs, "condition_description") orelse return false;
    const desired_expression = inputString(node.inputs, "condition_expression") orelse return false;
    const condition = jsonObject(binding.get("condition") orelse .{ .object = .empty }) orelse return false;
    return stringEquals(condition.get("title"), desired_title) and
        stringEquals(condition.get("description"), desired_description) and
        stringEquals(condition.get("expression"), desired_expression);
}

fn immutableStringChanged(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    observed: *const provider_mod.ResourceResult,
    field: []const u8,
) bool {
    const desired = resolveString(context, requiredValue(node.inputs, field) catch return true) catch return true;
    const actual = inputString(observed.observed_inputs, field) orelse return true;
    return !std.mem.eql(u8, desired, actual);
}

fn desiredHashChangedSinceState(context: *provider_mod.OperationContext, node: resource.ResourceNode) bool {
    const store = context.state orelse return false;
    const record = store.get(node.id) orelse return false;
    const desired_hash = std.fmt.bytesToHex(node.inputs_hash, .lower);
    return !std.mem.eql(u8, record.desired_hash, &desired_hash);
}

fn durationAlloc(allocator: std.mem.Allocator, seconds: i64) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}s", .{seconds}) catch error.OutOfMemory;
}

fn durationSeconds(input: ?std.json.Value) i64 {
    const text = jsonString(input) orelse return 0;
    if (!std.mem.endsWith(u8, text, "s")) return -1;
    return std.fmt.parseInt(i64, text[0 .. text.len - 1], 10) catch -1;
}

fn requiredValue(input: value.Value, name: []const u8) ProviderError!value.Value {
    if (input != .object) return error.InvalidConfiguration;
    for (input.object) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return error.InvalidConfiguration;
}

fn requiredString(input: value.Value, name: []const u8) ProviderError![]const u8 {
    return switch (try requiredValue(input, name)) {
        .string => |text| text,
        else => error.InvalidConfiguration,
    };
}

fn requiredInteger(input: value.Value, name: []const u8) ProviderError!i64 {
    return switch (try requiredValue(input, name)) {
        .integer => |number| number,
        else => error.InvalidConfiguration,
    };
}

fn requiredBool(input: value.Value, name: []const u8) ProviderError!bool {
    return switch (try requiredValue(input, name)) {
        .boolean => |boolean| boolean,
        else => error.InvalidConfiguration,
    };
}

fn resolveString(context: *provider_mod.OperationContext, input: value.Value) ProviderError![]const u8 {
    return switch (input) {
        .string => |text| text,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}

fn inputString(input: value.Value, name: []const u8) ?[]const u8 {
    return switch (requiredValue(input, name) catch return null) {
        .string => |text| text,
        else => null,
    };
}

fn stringEquals(input: ?std.json.Value, expected: []const u8) bool {
    const actual = jsonString(input) orelse return expected.len == 0;
    return std.mem.eql(u8, actual, expected);
}

fn jsonObject(input: std.json.Value) ?std.json.ObjectMap {
    return switch (input) {
        .object => |object| object,
        else => null,
    };
}

fn jsonArray(input: std.json.Value) ?std.json.Array {
    return switch (input) {
        .array => |array| array,
        else => null,
    };
}

fn jsonArrayLength(input: ?std.json.Value) usize {
    return if (input) |present| if (jsonArray(present)) |array| array.items.len else 0 else 0;
}

fn jsonString(input: ?std.json.Value) ?[]const u8 {
    const present = input orelse return null;
    return switch (present) {
        .string => |text| text,
        else => null,
    };
}

fn jsonInteger(input: ?std.json.Value) i64 {
    const present = input orelse return 0;
    return switch (present) {
        .integer => |number| number,
        else => 0,
    };
}

fn jsonBool(input: ?std.json.Value) bool {
    const present = input orelse return false;
    return switch (present) {
        .bool => |boolean| boolean,
        else => false,
    };
}

fn isIam(node: resource.ResourceNode) bool {
    return isType(node, topic_iam_type) or isType(node, subscription_iam_type);
}

fn isType(node: resource.ResourceNode, type_name: []const u8) bool {
    return std.mem.eql(u8, node.type_name, type_name);
}
