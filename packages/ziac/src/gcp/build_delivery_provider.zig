const std = @import("std");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const secret = @import("../secret.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;

const Kind = enum { trigger, worker_pool, connection, repository, project_settings, vpcsc };

pub const Handler = struct {
    client: *client_mod.Client,
    operation_policy: operation.Policy = .{},
    secret_source: ?secret.SecretSource = null,

    pub fn supports(node: resource.ResourceNode) bool {
        return kindOf(node) != null;
    }

    pub fn read(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (isAsync(kind)) if (context.operation_handle) |handle| try self.waitOperation(context, kind, handle);
        if (kind == .trigger and physical_override == null and context.physical_id == null) return self.discoverTrigger(context, node);
        const expected = try physicalAlloc(context.allocator, node, kind);
        defer context.allocator.free(expected);
        const physical = physical_override orelse context.physical_id orelse expected;
        if (kind != .trigger and !std.mem.eql(u8, physical, expected)) return error.InvalidConfiguration;
        try validatePhysical(node, kind, physical);
        const path = try readPathAlloc(context.allocator, kind, physical);
        defer context.allocator.free(path);
        var response = self.request(context, apiFor(kind), "GET", path, "") catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try resultFromJson(context, node, kind, physical, response.body) };
    }

    pub fn diff(context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (kind == .project_settings and std.mem.eql(u8, inputString(observed.observed_inputs, "redirection") orelse "", "REDIRECTION_FROM_GCR_IO_FINALIZED") and
            !std.mem.eql(u8, try requiredString(node.inputs, "redirection"), "REDIRECTION_FROM_GCR_IO_FINALIZED")) return error.InvalidConfiguration;
        if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash)) return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        const replace = switch (kind) {
            .trigger => identityChanged(node, observed, &.{ "project_id", "location", "name" }),
            .worker_pool => identityChanged(node, observed, &.{ "project_id", "location", "name", "network" }),
            .connection => identityChanged(node, observed, &.{ "project_id", "location", "name" }) or connectionIdentityChanged(node.inputs, observed.observed_inputs),
            .repository => true,
            .project_settings, .vpcsc => false,
        };
        return provider_mod.DiffResult.init(context.allocator, if (replace) .replace else .update, &.{if (replace) "immutable build delivery identity changed" else "build delivery configuration differs"});
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (kind == .project_settings or kind == .vpcsc) {
            const physical = try physicalAlloc(context.allocator, node, kind);
            defer context.allocator.free(physical);
            var observed = try provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &.{}, null);
            defer observed.deinit();
            return self.update(context, node, &observed);
        }
        const path = try createPathAlloc(context.allocator, node, kind);
        defer context.allocator.free(path);
        const body = try self.bodyAlloc(context, node, kind, null);
        defer context.allocator.free(body);
        var response = try self.request(context, apiFor(kind), "POST", path, body);
        defer response.deinit(context.allocator);
        if (isAsync(kind)) return pendingResult(context, node, kind, response.body);
        const physical = try triggerPhysicalFromJson(context.allocator, response.body);
        defer context.allocator.free(physical);
        return resultFromJson(context, node, kind, physical, response.body);
    }

    pub fn update(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (kind == .repository) return error.InvalidConfiguration;
        try validatePhysical(node, kind, observed.physical_id);
        if (kind == .project_settings and std.mem.eql(u8, inputString(observed.observed_inputs, "redirection") orelse "", "REDIRECTION_FROM_GCR_IO_FINALIZED")) return error.InvalidConfiguration;
        const etag = outputString(observed.*, "etag") orelse "";
        const path = try updatePathAlloc(context.allocator, node, kind, observed.physical_id, etag);
        defer context.allocator.free(path);
        const body = try self.bodyAlloc(context, node, kind, if (etag.len == 0) null else etag);
        defer context.allocator.free(body);
        var response = try self.request(context, apiFor(kind), "PATCH", path, body);
        defer response.deinit(context.allocator);
        if (isAsync(kind)) return pendingResult(context, node, kind, response.body);
        return resultFromJson(context, node, kind, observed.physical_id, response.body);
    }

    pub fn delete(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical: []const u8) ProviderError!void {
        try context.checkActive();
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        if (kind == .project_settings or kind == .vpcsc) return;
        try validatePhysical(node, kind, physical);
        const path = try deletePathAlloc(context.allocator, kind, physical);
        defer context.allocator.free(path);
        var response = self.request(context, apiFor(kind), "DELETE", path, "") catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer response.deinit(context.allocator);
        if (isAsync(kind)) {
            const handle = try operationName(response.body, context.allocator);
            defer context.allocator.free(handle);
            try self.waitOperation(context, kind, handle);
        }
    }

    pub fn importResource(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical: []const u8) ProviderError!provider_mod.ResourceResult {
        const kind = kindOf(node) orelse return error.InvalidConfiguration;
        try validatePhysical(node, kind, physical);
        var read_result = try self.read(context, node, physical);
        defer read_result.deinit();
        return switch (read_result) {
            .absent => error.NotFound,
            .present => |present| present.clone(context.allocator),
        };
    }

    fn discoverTrigger(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ReadResult {
        const project = try requiredString(node.inputs, "project_id");
        const location = try requiredString(node.inputs, "location");
        const wanted = try requiredString(node.inputs, "name");
        const path = try std.fmt.allocPrint(context.allocator, "/v1/projects/{s}/locations/{s}/triggers?pageSize=200", .{ project, location });
        defer context.allocator.free(path);
        var response = try self.request(context, .cloud_build, "GET", path, "");
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const root = jsonObject(parsed.value) orelse return error.ProviderBug;
        const triggers = jsonArray(root.get("triggers")) orelse return .absent;
        for (triggers.items) |candidate| {
            const item = jsonObject(candidate) orelse return error.ProviderBug;
            if (!std.mem.eql(u8, jsonString(item.get("name")) orelse "", wanted)) continue;
            const physical = jsonString(item.get("resourceName")) orelse return error.ProviderBug;
            const body = std.json.Stringify.valueAlloc(context.allocator, candidate, .{}) catch return error.OutOfMemory;
            defer context.allocator.free(body);
            return .{ .present = try resultFromJson(context, node, .trigger, physical, body) };
        }
        return .absent;
    }

    fn waitOperation(self: Handler, context: *provider_mod.OperationContext, kind: Kind, handle: []const u8) ProviderError!void {
        const version = if (kind == .worker_pool) "v1" else "v2";
        const endpoint = self.client.endpoints.cloud_build;
        const base = try std.fmt.allocPrint(context.allocator, "{s}/{s}", .{ std.mem.trimEnd(u8, endpoint, "/"), version });
        defer context.allocator.free(base);
        var target = operation.Target.genericAlloc(context.allocator, base, handle) catch return error.OutOfMemory;
        defer target.deinit(context.allocator);
        var completed = try operation.waitAlloc(self.client, context, target, self.operation_policy);
        completed.deinit(context.allocator);
    }

    fn bodyAlloc(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, etag: ?[]const u8) ProviderError![]const u8 {
        var arena_state = std.heap.ArenaAllocator.init(context.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var root = std.json.ObjectMap.empty;
        switch (kind) {
            .connection => try self.connectionBody(context, arena, &root, node),
            .repository => try repositoryBody(context, arena, &root, node),
            .worker_pool => try workerBody(arena, &root, node),
            .trigger => try triggerBody(context, arena, &root, node),
            .project_settings => {
                try root.put(arena, "name", .{ .string = try physicalAlloc(arena, node, kind) });
                try root.put(arena, "legacyRedirectionState", .{ .string = try requiredString(node.inputs, "redirection") });
                try root.put(arena, "pullPercent", .{ .integer = try requiredInteger(node.inputs, "pull_percent") });
            },
            .vpcsc => {
                try root.put(arena, "name", .{ .string = try physicalAlloc(arena, node, kind) });
                try root.put(arena, "vpcscPolicy", .{ .string = try requiredString(node.inputs, "policy") });
            },
        }
        if (etag) |current| try root.put(arena, "etag", .{ .string = current });
        return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch return error.OutOfMemory;
    }

    fn connectionBody(self: Handler, context: *provider_mod.OperationContext, arena: std.mem.Allocator, root: *std.json.ObjectMap, node: resource.ResourceNode) ProviderError!void {
        try root.put(arena, "name", .{ .string = try physicalAlloc(arena, node, .connection) });
        try root.put(arena, "disabled", .{ .bool = try requiredBoolean(node.inputs, "disabled") });
        try root.put(arena, "annotations", try objectJson(arena, try requiredValue(node.inputs, "annotations")));
        const config = valueObject(try requiredValue(node.inputs, "config")) orelse return error.InvalidConfiguration;
        const kind = try requiredObjectString(config, "kind");
        if (std.mem.eql(u8, kind, "github")) {
            var github = std.json.ObjectMap.empty;
            const installation = try requiredObjectString(config, "app_installation_id");
            if (installation.len != 0) try github.put(arena, "appInstallationId", .{ .string = installation });
            const oauth = try requiredObjectString(config, "oauth_token_secret_version");
            if (oauth.len != 0) {
                var credential = std.json.ObjectMap.empty;
                try credential.put(arena, "oauthTokenSecretVersion", .{ .string = oauth });
                try github.put(arena, "authorizerCredential", .{ .object = credential });
            }
            try root.put(arena, "githubConfig", .{ .object = github });
        } else if (std.mem.eql(u8, kind, "github_enterprise")) {
            var github = std.json.ObjectMap.empty;
            try github.put(arena, "hostUri", .{ .string = try requiredObjectString(config, "host_uri") });
            const reference = try resolveSecret(context, try requiredObjectValue(config, "api_key"));
            var payload = try (self.secret_source orelse return error.InvalidConfiguration).resolve(context, context.allocator, reference);
            defer payload.deinit();
            try github.put(arena, "apiKey", .{ .string = payload.bytes });
            try copyOptionalString(arena, &github, config, "app_id", "appId");
            try copyOptionalString(arena, &github, config, "app_slug", "appSlug");
            try copyOptionalString(arena, &github, config, "app_installation_id", "appInstallationId");
            try copyOptionalString(arena, &github, config, "private_key_secret_version", "privateKeySecretVersion");
            try copyOptionalString(arena, &github, config, "webhook_secret_version", "webhookSecretSecretVersion");
            try copyOptionalString(arena, &github, config, "ssl_ca", "sslCa");
            try serviceDirectory(arena, &github, config);
            try root.put(arena, "githubEnterpriseConfig", .{ .object = github });
        } else if (std.mem.eql(u8, kind, "gitlab") or std.mem.eql(u8, kind, "bitbucket_data_center") or std.mem.eql(u8, kind, "bitbucket_cloud")) {
            var vendor = std.json.ObjectMap.empty;
            try copyOptionalString(arena, &vendor, config, "host_uri", "hostUri");
            try copyOptionalString(arena, &vendor, config, "workspace", "workspace");
            try userCredential(arena, &vendor, config, "authorizer_secret_version", "authorizerCredential");
            try userCredential(arena, &vendor, config, "read_authorizer_secret_version", "readAuthorizerCredential");
            try copyOptionalString(arena, &vendor, config, "webhook_secret_version", "webhookSecretSecretVersion");
            try copyOptionalString(arena, &vendor, config, "ssl_ca", "sslCa");
            try serviceDirectory(arena, &vendor, config);
            const field = if (std.mem.eql(u8, kind, "gitlab")) "gitlabConfig" else if (std.mem.eql(u8, kind, "bitbucket_data_center")) "bitbucketDataCenterConfig" else "bitbucketCloudConfig";
            try root.put(arena, field, .{ .object = vendor });
        } else return error.InvalidConfiguration;
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, api: client_mod.Api, method: []const u8, path: []const u8, body: []const u8) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, .{ .api = api, .method = method, .path = path, .body = body }, &diagnostic);
    }
};

fn repositoryBody(context: *provider_mod.OperationContext, arena: std.mem.Allocator, root: *std.json.ObjectMap, node: resource.ResourceNode) ProviderError!void {
    try root.put(arena, "name", .{ .string = try physicalAlloc(arena, node, .repository) });
    try root.put(arena, "remoteUri", .{ .string = try requiredString(node.inputs, "remote_uri") });
    try root.put(arena, "annotations", try objectJson(arena, try requiredValue(node.inputs, "annotations")));
    _ = try resolveString(context, try requiredValue(node.inputs, "connection"));
}

fn workerBody(arena: std.mem.Allocator, root: *std.json.ObjectMap, node: resource.ResourceNode) ProviderError!void {
    try root.put(arena, "name", .{ .string = try physicalAlloc(arena, node, .worker_pool) });
    try root.put(arena, "displayName", .{ .string = try requiredString(node.inputs, "display_name") });
    try root.put(arena, "annotations", try objectJson(arena, try requiredValue(node.inputs, "annotations")));
    var private = std.json.ObjectMap.empty;
    var worker = std.json.ObjectMap.empty;
    try worker.put(arena, "machineType", .{ .string = try requiredString(node.inputs, "machine_type") });
    try worker.put(arena, "diskSizeGb", .{ .string = try std.fmt.allocPrint(arena, "{d}", .{try requiredInteger(node.inputs, "disk_size_gb")}) });
    try worker.put(arena, "enableNestedVirtualization", .{ .bool = try requiredBoolean(node.inputs, "nested_virtualization") });
    try private.put(arena, "workerConfig", .{ .object = worker });
    const network = valueObject(try requiredValue(node.inputs, "network")) orelse return error.InvalidConfiguration;
    if (inputObjectString(network, "kind")) |kind| {
        if (std.mem.eql(u8, kind, "peered")) {
            var config = std.json.ObjectMap.empty;
            try config.put(arena, "peeredNetwork", .{ .string = try requiredObjectString(network, "network") });
            try config.put(arena, "peeredNetworkIpRange", .{ .string = try requiredObjectString(network, "ip_range") });
            try config.put(arena, "egressOption", .{ .string = try requiredObjectString(network, "egress") });
            try private.put(arena, "networkConfig", .{ .object = config });
        } else if (std.mem.eql(u8, kind, "psc")) {
            var config = std.json.ObjectMap.empty;
            try config.put(arena, "networkAttachment", .{ .string = try requiredObjectString(network, "network_attachment") });
            try config.put(arena, "publicIpAddressDisabled", .{ .bool = try requiredObjectBoolean(network, "public_ip_disabled") });
            try config.put(arena, "routeAllTraffic", .{ .bool = try requiredObjectBoolean(network, "route_all_traffic") });
            try private.put(arena, "privateServiceConnect", .{ .object = config });
        }
    }
    try root.put(arena, "privatePoolV1Config", .{ .object = private });
}

fn triggerBody(context: *provider_mod.OperationContext, arena: std.mem.Allocator, root: *std.json.ObjectMap, node: resource.ResourceNode) ProviderError!void {
    try root.put(arena, "name", .{ .string = try requiredString(node.inputs, "name") });
    try root.put(arena, "description", .{ .string = try requiredString(node.inputs, "description") });
    try root.put(arena, "filename", .{ .string = try requiredString(node.inputs, "filename") });
    try root.put(arena, "disabled", .{ .bool = try requiredBoolean(node.inputs, "disabled") });
    const service_account = try requiredString(node.inputs, "service_account");
    if (service_account.len != 0) try root.put(arena, "serviceAccount", .{ .string = service_account });
    var approval = std.json.ObjectMap.empty;
    try approval.put(arena, "approvalRequired", .{ .bool = try requiredBoolean(node.inputs, "require_approval") });
    try root.put(arena, "approvalConfig", .{ .object = approval });
    try root.put(arena, "substitutions", try objectJson(arena, try requiredValue(node.inputs, "substitutions")));
    try root.put(arena, "includedFiles", try listJson(arena, try requiredValue(node.inputs, "included_files")));
    try root.put(arena, "ignoredFiles", try listJson(arena, try requiredValue(node.inputs, "ignored_files")));
    const repository = try resolveString(context, try requiredValue(node.inputs, "repository"));
    const event = valueObject(try requiredValue(node.inputs, "event")) orelse return error.InvalidConfiguration;
    var event_config = std.json.ObjectMap.empty;
    try event_config.put(arena, "repository", .{ .string = repository });
    const kind = try requiredObjectString(event, "kind");
    if (std.mem.eql(u8, kind, "push")) {
        var push = std.json.ObjectMap.empty;
        try push.put(arena, try requiredObjectString(event, "ref_kind"), .{ .string = try requiredObjectString(event, "pattern") });
        try event_config.put(arena, "push", .{ .object = push });
    } else {
        var pull = std.json.ObjectMap.empty;
        try pull.put(arena, "branch", .{ .string = try requiredObjectString(event, "pattern") });
        try pull.put(arena, "commentControl", .{ .string = if (try requiredObjectBoolean(event, "require_comment")) "COMMENTS_ENABLED_FOR_EXTERNAL_CONTRIBUTORS_ONLY" else "COMMENTS_DISABLED" });
        try event_config.put(arena, "pullRequest", .{ .object = pull });
    }
    try root.put(arena, "repositoryEventConfig", .{ .object = event_config });
    const pool = try resolveString(context, try requiredValue(node.inputs, "worker_pool"));
    if (pool.len != 0) {
        var options = std.json.ObjectMap.empty;
        var build_pool = std.json.ObjectMap.empty;
        try build_pool.put(arena, "name", .{ .string = pool });
        try options.put(arena, "pool", .{ .object = build_pool });
        var build = std.json.ObjectMap.empty;
        try build.put(arena, "options", .{ .object = options });
        try root.put(arena, "build", .{ .object = build });
    }
}

fn resultFromJson(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, physical: []const u8, body: []const u8) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const remote_name = jsonString(root.get(if (kind == .trigger) "resourceName" else "name"));
    if (remote_name) |name| if (!std.mem.eql(u8, name, physical)) return error.InvalidConfiguration;
    var observed = node.inputs.clone(context.allocator) catch return error.OutOfMemory;
    defer observed.deinit(context.allocator);
    try overlayObserved(context, &observed, kind, root);
    var outputs: [4]state.StateOutput = undefined;
    var count: usize = 1;
    outputs[0] = .{ .name = "name", .value = .{ .string = physical } };
    if (kind == .connection) {
        const installation = if (jsonObject(root.get("installationState") orelse .{ .object = std.json.ObjectMap.empty })) |item| jsonString(item.get("stage")) orelse "STATE_UNSPECIFIED" else "STATE_UNSPECIFIED";
        outputs[count] = .{ .name = "installation_state", .value = .{ .string = installation } };
        count += 1;
    } else if (kind == .repository) {
        outputs[count] = .{ .name = "webhook_id", .value = .{ .string = jsonString(root.get("webhookId")) orelse "" } };
        count += 1;
    } else if (kind == .worker_pool) {
        outputs[count] = .{ .name = "state", .value = .{ .string = jsonString(root.get("state")) orelse "STATE_UNSPECIFIED" } };
        count += 1;
    }
    if (jsonString(root.get("etag"))) |etag| {
        outputs[count] = .{ .name = "etag", .value = .{ .string = etag } };
        count += 1;
    }
    return provider_mod.ResourceResult.init(context.allocator, physical, observed, outputs[0..count], null);
}

fn overlayObserved(context: *provider_mod.OperationContext, observed: *value.Value, kind: Kind, root: std.json.ObjectMap) ProviderError!void {
    const allocator = context.allocator;
    switch (kind) {
        .trigger => {
            try setString(allocator, observed, "name", jsonString(root.get("name")) orelse try requiredString(observed.*, "name"));
            try setString(allocator, observed, "description", jsonString(root.get("description")) orelse "");
            try setString(allocator, observed, "filename", jsonString(root.get("filename")) orelse try requiredString(observed.*, "filename"));
            try setBoolean(observed, "disabled", jsonBoolean(root.get("disabled")) orelse false);
            try setString(allocator, observed, "service_account", jsonString(root.get("serviceAccount")) orelse "");
            const approval = jsonObject(root.get("approvalConfig") orelse .{ .object = std.json.ObjectMap.empty });
            try setBoolean(observed, "require_approval", if (approval) |config| jsonBoolean(config.get("approvalRequired")) orelse false else false);
            if (root.get("substitutions")) |substitutions| try setJsonValue(allocator, observed, "substitutions", substitutions) else try setValue(allocator, observed, "substitutions", .{ .object = &.{} });
            if (root.get("includedFiles")) |files| try setJsonValue(allocator, observed, "included_files", files) else try setValue(allocator, observed, "included_files", .{ .list = &.{} });
            if (root.get("ignoredFiles")) |files| try setJsonValue(allocator, observed, "ignored_files", files) else try setValue(allocator, observed, "ignored_files", .{ .list = &.{} });
            const event_config = jsonObject(root.get("repositoryEventConfig") orelse return error.ProviderBug) orelse return error.ProviderBug;
            try setResolvedString(context, observed, "repository", jsonString(event_config.get("repository")) orelse return error.ProviderBug);
            if (event_config.get("push")) |push_value| {
                const push = jsonObject(push_value) orelse return error.ProviderBug;
                const ref_kind = if (jsonString(push.get("branch")) != null) "branch" else "tag";
                const pattern = jsonString(push.get(ref_kind)) orelse return error.ProviderBug;
                const fields = [_]value.Field{
                    .{ .name = "kind", .value = .{ .string = "push" } },
                    .{ .name = "pattern", .value = .{ .string = pattern } },
                    .{ .name = "ref_kind", .value = .{ .string = ref_kind } },
                };
                try setValue(allocator, observed, "event", .{ .object = &fields });
            } else if (event_config.get("pullRequest")) |pull_value| {
                const pull = jsonObject(pull_value) orelse return error.ProviderBug;
                const fields = [_]value.Field{
                    .{ .name = "kind", .value = .{ .string = "pull_request" } },
                    .{ .name = "pattern", .value = .{ .string = jsonString(pull.get("branch")) orelse return error.ProviderBug } },
                    .{ .name = "require_comment", .value = .{ .boolean = !std.mem.eql(u8, jsonString(pull.get("commentControl")) orelse "COMMENTS_DISABLED", "COMMENTS_DISABLED") } },
                };
                try setValue(allocator, observed, "event", .{ .object = &fields });
            } else return error.ProviderBug;
            const build = jsonObject(root.get("build") orelse .{ .object = std.json.ObjectMap.empty });
            const options = if (build) |item| jsonObject(item.get("options") orelse .{ .object = std.json.ObjectMap.empty }) else null;
            const pool = if (options) |item| jsonObject(item.get("pool") orelse .{ .object = std.json.ObjectMap.empty }) else null;
            try setResolvedString(context, observed, "worker_pool", if (pool) |item| jsonString(item.get("name")) orelse "" else "");
        },
        .connection => {
            try setBoolean(observed, "disabled", jsonBoolean(root.get("disabled")) orelse false);
            if (root.get("annotations")) |annotations| try setJsonValue(allocator, observed, "annotations", annotations);
            try overlayConnection(allocator, observed, root);
        },
        .repository => {
            try setString(allocator, observed, "remote_uri", jsonString(root.get("remoteUri")) orelse try requiredString(observed.*, "remote_uri"));
            if (root.get("annotations")) |annotations| try setJsonValue(allocator, observed, "annotations", annotations);
        },
        .project_settings => {
            try setString(allocator, observed, "redirection", jsonString(root.get("legacyRedirectionState")) orelse try requiredString(observed.*, "redirection"));
            try setInteger(observed, "pull_percent", jsonInteger(root.get("pullPercent")) orelse 0);
        },
        .vpcsc => try setString(allocator, observed, "policy", jsonString(root.get("vpcscPolicy")) orelse try requiredString(observed.*, "policy")),
        .worker_pool => {
            try setString(allocator, observed, "display_name", jsonString(root.get("displayName")) orelse "");
            if (root.get("annotations")) |annotations| try setJsonValue(allocator, observed, "annotations", annotations);
            const private = jsonObject(root.get("privatePoolV1Config") orelse return error.ProviderBug) orelse return error.ProviderBug;
            const worker = jsonObject(private.get("workerConfig") orelse return error.ProviderBug) orelse return error.ProviderBug;
            try setString(allocator, observed, "machine_type", jsonString(worker.get("machineType")) orelse return error.ProviderBug);
            try setInteger(observed, "disk_size_gb", jsonIntegerOrString(worker.get("diskSizeGb")) orelse return error.ProviderBug);
            try setBoolean(observed, "nested_virtualization", jsonBoolean(worker.get("enableNestedVirtualization")) orelse false);
            if (private.get("networkConfig")) |network_value| {
                const network = jsonObject(network_value) orelse return error.ProviderBug;
                const fields = [_]value.Field{
                    .{ .name = "egress", .value = .{ .string = jsonString(network.get("egressOption")) orelse "PUBLIC_EGRESS" } },
                    .{ .name = "ip_range", .value = .{ .string = jsonString(network.get("peeredNetworkIpRange")) orelse "" } },
                    .{ .name = "kind", .value = .{ .string = "peered" } },
                    .{ .name = "network", .value = .{ .string = jsonString(network.get("peeredNetwork")) orelse return error.ProviderBug } },
                };
                try setValue(allocator, observed, "network", .{ .object = &fields });
            } else if (private.get("privateServiceConnect")) |psc_value| {
                const psc = jsonObject(psc_value) orelse return error.ProviderBug;
                const fields = [_]value.Field{
                    .{ .name = "kind", .value = .{ .string = "psc" } },
                    .{ .name = "network_attachment", .value = .{ .string = jsonString(psc.get("networkAttachment")) orelse return error.ProviderBug } },
                    .{ .name = "public_ip_disabled", .value = .{ .boolean = jsonBoolean(psc.get("publicIpAddressDisabled")) orelse false } },
                    .{ .name = "route_all_traffic", .value = .{ .boolean = jsonBoolean(psc.get("routeAllTraffic")) orelse false } },
                };
                try setValue(allocator, observed, "network", .{ .object = &fields });
            } else try setValue(allocator, observed, "network", .{ .object = &.{} });
        },
    }
}

fn pendingResult(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, body: []const u8) ProviderError!provider_mod.ResourceResult {
    const handle = try operationName(body, context.allocator);
    defer context.allocator.free(handle);
    const physical = try physicalAlloc(context.allocator, node, kind);
    defer context.allocator.free(physical);
    const outputs = [_]state.StateOutput{.{ .name = "name", .value = .{ .unknown_reason = "Cloud Build operation pending" } }};
    var result = try provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, &outputs, handle);
    result.completed = false;
    return result;
}

fn operationName(body: []const u8, allocator: std.mem.Allocator) ProviderError![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const handle = jsonString(root.get("name")) orelse return error.ProviderBug;
    if (std.mem.indexOf(u8, handle, "/operations/") == null) return error.ProviderBug;
    return allocator.dupe(u8, handle) catch return error.OutOfMemory;
}

fn triggerPhysicalFromJson(allocator: std.mem.Allocator, body: []const u8) ProviderError![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    return allocator.dupe(u8, jsonString(root.get("resourceName")) orelse return error.ProviderBug) catch return error.OutOfMemory;
}

fn kindOf(node: resource.ResourceNode) ?Kind {
    const mappings = [_]struct { name: []const u8, kind: Kind }{
        .{ .name = "gcp.cloudbuild.Trigger", .kind = .trigger },
        .{ .name = "gcp.cloudbuild.WorkerPool", .kind = .worker_pool },
        .{ .name = "gcp.cloudbuild.Connection", .kind = .connection },
        .{ .name = "gcp.cloudbuild.Repository", .kind = .repository },
        .{ .name = "gcp.artifact.ProjectSettings", .kind = .project_settings },
        .{ .name = "gcp.artifact.VpcscConfig", .kind = .vpcsc },
    };
    for (mappings) |mapping| if (std.mem.eql(u8, node.type_name, mapping.name)) return mapping.kind;
    return null;
}

fn isAsync(kind: Kind) bool {
    return kind == .worker_pool or kind == .connection or kind == .repository;
}

fn apiFor(kind: Kind) client_mod.Api {
    return if (kind == .project_settings or kind == .vpcsc) .artifact_registry else .cloud_build;
}

fn physicalAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    const project = try requiredString(node.inputs, "project_id");
    return switch (kind) {
        .project_settings => std.fmt.allocPrint(allocator, "projects/{s}/projectSettings", .{project}),
        .vpcsc => std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}/vpcscConfig", .{ project, try requiredString(node.inputs, "location") }),
        .repository => std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}/connections/{s}/repositories/{s}", .{ project, try requiredString(node.inputs, "location"), try requiredString(node.inputs, "connection_name"), try requiredString(node.inputs, "name") }),
        .trigger => std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}/triggers/{s}", .{ project, try requiredString(node.inputs, "location"), try requiredString(node.inputs, "name") }),
        .worker_pool => std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}/workerPools/{s}", .{ project, try requiredString(node.inputs, "location"), try requiredString(node.inputs, "name") }),
        .connection => std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}/connections/{s}", .{ project, try requiredString(node.inputs, "location"), try requiredString(node.inputs, "name") }),
    } catch return error.OutOfMemory;
}

fn validatePhysical(node: resource.ResourceNode, kind: Kind, physical: []const u8) ProviderError!void {
    if (std.mem.indexOfAny(u8, physical, "?# \t\r\n") != null) return error.InvalidConfiguration;
    if (kind == .trigger) {
        const prefix = try std.fmt.allocPrint(std.heap.page_allocator, "projects/{s}/locations/{s}/triggers/", .{ try requiredString(node.inputs, "project_id"), try requiredString(node.inputs, "location") });
        defer std.heap.page_allocator.free(prefix);
        if (!std.mem.startsWith(u8, physical, prefix) or physical.len == prefix.len) return error.InvalidConfiguration;
        return;
    }
    const expected = try physicalAlloc(std.heap.page_allocator, node, kind);
    defer std.heap.page_allocator.free(expected);
    if (!std.mem.eql(u8, expected, physical)) return error.InvalidConfiguration;
}

fn createPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    const project = try requiredString(node.inputs, "project_id");
    const location = try requiredString(node.inputs, "location");
    const name = try requiredString(node.inputs, "name");
    return switch (kind) {
        .trigger => std.fmt.allocPrint(allocator, "/v1/projects/{s}/locations/{s}/triggers", .{ project, location }),
        .worker_pool => std.fmt.allocPrint(allocator, "/v1/projects/{s}/locations/{s}/workerPools?workerPoolId={s}", .{ project, location, name }),
        .connection => std.fmt.allocPrint(allocator, "/v2/projects/{s}/locations/{s}/connections?connectionId={s}", .{ project, location, name }),
        .repository => std.fmt.allocPrint(allocator, "/v2/projects/{s}/locations/{s}/connections/{s}/repositories?repositoryId={s}", .{ project, location, try requiredString(node.inputs, "connection_name"), name }),
        else => return error.InvalidConfiguration,
    } catch return error.OutOfMemory;
}

fn readPathAlloc(allocator: std.mem.Allocator, kind: Kind, physical: []const u8) ProviderError![]const u8 {
    return std.fmt.allocPrint(allocator, "/{s}/{s}", .{ if (kind == .connection or kind == .repository) "v2" else "v1", physical }) catch return error.OutOfMemory;
}

fn updatePathAlloc(allocator: std.mem.Allocator, _: resource.ResourceNode, kind: Kind, physical: []const u8, etag: []const u8) ProviderError![]const u8 {
    const mask = switch (kind) {
        .trigger => "approvalConfig,build.options.pool,description,disabled,filename,ignoredFiles,includedFiles,repositoryEventConfig,serviceAccount,substitutions",
        .worker_pool => "annotations,displayName,privatePoolV1Config.workerConfig.diskSizeGb,privatePoolV1Config.workerConfig.enableNestedVirtualization,privatePoolV1Config.workerConfig.machineType",
        .connection => "annotations,disabled,githubConfig,githubEnterpriseConfig,gitlabConfig,bitbucketDataCenterConfig,bitbucketCloudConfig",
        .project_settings => "legacyRedirectionState,pullPercent",
        .vpcsc => "vpcscPolicy",
        .repository => return error.InvalidConfiguration,
    };
    const encoded = try percentEncodeAlloc(allocator, mask);
    defer allocator.free(encoded);
    const version = if (kind == .connection) "v2" else "v1";
    if (kind == .connection and etag.len != 0) return std.fmt.allocPrint(allocator, "/{s}/{s}?updateMask={s}&etag={s}", .{ version, physical, encoded, etag }) catch return error.OutOfMemory;
    return std.fmt.allocPrint(allocator, "/{s}/{s}?updateMask={s}", .{ version, physical, encoded }) catch return error.OutOfMemory;
}

fn deletePathAlloc(allocator: std.mem.Allocator, kind: Kind, physical: []const u8) ProviderError![]const u8 {
    const version = if (kind == .connection or kind == .repository) "v2" else "v1";
    return std.fmt.allocPrint(allocator, "/{s}/{s}", .{ version, physical }) catch return error.OutOfMemory;
}

fn connectionIdentityChanged(desired: value.Value, observed: value.Value) bool {
    const desired_config = valueObject(requiredValue(desired, "config") catch return true) orelse return true;
    const observed_config = valueObject(requiredValue(observed, "config") catch return true) orelse return true;
    for ([_][]const u8{ "kind", "host_uri", "workspace", "service_directory_service" }) |field| {
        const left = inputObjectString(desired_config, field) orelse "";
        const right = inputObjectString(observed_config, field) orelse "";
        if (!std.mem.eql(u8, left, right)) return true;
    }
    return false;
}

fn identityChanged(node: resource.ResourceNode, observed: *const provider_mod.ResourceResult, fields: []const []const u8) bool {
    for (fields) |field| {
        const left = requiredValue(node.inputs, field) catch return true;
        const right = requiredValue(observed.observed_inputs, field) catch return true;
        const left_json = left.canonicalJsonAlloc(std.heap.page_allocator) catch return true;
        defer std.heap.page_allocator.free(left_json);
        const right_json = right.canonicalJsonAlloc(std.heap.page_allocator) catch return true;
        defer std.heap.page_allocator.free(right_json);
        if (!std.mem.eql(u8, left_json, right_json)) return true;
    }
    return false;
}

fn outputString(result: provider_mod.ResourceResult, name: []const u8) ?[]const u8 {
    for (result.outputs) |item| if (std.mem.eql(u8, item.name, name)) return switch (item.value) {
        .string => |text| text,
        else => null,
    };
    return null;
}

fn requiredValue(inputs: value.Value, name: []const u8) ProviderError!value.Value {
    return switch (inputs) {
        .object => |fields| requiredObjectValue(fields, name),
        else => error.InvalidConfiguration,
    };
}
fn requiredString(inputs: value.Value, name: []const u8) ProviderError![]const u8 {
    return switch (try requiredValue(inputs, name)) {
        .string => |text| text,
        else => error.InvalidConfiguration,
    };
}
fn requiredInteger(inputs: value.Value, name: []const u8) ProviderError!i64 {
    return switch (try requiredValue(inputs, name)) {
        .integer => |number| number,
        else => error.InvalidConfiguration,
    };
}
fn requiredBoolean(inputs: value.Value, name: []const u8) ProviderError!bool {
    return switch (try requiredValue(inputs, name)) {
        .boolean => |flag| flag,
        else => error.InvalidConfiguration,
    };
}
fn requiredObjectValue(fields: []const value.Field, name: []const u8) ProviderError!value.Value {
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return error.InvalidConfiguration;
}
fn requiredObjectString(fields: []const value.Field, name: []const u8) ProviderError![]const u8 {
    return switch (try requiredObjectValue(fields, name)) {
        .string => |text| text,
        else => error.InvalidConfiguration,
    };
}
fn requiredObjectBoolean(fields: []const value.Field, name: []const u8) ProviderError!bool {
    return switch (try requiredObjectValue(fields, name)) {
        .boolean => |flag| flag,
        else => error.InvalidConfiguration,
    };
}
fn inputString(inputs: value.Value, name: []const u8) ?[]const u8 {
    return switch (requiredValue(inputs, name) catch return null) {
        .string => |text| text,
        else => null,
    };
}
fn inputObjectString(fields: []const value.Field, name: []const u8) ?[]const u8 {
    return switch (requiredObjectValue(fields, name) catch return null) {
        .string => |text| text,
        else => null,
    };
}
fn valueObject(input: value.Value) ?[]const value.Field {
    return switch (input) {
        .object => |fields| fields,
        else => null,
    };
}
fn resolveString(context: *provider_mod.OperationContext, input: value.Value) ProviderError![]const u8 {
    return switch (input) {
        .string => |text| text,
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

fn objectJson(arena: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    const fields = valueObject(input) orelse return error.InvalidConfiguration;
    var object = std.json.ObjectMap.empty;
    for (fields) |field| try object.put(arena, field.name, switch (field.value) {
        .string => |text| .{ .string = text },
        else => return error.InvalidConfiguration,
    });
    return .{ .object = object };
}
fn listJson(arena: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    const items = switch (input) {
        .list => |list| list,
        else => return error.InvalidConfiguration,
    };
    var array = std.json.Array.init(arena);
    for (items) |item| try array.append(switch (item) {
        .string => |text| .{ .string = text },
        else => return error.InvalidConfiguration,
    });
    return .{ .array = array };
}

fn copyOptionalString(arena: std.mem.Allocator, target: *std.json.ObjectMap, fields: []const value.Field, source: []const u8, destination: []const u8) ProviderError!void {
    const text = inputObjectString(fields, source) orelse return;
    if (text.len != 0) try target.put(arena, destination, .{ .string = text });
}
fn userCredential(arena: std.mem.Allocator, target: *std.json.ObjectMap, fields: []const value.Field, source: []const u8, destination: []const u8) ProviderError!void {
    const text = try requiredObjectString(fields, source);
    var credential = std.json.ObjectMap.empty;
    try credential.put(arena, "userTokenSecretVersion", .{ .string = text });
    try target.put(arena, destination, .{ .object = credential });
}
fn serviceDirectory(arena: std.mem.Allocator, target: *std.json.ObjectMap, fields: []const value.Field) ProviderError!void {
    const text = inputObjectString(fields, "service_directory_service") orelse return;
    if (text.len == 0) return;
    var config = std.json.ObjectMap.empty;
    try config.put(arena, "service", .{ .string = text });
    try target.put(arena, "serviceDirectoryConfig", .{ .object = config });
}

fn overlayConnection(allocator: std.mem.Allocator, observed: *value.Value, root: std.json.ObjectMap) ProviderError!void {
    const candidates = [_]struct { field: []const u8, kind: []const u8 }{
        .{ .field = "githubConfig", .kind = "github" },
        .{ .field = "githubEnterpriseConfig", .kind = "github_enterprise" },
        .{ .field = "gitlabConfig", .kind = "gitlab" },
        .{ .field = "bitbucketDataCenterConfig", .kind = "bitbucket_data_center" },
        .{ .field = "bitbucketCloudConfig", .kind = "bitbucket_cloud" },
    };
    for (candidates) |candidate| {
        const remote_value = root.get(candidate.field) orelse continue;
        const remote = jsonObject(remote_value) orelse return error.ProviderBug;
        const config = mutableValue(observed, "config") orelse return error.ProviderBug;
        try setString(allocator, config, "kind", candidate.kind);
        try setOptionalRemoteString(allocator, config, "host_uri", remote, "hostUri");
        try setOptionalRemoteString(allocator, config, "workspace", remote, "workspace");
        try setOptionalRemoteString(allocator, config, "app_id", remote, "appId");
        try setOptionalRemoteString(allocator, config, "app_slug", remote, "appSlug");
        try setOptionalRemoteString(allocator, config, "app_installation_id", remote, "appInstallationId");
        try setOptionalRemoteString(allocator, config, "ssl_ca", remote, "sslCa");
        if (jsonObject(remote.get("serviceDirectoryConfig") orelse .{ .object = std.json.ObjectMap.empty })) |directory| {
            try setOptionalRemoteString(allocator, config, "service_directory_service", directory, "service");
        }
        return;
    }
    return error.ProviderBug;
}

fn setOptionalRemoteString(allocator: std.mem.Allocator, inputs: *value.Value, local_name: []const u8, remote: std.json.ObjectMap, remote_name: []const u8) ProviderError!void {
    if (jsonString(remote.get(remote_name))) |text| try setString(allocator, inputs, local_name, text);
}

fn mutableValue(inputs: *value.Value, name: []const u8) ?*value.Value {
    if (inputs.* != .object) return null;
    const fields: []value.Field = @constCast(inputs.object);
    for (fields) |*field| if (std.mem.eql(u8, field.name, name)) return &field.value;
    return null;
}

fn setJsonValue(allocator: std.mem.Allocator, inputs: *value.Value, name: []const u8, json: std.json.Value) ProviderError!void {
    var converted = try jsonToValueAlloc(allocator, json);
    defer converted.deinit(allocator);
    return setValue(allocator, inputs, name, converted);
}

fn setResolvedString(context: *provider_mod.OperationContext, inputs: *value.Value, name: []const u8, remote: []const u8) ProviderError!void {
    const current = try requiredValue(inputs.*, name);
    if (current == .output_ref and std.mem.eql(u8, try context.resolveOutputString(current.output_ref), remote)) return;
    return setString(context.allocator, inputs, name, remote);
}

fn setValue(allocator: std.mem.Allocator, inputs: *value.Value, name: []const u8, replacement: value.Value) ProviderError!void {
    const target = mutableValue(inputs, name) orelse return error.ProviderBug;
    const owned = value.Value.initOwned(allocator, replacement) catch |err| switch (err) {
        error.DuplicateField => return error.ProviderBug,
        error.OutOfMemory => return error.OutOfMemory,
    };
    target.deinit(allocator);
    target.* = owned;
}

fn jsonToValueAlloc(allocator: std.mem.Allocator, json: std.json.Value) ProviderError!value.Value {
    return switch (json) {
        .string => |text| ownValue(allocator, .{ .string = text }),
        .integer => |number| ownValue(allocator, .{ .integer = number }),
        .bool => |flag| ownValue(allocator, .{ .boolean = flag }),
        .array => |array| blk: {
            const items = try allocator.alloc(value.Value, array.items.len);
            defer allocator.free(items);
            var initialized: usize = 0;
            defer for (items[0..initialized]) |*item| item.deinit(allocator);
            for (array.items, 0..) |item, index| {
                items[index] = try jsonToValueAlloc(allocator, item);
                initialized += 1;
            }
            break :blk try ownValue(allocator, .{ .list = items });
        },
        .object => |object| blk: {
            const fields = try allocator.alloc(value.Field, object.count());
            defer allocator.free(fields);
            var iterator = object.iterator();
            var index: usize = 0;
            defer for (fields[0..index]) |*field| field.value.deinit(allocator);
            while (iterator.next()) |entry| : (index += 1) fields[index] = .{ .name = entry.key_ptr.*, .value = try jsonToValueAlloc(allocator, entry.value_ptr.*) };
            break :blk try ownValue(allocator, .{ .object = fields });
        },
        else => error.ProviderBug,
    };
}

fn ownValue(allocator: std.mem.Allocator, input: value.Value) ProviderError!value.Value {
    return value.Value.initOwned(allocator, input) catch |err| switch (err) {
        error.DuplicateField => error.ProviderBug,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn setString(allocator: std.mem.Allocator, inputs: *value.Value, name: []const u8, text: []const u8) ProviderError!void {
    const fields: []value.Field = @constCast(inputs.object);
    for (fields) |*field| if (std.mem.eql(u8, field.name, name)) {
        const replacement = allocator.dupe(u8, text) catch return error.OutOfMemory;
        field.value.deinit(allocator);
        field.value = .{ .string = replacement };
        return;
    };
}
fn setBoolean(inputs: *value.Value, name: []const u8, flag: bool) ProviderError!void {
    const fields: []value.Field = @constCast(inputs.object);
    for (fields) |*field| if (std.mem.eql(u8, field.name, name)) {
        field.value = .{ .boolean = flag };
        return;
    };
}
fn setInteger(inputs: *value.Value, name: []const u8, number: i64) ProviderError!void {
    const fields: []value.Field = @constCast(inputs.object);
    for (fields) |*field| if (std.mem.eql(u8, field.name, name)) {
        field.value = .{ .integer = number };
        return;
    };
}

fn jsonObject(input: std.json.Value) ?std.json.ObjectMap {
    return switch (input) {
        .object => |object| object,
        else => null,
    };
}
fn jsonArray(input: ?std.json.Value) ?std.json.Array {
    return switch (input orelse return null) {
        .array => |array| array,
        else => null,
    };
}
fn jsonString(input: ?std.json.Value) ?[]const u8 {
    return switch (input orelse return null) {
        .string => |text| text,
        else => null,
    };
}
fn jsonBoolean(input: ?std.json.Value) ?bool {
    return switch (input orelse return null) {
        .bool => |flag| flag,
        else => null,
    };
}
fn jsonInteger(input: ?std.json.Value) ?i64 {
    return switch (input orelse return null) {
        .integer => |number| number,
        else => null,
    };
}

fn jsonIntegerOrString(input: ?std.json.Value) ?i64 {
    return switch (input orelse return null) {
        .integer => |number| number,
        .string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
}

fn percentEncodeAlloc(allocator: std.mem.Allocator, input: []const u8) ProviderError![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (input) |byte| if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') try output.append(allocator, byte) else {
        try output.append(allocator, '%');
        try output.append(allocator, hex[byte >> 4]);
        try output.append(allocator, hex[byte & 0x0f]);
    };
    return output.toOwnedSlice(allocator) catch return error.OutOfMemory;
}
