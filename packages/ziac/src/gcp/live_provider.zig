const std = @import("std");
const client_mod = @import("client.zig");
const compute_provider = @import("compute_provider.zig");
const dns_provider = @import("dns_provider.zig");
const operation = @import("operation.zig");
const run_provider = @import("run_provider.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;

const project_service_type = "gcp.project.Service";
const service_account_type = "gcp.iam.ServiceAccount";
const project_member_type = "gcp.iam.ProjectMember";
const artifact_repository_type = "gcp.artifact.Repository";
const secret_type = "gcp.secret.Secret";
const secret_version_type = "gcp.secret.SecretVersion";
const secret_iam_member_type = "gcp.secret.SecretIamMember";
const cloud_run_service_type = "gcp.run.Service";

pub const PayloadDeinitObserver = struct {
    ptr: *anyopaque,
    deinitFn: *const fn (*anyopaque) void,
};

pub const SecretPayload = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    observer: ?PayloadDeinitObserver = null,

    pub fn initOwned(
        allocator: std.mem.Allocator,
        bytes: []const u8,
        observer: ?PayloadDeinitObserver,
    ) ProviderError!SecretPayload {
        return .{
            .allocator = allocator,
            .bytes = allocator.dupe(u8, bytes) catch return error.OutOfMemory,
            .observer = observer,
        };
    }

    pub fn deinit(self: *SecretPayload) void {
        std.crypto.secureZero(u8, self.bytes);
        self.allocator.free(self.bytes);
        if (self.observer) |observer| observer.deinitFn(observer.ptr);
        self.* = undefined;
    }
};

pub const SecretSource = struct {
    ptr: *anyopaque,
    resolveFn: *const fn (*anyopaque, std.mem.Allocator, value.SecretReference) ProviderError!SecretPayload,

    pub fn resolve(
        self: SecretSource,
        allocator: std.mem.Allocator,
        reference: value.SecretReference,
    ) ProviderError!SecretPayload {
        return self.resolveFn(self.ptr, allocator, reference);
    }
};

pub const LiveProvider = struct {
    client: *client_mod.Client,
    operation_policy: operation.Policy = .{},
    iam_conflict_retries: usize = 3,
    compute_conflict_retries: usize = 3,
    secret_source: ?SecretSource = null,

    pub fn init(client: *client_mod.Client) LiveProvider {
        return .{ .client = client };
    }

    pub fn provider(self: *LiveProvider) provider_mod.Provider {
        return .{
            .ptr = self,
            .readFn = read,
            .diffFn = diff,
            .createFn = create,
            .updateFn = update,
            .deleteFn = delete,
            .importFn = importResource,
        };
    }

    fn read(ptr: *anyopaque, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ReadResult {
        const self: *LiveProvider = @ptrCast(@alignCast(ptr));
        if (isType(node, project_service_type)) return self.readProjectService(context, node);
        if (isType(node, service_account_type)) return self.readServiceAccount(context, node, null);
        if (isType(node, project_member_type)) return self.readProjectMember(context, node);
        if (isType(node, artifact_repository_type)) return self.readArtifactRepository(context, node, null);
        if (isType(node, secret_type)) return self.readSecret(context, node, null);
        if (isType(node, secret_version_type)) return self.readSecretVersion(context, node, context.physical_id);
        if (isType(node, secret_iam_member_type)) return self.readSecretIamMember(context, node);
        if (isType(node, cloud_run_service_type)) return self.runHandler().read(context, node, null);
        if (compute_provider.supports(node)) return self.computeHandler().read(context, node, null);
        if (dns_provider.supports(node)) return self.dnsHandler().read(context, node, null);
        return error.InvalidConfiguration;
    }

    fn diff(
        _: *anyopaque,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        observed: *const provider_mod.ResourceResult,
    ) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        if (!isSupported(node)) return error.InvalidConfiguration;
        if (isType(node, cloud_run_service_type)) return run_provider.Handler.diff(context, node, observed);
        if (compute_provider.supports(node)) return compute_provider.Handler.diff(context, node, observed);
        if (dns_provider.supports(node)) return dns_provider.Handler.diff(context, node, observed);
        const kind: provider_mod.DiffKind = if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash))
            .noop
        else if (isType(node, artifact_repository_type))
            artifactRepositoryDiff(node, observed.observed_inputs)
        else if (isType(node, secret_type))
            secretDiff(node, observed.observed_inputs)
        else if (isType(node, secret_version_type) or isType(node, secret_iam_member_type))
            .replace
        else if (isType(node, project_service_type))
            .replace
        else
            .update;
        const reasons: []const []const u8 = if (kind == .noop) &.{} else &.{"observed inputs differ from desired inputs"};
        return provider_mod.DiffResult.init(context.allocator, kind, reasons);
    }

    fn create(ptr: *anyopaque, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        const self: *LiveProvider = @ptrCast(@alignCast(ptr));
        if (isType(node, project_service_type)) return self.enableProjectService(context, node);
        if (isType(node, service_account_type)) return self.createServiceAccount(context, node);
        if (isType(node, project_member_type)) return self.ensureProjectMember(context, node, true);
        if (isType(node, artifact_repository_type)) return self.createArtifactRepository(context, node);
        if (isType(node, secret_type)) return self.createSecret(context, node);
        if (isType(node, secret_version_type)) return self.createSecretVersion(context, node);
        if (isType(node, secret_iam_member_type)) return self.ensureSecretIamMember(context, node, true);
        if (isType(node, cloud_run_service_type)) return self.runHandler().create(context, node);
        if (compute_provider.supports(node)) return self.computeHandler().create(context, node);
        if (dns_provider.supports(node)) return self.dnsHandler().create(context, node);
        return error.InvalidConfiguration;
    }

    fn update(
        ptr: *anyopaque,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        observed: *const provider_mod.ResourceResult,
    ) ProviderError!provider_mod.ResourceResult {
        const self: *LiveProvider = @ptrCast(@alignCast(ptr));
        if (isType(node, service_account_type)) return self.updateServiceAccount(context, node, observed.physical_id);
        if (isType(node, project_member_type)) return self.ensureProjectMember(context, node, true);
        if (isType(node, artifact_repository_type)) return self.updateArtifactRepository(context, node, observed.physical_id);
        if (isType(node, secret_type)) return self.updateSecret(context, node, observed.physical_id);
        if (isType(node, cloud_run_service_type)) return self.runHandler().update(context, node, observed.physical_id);
        if (compute_provider.supports(node)) return self.computeHandler().update(context, node, observed.physical_id);
        if (dns_provider.supports(node)) return self.dnsHandler().update(context, node, observed.physical_id);
        return error.InvalidConfiguration;
    }

    fn delete(
        ptr: *anyopaque,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!void {
        const self: *LiveProvider = @ptrCast(@alignCast(ptr));
        if (isType(node, project_service_type)) return self.disableProjectService(context, physical_id);
        if (isType(node, service_account_type)) return self.deleteServiceAccount(context, physical_id);
        if (isType(node, artifact_repository_type)) return self.deleteArtifactRepository(context, physical_id);
        if (isType(node, secret_type)) return self.deleteSecret(context, physical_id);
        if (isType(node, secret_version_type)) return self.destroySecretVersion(context, physical_id);
        if (isType(node, cloud_run_service_type)) return self.runHandler().delete(context, physical_id);
        if (compute_provider.supports(node)) return self.computeHandler().delete(context, node, physical_id);
        if (dns_provider.supports(node)) return self.dnsHandler().delete(context, node, physical_id);
        if (isType(node, secret_iam_member_type)) {
            var removed = try self.ensureSecretIamMember(context, node, false);
            removed.deinit();
            return;
        }
        if (isType(node, project_member_type)) {
            var removed = try self.ensureProjectMember(context, node, false);
            removed.deinit();
            return;
        }
        return error.InvalidConfiguration;
    }

    fn importResource(
        ptr: *anyopaque,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!provider_mod.ResourceResult {
        const self: *LiveProvider = @ptrCast(@alignCast(ptr));
        if (isType(node, service_account_type)) {
            const result = try self.readServiceAccount(context, node, physical_id);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (isType(node, project_service_type)) {
            const result = try self.readProjectService(context, node);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (isType(node, project_member_type)) {
            const result = try self.readProjectMember(context, node);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (isType(node, artifact_repository_type)) {
            const result = try self.readArtifactRepository(context, node, physical_id);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (isType(node, secret_type)) {
            const result = try self.readSecret(context, node, physical_id);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (isType(node, secret_version_type)) {
            const result = try self.readSecretVersion(context, node, physical_id);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (isType(node, secret_iam_member_type)) {
            const result = try self.readSecretIamMember(context, node);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (isType(node, cloud_run_service_type)) {
            const result = try self.runHandler().read(context, node, physical_id);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (compute_provider.supports(node)) {
            const result = try self.computeHandler().read(context, node, physical_id);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (dns_provider.supports(node)) {
            const result = try self.dnsHandler().read(context, node, physical_id);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        return error.InvalidConfiguration;
    }

    fn readProjectService(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ReadResult {
        const physical_id = try projectServiceNameAlloc(context.allocator, node);
        defer context.allocator.free(physical_id);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical_id});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .service_usage, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);

        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const object = jsonObject(parsed.value) orelse return error.ProviderBug;
        const service_state = jsonString(object.get("state")) orelse return error.ProviderBug;
        if (!std.mem.eql(u8, service_state, "ENABLED")) return .absent;
        return .{ .present = try projectServiceResult(context.allocator, node, physical_id, null) };
    }

    fn enableProjectService(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        const physical_id = try projectServiceNameAlloc(context.allocator, node);
        defer context.allocator.free(physical_id);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}:enable", .{physical_id});
        defer context.allocator.free(path);
        const operation_name = try self.startOperation(context, .service_usage, path, "POST", "{}");
        defer context.allocator.free(operation_name);
        try self.waitForServiceUsageOperation(context, operation_name);
        return projectServiceResult(context.allocator, node, physical_id, operation_name);
    }

    fn disableProjectService(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        physical_id: []const u8,
    ) ProviderError!void {
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}:disable", .{physical_id});
        defer context.allocator.free(path);
        const operation_name = self.startOperation(context, .service_usage, path, "POST", "{}") catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer context.allocator.free(operation_name);
        try self.waitForServiceUsageOperation(context, operation_name);
    }

    fn startOperation(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        api: client_mod.Api,
        path: []const u8,
        method: []const u8,
        body: []const u8,
    ) ProviderError![]const u8 {
        var response = try self.request(context, .{ .api = api, .method = method, .path = path, .body = body });
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const object = jsonObject(parsed.value) orelse return error.ProviderBug;
        const name = jsonString(object.get("name")) orelse return error.ProviderBug;
        return context.allocator.dupe(u8, name) catch return error.OutOfMemory;
    }

    fn waitForServiceUsageOperation(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        operation_name: []const u8,
    ) ProviderError!void {
        const base = try std.fmt.allocPrint(
            context.allocator,
            "{s}/v1",
            .{std.mem.trimEnd(u8, self.client.endpoints.service_usage, "/")},
        );
        defer context.allocator.free(base);
        var target = operation.Target.genericAlloc(context.allocator, base, operation_name) catch return error.OutOfMemory;
        defer target.deinit(context.allocator);
        var result = try operation.waitAlloc(self.client, context, target, self.operation_policy);
        result.deinit(context.allocator);
    }

    fn readServiceAccount(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_override: ?[]const u8,
    ) ProviderError!provider_mod.ReadResult {
        const generated = if (physical_override == null) try serviceAccountNameAlloc(context.allocator, node) else null;
        defer if (generated) |name| context.allocator.free(name);
        const physical_id = physical_override orelse generated.?;
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical_id});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .iam, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try serviceAccountResultFromJson(context.allocator, node, response.body) };
    }

    fn createServiceAccount(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        const project_id = try requiredInput(node, "project_id");
        const account_id = try requiredInput(node, "account_id");
        const display_name = try requiredInput(node, "display_name");
        const description = try requiredInput(node, "description");
        const path = try std.fmt.allocPrint(context.allocator, "/v1/projects/{s}/serviceAccounts", .{project_id});
        defer context.allocator.free(path);
        const body = std.json.Stringify.valueAlloc(context.allocator, .{
            .accountId = account_id,
            .serviceAccount = .{
                .displayName = display_name,
                .description = description,
            },
        }, .{}) catch return error.OutOfMemory;
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .iam, .method = "POST", .path = path, .body = body });
        defer response.deinit(context.allocator);
        return serviceAccountResultFromJson(context.allocator, node, response.body);
    }

    fn updateServiceAccount(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!provider_mod.ResourceResult {
        const display_name = try requiredInput(node, "display_name");
        const description = try requiredInput(node, "description");
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical_id});
        defer context.allocator.free(path);
        const body = std.json.Stringify.valueAlloc(context.allocator, .{
            .serviceAccount = .{
                .name = physical_id,
                .displayName = display_name,
                .description = description,
            },
            .updateMask = "displayName,description",
        }, .{}) catch return error.OutOfMemory;
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .iam, .method = "PATCH", .path = path, .body = body });
        defer response.deinit(context.allocator);
        return serviceAccountResultFromJson(context.allocator, node, response.body);
    }

    fn deleteServiceAccount(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        physical_id: []const u8,
    ) ProviderError!void {
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical_id});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .iam, .method = "DELETE", .path = path }) catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        response.deinit(context.allocator);
    }

    fn readArtifactRepository(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_override: ?[]const u8,
    ) ProviderError!provider_mod.ReadResult {
        const generated = if (physical_override == null) try artifactRepositoryNameAlloc(context.allocator, node) else null;
        defer if (generated) |name| context.allocator.free(name);
        const physical_id = physical_override orelse generated.?;
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical_id});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .artifact_registry, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try artifactRepositoryResultFromJson(context.allocator, node, response.body) };
    }

    fn createArtifactRepository(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        const project_id = try requiredInput(node, "project_id");
        const location = try requiredInput(node, "location");
        const name = try requiredInput(node, "name");
        const labels_json = try inputJsonAlloc(context.allocator, node, "labels");
        defer context.allocator.free(labels_json);
        const path = try std.fmt.allocPrint(
            context.allocator,
            "/v1/projects/{s}/locations/{s}/repositories?repositoryId={s}",
            .{ project_id, location, name },
        );
        defer context.allocator.free(path);
        const body = try std.fmt.allocPrint(context.allocator, "{{\"format\":\"DOCKER\",\"labels\":{s}}}", .{labels_json});
        defer context.allocator.free(body);
        const operation_name = self.startOperation(context, .artifact_registry, path, "POST", body) catch |err| {
            if (err != error.Conflict) return err;
            const existing = try self.readArtifactRepository(context, node, null);
            return switch (existing) {
                .absent => error.Conflict,
                .present => |present| if (std.mem.eql(u8, &node.inputs_hash, &present.observed_hash))
                    present
                else conflict: {
                    var mutable = present;
                    mutable.deinit();
                    break :conflict error.Conflict;
                },
            };
        };
        defer context.allocator.free(operation_name);
        try self.waitForArtifactOperation(context, operation_name);
        return artifactRepositoryDesiredResult(context.allocator, node, operation_name);
    }

    fn updateArtifactRepository(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!provider_mod.ResourceResult {
        const labels_json = try inputJsonAlloc(context.allocator, node, "labels");
        defer context.allocator.free(labels_json);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}?updateMask=labels", .{physical_id});
        defer context.allocator.free(path);
        const body = try std.fmt.allocPrint(
            context.allocator,
            "{{\"name\":\"{s}\",\"labels\":{s}}}",
            .{ physical_id, labels_json },
        );
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .artifact_registry, .method = "PATCH", .path = path, .body = body });
        defer response.deinit(context.allocator);
        return artifactRepositoryResultFromJson(context.allocator, node, response.body);
    }

    fn deleteArtifactRepository(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        physical_id: []const u8,
    ) ProviderError!void {
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical_id});
        defer context.allocator.free(path);
        const operation_name = self.startOperation(context, .artifact_registry, path, "DELETE", "") catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer context.allocator.free(operation_name);
        try self.waitForArtifactOperation(context, operation_name);
    }

    fn waitForArtifactOperation(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        operation_name: []const u8,
    ) ProviderError!void {
        const base = try std.fmt.allocPrint(
            context.allocator,
            "{s}/v1",
            .{std.mem.trimEnd(u8, self.client.endpoints.artifact_registry, "/")},
        );
        defer context.allocator.free(base);
        var target = operation.Target.genericAlloc(context.allocator, base, operation_name) catch return error.OutOfMemory;
        defer target.deinit(context.allocator);
        var result = try operation.waitAlloc(self.client, context, target, self.operation_policy);
        result.deinit(context.allocator);
    }

    fn readSecret(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_override: ?[]const u8,
    ) ProviderError!provider_mod.ReadResult {
        const generated = if (physical_override == null) try secretNameAlloc(context.allocator, node) else null;
        defer if (generated) |name| context.allocator.free(name);
        const physical_id = physical_override orelse generated.?;
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical_id});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .secret_manager, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try secretResultFromJson(context.allocator, node, response.body) };
    }

    fn createSecret(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        const project_id = try requiredInput(node, "project_id");
        const name = try requiredInput(node, "name");
        const labels_json = try inputJsonAlloc(context.allocator, node, "labels");
        defer context.allocator.free(labels_json);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/projects/{s}/secrets?secretId={s}", .{ project_id, name });
        defer context.allocator.free(path);
        const body = try std.fmt.allocPrint(
            context.allocator,
            "{{\"replication\":{{\"automatic\":{{}}}},\"labels\":{s}}}",
            .{labels_json},
        );
        defer context.allocator.free(body);
        var response = self.request(context, .{ .api = .secret_manager, .method = "POST", .path = path, .body = body }) catch |err| {
            if (err != error.Conflict) return err;
            const existing = try self.readSecret(context, node, null);
            return switch (existing) {
                .absent => error.Conflict,
                .present => |present| if (std.mem.eql(u8, &node.inputs_hash, &present.observed_hash))
                    present
                else conflict: {
                    var mutable = present;
                    mutable.deinit();
                    break :conflict error.Conflict;
                },
            };
        };
        defer response.deinit(context.allocator);
        return secretResultFromJson(context.allocator, node, response.body);
    }

    fn updateSecret(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!provider_mod.ResourceResult {
        const labels_json = try inputJsonAlloc(context.allocator, node, "labels");
        defer context.allocator.free(labels_json);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}?updateMask=labels", .{physical_id});
        defer context.allocator.free(path);
        const body = try std.fmt.allocPrint(
            context.allocator,
            "{{\"name\":\"{s}\",\"labels\":{s}}}",
            .{ physical_id, labels_json },
        );
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .secret_manager, .method = "PATCH", .path = path, .body = body });
        defer response.deinit(context.allocator);
        return secretResultFromJson(context.allocator, node, response.body);
    }

    fn deleteSecret(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        physical_id: []const u8,
    ) ProviderError!void {
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical_id});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .secret_manager, .method = "DELETE", .path = path }) catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        response.deinit(context.allocator);
    }

    fn readSecretVersion(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: ?[]const u8,
    ) ProviderError!provider_mod.ReadResult {
        const version_name = physical_id orelse return .absent;
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{version_name});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .secret_manager, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const object = jsonObject(parsed.value) orelse return error.ProviderBug;
        const version_state = jsonString(object.get("state")) orelse return error.ProviderBug;
        if (std.mem.eql(u8, version_state, "DESTROYED")) return .absent;
        return .{ .present = try secretVersionResultFromJson(context.allocator, node, response.body) };
    }

    fn createSecretVersion(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        const source = self.secret_source orelse return error.InvalidConfiguration;
        const reference = try requiredSecretInput(node, "source");
        var payload = try source.resolve(context.allocator, reference);
        defer payload.deinit();
        const encoded_size = std.base64.standard.Encoder.calcSize(payload.bytes.len);
        const encoded = context.allocator.alloc(u8, encoded_size) catch return error.OutOfMemory;
        defer {
            std.crypto.secureZero(u8, encoded);
            context.allocator.free(encoded);
        }
        _ = std.base64.standard.Encoder.encode(encoded, payload.bytes);
        const body = std.json.Stringify.valueAlloc(context.allocator, .{
            .payload = .{ .data = encoded },
        }, .{}) catch return error.OutOfMemory;
        defer {
            std.crypto.secureZero(u8, body);
            context.allocator.free(body);
        }
        const secret_name = try secretNameAlloc(context.allocator, node);
        defer context.allocator.free(secret_name);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}:addVersion", .{secret_name});
        defer context.allocator.free(path);
        var response = try self.request(context, .{ .api = .secret_manager, .method = "POST", .path = path, .body = body });
        defer response.deinit(context.allocator);
        return secretVersionResultFromJson(context.allocator, node, response.body);
    }

    fn destroySecretVersion(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        physical_id: []const u8,
    ) ProviderError!void {
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}:destroy", .{physical_id});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .secret_manager, .method = "POST", .path = path, .body = "{}" }) catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        response.deinit(context.allocator);
    }

    fn readSecretIamMember(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ReadResult {
        const role = try requiredInput(node, "role");
        const member = try requiredInput(node, "member");
        var policy = try self.getSecretPolicy(context, node);
        defer policy.deinit();
        if (!policyHasMember(policy.value, role, member)) return .absent;
        return .{ .present = try secretIamMemberResult(context.allocator, node) };
    }

    fn ensureSecretIamMember(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        should_exist: bool,
    ) ProviderError!provider_mod.ResourceResult {
        const role = try requiredInput(node, "role");
        const member = try requiredInput(node, "member");
        var conflicts: usize = 0;
        while (true) {
            try context.checkActive();
            var policy = try self.getSecretPolicy(context, node);
            defer policy.deinit();
            const changed = try mutatePolicy(&policy, role, member, should_exist);
            if (!changed) return secretIamMemberResult(context.allocator, node);
            self.setSecretPolicy(context, node, policy.value) catch |err| {
                if (err == error.Conflict and conflicts < self.iam_conflict_retries) {
                    conflicts += 1;
                    continue;
                }
                return err;
            };
            return secretIamMemberResult(context.allocator, node);
        }
    }

    fn getSecretPolicy(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!std.json.Parsed(std.json.Value) {
        const secret_name = try secretNameAlloc(context.allocator, node);
        defer context.allocator.free(secret_name);
        const path = try std.fmt.allocPrint(
            context.allocator,
            "/v1/{s}:getIamPolicy?options.requestedPolicyVersion=3",
            .{secret_name},
        );
        defer context.allocator.free(path);
        var response = try self.request(context, .{ .api = .secret_manager, .method = "GET", .path = path });
        defer response.deinit(context.allocator);
        return std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
    }

    fn setSecretPolicy(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        policy: std.json.Value,
    ) ProviderError!void {
        const secret_name = try secretNameAlloc(context.allocator, node);
        defer context.allocator.free(secret_name);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}:setIamPolicy", .{secret_name});
        defer context.allocator.free(path);
        const body = std.json.Stringify.valueAlloc(context.allocator, .{ .policy = policy }, .{}) catch return error.OutOfMemory;
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .secret_manager, .method = "POST", .path = path, .body = body });
        response.deinit(context.allocator);
    }

    fn readProjectMember(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ReadResult {
        const project_id = try requiredInput(node, "project_id");
        const role = try requiredInput(node, "role");
        const member = try requiredInput(node, "member");
        var policy = try self.getProjectPolicy(context, project_id);
        defer policy.deinit();
        if (!policyHasMember(policy.value, role, member)) return .absent;
        return .{ .present = try projectMemberResult(context.allocator, node) };
    }

    fn ensureProjectMember(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        should_exist: bool,
    ) ProviderError!provider_mod.ResourceResult {
        const project_id = try requiredInput(node, "project_id");
        const role = try requiredInput(node, "role");
        const member = try requiredInput(node, "member");
        var conflicts: usize = 0;
        while (true) {
            try context.checkActive();
            var policy = try self.getProjectPolicy(context, project_id);
            defer policy.deinit();
            const changed = try mutatePolicy(&policy, role, member, should_exist);
            if (!changed) return projectMemberResult(context.allocator, node);
            self.setProjectPolicy(context, project_id, policy.value) catch |err| {
                if (err == error.Conflict and conflicts < self.iam_conflict_retries) {
                    conflicts += 1;
                    continue;
                }
                return err;
            };
            return projectMemberResult(context.allocator, node);
        }
    }

    fn getProjectPolicy(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        project_id: []const u8,
    ) ProviderError!std.json.Parsed(std.json.Value) {
        const path = try std.fmt.allocPrint(context.allocator, "/v1/projects/{s}:getIamPolicy", .{project_id});
        defer context.allocator.free(path);
        var response = try self.request(context, .{
            .api = .resource_manager,
            .method = "POST",
            .path = path,
            .body = "{\"options\":{\"requestedPolicyVersion\":3}}",
        });
        defer response.deinit(context.allocator);
        return std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
    }

    fn setProjectPolicy(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        project_id: []const u8,
        policy: std.json.Value,
    ) ProviderError!void {
        const path = try std.fmt.allocPrint(context.allocator, "/v1/projects/{s}:setIamPolicy", .{project_id});
        defer context.allocator.free(path);
        const body = std.json.Stringify.valueAlloc(context.allocator, .{ .policy = policy }, .{}) catch return error.OutOfMemory;
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .resource_manager, .method = "POST", .path = path, .body = body });
        response.deinit(context.allocator);
    }

    fn request(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        request_value: client_mod.Request,
    ) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, request_value, &diagnostic);
    }

    fn runHandler(self: *LiveProvider) run_provider.Handler {
        return .{ .client = self.client, .operation_policy = self.operation_policy };
    }

    fn computeHandler(self: *LiveProvider) compute_provider.Handler {
        return .{
            .client = self.client,
            .operation_policy = self.operation_policy,
            .conflict_retries = self.compute_conflict_retries,
        };
    }

    fn dnsHandler(self: *LiveProvider) dns_provider.Handler {
        return .{ .client = self.client };
    }
};

fn projectServiceResult(
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    physical_id: []const u8,
    operation_handle: ?[]const u8,
) ProviderError!provider_mod.ResourceResult {
    const outputs = [_]state.StateOutput{
        .{ .name = "resource_name", .value = .{ .string = physical_id } },
    };
    return provider_mod.ResourceResult.init(allocator, physical_id, node.inputs, &outputs, operation_handle);
}

fn serviceAccountResultFromJson(
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    body: []const u8,
) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const object = jsonObject(parsed.value) orelse return error.ProviderBug;
    const name = jsonString(object.get("name")) orelse return error.ProviderBug;
    const email = jsonString(object.get("email")) orelse return error.ProviderBug;
    const unique_id = jsonString(object.get("uniqueId")) orelse return error.ProviderBug;
    const display_name = jsonString(object.get("displayName")) orelse "";
    const description = jsonString(object.get("description")) orelse "";
    const account_id = try requiredInput(node, "account_id");
    const project_id = try requiredInput(node, "project_id");
    const fields = [_]value.Field{
        .{ .name = "account_id", .value = .{ .string = account_id } },
        .{ .name = "description", .value = .{ .string = description } },
        .{ .name = "display_name", .value = .{ .string = display_name } },
        .{ .name = "project_id", .value = .{ .string = project_id } },
    };
    const outputs = [_]state.StateOutput{
        .{ .name = "email", .value = .{ .string = email } },
        .{ .name = "unique_id", .value = .{ .string = unique_id } },
    };
    return provider_mod.ResourceResult.init(allocator, name, .{ .object = &fields }, &outputs, null);
}

fn artifactRepositoryResultFromJson(
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    body: []const u8,
) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const object = jsonObject(parsed.value) orelse return error.ProviderBug;
    const physical_id = jsonString(object.get("name")) orelse return error.ProviderBug;
    const format = jsonString(object.get("format")) orelse return error.ProviderBug;
    const project_id = try requiredInput(node, "project_id");
    const location = try requiredInput(node, "location");
    const name = try requiredInput(node, "name");
    const registry_uri = jsonString(object.get("registryUri")) orelse return error.ProviderBug;
    const label_object = if (object.get("labels")) |labels_value|
        jsonObject(labels_value) orelse return error.ProviderBug
    else
        std.json.ObjectMap.empty;
    const label_fields = try allocator.alloc(value.Field, label_object.count());
    defer allocator.free(label_fields);
    var iterator = label_object.iterator();
    var label_index: usize = 0;
    while (iterator.next()) |entry| : (label_index += 1) {
        const label_value = jsonString(entry.value_ptr.*) orelse return error.ProviderBug;
        label_fields[label_index] = .{ .name = entry.key_ptr.*, .value = .{ .string = label_value } };
    }
    const fields = [_]value.Field{
        .{ .name = "format", .value = .{ .string = format } },
        .{ .name = "labels", .value = .{ .object = label_fields } },
        .{ .name = "location", .value = .{ .string = location } },
        .{ .name = "name", .value = .{ .string = name } },
        .{ .name = "project_id", .value = .{ .string = project_id } },
    };
    const outputs = [_]state.StateOutput{
        .{ .name = "repository_url", .value = .{ .string = registry_uri } },
    };
    return provider_mod.ResourceResult.init(allocator, physical_id, .{ .object = &fields }, &outputs, null);
}

fn artifactRepositoryDesiredResult(
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    operation_handle: ?[]const u8,
) ProviderError!provider_mod.ResourceResult {
    const project_id = try requiredInput(node, "project_id");
    const location = try requiredInput(node, "location");
    const name = try requiredInput(node, "name");
    const physical_id = try artifactRepositoryNameAlloc(allocator, node);
    defer allocator.free(physical_id);
    const registry_uri = try std.fmt.allocPrint(allocator, "{s}-docker.pkg.dev/{s}/{s}", .{ location, project_id, name });
    defer allocator.free(registry_uri);
    const outputs = [_]state.StateOutput{
        .{ .name = "repository_url", .value = .{ .string = registry_uri } },
    };
    return provider_mod.ResourceResult.init(allocator, physical_id, node.inputs, &outputs, operation_handle);
}

fn secretResultFromJson(
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    body: []const u8,
) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const object = jsonObject(parsed.value) orelse return error.ProviderBug;
    const physical_id = jsonString(object.get("name")) orelse return error.ProviderBug;
    const replication_value = object.get("replication") orelse return error.ProviderBug;
    const replication = jsonObject(replication_value) orelse return error.ProviderBug;
    if (replication.get("automatic") == null) return error.ProviderBug;
    const project_id = try requiredInput(node, "project_id");
    const name = try requiredInput(node, "name");
    const label_object = if (object.get("labels")) |labels_value|
        jsonObject(labels_value) orelse return error.ProviderBug
    else
        std.json.ObjectMap.empty;
    const label_fields = try jsonLabelFieldsAlloc(allocator, label_object);
    defer allocator.free(label_fields);
    const fields = [_]value.Field{
        .{ .name = "labels", .value = .{ .object = label_fields } },
        .{ .name = "name", .value = .{ .string = name } },
        .{ .name = "project_id", .value = .{ .string = project_id } },
        .{ .name = "replication", .value = .{ .string = "automatic" } },
    };
    const outputs = [_]state.StateOutput{
        .{ .name = "resource_name", .value = .{ .string = physical_id } },
    };
    return provider_mod.ResourceResult.init(allocator, physical_id, .{ .object = &fields }, &outputs, null);
}

fn secretVersionResultFromJson(
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    body: []const u8,
) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const object = jsonObject(parsed.value) orelse return error.ProviderBug;
    const physical_id = jsonString(object.get("name")) orelse return error.ProviderBug;
    const marker = "/versions/";
    const version_index = std.mem.lastIndexOf(u8, physical_id, marker) orelse return error.ProviderBug;
    const secret_name = physical_id[0..version_index];
    const version = physical_id[version_index + marker.len ..];
    if (version.len == 0) return error.ProviderBug;
    const outputs = [_]state.StateOutput{
        .{ .name = "version", .value = .{ .secret_ref = .{
            .provider = "gcp-secret-manager",
            .resource = secret_name,
            .version = version,
        } } },
    };
    return provider_mod.ResourceResult.init(allocator, physical_id, node.inputs, &outputs, null);
}

fn secretIamMemberResult(
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
) ProviderError!provider_mod.ResourceResult {
    const secret_name = try secretNameAlloc(allocator, node);
    defer allocator.free(secret_name);
    const name = try requiredInput(node, "name");
    const role = try requiredInput(node, "role");
    const member = try requiredInput(node, "member");
    const physical_id = try std.fmt.allocPrint(allocator, "{s}/iam/{s}", .{ secret_name, name });
    defer allocator.free(physical_id);
    const binding_id = try std.fmt.allocPrint(allocator, "{s}|{s}|{s}", .{ secret_name, role, member });
    defer allocator.free(binding_id);
    const outputs = [_]state.StateOutput{
        .{ .name = "binding_id", .value = .{ .string = binding_id } },
    };
    return provider_mod.ResourceResult.init(allocator, physical_id, node.inputs, &outputs, null);
}

fn jsonLabelFieldsAlloc(
    allocator: std.mem.Allocator,
    label_object: std.json.ObjectMap,
) ProviderError![]value.Field {
    const label_fields = try allocator.alloc(value.Field, label_object.count());
    var iterator = label_object.iterator();
    var label_index: usize = 0;
    while (iterator.next()) |entry| : (label_index += 1) {
        const label_value = jsonString(entry.value_ptr.*) orelse return error.ProviderBug;
        label_fields[label_index] = .{ .name = entry.key_ptr.*, .value = .{ .string = label_value } };
    }
    return label_fields;
}

fn projectMemberResult(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
    const project_id = try requiredInput(node, "project_id");
    const name = try requiredInput(node, "name");
    const role = try requiredInput(node, "role");
    const member = try requiredInput(node, "member");
    const physical_id = try std.fmt.allocPrint(allocator, "projects/{s}/iam/{s}", .{ project_id, name });
    defer allocator.free(physical_id);
    const binding_id = try std.fmt.allocPrint(allocator, "{s}|{s}|{s}", .{ project_id, role, member });
    defer allocator.free(binding_id);
    const outputs = [_]state.StateOutput{
        .{ .name = "binding_id", .value = .{ .string = binding_id } },
    };
    return provider_mod.ResourceResult.init(allocator, physical_id, node.inputs, &outputs, null);
}

fn policyHasMember(policy: std.json.Value, role: []const u8, member: []const u8) bool {
    const object = jsonObject(policy) orelse return false;
    const bindings_value = object.get("bindings") orelse return false;
    const bindings = switch (bindings_value) {
        .array => |array| array.items,
        else => return false,
    };
    for (bindings) |binding_value| {
        const binding = jsonObject(binding_value) orelse continue;
        if (binding.get("condition") != null) continue;
        const binding_role = jsonString(binding.get("role")) orelse continue;
        if (!std.mem.eql(u8, binding_role, role)) continue;
        const members_value = binding.get("members") orelse continue;
        const members = switch (members_value) {
            .array => |array| array.items,
            else => continue,
        };
        for (members) |member_value| {
            const candidate = jsonString(member_value) orelse continue;
            if (std.mem.eql(u8, candidate, member)) return true;
        }
    }
    return false;
}

fn mutatePolicy(
    parsed: *std.json.Parsed(std.json.Value),
    role: []const u8,
    member: []const u8,
    should_exist: bool,
) ProviderError!bool {
    const allocator = parsed.arena.allocator();
    const root = switch (parsed.value) {
        .object => |*object| object,
        else => return error.ProviderBug,
    };
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
        if (binding.get("condition") != null) continue;
        const binding_role = jsonString(binding.get("role")) orelse continue;
        if (!std.mem.eql(u8, binding_role, role)) continue;
        const members_value = binding.getPtr("members") orelse continue;
        const members = switch (members_value.*) {
            .array => |*array| array,
            else => continue,
        };
        for (members.items, 0..) |member_value, member_index| {
            const candidate = jsonString(member_value) orelse continue;
            if (!std.mem.eql(u8, candidate, member)) continue;
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
    try members.append(.{ .string = member });
    var binding: std.json.ObjectMap = .empty;
    try binding.put(allocator, "role", .{ .string = role });
    try binding.put(allocator, "members", .{ .array = members });
    try bindings.append(.{ .object = binding });
    return true;
}

fn projectServiceNameAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]const u8 {
    const project_id = try requiredInput(node, "project_id");
    const service = try requiredInput(node, "service");
    return std.fmt.allocPrint(allocator, "projects/{s}/services/{s}", .{ project_id, service }) catch return error.OutOfMemory;
}

fn serviceAccountNameAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]const u8 {
    const project_id = try requiredInput(node, "project_id");
    const account_id = try requiredInput(node, "account_id");
    return std.fmt.allocPrint(
        allocator,
        "projects/{s}/serviceAccounts/{s}@{s}.iam.gserviceaccount.com",
        .{ project_id, account_id, project_id },
    ) catch return error.OutOfMemory;
}

fn artifactRepositoryNameAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]const u8 {
    const project_id = try requiredInput(node, "project_id");
    const location = try requiredInput(node, "location");
    const name = try requiredInput(node, "name");
    return std.fmt.allocPrint(
        allocator,
        "projects/{s}/locations/{s}/repositories/{s}",
        .{ project_id, location, name },
    ) catch return error.OutOfMemory;
}

fn secretNameAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]const u8 {
    const project_id = try requiredInput(node, "project_id");
    const secret_id = inputStringFromValue(node.inputs, "secret_id") orelse
        inputStringFromValue(node.inputs, "name") orelse return error.InvalidConfiguration;
    return std.fmt.allocPrint(allocator, "projects/{s}/secrets/{s}", .{ project_id, secret_id }) catch return error.OutOfMemory;
}

fn artifactRepositoryDiff(node: resource.ResourceNode, observed: value.Value) provider_mod.DiffKind {
    for ([_][]const u8{ "project_id", "location", "name", "format" }) |field| {
        const desired_value = inputStringFromValue(node.inputs, field) orelse return .replace;
        const observed_value = inputStringFromValue(observed, field) orelse return .replace;
        if (!std.mem.eql(u8, desired_value, observed_value)) return .replace;
    }
    return .update;
}

fn secretDiff(node: resource.ResourceNode, observed: value.Value) provider_mod.DiffKind {
    for ([_][]const u8{ "project_id", "name", "replication" }) |field| {
        const desired_value = inputStringFromValue(node.inputs, field) orelse return .replace;
        const observed_value = inputStringFromValue(observed, field) orelse return .replace;
        if (!std.mem.eql(u8, desired_value, observed_value)) return .replace;
    }
    return .update;
}

fn inputJsonAlloc(
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    name: []const u8,
) ProviderError![]const u8 {
    const fields = switch (node.inputs) {
        .object => |fields| fields,
        else => return error.InvalidConfiguration,
    };
    for (fields) |field| {
        if (!std.mem.eql(u8, field.name, name)) continue;
        return field.value.canonicalJsonAlloc(allocator) catch |err| switch (err) {
            error.DuplicateField => error.InvalidConfiguration,
            error.OutOfMemory => error.OutOfMemory,
        };
    }
    return error.InvalidConfiguration;
}

fn requiredInput(node: resource.ResourceNode, name: []const u8) ProviderError![]const u8 {
    return inputStringFromValue(node.inputs, name) orelse error.InvalidConfiguration;
}

fn requiredSecretInput(node: resource.ResourceNode, name: []const u8) ProviderError!value.SecretReference {
    const fields = switch (node.inputs) {
        .object => |fields| fields,
        else => return error.InvalidConfiguration,
    };
    for (fields) |field| {
        if (!std.mem.eql(u8, field.name, name)) continue;
        return switch (field.value) {
            .secret_ref => |reference| reference,
            else => error.InvalidConfiguration,
        };
    }
    return error.InvalidConfiguration;
}

fn inputStringFromValue(input: value.Value, name: []const u8) ?[]const u8 {
    const fields = switch (input) {
        .object => |fields| fields,
        else => return null,
    };
    for (fields) |field| {
        if (!std.mem.eql(u8, field.name, name)) continue;
        return switch (field.value) {
            .string => |text| text,
            else => null,
        };
    }
    return null;
}

fn jsonObject(json_value: std.json.Value) ?std.json.ObjectMap {
    return switch (json_value) {
        .object => |object| object,
        else => null,
    };
}

fn jsonString(json_value: ?std.json.Value) ?[]const u8 {
    const present = json_value orelse return null;
    return switch (present) {
        .string => |text| text,
        else => null,
    };
}

fn isType(node: resource.ResourceNode, expected: []const u8) bool {
    return std.mem.eql(u8, node.type_name, expected);
}

fn isSupported(node: resource.ResourceNode) bool {
    return isType(node, project_service_type) or
        isType(node, service_account_type) or
        isType(node, project_member_type) or
        isType(node, artifact_repository_type) or
        isType(node, secret_type) or
        isType(node, secret_version_type) or
        isType(node, secret_iam_member_type) or
        isType(node, cloud_run_service_type) or
        compute_provider.supports(node) or
        dns_provider.supports(node);
}
