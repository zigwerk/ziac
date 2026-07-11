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
    patch,
    delete,

    pub fn text(self: HttpMethod) []const u8 {
        return switch (self) {
            .get => "GET",
            .post => "POST",
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
};
