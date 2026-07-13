const std = @import("std");
const grpc_mod = @import("grpc.zig");
const proto_contract = @import("proto_contract.zig");

pub const googleapis_revision = "95de37fafded89761dd958268242904a6d893eae";

pub const Transport = enum {
    grpc,
    rest_transcoding,
    rest_discovery,
    protobuf_http_fallback,
};

pub const TransportSupport = struct {
    grpc: bool = false,
    rest_transcoding: bool = false,
    rest_discovery: bool = false,
    protobuf_http_fallback: bool = false,
};

pub const TransportCapabilities = struct {
    grpc_http2: bool = false,
    rest_json: bool = false,
    experimental_protobuf_http: bool = false,
};

pub const TransportPolicy = struct {
    prefer_grpc: bool = true,
    allow_experimental_fallback: bool = false,
};

pub fn capabilitiesFromAudit(grpc_capabilities: grpc_mod.Capabilities, rest_json: bool) TransportCapabilities {
    grpc_mod.requireQualified(grpc_capabilities) catch return .{ .rest_json = rest_json };
    return .{ .grpc_http2 = true, .rest_json = rest_json };
}

pub const ContractError = proto_contract.Error || error{RpcContractMismatch};

pub fn verifyPinnedContract(allocator: std.mem.Allocator) ContractError!void {
    try proto_contract.verifyEmbeddedLock();
    var contract = try proto_contract.inspectCloudRunV2(allocator, proto_contract.embedded_descriptor);
    defer contract.deinit(allocator);
    if (!std.mem.eql(u8, contract.default_host, cloud_run_v2.create_service.default_host)) {
        return error.RpcContractMismatch;
    }
    for ([_]Method{
        cloud_run_v2.create_service,
        cloud_run_v2.get_service,
        cloud_run_v2.update_service,
        cloud_run_v2.delete_service,
    }) |method| try verifyMethod(contract, method);
}

fn verifyMethod(contract: proto_contract.Contract, method: Method) error{RpcContractMismatch}!void {
    const generated = contract.method(method.method) orelse return error.RpcContractMismatch;
    const rest = method.rest orelse return error.RpcContractMismatch;
    if (!std.mem.eql(u8, generated.http_method, rest.method.text()) or
        !std.mem.eql(u8, generated.path_template, rest.path_template) or
        !std.mem.eql(u8, generated.body, rest.body orelse "") or
        !std.mem.eql(u8, generated.routing_field, method.routing_field orelse "") or
        !typeNameMatches(generated.input_type, method.request_type) or
        !typeNameMatches(generated.output_type, method.response_type))
    {
        return error.RpcContractMismatch;
    }
    if (generated.lro_response_type.len > 0) {
        const lro = method.long_running orelse return error.RpcContractMismatch;
        if (!typeNameMatches(generated.lro_response_type, lro.response_type) or
            !typeNameMatches(generated.lro_metadata_type, lro.metadata_type))
        {
            return error.RpcContractMismatch;
        }
    } else if (method.long_running != null) return error.RpcContractMismatch;
}

fn typeNameMatches(generated: []const u8, declared: []const u8) bool {
    const normalized = std.mem.trimStart(u8, generated, ".");
    return std.mem.eql(u8, normalized, declared) or
        (std.mem.endsWith(u8, declared, normalized) and declared.len > normalized.len and
            declared[declared.len - normalized.len - 1] == '.');
}

pub const HttpMethod = enum {
    get,
    post,
    put,
    patch,
    delete,

    pub fn text(self: HttpMethod) []const u8 {
        return switch (self) {
            .get => "GET",
            .post => "POST",
            .put => "PUT",
            .patch => "PATCH",
            .delete => "DELETE",
        };
    }
};

pub const QueryField = struct {
    request_field: []const u8,
    wire_name: []const u8,
};

pub const RestBinding = struct {
    method: HttpMethod,
    path_template: []const u8,
    body: ?[]const u8 = null,
    query_fields: []const QueryField = &.{},
};

pub const LongRunning = struct {
    response_type: []const u8,
    metadata_type: []const u8,
};

pub const Semantics = struct {
    validate_only: bool = false,
    update_mask: bool = false,
    etag: bool = false,
    request_id: bool = false,
    reconciling: bool = false,
};

pub const Method = struct {
    package: []const u8,
    service: []const u8,
    method: []const u8,
    default_host: []const u8,
    request_type: []const u8,
    response_type: []const u8,
    rest: ?RestBinding = null,
    routing_field: ?[]const u8 = null,
    long_running: ?LongRunning = null,
    transports: TransportSupport,
    semantics: Semantics = .{},
};

pub const Parameter = struct {
    field: []const u8,
    value: []const u8,
};

pub const TransportError = error{NoSupportedTransport};

pub fn selectTransport(
    method: Method,
    capabilities: TransportCapabilities,
    policy: TransportPolicy,
) TransportError!Transport {
    if (policy.prefer_grpc and method.transports.grpc and capabilities.grpc_http2) return .grpc;
    if (method.transports.rest_transcoding and capabilities.rest_json) return .rest_transcoding;
    if (method.transports.rest_discovery and capabilities.rest_json) return .rest_discovery;
    if (!policy.prefer_grpc and method.transports.grpc and capabilities.grpc_http2) return .grpc;
    if (policy.allow_experimental_fallback and
        method.transports.protobuf_http_fallback and
        capabilities.experimental_protobuf_http)
    {
        return .protobuf_http_fallback;
    }
    return error.NoSupportedTransport;
}

pub const PathError = std.mem.Allocator.Error || error{
    InvalidPathTemplate,
    InvalidResourceName,
    MissingPathParameter,
    UnknownQueryParameter,
    MissingRestBinding,
};

pub fn restPathAlloc(
    allocator: std.mem.Allocator,
    method: Method,
    path_parameters: []const Parameter,
    query_parameters: []const Parameter,
) PathError![]u8 {
    const rest = method.rest orelse return error.MissingRestBinding;
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    var cursor: usize = 0;
    while (std.mem.indexOfScalarPos(u8, rest.path_template, cursor, '{')) |open| {
        try result.appendSlice(allocator, rest.path_template[cursor..open]);
        const close = std.mem.indexOfScalarPos(u8, rest.path_template, open + 1, '}') orelse
            return error.InvalidPathTemplate;
        const expression = rest.path_template[open + 1 .. close];
        const separator = std.mem.indexOfScalar(u8, expression, '=') orelse return error.InvalidPathTemplate;
        const field = expression[0..separator];
        const pattern = expression[separator + 1 ..];
        if (field.len == 0 or pattern.len == 0) return error.InvalidPathTemplate;
        const parameter = findParameter(path_parameters, field) orelse return error.MissingPathParameter;
        if (!matchesResourcePattern(pattern, parameter.value)) return error.InvalidResourceName;
        try result.appendSlice(allocator, parameter.value);
        cursor = close + 1;
    }
    try result.appendSlice(allocator, rest.path_template[cursor..]);

    for (query_parameters, 0..) |parameter, index| {
        const query = findQueryField(rest.query_fields, parameter.field) orelse return error.UnknownQueryParameter;
        try result.append(allocator, if (index == 0) '?' else '&');
        try result.appendSlice(allocator, query.wire_name);
        try result.append(allocator, '=');
        try appendQueryValue(allocator, &result, parameter.value);
    }
    return result.toOwnedSlice(allocator);
}

fn findParameter(parameters: []const Parameter, field: []const u8) ?Parameter {
    for (parameters) |parameter| if (std.mem.eql(u8, parameter.field, field)) return parameter;
    return null;
}

fn findQueryField(fields: []const QueryField, name: []const u8) ?QueryField {
    for (fields) |field| if (std.mem.eql(u8, field.request_field, name)) return field;
    return null;
}

fn matchesResourcePattern(pattern: []const u8, value: []const u8) bool {
    if (value.len == 0 or std.mem.indexOfAny(u8, value, "?#{}") != null) return false;
    var pattern_parts = std.mem.splitScalar(u8, pattern, '/');
    var value_parts = std.mem.splitScalar(u8, value, '/');
    while (pattern_parts.next()) |expected| {
        if (std.mem.eql(u8, expected, "**")) return value_parts.rest().len > 0;
        const actual = value_parts.next() orelse return false;
        if (actual.len == 0) return false;
        if (!std.mem.eql(u8, expected, "*") and !std.mem.eql(u8, expected, actual)) return false;
    }
    return value_parts.next() == null;
}

fn appendQueryValue(
    allocator: std.mem.Allocator,
    result: *std.ArrayList(u8),
    value: []const u8,
) std.mem.Allocator.Error!void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~' or byte == ',') {
            try result.append(allocator, byte);
        } else {
            try result.appendSlice(allocator, &.{ '%', hex[byte >> 4], hex[byte & 0x0f] });
        }
    }
}

const cloud_run_transport = TransportSupport{
    .grpc = true,
    .rest_transcoding = true,
};
const create_query = [_]QueryField{
    .{ .request_field = "service_id", .wire_name = "serviceId" },
    .{ .request_field = "validate_only", .wire_name = "validateOnly" },
};
const update_query = [_]QueryField{
    .{ .request_field = "update_mask", .wire_name = "updateMask" },
    .{ .request_field = "validate_only", .wire_name = "validateOnly" },
    .{ .request_field = "allow_missing", .wire_name = "allowMissing" },
};
const delete_query = [_]QueryField{
    .{ .request_field = "validate_only", .wire_name = "validateOnly" },
    .{ .request_field = "etag", .wire_name = "etag" },
};
const cloud_run_iam_get_query = [_]QueryField{
    .{ .request_field = "requested_policy_version", .wire_name = "options.requestedPolicyVersion" },
};
const service_lro = LongRunning{
    .response_type = "google.cloud.run.v2.Service",
    .metadata_type = "google.cloud.run.v2.Service",
};

pub const cloud_run_v2 = struct {
    pub const create_service = Method{
        .package = "google.cloud.run.v2",
        .service = "google.cloud.run.v2.Services",
        .method = "CreateService",
        .default_host = "run.googleapis.com",
        .request_type = "google.cloud.run.v2.CreateServiceRequest",
        .response_type = "google.longrunning.Operation",
        .rest = .{
            .method = .post,
            .path_template = "/v2/{parent=projects/*/locations/*}/services",
            .body = "service",
            .query_fields = &create_query,
        },
        .routing_field = "parent",
        .long_running = service_lro,
        .transports = cloud_run_transport,
        .semantics = .{ .validate_only = true, .reconciling = true },
    };

    pub const get_service = Method{
        .package = "google.cloud.run.v2",
        .service = "google.cloud.run.v2.Services",
        .method = "GetService",
        .default_host = "run.googleapis.com",
        .request_type = "google.cloud.run.v2.GetServiceRequest",
        .response_type = "google.cloud.run.v2.Service",
        .rest = .{ .method = .get, .path_template = "/v2/{name=projects/*/locations/*/services/*}" },
        .routing_field = "name",
        .transports = cloud_run_transport,
        .semantics = .{ .etag = true, .reconciling = true },
    };

    pub const update_service = Method{
        .package = "google.cloud.run.v2",
        .service = "google.cloud.run.v2.Services",
        .method = "UpdateService",
        .default_host = "run.googleapis.com",
        .request_type = "google.cloud.run.v2.UpdateServiceRequest",
        .response_type = "google.longrunning.Operation",
        .rest = .{
            .method = .patch,
            .path_template = "/v2/{service.name=projects/*/locations/*/services/*}",
            .body = "service",
            .query_fields = &update_query,
        },
        .routing_field = "service.name",
        .long_running = service_lro,
        .transports = cloud_run_transport,
        .semantics = .{ .validate_only = true, .update_mask = true, .etag = true, .reconciling = true },
    };

    pub const delete_service = Method{
        .package = "google.cloud.run.v2",
        .service = "google.cloud.run.v2.Services",
        .method = "DeleteService",
        .default_host = "run.googleapis.com",
        .request_type = "google.cloud.run.v2.DeleteServiceRequest",
        .response_type = "google.longrunning.Operation",
        .rest = .{
            .method = .delete,
            .path_template = "/v2/{name=projects/*/locations/*/services/*}",
            .query_fields = &delete_query,
        },
        .routing_field = "name",
        .long_running = service_lro,
        .transports = cloud_run_transport,
        .semantics = .{ .validate_only = true, .etag = true, .reconciling = true },
    };

    pub const get_service_iam_policy = Method{
        .package = "google.cloud.run.v2",
        .service = "google.cloud.run.v2.Services",
        .method = "GetIamPolicy",
        .default_host = "run.googleapis.com",
        .request_type = "google.iam.v1.GetIamPolicyRequest",
        .response_type = "google.iam.v1.Policy",
        .rest = .{
            .method = .get,
            .path_template = "/v2/{resource=projects/*/locations/*/services/*}:getIamPolicy",
            .query_fields = &cloud_run_iam_get_query,
        },
        .routing_field = "resource",
        .transports = cloud_run_transport,
        .semantics = .{ .etag = true },
    };

    pub const set_service_iam_policy = Method{
        .package = "google.cloud.run.v2",
        .service = "google.cloud.run.v2.Services",
        .method = "SetIamPolicy",
        .default_host = "run.googleapis.com",
        .request_type = "google.iam.v1.SetIamPolicyRequest",
        .response_type = "google.iam.v1.Policy",
        .rest = .{
            .method = .post,
            .path_template = "/v2/{resource=projects/*/locations/*/services/*}:setIamPolicy",
            .body = "*",
        },
        .routing_field = "resource",
        .transports = cloud_run_transport,
        .semantics = .{ .etag = true },
    };
};

const pubsub_transport = TransportSupport{
    .grpc = true,
    .rest_transcoding = true,
};
const pubsub_schema_create_query = [_]QueryField{
    .{ .request_field = "schema_id", .wire_name = "schemaId" },
};
const pubsub_update_query = [_]QueryField{
    .{ .request_field = "update_mask", .wire_name = "updateMask" },
};
const pubsub_schema_get_query = [_]QueryField{
    .{ .request_field = "view", .wire_name = "view" },
};
const pubsub_iam_get_query = [_]QueryField{
    .{ .request_field = "requested_policy_version", .wire_name = "options.requestedPolicyVersion" },
};

fn pubsubMethod(
    service: []const u8,
    method: []const u8,
    request_type: []const u8,
    response_type: []const u8,
    rest: RestBinding,
    routing_field: []const u8,
    semantics: Semantics,
) Method {
    return .{
        .package = "google.pubsub.v1",
        .service = service,
        .method = method,
        .default_host = "pubsub.googleapis.com",
        .request_type = request_type,
        .response_type = response_type,
        .rest = rest,
        .routing_field = routing_field,
        .transports = pubsub_transport,
        .semantics = semantics,
    };
}

/// Pub/Sub v1 method metadata pinned to `googleapis_revision`.
/// The embedded descriptor lock currently covers Cloud Run; these declarations
/// are still tested against Google's canonical HTTP transcoding surface.
pub const pubsub_v1 = struct {
    pub const create_topic = pubsubMethod(
        "google.pubsub.v1.Publisher",
        "CreateTopic",
        "google.pubsub.v1.Topic",
        "google.pubsub.v1.Topic",
        .{ .method = .put, .path_template = "/v1/{name=projects/*/topics/*}", .body = "*" },
        "name",
        .{},
    );
    pub const get_topic = pubsubMethod(
        "google.pubsub.v1.Publisher",
        "GetTopic",
        "google.pubsub.v1.GetTopicRequest",
        "google.pubsub.v1.Topic",
        .{ .method = .get, .path_template = "/v1/{topic=projects/*/topics/*}" },
        "topic",
        .{},
    );
    pub const update_topic = pubsubMethod(
        "google.pubsub.v1.Publisher",
        "UpdateTopic",
        "google.pubsub.v1.UpdateTopicRequest",
        "google.pubsub.v1.Topic",
        .{ .method = .patch, .path_template = "/v1/{topic.name=projects/*/topics/*}", .body = "topic", .query_fields = &pubsub_update_query },
        "topic.name",
        .{ .update_mask = true },
    );
    pub const delete_topic = pubsubMethod(
        "google.pubsub.v1.Publisher",
        "DeleteTopic",
        "google.pubsub.v1.DeleteTopicRequest",
        "google.protobuf.Empty",
        .{ .method = .delete, .path_template = "/v1/{topic=projects/*/topics/*}" },
        "topic",
        .{},
    );
    pub const get_topic_iam_policy = pubsubMethod(
        "google.pubsub.v1.Publisher",
        "GetIamPolicy",
        "google.iam.v1.GetIamPolicyRequest",
        "google.iam.v1.Policy",
        .{ .method = .get, .path_template = "/v1/{resource=projects/*/topics/*}:getIamPolicy", .query_fields = &pubsub_iam_get_query },
        "resource",
        .{ .etag = true },
    );
    pub const set_topic_iam_policy = pubsubMethod(
        "google.pubsub.v1.Publisher",
        "SetIamPolicy",
        "google.iam.v1.SetIamPolicyRequest",
        "google.iam.v1.Policy",
        .{ .method = .post, .path_template = "/v1/{resource=projects/*/topics/*}:setIamPolicy", .body = "*" },
        "resource",
        .{ .etag = true },
    );

    pub const create_schema = pubsubMethod(
        "google.pubsub.v1.SchemaService",
        "CreateSchema",
        "google.pubsub.v1.CreateSchemaRequest",
        "google.pubsub.v1.Schema",
        .{ .method = .post, .path_template = "/v1/{parent=projects/*}/schemas", .body = "schema", .query_fields = &pubsub_schema_create_query },
        "parent",
        .{},
    );
    pub const get_schema = pubsubMethod(
        "google.pubsub.v1.SchemaService",
        "GetSchema",
        "google.pubsub.v1.GetSchemaRequest",
        "google.pubsub.v1.Schema",
        .{ .method = .get, .path_template = "/v1/{name=projects/*/schemas/*}", .query_fields = &pubsub_schema_get_query },
        "name",
        .{},
    );
    pub const commit_schema = pubsubMethod(
        "google.pubsub.v1.SchemaService",
        "CommitSchema",
        "google.pubsub.v1.CommitSchemaRequest",
        "google.pubsub.v1.Schema",
        .{ .method = .post, .path_template = "/v1/{name=projects/*/schemas/*}:commit", .body = "*" },
        "name",
        .{},
    );
    pub const delete_schema = pubsubMethod(
        "google.pubsub.v1.SchemaService",
        "DeleteSchema",
        "google.pubsub.v1.DeleteSchemaRequest",
        "google.protobuf.Empty",
        .{ .method = .delete, .path_template = "/v1/{name=projects/*/schemas/*}" },
        "name",
        .{},
    );

    pub const create_subscription = pubsubMethod(
        "google.pubsub.v1.Subscriber",
        "CreateSubscription",
        "google.pubsub.v1.Subscription",
        "google.pubsub.v1.Subscription",
        .{ .method = .put, .path_template = "/v1/{name=projects/*/subscriptions/*}", .body = "*" },
        "name",
        .{},
    );
    pub const get_subscription = pubsubMethod(
        "google.pubsub.v1.Subscriber",
        "GetSubscription",
        "google.pubsub.v1.GetSubscriptionRequest",
        "google.pubsub.v1.Subscription",
        .{ .method = .get, .path_template = "/v1/{subscription=projects/*/subscriptions/*}" },
        "subscription",
        .{},
    );
    pub const update_subscription = pubsubMethod(
        "google.pubsub.v1.Subscriber",
        "UpdateSubscription",
        "google.pubsub.v1.UpdateSubscriptionRequest",
        "google.pubsub.v1.Subscription",
        .{ .method = .patch, .path_template = "/v1/{subscription.name=projects/*/subscriptions/*}", .body = "subscription", .query_fields = &pubsub_update_query },
        "subscription.name",
        .{ .update_mask = true },
    );
    pub const delete_subscription = pubsubMethod(
        "google.pubsub.v1.Subscriber",
        "DeleteSubscription",
        "google.pubsub.v1.DeleteSubscriptionRequest",
        "google.protobuf.Empty",
        .{ .method = .delete, .path_template = "/v1/{subscription=projects/*/subscriptions/*}" },
        "subscription",
        .{},
    );
    pub const get_subscription_iam_policy = pubsubMethod(
        "google.pubsub.v1.Subscriber",
        "GetIamPolicy",
        "google.iam.v1.GetIamPolicyRequest",
        "google.iam.v1.Policy",
        .{ .method = .get, .path_template = "/v1/{resource=projects/*/subscriptions/*}:getIamPolicy", .query_fields = &pubsub_iam_get_query },
        "resource",
        .{ .etag = true },
    );
    pub const set_subscription_iam_policy = pubsubMethod(
        "google.pubsub.v1.Subscriber",
        "SetIamPolicy",
        "google.iam.v1.SetIamPolicyRequest",
        "google.iam.v1.Policy",
        .{ .method = .post, .path_template = "/v1/{resource=projects/*/subscriptions/*}:setIamPolicy", .body = "*" },
        "resource",
        .{ .etag = true },
    );

    pub const create_snapshot = pubsubMethod(
        "google.pubsub.v1.Subscriber",
        "CreateSnapshot",
        "google.pubsub.v1.Snapshot",
        "google.pubsub.v1.Snapshot",
        .{ .method = .put, .path_template = "/v1/{name=projects/*/snapshots/*}", .body = "*" },
        "name",
        .{},
    );
    pub const get_snapshot = pubsubMethod(
        "google.pubsub.v1.Subscriber",
        "GetSnapshot",
        "google.pubsub.v1.GetSnapshotRequest",
        "google.pubsub.v1.Snapshot",
        .{ .method = .get, .path_template = "/v1/{snapshot=projects/*/snapshots/*}" },
        "snapshot",
        .{},
    );
    pub const update_snapshot = pubsubMethod(
        "google.pubsub.v1.Subscriber",
        "UpdateSnapshot",
        "google.pubsub.v1.UpdateSnapshotRequest",
        "google.pubsub.v1.Snapshot",
        .{ .method = .patch, .path_template = "/v1/{snapshot.name=projects/*/snapshots/*}", .body = "snapshot", .query_fields = &pubsub_update_query },
        "snapshot.name",
        .{ .update_mask = true },
    );
    pub const delete_snapshot = pubsubMethod(
        "google.pubsub.v1.Subscriber",
        "DeleteSnapshot",
        "google.pubsub.v1.DeleteSnapshotRequest",
        "google.protobuf.Empty",
        .{ .method = .delete, .path_template = "/v1/{snapshot=projects/*/snapshots/*}" },
        "snapshot",
        .{},
    );
};

const cloud_tasks_transport = TransportSupport{
    .grpc = true,
    .rest_transcoding = true,
};
const cloud_tasks_update_query = [_]QueryField{
    .{ .request_field = "update_mask", .wire_name = "updateMask" },
};
const cloud_tasks_iam_get_query = [_]QueryField{
    .{ .request_field = "requested_policy_version", .wire_name = "options.requestedPolicyVersion" },
};

fn cloudTasksMethod(
    method: []const u8,
    request_type: []const u8,
    response_type: []const u8,
    rest: RestBinding,
    routing_field: []const u8,
    semantics: Semantics,
) Method {
    return .{
        .package = "google.cloud.tasks.v2",
        .service = "google.cloud.tasks.v2.CloudTasks",
        .method = method,
        .default_host = "cloudtasks.googleapis.com",
        .request_type = request_type,
        .response_type = response_type,
        .rest = rest,
        .routing_field = routing_field,
        .transports = cloud_tasks_transport,
        .semantics = semantics,
    };
}

/// Cloud Tasks v2 queue methods pinned to `googleapis_revision`.
pub const cloud_tasks_v2 = struct {
    pub const create_queue = cloudTasksMethod(
        "CreateQueue",
        "google.cloud.tasks.v2.CreateQueueRequest",
        "google.cloud.tasks.v2.Queue",
        .{ .method = .post, .path_template = "/v2/{parent=projects/*/locations/*}/queues", .body = "queue" },
        "parent",
        .{},
    );
    pub const get_queue = cloudTasksMethod(
        "GetQueue",
        "google.cloud.tasks.v2.GetQueueRequest",
        "google.cloud.tasks.v2.Queue",
        .{ .method = .get, .path_template = "/v2/{name=projects/*/locations/*/queues/*}" },
        "name",
        .{},
    );
    pub const update_queue = cloudTasksMethod(
        "UpdateQueue",
        "google.cloud.tasks.v2.UpdateQueueRequest",
        "google.cloud.tasks.v2.Queue",
        .{ .method = .patch, .path_template = "/v2/{queue.name=projects/*/locations/*/queues/*}", .body = "queue", .query_fields = &cloud_tasks_update_query },
        "queue.name",
        .{ .update_mask = true },
    );
    pub const delete_queue = cloudTasksMethod(
        "DeleteQueue",
        "google.cloud.tasks.v2.DeleteQueueRequest",
        "google.protobuf.Empty",
        .{ .method = .delete, .path_template = "/v2/{name=projects/*/locations/*/queues/*}" },
        "name",
        .{},
    );
    pub const get_queue_iam_policy = cloudTasksMethod(
        "GetIamPolicy",
        "google.iam.v1.GetIamPolicyRequest",
        "google.iam.v1.Policy",
        .{ .method = .get, .path_template = "/v2/{resource=projects/*/locations/*/queues/*}:getIamPolicy", .query_fields = &cloud_tasks_iam_get_query },
        "resource",
        .{ .etag = true },
    );
    pub const set_queue_iam_policy = cloudTasksMethod(
        "SetIamPolicy",
        "google.iam.v1.SetIamPolicyRequest",
        "google.iam.v1.Policy",
        .{ .method = .post, .path_template = "/v2/{resource=projects/*/locations/*/queues/*}:setIamPolicy", .body = "*" },
        "resource",
        .{ .etag = true },
    );
};

const eventarc_transport = TransportSupport{
    .grpc = true,
    .rest_transcoding = true,
};
const eventarc_create_query = [_]QueryField{
    .{ .request_field = "trigger_id", .wire_name = "triggerId" },
    .{ .request_field = "validate_only", .wire_name = "validateOnly" },
};
const eventarc_update_query = [_]QueryField{
    .{ .request_field = "update_mask", .wire_name = "updateMask" },
    .{ .request_field = "allow_missing", .wire_name = "allowMissing" },
    .{ .request_field = "validate_only", .wire_name = "validateOnly" },
};
const eventarc_delete_query = [_]QueryField{
    .{ .request_field = "etag", .wire_name = "etag" },
    .{ .request_field = "allow_missing", .wire_name = "allowMissing" },
    .{ .request_field = "validate_only", .wire_name = "validateOnly" },
};
const eventarc_lro = LongRunning{
    .response_type = "google.cloud.eventarc.v1.Trigger",
    .metadata_type = "google.cloud.eventarc.v1.OperationMetadata",
};

fn eventarcMethod(
    method: []const u8,
    request_type: []const u8,
    response_type: []const u8,
    rest: RestBinding,
    routing_field: []const u8,
    long_running: ?LongRunning,
    semantics: Semantics,
) Method {
    return .{
        .package = "google.cloud.eventarc.v1",
        .service = "google.cloud.eventarc.v1.Eventarc",
        .method = method,
        .default_host = "eventarc.googleapis.com",
        .request_type = request_type,
        .response_type = response_type,
        .rest = rest,
        .routing_field = routing_field,
        .long_running = long_running,
        .transports = eventarc_transport,
        .semantics = semantics,
    };
}

/// Eventarc v1 trigger methods pinned to `googleapis_revision`.
pub const eventarc_v1 = struct {
    pub const create_trigger = eventarcMethod(
        "CreateTrigger",
        "google.cloud.eventarc.v1.CreateTriggerRequest",
        "google.longrunning.Operation",
        .{ .method = .post, .path_template = "/v1/{parent=projects/*/locations/*}/triggers", .body = "trigger", .query_fields = &eventarc_create_query },
        "parent",
        eventarc_lro,
        .{ .validate_only = true },
    );
    pub const get_trigger = eventarcMethod(
        "GetTrigger",
        "google.cloud.eventarc.v1.GetTriggerRequest",
        "google.cloud.eventarc.v1.Trigger",
        .{ .method = .get, .path_template = "/v1/{name=projects/*/locations/*/triggers/*}" },
        "name",
        null,
        .{ .etag = true },
    );
    pub const update_trigger = eventarcMethod(
        "UpdateTrigger",
        "google.cloud.eventarc.v1.UpdateTriggerRequest",
        "google.longrunning.Operation",
        .{ .method = .patch, .path_template = "/v1/{trigger.name=projects/*/locations/*/triggers/*}", .body = "trigger", .query_fields = &eventarc_update_query },
        "trigger.name",
        eventarc_lro,
        .{ .validate_only = true, .update_mask = true, .etag = true },
    );
    pub const delete_trigger = eventarcMethod(
        "DeleteTrigger",
        "google.cloud.eventarc.v1.DeleteTriggerRequest",
        "google.longrunning.Operation",
        .{ .method = .delete, .path_template = "/v1/{name=projects/*/locations/*/triggers/*}", .query_fields = &eventarc_delete_query },
        "name",
        eventarc_lro,
        .{ .validate_only = true, .etag = true },
    );
};
