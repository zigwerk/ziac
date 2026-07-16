const std = @import("std");
const artifact_registry = @import("../artifact_registry.zig");
const binding_mod = @import("../../binding.zig");
const cloud_build = @import("../cloud_build.zig");
const cloud_run = @import("../cloud_run.zig");
const config_mod = @import("../config.zig");
const container_service = @import("container_service.zig");
const iam = @import("../iam.zig");
const output = @import("../../output.zig");
const project_service = @import("../project_service.zig");
const provider_mod = @import("../../provider.zig");
const resource = @import("../../resource.zig");
const secret_manager = @import("../secret_manager.zig");
const source_archive = @import("../../build/source_archive.zig");
const stack = @import("../../stack.zig");
const storage = @import("../storage.zig");
const storage_provider = @import("../storage_provider.zig");
const value = @import("../../value.zig");
const zig_recipe = @import("../../build/zig_recipe.zig");

pub const Source = struct {
    io: std.Io,
    root: std.Io.Dir,
    options: source_archive.Options = .{},
};

pub fn ZigService(
    comptime DeploymentContract: type,
    comptime Bindings: type,
    comptime Providers: type,
) type {
    comptime {
        Providers.require(.gcp);
        _ = binding_mod.validateBindings(DeploymentContract, Bindings, .global);
        validateBindingTypes(Bindings);
    }

    return struct {
        const Self = @This();

        pub const Args = struct {
            base_graph: ?*const resource.ResourceGraph = null,
            source: Source,
            name: []const u8,
            artifact_name: []const u8,
            regions: []const []const u8 = &.{},
            domain: []const u8,
            dns_zone: ?[]const u8 = null,
            dns_ttl: u32 = 300,
            bindings: Bindings,
            manage_apis: bool = true,
            repository_name: ?[]const u8 = null,
            bucket_lifecycle_age_days: u32 = 30,
            cloud_builder: []const u8 = zig_recipe.default_cloud_builder,
            recipe: ?zig_recipe.Config = null,
            health_mode: container_service.HealthMode = .standard,
            port: u16 = 8080,
            cpu: []const u8 = "1",
            memory: []const u8 = "512Mi",
            concurrency: u16 = 80,
            timeout_seconds: u32 = 300,
            min_instances: u32 = 0,
            max_instances: u32 = 100,
            startup_probe: ?cloud_run.HttpProbe = null,
            liveness_probe: ?cloud_run.HttpProbe = null,
            readiness_probe: ?cloud_run.HttpProbe = null,
            direct_vpc: ?cloud_run.DirectVpc = null,
            regional_direct_vpc: []const container_service.RegionalDirectVpc = &.{},
            realization: container_service.Realization = .automatic,
            http_redirect: bool = true,
            redirect_strip_query: bool = false,
        };

        allocator: std.mem.Allocator,
        graph: resource.ResourceGraph,
        archive_source: ArchiveSource,
        url: output.Output([]const u8, .public),
        image_ref: cloud_build.ZigImage.Outputs.ImageRef.OutputType,
        image_digest: cloud_build.ZigImage.Outputs.ImageDigest.OutputType,
        build_id: cloud_build.ZigImage.Outputs.BuildId.OutputType,
        repository_url: artifact_registry.DockerRepository.Outputs.RepositoryUrl.OutputType,
        runtime_service_account: iam.ServiceAccount.Outputs.Email.OutputType,
        ip_address: @import("../compute.zig").GlobalAddress.Outputs.Address.OutputType,
        certificate_status: @import("../compute.zig").ManagedSslCertificate.Outputs.Status.OutputType,
        realization: container_service.Realization,
        realization_reason: []const u8,
        source_digest: [64]u8,
        build_digest: [64]u8,
        source_path: []const u8,
        owned_url: []const u8,
        image_resource_id: []const u8,
        repository_resource_id: []const u8,
        runtime_account_resource_id: []const u8,
        address_resource_id: []const u8,
        certificate_resource_id: []const u8,

        pub fn build(
            allocator: std.mem.Allocator,
            provider: config_mod.ProviderConfig,
            args: Args,
        ) !Self {
            try provider.validate();
            try validateName(args.name);
            if (args.source.options.generated_files.len != 0) return error.GeneratedFilesReserved;
            const recipe_config = args.recipe orelse zig_recipe.Config{
                .artifact_name = args.artifact_name,
                .port = args.port,
            };
            if (!std.mem.eql(u8, recipe_config.artifact_name, args.artifact_name) or recipe_config.port != args.port) {
                return error.RecipeContractMismatch;
            }
            const recipe_bytes = try zig_recipe.dockerfileAlloc(allocator, recipe_config);
            defer allocator.free(recipe_bytes);
            const generated = [_]source_archive.GeneratedFile{.{
                .path = "Dockerfile.ziac",
                .contents = recipe_bytes,
            }};
            var archive_options = args.source.options;
            archive_options.generated_files = &generated;
            var archive = try source_archive.createAlloc(
                allocator,
                args.source.io,
                args.source.root,
                archive_options,
            );
            defer archive.deinit();
            const integrity = storage.integrity(archive.bytes);
            if (!std.mem.eql(u8, &archive.digest, &integrity.sha256)) return error.ArchiveDigestMismatch;
            const build_digest = try zig_recipe.buildDigest(&integrity.sha256, recipe_bytes, args.cloud_builder);
            const source_path = try std.fmt.allocPrint(
                allocator,
                ".ziac/build/{s}-{s}.tar.gz",
                .{ args.name, integrity.sha256 },
            );
            defer allocator.free(source_path);
            var archive_source = try ArchiveSource.initOwned(allocator, args.source, source_path, recipe_bytes);
            errdefer archive_source.deinit();

            var graph = resource.ResourceGraph.init(allocator);
            defer graph.deinit();
            if (args.base_graph) |base| try graph.appendGraph(base);
            const component_start = graph.resources.items.len;
            const api_start = component_start;
            if (args.manage_apis) try addRequiredApis(allocator, &graph, provider, args.dns_zone != null);
            const api_end = graph.resources.items.len;

            const build_account_id = try accountIdAlloc(allocator, args.name, "build");
            defer allocator.free(build_account_id);
            const runtime_account_id = try accountIdAlloc(allocator, args.name, "runtime");
            defer allocator.free(runtime_account_id);
            const build_email = try serviceAccountEmailAlloc(allocator, build_account_id, provider.project_id);
            defer allocator.free(build_email);
            const runtime_email = try serviceAccountEmailAlloc(allocator, runtime_account_id, provider.project_id);
            defer allocator.free(runtime_email);
            const build_member = try std.fmt.allocPrint(allocator, "serviceAccount:{s}", .{build_email});
            defer allocator.free(build_member);

            var build_account = try iam.ServiceAccount.build(allocator, provider, .{
                .account_id = build_account_id,
                .display_name = "Ziac Cloud Build",
                .description = "Builds immutable Zig service images",
            });
            defer build_account.deinit(allocator);
            try graph.addResource(build_account.node);
            var runtime_account = try iam.ServiceAccount.build(allocator, provider, .{
                .account_id = runtime_account_id,
                .display_name = "Ziac Cloud Run",
                .description = "Runs the global Zig service",
            });
            defer runtime_account.deinit(allocator);
            try graph.addResource(runtime_account.node);

            const build_roles = [_][]const u8{
                "roles/artifactregistry.writer",
                "roles/storage.objectViewer",
                "roles/logging.logWriter",
            };
            var build_role_ids: [build_roles.len][]const u8 = undefined;
            var initialized_role_ids: usize = 0;
            defer for (build_role_ids[0..initialized_role_ids]) |id| allocator.free(id);
            for (build_roles, 0..) |role, index| {
                const role_name = try roleBindingNameAlloc(allocator, args.name, role);
                defer allocator.free(role_name);
                var member = try iam.ProjectMember.build(allocator, provider, .{
                    .name = role_name,
                    .role = role,
                    .member = build_member,
                });
                defer member.deinit(allocator);
                try graph.addResource(member.node);
                try graph.addDependency(member.node.id, build_account.node.id);
                build_role_ids[index] = try allocator.dupe(u8, member.node.id);
                initialized_role_ids += 1;
            }

            const repository_name = args.repository_name orelse args.name;
            var repository = try artifact_registry.DockerRepository.build(allocator, provider, .{
                .name = repository_name,
                .location = provider.primary_region,
            });
            defer repository.deinit(allocator);
            repository.node.lifecycle.retain_on_delete = true;
            try graph.addResource(repository.node);

            const bucket_name = try bucketNameAlloc(allocator, provider.project_id, args.name);
            defer allocator.free(bucket_name);
            var bucket = try storage.BuildBucket.build(allocator, provider, .{
                .name = bucket_name,
                .location = provider.primary_region,
                .lifecycle_age_days = args.bucket_lifecycle_age_days,
            });
            defer bucket.deinit(allocator);
            try graph.addResource(bucket.node);

            const object_name = try std.fmt.allocPrint(
                allocator,
                "sources/{s}/{s}.tar.gz",
                .{ args.name, integrity.sha256 },
            );
            defer allocator.free(object_name);
            var source_object = try storage.SourceObject.build(allocator, provider, .{
                .name = args.name,
                .bucket = bucket.name,
                .object_name = object_name,
                .source_path = source_path,
                .source_digest = &integrity.sha256,
                .size = integrity.size,
                .crc32c = &integrity.crc32c,
            });
            defer source_object.deinit(allocator);
            try graph.addResource(source_object.node);

            const build_service_account = try std.fmt.allocPrint(
                allocator,
                "projects/{s}/serviceAccounts/{s}",
                .{ provider.project_id, build_email },
            );
            defer allocator.free(build_service_account);
            var image = try cloud_build.ZigImage.build(allocator, provider, .{
                .name = args.name,
                .location = provider.primary_region,
                .source_bucket = source_object.bucket,
                .source_object = source_object.object_name,
                .source_generation = source_object.generation,
                .source_digest = &integrity.sha256,
                .build_digest = &build_digest,
                .repository = repository.repository_url,
                .image_name = args.name,
                .docker_builder = args.cloud_builder,
                .service_account = build_service_account,
            });
            defer image.deinit(allocator);
            try graph.addResource(image.node);
            try graph.addDependency(image.node.id, build_account.node.id);
            for (build_role_ids) |role_id| try graph.addDependency(image.node.id, role_id);

            var env = try lowerBindingsAlloc(Bindings, allocator, args.bindings);
            defer env.deinit();
            var secret_access_ids = std.ArrayList([]const u8).empty;
            defer {
                for (secret_access_ids.items) |id| allocator.free(id);
                secret_access_ids.deinit(allocator);
            }
            try addSecretAccessBindings(
                allocator,
                &graph,
                provider,
                args.name,
                runtime_email,
                env.values,
                &secret_access_ids,
            );

            var routed = try container_service.ContainerService.build(allocator, provider, .{
                .base_graph = &graph,
                .name = args.name,
                .image_output = image.image_ref,
                .regions = args.regions,
                .domain = args.domain,
                .dns_zone = args.dns_zone,
                .dns_ttl = args.dns_ttl,
                .http_redirect = args.http_redirect,
                .redirect_strip_query = args.redirect_strip_query,
                .health_mode = args.health_mode,
                .port = args.port,
                .cpu = args.cpu,
                .memory = args.memory,
                .concurrency = args.concurrency,
                .timeout_seconds = args.timeout_seconds,
                .min_instances = args.min_instances,
                .max_instances = args.max_instances,
                .startup_probe = args.startup_probe orelse .{ .path = "/health/startup" },
                .liveness_probe = args.liveness_probe orelse .{ .path = "/health/live" },
                .readiness_probe = args.readiness_probe,
                .service_account = runtime_email,
                .env = env.values,
                .direct_vpc = args.direct_vpc,
                .regional_direct_vpc = args.regional_direct_vpc,
                .realization = args.realization,
            });
            defer routed.deinit();
            var final_graph = routed.takeGraph();
            errdefer final_graph.deinit();
            if (args.manage_apis) try addApiDependencies(&final_graph, component_start, api_start, api_end);
            for (final_graph.resources.items[component_start..]) |node| {
                if (!std.mem.eql(u8, node.type_name, "gcp.run.Service")) continue;
                try final_graph.addDependency(node.id, runtime_account.node.id);
                for (secret_access_ids.items) |binding_id| try final_graph.addDependency(node.id, binding_id);
            }
            try final_graph.validateAcyclic();

            const owned_url = try allocator.dupe(u8, routed.url.value);
            errdefer allocator.free(owned_url);
            const image_resource_id = try allocator.dupe(u8, image.node.id);
            errdefer allocator.free(image_resource_id);
            const repository_resource_id = try allocator.dupe(u8, repository.node.id);
            errdefer allocator.free(repository_resource_id);
            const runtime_account_resource_id = try allocator.dupe(u8, runtime_account.node.id);
            errdefer allocator.free(runtime_account_resource_id);
            const address_resource_id = try allocator.dupe(u8, routed.ip_address.resource_ref.resource_id);
            errdefer allocator.free(address_resource_id);
            const certificate_resource_id = try allocator.dupe(u8, routed.certificate_status.resource_ref.resource_id);
            errdefer allocator.free(certificate_resource_id);
            return .{
                .allocator = allocator,
                .graph = final_graph,
                .archive_source = archive_source,
                .url = .{ .value = owned_url },
                .image_ref = cloud_build.ZigImage.Outputs.ImageRef.fromResource(image_resource_id),
                .image_digest = cloud_build.ZigImage.Outputs.ImageDigest.fromResource(image_resource_id),
                .build_id = cloud_build.ZigImage.Outputs.BuildId.fromResource(image_resource_id),
                .repository_url = artifact_registry.DockerRepository.Outputs.RepositoryUrl.fromResource(repository_resource_id),
                .runtime_service_account = iam.ServiceAccount.Outputs.Email.fromResource(runtime_account_resource_id),
                .ip_address = @import("../compute.zig").GlobalAddress.Outputs.Address.fromResource(address_resource_id),
                .certificate_status = @import("../compute.zig").ManagedSslCertificate.Outputs.Status.fromResource(certificate_resource_id),
                .realization = routed.realization,
                .realization_reason = routed.realization_reason,
                .source_digest = integrity.sha256,
                .build_digest = build_digest,
                .source_path = archive_source.source_path,
                .owned_url = owned_url,
                .image_resource_id = image_resource_id,
                .repository_resource_id = repository_resource_id,
                .runtime_account_resource_id = runtime_account_resource_id,
                .address_resource_id = address_resource_id,
                .certificate_resource_id = certificate_resource_id,
            };
        }

        pub fn deinit(self: *Self) void {
            self.graph.deinit();
            self.archive_source.deinit();
            self.allocator.free(self.owned_url);
            self.allocator.free(self.image_resource_id);
            self.allocator.free(self.repository_resource_id);
            self.allocator.free(self.runtime_account_resource_id);
            self.allocator.free(self.address_resource_id);
            self.allocator.free(self.certificate_resource_id);
            self.* = undefined;
        }

        pub fn payloadSource(self: *Self) storage_provider.PayloadSource {
            return self.archive_source.payloadSource();
        }

        pub fn dockerfile(self: *const Self) []const u8 {
            return self.archive_source.dockerfile;
        }

        pub fn takeGraph(self: *Self) resource.ResourceGraph {
            const graph = self.graph;
            self.graph = resource.ResourceGraph.init(self.allocator);
            return graph;
        }
    };
}

const ArchiveSource = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    options: source_archive.Options,
    owned_ignore_file_name: ?[]const u8,
    source_path: []const u8,
    dockerfile: []const u8,

    fn initOwned(
        allocator: std.mem.Allocator,
        source: Source,
        source_path: []const u8,
        dockerfile: []const u8,
    ) !ArchiveSource {
        const ignore_name = if (source.options.ignore_file_name) |name| try allocator.dupe(u8, name) else null;
        errdefer if (ignore_name) |name| allocator.free(name);
        const owned_path = try allocator.dupe(u8, source_path);
        errdefer allocator.free(owned_path);
        const owned_dockerfile = try allocator.dupe(u8, dockerfile);
        var options = source.options;
        options.ignore_file_name = ignore_name;
        options.generated_files = &.{};
        return .{
            .allocator = allocator,
            .io = source.io,
            .root = source.root,
            .options = options,
            .owned_ignore_file_name = ignore_name,
            .source_path = owned_path,
            .dockerfile = owned_dockerfile,
        };
    }

    fn deinit(self: *ArchiveSource) void {
        if (self.owned_ignore_file_name) |name| self.allocator.free(name);
        self.allocator.free(self.source_path);
        self.allocator.free(self.dockerfile);
        self.* = undefined;
    }

    fn payloadSource(self: *ArchiveSource) storage_provider.PayloadSource {
        return .{ .ptr = self, .resolveFn = resolve };
    }

    fn resolve(
        raw: *anyopaque,
        context: *provider_mod.OperationContext,
        allocator: std.mem.Allocator,
        requested_path: []const u8,
    ) provider_mod.ProviderError!storage_provider.Payload {
        const self: *ArchiveSource = @ptrCast(@alignCast(raw));
        try context.checkActive();
        if (!std.mem.eql(u8, requested_path, self.source_path)) return error.NotFound;
        const generated = [_]source_archive.GeneratedFile{.{
            .path = "Dockerfile.ziac",
            .contents = self.dockerfile,
        }};
        var options = self.options;
        options.generated_files = &generated;
        var archive = source_archive.createAlloc(allocator, self.io, self.root, options) catch |err| return mapArchiveError(err);
        defer archive.deinit();
        return storage_provider.Payload.initTake(allocator, archive.takeBytes(), null);
    }
};

const OwnedEnv = struct {
    allocator: std.mem.Allocator,
    values: []cloud_run.EnvVar,
    names: [][]const u8,

    fn deinit(self: *OwnedEnv) void {
        for (self.names) |name| self.allocator.free(name);
        self.allocator.free(self.names);
        self.allocator.free(self.values);
        self.* = undefined;
    }
};

fn lowerBindingsAlloc(comptime Bindings: type, allocator: std.mem.Allocator, bindings: Bindings) !OwnedEnv {
    const fields = @typeInfo(Bindings).@"struct".fields;
    const values = try allocator.alloc(cloud_run.EnvVar, fields.len);
    errdefer allocator.free(values);
    const names = try allocator.alloc([]const u8, fields.len);
    errdefer allocator.free(names);
    var initialized: usize = 0;
    errdefer for (names[0..initialized]) |name| allocator.free(name);
    inline for (fields, 0..) |field, index| {
        names[index] = try envNameAlloc(allocator, field.name);
        initialized += 1;
        const selected = @field(bindings, field.name);
        if (field.type.secrecy == .public) {
            values[index] = .{ .name = names[index] };
            switch (selected) {
                .value => |known| values[index].value = known,
                .resource_ref => |reference| values[index].value_output = .{ .resource_ref = reference },
                .unknown_reason => return error.OutputNotKnown,
            }
        } else {
            values[index] = .{ .name = names[index], .secret = true };
            switch (selected) {
                .value => |known| {
                    if (field.type.ValueType == value.SecretReference) {
                        values[index].secret_output = .{ .value = known };
                    } else {
                        return error.InlineSecretBinding;
                    }
                },
                .resource_ref => |reference| values[index].secret_output = .{ .resource_ref = reference },
                .unknown_reason => return error.OutputNotKnown,
            }
        }
    }
    return .{ .allocator = allocator, .values = values, .names = names };
}

fn addRequiredApis(
    allocator: std.mem.Allocator,
    graph: *resource.ResourceGraph,
    provider: config_mod.ProviderConfig,
    include_dns: bool,
) !void {
    const required = [_][]const u8{
        "artifactregistry.googleapis.com",
        "cloudbuild.googleapis.com",
        "cloudresourcemanager.googleapis.com",
        "compute.googleapis.com",
        "iam.googleapis.com",
        "logging.googleapis.com",
        "run.googleapis.com",
        "secretmanager.googleapis.com",
        "storage.googleapis.com",
    };
    for (required) |service_name| try addRequiredApi(allocator, graph, provider, service_name);
    if (include_dns) try addRequiredApi(allocator, graph, provider, "dns.googleapis.com");
}

fn addRequiredApi(
    allocator: std.mem.Allocator,
    graph: *resource.ResourceGraph,
    provider: config_mod.ProviderConfig,
    service_name: []const u8,
) !void {
    var service = try project_service.Service.build(allocator, provider, .{ .service = service_name });
    defer service.deinit(allocator);
    for (graph.resources.items) |*existing| {
        if (!std.mem.eql(u8, existing.id, service.node.id)) continue;
        if (existing.provider != service.node.provider or
            existing.schema_version != service.node.schema_version or
            !std.mem.eql(u8, existing.type_name, service.node.type_name) or
            !std.mem.eql(u8, &existing.inputs_hash, &service.node.inputs_hash))
        {
            return error.DuplicateResource;
        }
        existing.lifecycle.retain_on_delete = true;
        return;
    }
    service.node.lifecycle.retain_on_delete = true;
    try graph.addResource(service.node);
}

fn addApiDependencies(
    graph: *resource.ResourceGraph,
    component_start: usize,
    api_start: usize,
    api_end: usize,
) !void {
    for (graph.resources.items[component_start..]) |node| {
        if (std.mem.eql(u8, node.type_name, "gcp.project.Service")) continue;
        for (graph.resources.items[api_start..api_end]) |api| try graph.addDependency(node.id, api.id);
    }
}

fn addSecretAccessBindings(
    allocator: std.mem.Allocator,
    graph: *resource.ResourceGraph,
    provider: config_mod.ProviderConfig,
    service_name: []const u8,
    runtime_email: []const u8,
    env: []const cloud_run.EnvVar,
    binding_ids: *std.ArrayList([]const u8),
) !void {
    const member = try std.fmt.allocPrint(allocator, "serviceAccount:{s}", .{runtime_email});
    defer allocator.free(member);
    for (env) |entry| {
        if (!entry.secret) continue;
        const secret_id = try secretIdForEnv(graph, provider, entry);
        var duplicate = false;
        for (binding_ids.items) |binding_id| {
            const existing = findNode(graph, binding_id) orelse continue;
            if (std.mem.eql(u8, inputString(existing.inputs, "secret_id") orelse "", secret_id)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        const binding_name = try std.fmt.allocPrint(allocator, "{s}-{s}-access", .{ service_name, secret_id });
        defer allocator.free(binding_name);
        var access = try secret_manager.SecretIamMember.build(allocator, provider, .{
            .name = binding_name,
            .secret_id = secret_id,
            .role = "roles/secretmanager.secretAccessor",
            .member = member,
        });
        defer access.deinit(allocator);
        try graph.addResource(access.node);
        const metadata_id = try std.fmt.allocPrint(allocator, "gcp.secret.Secret.{s}", .{secret_id});
        defer allocator.free(metadata_id);
        if (findNode(graph, metadata_id) != null) try graph.addDependency(access.node.id, metadata_id);
        const owned_id = try allocator.dupe(u8, access.node.id);
        errdefer allocator.free(owned_id);
        try binding_ids.append(allocator, owned_id);
    }
}

fn secretIdForEnv(
    graph: *const resource.ResourceGraph,
    provider: config_mod.ProviderConfig,
    entry: cloud_run.EnvVar,
) ![]const u8 {
    const selected = entry.secret_output orelse return entry.secret_name orelse entry.name;
    return switch (selected) {
        .value => |reference| blk: {
            if (!std.mem.eql(u8, reference.provider, "gcp-secret-manager") or reference.field != null) {
                return error.InvalidSecretBinding;
            }
            break :blk secretIdFromResource(reference.resource, provider.project_id) orelse return error.InvalidSecretBinding;
        },
        .resource_ref => |reference| blk: {
            const producer = findNode(graph, reference.resource_id) orelse return error.InvalidSecretBinding;
            if (producer.provider != .gcp or !std.mem.eql(u8, producer.type_name, "gcp.secret.SecretVersion")) {
                return error.InvalidSecretBinding;
            }
            break :blk inputString(producer.inputs, "secret_id") orelse return error.InvalidSecretBinding;
        },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn secretIdFromResource(resource_name: []const u8, project_id: []const u8) ?[]const u8 {
    if (resource_name.len == 0) return null;
    if (std.mem.indexOfScalar(u8, resource_name, '/') == null) return resource_name;
    var parts = std.mem.splitScalar(u8, resource_name, '/');
    if (!std.mem.eql(u8, parts.next() orelse return null, "projects")) return null;
    if (!std.mem.eql(u8, parts.next() orelse return null, project_id)) return null;
    if (!std.mem.eql(u8, parts.next() orelse return null, "secrets")) return null;
    const secret_id = parts.next() orelse return null;
    if (secret_id.len == 0) return null;
    if (parts.next()) |kind| {
        if (!std.mem.eql(u8, kind, "versions")) return null;
        const version = parts.next() orelse return null;
        if (version.len == 0 or parts.next() != null) return null;
    }
    return secret_id;
}

fn findNode(graph: *const resource.ResourceGraph, id: []const u8) ?resource.ResourceNode {
    for (graph.resources.items) |node| if (std.mem.eql(u8, node.id, id)) return node;
    return null;
}

fn inputString(input: value.Value, name: []const u8) ?[]const u8 {
    const fields = switch (input) {
        .object => |fields| fields,
        else => return null,
    };
    for (fields) |field| {
        if (!std.mem.eql(u8, field.name, name)) continue;
        return switch (field.value) {
            .string => |string| string,
            else => null,
        };
    }
    return null;
}

fn validateBindingTypes(comptime Bindings: type) void {
    const info = switch (@typeInfo(Bindings)) {
        .@"struct" => |present| present,
        else => @compileError("ZIAC102 bindings must be a struct"),
    };
    inline for (info.fields) |field| {
        if (field.type.secrecy == .public and field.type.ValueType != []const u8) {
            @compileError("ZIAC106 ZigService public binding must be a string: " ++ field.name);
        }
        if (field.type.secrecy == .secret and
            field.type.ValueType != []const u8 and
            field.type.ValueType != value.SecretReference)
        {
            @compileError("ZIAC106 ZigService secret binding must be a string or SecretReference: " ++ field.name);
        }
    }
}

fn envNameAlloc(allocator: std.mem.Allocator, field_name: []const u8) ![]const u8 {
    if (field_name.len == 0 or !std.ascii.isAlphabetic(field_name[0])) return error.InvalidEnvName;
    const name = try allocator.alloc(u8, field_name.len);
    errdefer allocator.free(name);
    for (field_name, 0..) |character, index| {
        if (!std.ascii.isAlphanumeric(character) and character != '_') return error.InvalidEnvName;
        name[index] = std.ascii.toUpper(character);
    }
    return name;
}

fn validateName(name: []const u8) !void {
    if (name.len == 0 or name.len > 63 or !std.ascii.isLower(name[0])) return error.InvalidName;
    for (name) |character| {
        if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return error.InvalidName;
    }
}

fn accountIdAlloc(allocator: std.mem.Allocator, name: []const u8, suffix: []const u8) ![]const u8 {
    const candidate = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ name, suffix });
    if (candidate.len <= 30) return candidate;
    defer allocator.free(candidate);
    const digest = shortDigest(name, suffix);
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ name[0..17], digest[0..12] });
}

fn bucketNameAlloc(allocator: std.mem.Allocator, project_id: []const u8, name: []const u8) ![]const u8 {
    const digest = shortDigest(project_id, name);
    return std.fmt.allocPrint(allocator, "ziac-{s}-{s}-{s}", .{
        project_id[0..@min(project_id.len, 18)],
        name[0..@min(name.len, 18)],
        digest[0..16],
    });
}

fn shortDigest(left: []const u8, right: []const u8) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(left);
    hasher.update("\x00");
    hasher.update(right);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn serviceAccountEmailAlloc(allocator: std.mem.Allocator, account_id: []const u8, project_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}@{s}.iam.gserviceaccount.com", .{ account_id, project_id });
}

fn roleBindingNameAlloc(allocator: std.mem.Allocator, name: []const u8, role: []const u8) ![]const u8 {
    const role_name = if (std.mem.startsWith(u8, role, "roles/")) role["roles/".len..] else role;
    const normalized = try allocator.dupe(u8, role_name);
    defer allocator.free(normalized);
    std.mem.replaceScalar(u8, normalized, '.', '-');
    return std.fmt.allocPrint(allocator, "{s}-build-{s}", .{ name, normalized });
}

fn mapArchiveError(err: anyerror) provider_mod.ProviderError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Canceled => error.ProviderCancelled,
        error.FileNotFound, error.NotDir => error.NotFound,
        else => error.InvalidConfiguration,
    };
}

comptime {
    _ = stack.ProviderSet;
}
