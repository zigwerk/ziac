const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    DuplicateKey,
    DuplicateValue,
    InvalidArtifact,
    InvalidConnectivity,
    InvalidIamMember,
    InvalidMetadata,
    InvalidName,
    InvalidOutput,
    InvalidRegion,
    InvalidRole,
    InvalidSource,
    InvalidStorage,
};

pub const KeyValue = struct { key: []const u8, value: []const u8 };
pub const RemovalPolicy = enum { retain, delete };
pub const IamCondition = struct { title: []const u8, expression: []const u8, description: []const u8 = "" };

pub const DatasetArgs = struct {
    name: []const u8,
    location: []const u8,
    display_name: []const u8,
    metadata_schema_uri: []const u8,
    metadata_json: []const u8,
    description: []const u8 = "",
    kms_key_name: ?output.Output([]const u8, .public) = null,
    labels: []const KeyValue = &.{},
    protect: bool = true,
    removal_policy: RemovalPolicy = .retain,
};

pub const Dataset = struct {
    pub const Outputs = CommonOutputs;
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    etag: Outputs.Etag.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: DatasetArgs) BuildError!Dataset {
        try validateCommon(provider, args.name, args.location, args.display_name);
        try validateSchemaUri(args.metadata_schema_uri, "dataset");
        try validateJson(args.metadata_json, 128 * 1024);
        var labels = try mapValue(allocator, args.labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "kms_key_name", .value = try optionalOutputValue(args.kms_key_name) },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "metadata_json", .value = .{ .string = args.metadata_json } },
            .{ .name = "metadata_schema_uri", .value = .{ .string = args.metadata_schema_uri } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
        };
        const node = try nodeOwned(allocator, "gcp.vertex.Dataset", args.location, args.name, null, &fields, lifecycle(args.protect, args.removal_policy));
        return commonResource(Dataset, node);
    }
    pub fn deinit(self: *Dataset, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const ServingContainer = struct {
    image_uri: []const u8,
    ports: []const u16 = &.{8080},
    predict_route: []const u8 = "/predict",
    health_route: []const u8 = "/health",
    command: []const []const u8 = &.{},
    args: []const []const u8 = &.{},
    environment: []const KeyValue = &.{},
};
pub const ModelArgs = struct {
    name: []const u8,
    location: []const u8,
    display_name: []const u8,
    artifact_uri: []const u8,
    container: ServingContainer,
    description: []const u8 = "",
    metadata_schema_uri: []const u8 = "",
    metadata_json: []const u8 = "{}",
    kms_key_name: ?output.Output([]const u8, .public) = null,
    labels: []const KeyValue = &.{},
    protect: bool = true,
    removal_policy: RemovalPolicy = .retain,
};

pub const Model = struct {
    pub const Outputs = CommonOutputs;
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    etag: Outputs.Etag.OutputType,
    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ModelArgs) BuildError!Model {
        try validateCommon(provider, args.name, args.location, args.display_name);
        try validateArtifact(args.artifact_uri, args.container);
        if (args.metadata_schema_uri.len != 0) try validateSchemaUri(args.metadata_schema_uri, "model");
        try validateJson(args.metadata_json, 128 * 1024);
        var container = try containerValue(allocator, args.container);
        defer container.deinit(allocator);
        var labels = try mapValue(allocator, args.labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "artifact_uri", .value = .{ .string = args.artifact_uri } },
            .{ .name = "container", .value = container },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "kms_key_name", .value = try optionalOutputValue(args.kms_key_name) },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "metadata_json", .value = .{ .string = args.metadata_json } },
            .{ .name = "metadata_schema_uri", .value = .{ .string = args.metadata_schema_uri } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
        };
        const node = try nodeOwned(allocator, "gcp.vertex.Model", args.location, args.name, null, &fields, lifecycle(args.protect, args.removal_policy));
        return commonResource(Model, node);
    }
    pub fn deinit(self: *Model, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const PrivateServiceConnect = struct { project_allowlist: []const []const u8 = &.{} };
pub const Connectivity = union(enum) {
    public,
    vpc: output.Output([]const u8, .public),
    private_service_connect: PrivateServiceConnect,
};
pub const EndpointArgs = struct {
    name: []const u8,
    location: []const u8,
    display_name: []const u8,
    description: []const u8 = "",
    connectivity: Connectivity = .public,
    dedicated_endpoint: bool = false,
    kms_key_name: ?output.Output([]const u8, .public) = null,
    labels: []const KeyValue = &.{},
    protect: bool = true,
    removal_policy: RemovalPolicy = .retain,
};

pub const Endpoint = struct {
    pub const Outputs = EndpointOutputs;
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    etag: Outputs.Etag.OutputType,
    serving_uri: Outputs.ServingUri.OutputType,
    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: EndpointArgs) BuildError!Endpoint {
        try validateCommon(provider, args.name, args.location, args.display_name);
        var connectivity = try connectivityValue(allocator, args.connectivity);
        defer connectivity.deinit(allocator);
        var labels = try mapValue(allocator, args.labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "connectivity", .value = connectivity },
            .{ .name = "dedicated_endpoint", .value = .{ .boolean = args.dedicated_endpoint } },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "kms_key_name", .value = try optionalOutputValue(args.kms_key_name) },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
        };
        const node = try nodeOwned(allocator, "gcp.vertex.Endpoint", args.location, args.name, null, &fields, lifecycle(args.protect, args.removal_policy));
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .etag = Outputs.Etag.fromResource(node.id), .serving_uri = Outputs.ServingUri.fromResource(node.id) };
    }
    pub fn deinit(self: *Endpoint, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const IndexUpdateMethod = enum { batch_update, stream_update };
pub const IndexArgs = struct {
    name: []const u8,
    location: []const u8,
    display_name: []const u8,
    metadata_schema_uri: []const u8,
    metadata_json: []const u8,
    update_method: IndexUpdateMethod = .batch_update,
    description: []const u8 = "",
    kms_key_name: ?output.Output([]const u8, .public) = null,
    labels: []const KeyValue = &.{},
    protect: bool = true,
    removal_policy: RemovalPolicy = .retain,
};
pub const Index = struct {
    pub const Outputs = CommonOutputs;
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    etag: Outputs.Etag.OutputType,
    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: IndexArgs) BuildError!Index {
        try validateCommon(provider, args.name, args.location, args.display_name);
        try validateSchemaUri(args.metadata_schema_uri, "matchingengine");
        try validateJson(args.metadata_json, 256 * 1024);
        var labels = try mapValue(allocator, args.labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "kms_key_name", .value = try optionalOutputValue(args.kms_key_name) },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "metadata_json", .value = .{ .string = args.metadata_json } },
            .{ .name = "metadata_schema_uri", .value = .{ .string = args.metadata_schema_uri } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
            .{ .name = "update_method", .value = .{ .string = indexUpdateName(args.update_method) } },
        };
        const node = try nodeOwned(allocator, "gcp.vertex.Index", args.location, args.name, null, &fields, lifecycle(args.protect, args.removal_policy));
        return commonResource(Index, node);
    }
    pub fn deinit(self: *Index, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const IndexEndpointArgs = struct {
    name: []const u8,
    location: []const u8,
    display_name: []const u8,
    description: []const u8 = "",
    connectivity: Connectivity = .public,
    kms_key_name: ?output.Output([]const u8, .public) = null,
    labels: []const KeyValue = &.{},
    protect: bool = true,
    removal_policy: RemovalPolicy = .retain,
};
pub const IndexEndpoint = struct {
    pub const Outputs = EndpointOutputs;
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    etag: Outputs.Etag.OutputType,
    serving_uri: Outputs.ServingUri.OutputType,
    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: IndexEndpointArgs) BuildError!IndexEndpoint {
        try validateCommon(provider, args.name, args.location, args.display_name);
        var connectivity = try connectivityValue(allocator, args.connectivity);
        defer connectivity.deinit(allocator);
        var labels = try mapValue(allocator, args.labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "connectivity", .value = connectivity },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "kms_key_name", .value = try optionalOutputValue(args.kms_key_name) },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
        };
        const node = try nodeOwned(allocator, "gcp.vertex.IndexEndpoint", args.location, args.name, null, &fields, lifecycle(args.protect, args.removal_policy));
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .etag = Outputs.Etag.fromResource(node.id), .serving_uri = Outputs.ServingUri.fromResource(node.id) };
    }
    pub fn deinit(self: *IndexEndpoint, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const FeatureGroupArgs = struct {
    name: []const u8,
    location: []const u8,
    bigquery_source: []const u8,
    entity_id_columns: []const []const u8,
    description: []const u8 = "",
    labels: []const KeyValue = &.{},
    protect: bool = true,
    removal_policy: RemovalPolicy = .retain,
};
pub const FeatureGroup = struct {
    pub const Outputs = ServiceAgentOutputs;
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    etag: Outputs.Etag.OutputType,
    service_account: Outputs.ServiceAccount.OutputType,
    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: FeatureGroupArgs) BuildError!FeatureGroup {
        try validateCommon(provider, args.name, args.location, "");
        if (!std.mem.startsWith(u8, args.bigquery_source, "bq://") or args.entity_id_columns.len == 0 or args.entity_id_columns.len > 10) return error.InvalidSource;
        try validateNames(args.entity_id_columns);
        var columns = try stringsValue(allocator, args.entity_id_columns);
        defer columns.deinit(allocator);
        var labels = try mapValue(allocator, args.labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "bigquery_source", .value = .{ .string = args.bigquery_source } },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "entity_id_columns", .value = columns },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
        };
        const node = try nodeOwned(allocator, "gcp.vertex.FeatureGroup", args.location, args.name, null, &fields, lifecycle(args.protect, args.removal_policy));
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .etag = Outputs.Etag.fromResource(node.id), .service_account = Outputs.ServiceAccount.fromResource(node.id) };
    }
    pub fn deinit(self: *FeatureGroup, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const FeatureArgs = struct {
    name: []const u8,
    location: []const u8,
    feature_group: output.Output([]const u8, .public),
    description: []const u8 = "",
    point_of_contact: []const u8 = "",
    labels: []const KeyValue = &.{},
    protect: bool = true,
    removal_policy: RemovalPolicy = .retain,
};
pub const Feature = struct {
    pub const Outputs = CommonOutputs;
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    etag: Outputs.Etag.OutputType,
    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: FeatureArgs) BuildError!Feature {
        try validateCommon(provider, args.name, args.location, "");
        try validateRegionalOutput(args.feature_group, args.location, "/featureGroups/");
        var labels = try mapValue(allocator, args.labels);
        defer labels.deinit(allocator);
        const group_name = targetBasename(args.feature_group);
        const logical = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ group_name, args.name });
        defer allocator.free(logical);
        const fields = [_]value.Field{
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "feature_group", .value = try outputValue(args.feature_group) },
            .{ .name = "feature_group_name", .value = .{ .string = group_name } },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "point_of_contact", .value = .{ .string = args.point_of_contact } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
        };
        const node = try nodeOwned(allocator, "gcp.vertex.Feature", args.location, logical, null, &fields, lifecycle(args.protect, args.removal_policy));
        return commonResource(Feature, node);
    }
    pub fn deinit(self: *Feature, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const BigtableStorage = struct { min_nodes: u16 = 1, max_nodes: u16 = 1 };
pub const OptimizedStorage = struct { private_service_connect: bool = false };
pub const OnlineStoreStorage = union(enum) { bigtable: BigtableStorage, optimized: OptimizedStorage };
pub const FeatureOnlineStoreArgs = struct {
    name: []const u8,
    location: []const u8,
    storage: OnlineStoreStorage,
    kms_key_name: ?output.Output([]const u8, .public) = null,
    labels: []const KeyValue = &.{},
    protect: bool = true,
    removal_policy: RemovalPolicy = .retain,
};
pub const FeatureOnlineStore = struct {
    pub const Outputs = StoreOutputs;
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    etag: Outputs.Etag.OutputType,
    serving_uri: Outputs.ServingUri.OutputType,
    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: FeatureOnlineStoreArgs) BuildError!FeatureOnlineStore {
        try validateCommon(provider, args.name, args.location, "");
        var storage = try storageValue(allocator, args.storage);
        defer storage.deinit(allocator);
        var labels = try mapValue(allocator, args.labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "kms_key_name", .value = try optionalOutputValue(args.kms_key_name) },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
            .{ .name = "storage", .value = storage },
        };
        const node = try nodeOwned(allocator, "gcp.vertex.FeatureOnlineStore", args.location, args.name, null, &fields, lifecycle(args.protect, args.removal_policy));
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .etag = Outputs.Etag.fromResource(node.id), .serving_uri = Outputs.ServingUri.fromResource(node.id) };
    }
    pub fn deinit(self: *FeatureOnlineStore, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const FeatureRegistrySource = struct {
    feature_group: output.Output([]const u8, .public),
    features: []const output.Output([]const u8, .public),
};
pub const FeatureViewSource = union(enum) { bigquery: []const u8, feature_registry: FeatureRegistrySource };
pub const FeatureViewArgs = struct {
    name: []const u8,
    location: []const u8,
    online_store: output.Output([]const u8, .public),
    source: FeatureViewSource,
    sync_interval_seconds: u32,
    labels: []const KeyValue = &.{},
    protect: bool = true,
    removal_policy: RemovalPolicy = .retain,
};
pub const FeatureView = struct {
    pub const Outputs = ServiceAgentOutputs;
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    etag: Outputs.Etag.OutputType,
    service_account: Outputs.ServiceAccount.OutputType,
    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: FeatureViewArgs) BuildError!FeatureView {
        try validateCommon(provider, args.name, args.location, "");
        try validateRegionalOutput(args.online_store, args.location, "/featureOnlineStores/");
        if (!validSyncInterval(args.sync_interval_seconds)) return error.InvalidSource;
        var source = try featureViewSourceValue(allocator, args.location, args.source);
        defer source.deinit(allocator);
        var labels = try mapValue(allocator, args.labels);
        defer labels.deinit(allocator);
        const store_name = targetBasename(args.online_store);
        const fields = [_]value.Field{
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "online_store", .value = try outputValue(args.online_store) },
            .{ .name = "online_store_name", .value = .{ .string = store_name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
            .{ .name = "source", .value = source },
            .{ .name = "sync_interval_seconds", .value = .{ .integer = args.sync_interval_seconds } },
        };
        const node = try nodeOwned(allocator, "gcp.vertex.FeatureView", args.location, args.name, store_name, &fields, lifecycle(args.protect, args.removal_policy));
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .etag = Outputs.Etag.fromResource(node.id), .service_account = Outputs.ServiceAccount.fromResource(node.id) };
    }
    pub fn deinit(self: *FeatureView, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const TensorboardArgs = struct {
    name: []const u8,
    location: []const u8,
    display_name: []const u8,
    description: []const u8 = "",
    is_default: bool = false,
    kms_key_name: ?output.Output([]const u8, .public) = null,
    labels: []const KeyValue = &.{},
    protect: bool = true,
    removal_policy: RemovalPolicy = .retain,
};
pub const Tensorboard = struct {
    pub const Outputs = CommonOutputs;
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    etag: Outputs.Etag.OutputType,
    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: TensorboardArgs) BuildError!Tensorboard {
        try validateCommon(provider, args.name, args.location, args.display_name);
        var labels = try mapValue(allocator, args.labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "is_default", .value = .{ .boolean = args.is_default } },
            .{ .name = "kms_key_name", .value = try optionalOutputValue(args.kms_key_name) },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
        };
        const node = try nodeOwned(allocator, "gcp.vertex.Tensorboard", args.location, args.name, null, &fields, lifecycle(args.protect, args.removal_policy));
        return commonResource(Tensorboard, node);
    }
    pub fn deinit(self: *Tensorboard, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const MetadataStoreArgs = struct {
    name: []const u8,
    location: []const u8,
    description: []const u8 = "",
    kms_key_name: ?output.Output([]const u8, .public) = null,
    protect: bool = true,
    removal_policy: RemovalPolicy = .retain,
};
pub const MetadataStore = struct {
    pub const Outputs = NameOutputs;
    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: MetadataStoreArgs) BuildError!MetadataStore {
        try validateCommon(provider, args.name, args.location, "");
        const fields = [_]value.Field{
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "kms_key_name", .value = try optionalOutputValue(args.kms_key_name) },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "removal_policy", .value = .{ .string = @tagName(args.removal_policy) } },
        };
        const node = try nodeOwned(allocator, "gcp.vertex.MetadataStore", args.location, args.name, null, &fields, lifecycle(args.protect, args.removal_policy));
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
    }
    pub fn deinit(self: *MetadataStore, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const DatasetIamMemberArgs = struct { location: []const u8, dataset: output.Output([]const u8, .public), role: []const u8, member: []const u8, condition: ?IamCondition = null, protect: bool = true };
pub const ModelIamMemberArgs = struct { location: []const u8, model: output.Output([]const u8, .public), role: []const u8, member: []const u8, condition: ?IamCondition = null, protect: bool = true };
pub const FeatureGroupIamMemberArgs = struct { location: []const u8, feature_group: output.Output([]const u8, .public), role: []const u8, member: []const u8, condition: ?IamCondition = null, protect: bool = true };
pub const FeatureOnlineStoreIamMemberArgs = struct { location: []const u8, online_store: output.Output([]const u8, .public), role: []const u8, member: []const u8, condition: ?IamCondition = null, protect: bool = true };
pub const FeatureViewIamMemberArgs = struct { location: []const u8, feature_view: output.Output([]const u8, .public), role: []const u8, member: []const u8, condition: ?IamCondition = null, protect: bool = true };

pub const DatasetIamMember = iamWrapper("gcp.vertex.DatasetIamMember", DatasetIamMemberArgs, "dataset", "/datasets/");
pub const ModelIamMember = iamWrapper("gcp.vertex.ModelIamMember", ModelIamMemberArgs, "model", "/models/");
pub const FeatureGroupIamMember = iamWrapper("gcp.vertex.FeatureGroupIamMember", FeatureGroupIamMemberArgs, "feature_group", "/featureGroups/");
pub const FeatureOnlineStoreIamMember = iamWrapper("gcp.vertex.FeatureOnlineStoreIamMember", FeatureOnlineStoreIamMemberArgs, "online_store", "/featureOnlineStores/");
pub const FeatureViewIamMember = iamWrapper("gcp.vertex.FeatureViewIamMember", FeatureViewIamMemberArgs, "feature_view", "/featureViews/");

const NameOutputs = struct {
    pub const Name = output.Descriptor("name", []const u8, .public);
};
const CommonOutputs = struct {
    pub const Name = output.Descriptor("name", []const u8, .public);
    pub const Etag = output.Descriptor("etag", []const u8, .public);
};
const EndpointOutputs = struct {
    pub const Name = output.Descriptor("name", []const u8, .public);
    pub const Etag = output.Descriptor("etag", []const u8, .public);
    pub const ServingUri = output.Descriptor("serving_uri", []const u8, .public);
};
const ServiceAgentOutputs = struct {
    pub const Name = output.Descriptor("name", []const u8, .public);
    pub const Etag = output.Descriptor("etag", []const u8, .public);
    pub const ServiceAccount = output.Descriptor("service_account", []const u8, .public);
};
const StoreOutputs = EndpointOutputs;

fn commonResource(comptime T: type, node: resource.ResourceNode) T {
    return .{ .node = node, .name = T.Outputs.Name.fromResource(node.id), .etag = T.Outputs.Etag.fromResource(node.id) };
}

fn iamWrapper(comptime type_name: []const u8, comptime Args: type, comptime target_field: []const u8, comptime segment: []const u8) type {
    return struct {
        node: resource.ResourceNode,
        pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: Args) BuildError!@This() {
            try provider.validate();
            try validateRegion(provider, args.location);
            const target = @field(args, target_field);
            try validateRegionalOutput(target, args.location, segment);
            if (!std.mem.startsWith(u8, args.role, "roles/") or std.mem.indexOfScalar(u8, args.role, ' ') != null) return error.InvalidRole;
            if (!validMember(args.member)) return error.InvalidIamMember;
            var condition = if (args.condition) |selected| try conditionValue(allocator, selected) else try ownedValue(allocator, .{ .object = &.{} });
            defer condition.deinit(allocator);
            const identity = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ args.role, args.member });
            defer allocator.free(identity);
            const logical = try slugAlloc(allocator, identity);
            defer allocator.free(logical);
            const fields = [_]value.Field{
                .{ .name = "condition", .value = condition },
                .{ .name = "has_condition", .value = .{ .boolean = args.condition != null } },
                .{ .name = "location", .value = .{ .string = args.location } },
                .{ .name = "member", .value = .{ .string = args.member } },
                .{ .name = "project_id", .value = .{ .string = provider.project_id } },
                .{ .name = "resource", .value = try outputValue(target) },
                .{ .name = "role", .value = .{ .string = args.role } },
            };
            return .{ .node = try nodeOwned(allocator, type_name, args.location, logical, targetBasename(target), &fields, .{ .protect = args.protect }) };
        }
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.node.deinit(allocator);
            self.* = undefined;
        }
    };
}

fn validateCommon(provider: config_mod.ProviderConfig, name: []const u8, location: []const u8, display_name: []const u8) BuildError!void {
    try provider.validate();
    try validateName(name);
    try validateRegion(provider, location);
    if (display_name.len > 128 or std.mem.indexOfAny(u8, display_name, "\r\n") != null) return error.InvalidName;
}

fn validSyncInterval(seconds: u32) bool {
    if (seconds < 60 or seconds > 604800 or seconds % 60 != 0) return false;
    const minutes = seconds / 60;
    if (minutes < 60) return 60 % minutes == 0;
    if (minutes < 1440 and minutes % 60 == 0) return 24 % (minutes / 60) == 0;
    return seconds == 86400 or seconds == 604800;
}
fn validateRegion(provider: config_mod.ProviderConfig, location: []const u8) BuildError!void {
    if (location.len == 0 or location.len > 32) return error.InvalidRegion;
    for (location) |char| if (!(std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '-')) return error.InvalidRegion;
    if (provider.service_regions.len == 0) {
        if (!std.mem.eql(u8, provider.primary_region, location)) return error.InvalidRegion;
        return;
    }
    for (provider.service_regions) |allowed| if (std.mem.eql(u8, allowed, location)) return;
    return error.InvalidRegion;
}
fn validateName(name: []const u8) BuildError!void {
    if (name.len == 0 or name.len > 63 or !std.ascii.isLower(name[0]) or !std.ascii.isAlphanumeric(name[name.len - 1])) return error.InvalidName;
    for (name) |char| if (!(std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '-' or char == '_')) return error.InvalidName;
}
fn validateNames(names: []const []const u8) BuildError!void {
    for (names, 0..) |name, index| {
        try validateName(name);
        for (names[0..index]) |prior| if (std.mem.eql(u8, prior, name)) return error.DuplicateValue;
    }
}
fn validateSchemaUri(uri: []const u8, category: []const u8) BuildError!void {
    if (!std.mem.startsWith(u8, uri, "gs://google-cloud-aiplatform/schema/") or std.mem.indexOf(u8, uri, category) == null or !std.mem.endsWith(u8, uri, ".yaml")) return error.InvalidMetadata;
}
fn validateJson(json: []const u8, max_bytes: usize) BuildError!void {
    if (json.len == 0 or json.len > max_bytes) return error.InvalidMetadata;
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, json, .{}) catch return error.InvalidMetadata;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidMetadata;
}
fn validateArtifact(artifact_uri: []const u8, container: ServingContainer) BuildError!void {
    if (!std.mem.startsWith(u8, artifact_uri, "gs://") or std.mem.indexOfAny(u8, artifact_uri, "\r\n?#") != null) return error.InvalidArtifact;
    const digest = std.mem.indexOf(u8, container.image_uri, "@sha256:") orelse return error.InvalidArtifact;
    const hash = container.image_uri[digest + 8 ..];
    if (hash.len != 64) return error.InvalidArtifact;
    for (hash) |char| if (!std.ascii.isHex(char)) return error.InvalidArtifact;
    if (container.ports.len == 0 or container.ports.len > 5) return error.InvalidArtifact;
    for (container.ports) |port| if (port == 0) return error.InvalidArtifact;
    inline for (.{ container.predict_route, container.health_route }) |route| if (!std.mem.startsWith(u8, route, "/") or std.mem.indexOfAny(u8, route, "\r\n?#") != null) return error.InvalidArtifact;
}

fn containerValue(allocator: std.mem.Allocator, container: ServingContainer) BuildError!value.Value {
    const ports = try allocator.alloc(value.Value, container.ports.len);
    defer allocator.free(ports);
    for (container.ports, 0..) |port, index| ports[index] = .{ .integer = port };
    var port_values = try ownedValue(allocator, .{ .list = ports });
    defer port_values.deinit(allocator);
    var command = try stringsValue(allocator, container.command);
    defer command.deinit(allocator);
    var args = try stringsValue(allocator, container.args);
    defer args.deinit(allocator);
    var environment = try mapValue(allocator, container.environment);
    defer environment.deinit(allocator);
    const fields = [_]value.Field{
        .{ .name = "args", .value = args },
        .{ .name = "command", .value = command },
        .{ .name = "environment", .value = environment },
        .{ .name = "health_route", .value = .{ .string = container.health_route } },
        .{ .name = "image_uri", .value = .{ .string = container.image_uri } },
        .{ .name = "ports", .value = port_values },
        .{ .name = "predict_route", .value = .{ .string = container.predict_route } },
    };
    return ownedValue(allocator, .{ .object = &fields });
}

fn connectivityValue(allocator: std.mem.Allocator, connectivity: Connectivity) BuildError!value.Value {
    return switch (connectivity) {
        .public => ownedValue(allocator, .{ .object = &.{.{ .name = "kind", .value = .{ .string = "public" } }} }),
        .vpc => |network| blk: {
            try validateOutputContains(network, "/global/networks/");
            const fields = [_]value.Field{
                .{ .name = "kind", .value = .{ .string = "vpc" } },
                .{ .name = "network", .value = try outputValue(network) },
            };
            break :blk ownedValue(allocator, .{ .object = &fields });
        },
        .private_service_connect => |psc| blk: {
            if (psc.project_allowlist.len > 100) return error.InvalidConnectivity;
            for (psc.project_allowlist) |project| for (project) |char| if (!std.ascii.isDigit(char)) return error.InvalidConnectivity;
            var projects = try stringsValue(allocator, psc.project_allowlist);
            defer projects.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "kind", .value = .{ .string = "private_service_connect" } },
                .{ .name = "project_allowlist", .value = projects },
            };
            break :blk ownedValue(allocator, .{ .object = &fields });
        },
    };
}

fn storageValue(allocator: std.mem.Allocator, storage: OnlineStoreStorage) BuildError!value.Value {
    return switch (storage) {
        .bigtable => |selected| blk: {
            if (selected.min_nodes == 0 or selected.max_nodes < selected.min_nodes or selected.max_nodes > 100) return error.InvalidStorage;
            const fields = [_]value.Field{
                .{ .name = "kind", .value = .{ .string = "bigtable" } },
                .{ .name = "max_nodes", .value = .{ .integer = selected.max_nodes } },
                .{ .name = "min_nodes", .value = .{ .integer = selected.min_nodes } },
            };
            break :blk ownedValue(allocator, .{ .object = &fields });
        },
        .optimized => |selected| blk: {
            const fields = [_]value.Field{
                .{ .name = "kind", .value = .{ .string = "optimized" } },
                .{ .name = "private_service_connect", .value = .{ .boolean = selected.private_service_connect } },
            };
            break :blk ownedValue(allocator, .{ .object = &fields });
        },
    };
}

fn featureViewSourceValue(allocator: std.mem.Allocator, location: []const u8, source: FeatureViewSource) BuildError!value.Value {
    return switch (source) {
        .bigquery => |uri| blk: {
            if (!std.mem.startsWith(u8, uri, "bq://")) return error.InvalidSource;
            const fields = [_]value.Field{
                .{ .name = "kind", .value = .{ .string = "bigquery" } },
                .{ .name = "uri", .value = .{ .string = uri } },
            };
            break :blk ownedValue(allocator, .{ .object = &fields });
        },
        .feature_registry => |registry| blk: {
            try validateRegionalOutput(registry.feature_group, location, "/featureGroups/");
            if (registry.features.len == 0 or registry.features.len > 100) return error.InvalidSource;
            const features = try allocator.alloc(value.Value, registry.features.len);
            defer allocator.free(features);
            for (registry.features, 0..) |feature, index| {
                try validateRegionalOutput(feature, location, "/features/");
                features[index] = try outputValue(feature);
            }
            var feature_values = try ownedValue(allocator, .{ .list = features });
            defer feature_values.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "feature_group", .value = try outputValue(registry.feature_group) },
                .{ .name = "features", .value = feature_values },
                .{ .name = "kind", .value = .{ .string = "feature_registry" } },
            };
            break :blk ownedValue(allocator, .{ .object = &fields });
        },
    };
}

fn indexUpdateName(method: IndexUpdateMethod) []const u8 {
    return switch (method) {
        .batch_update => "BATCH_UPDATE",
        .stream_update => "STREAM_UPDATE",
    };
}
fn mapValue(allocator: std.mem.Allocator, items: []const KeyValue) BuildError!value.Value {
    if (items.len > 64) return error.InvalidName;
    const fields = try allocator.alloc(value.Field, items.len);
    defer allocator.free(fields);
    for (items, 0..) |item, index| {
        if (item.key.len == 0 or item.key.len > 64 or item.value.len > 64) return error.InvalidName;
        for (items[0..index]) |prior| if (std.mem.eql(u8, prior.key, item.key)) return error.DuplicateKey;
        fields[index] = .{ .name = item.key, .value = .{ .string = item.value } };
    }
    std.mem.sort(value.Field, fields, {}, lessField);
    return ownedValue(allocator, .{ .object = fields });
}
fn stringsValue(allocator: std.mem.Allocator, items: []const []const u8) BuildError!value.Value {
    const values = try allocator.alloc(value.Value, items.len);
    defer allocator.free(values);
    for (items, 0..) |item, index| values[index] = .{ .string = item };
    return ownedValue(allocator, .{ .list = values });
}
fn conditionValue(allocator: std.mem.Allocator, condition: IamCondition) BuildError!value.Value {
    if (condition.title.len == 0 or condition.expression.len == 0 or std.mem.indexOfAny(u8, condition.expression, "\r\n") != null) return error.InvalidIamMember;
    const fields = [_]value.Field{
        .{ .name = "description", .value = .{ .string = condition.description } },
        .{ .name = "expression", .value = .{ .string = condition.expression } },
        .{ .name = "title", .value = .{ .string = condition.title } },
    };
    return ownedValue(allocator, .{ .object = &fields });
}
fn validMember(member: []const u8) bool {
    inline for (.{ "user:", "group:", "serviceAccount:", "domain:" }) |prefix| if (std.mem.startsWith(u8, member, prefix) and member.len > prefix.len) return true;
    return std.mem.eql(u8, member, "allUsers") or std.mem.eql(u8, member, "allAuthenticatedUsers");
}
fn validateOutputContains(selected: output.Output([]const u8, .public), segment: []const u8) BuildError!void {
    switch (selected) {
        .value => |text| if (std.mem.indexOf(u8, text, segment) == null) return error.InvalidConnectivity,
        .resource_ref => {},
        .unknown_reason => return error.InvalidOutput,
    }
}
fn validateRegionalOutput(selected: output.Output([]const u8, .public), location: []const u8, segment: []const u8) BuildError!void {
    switch (selected) {
        .value => |text| {
            if (std.mem.indexOf(u8, text, segment) == null) return error.InvalidOutput;
            const marker = try std.fmt.allocPrint(std.heap.page_allocator, "/locations/{s}/", .{location});
            defer std.heap.page_allocator.free(marker);
            if (std.mem.indexOf(u8, text, marker) == null) return error.InvalidRegion;
        },
        .resource_ref => {},
        .unknown_reason => return error.InvalidOutput,
    }
}
fn outputValue(selected: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (selected) {
        .value => |text| .{ .string = text },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.InvalidOutput,
    };
}
fn optionalOutputValue(selected: ?output.Output([]const u8, .public)) BuildError!value.Value {
    return if (selected) |known| outputValue(known) else .{ .string = "" };
}
fn targetBasename(target: output.Output([]const u8, .public)) []const u8 {
    const source = switch (target) {
        .value => |text| text,
        .resource_ref => |reference| reference.resource_id,
        .unknown_reason => return "unknown",
    };
    const slash = std.mem.lastIndexOfScalar(u8, source, '/');
    const dot = std.mem.lastIndexOfScalar(u8, source, '.');
    const index = @max(if (slash) |position| position + 1 else 0, if (dot) |position| position + 1 else 0);
    return source[index..];
}
fn slugAlloc(allocator: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error![]u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    var separator = false;
    for (source) |char| {
        if (std.ascii.isAlphanumeric(char)) {
            if (separator and result.items.len != 0) try result.append(allocator, '-');
            try result.append(allocator, std.ascii.toLower(char));
            separator = false;
        } else separator = true;
    }
    return result.toOwnedSlice(allocator);
}
fn lifecycle(protect: bool, removal_policy: RemovalPolicy) resource.Lifecycle {
    return .{ .protect = protect, .retain_on_delete = removal_policy == .retain };
}
fn lessField(_: void, left: value.Field, right: value.Field) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}
fn ownedValue(allocator: std.mem.Allocator, selected: value.Value) BuildError!value.Value {
    return value.Value.initOwned(allocator, selected) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
    };
}
fn nodeOwned(allocator: std.mem.Allocator, type_name: []const u8, scope: []const u8, logical: []const u8, parent: ?[]const u8, fields: []const value.Field, resource_lifecycle: resource.Lifecycle) BuildError!resource.ResourceNode {
    const id = if (parent) |selected|
        try std.fmt.allocPrint(allocator, "{s}.{s}.{s}.{s}", .{ type_name, scope, selected, logical })
    else
        try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ type_name, scope, logical });
    defer allocator.free(id);
    return resource.ResourceNode.initOwned(allocator, .{ .id = id, .provider = .gcp, .type_name = type_name, .schema_version = 1, .logical_id = logical, .inputs = .{ .object = fields }, .lifecycle = resource_lifecycle }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
        else => unreachable,
    };
}
