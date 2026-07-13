const std = @import("std");
const zstd = @import("zigeffect_std");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const secret = @import("../secret.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;
const instance_type = "gcp.sql.Instance";
const replica_type = "gcp.sql.ReadReplica";
const database_type = "gcp.sql.Database";
const user_type = "gcp.sql.User";
const certificate_type = "gcp.sql.ClientCertificate";

const Kind = enum { instance, replica, database, user, certificate };

const OperationStart = struct {
    name: []const u8,
    done: bool,
};

pub const Handler = struct {
    client: *client_mod.Client,
    operation_policy: operation.Policy,
    secret_source: ?secret.SecretSource,

    pub fn read(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_override: ?[]const u8) ProviderError!provider_mod.ReadResult {
        const kind = try kindFor(node);
        if (context.operation_handle) |handle| try self.waitOperation(context, node, handle);
        const physical = try physicalForReadAlloc(context, node, kind, physical_override) orelse return .absent;
        defer context.allocator.free(physical);
        const path = try getPathAlloc(context.allocator, node, kind, physical);
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .sql_admin, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try resultFromJson(context, node, kind, physical, response.body, null) };
    }

    pub fn diff(context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        const kind = try kindFor(node);
        if (kind == .user and std.mem.eql(u8, try requiredString(node.inputs, "user_type"), "BUILT_IN")) {
            if (context.state) |store| if (store.get(node.id)) |record| {
                const desired_hash = std.fmt.bytesToHex(node.inputs_hash, .lower);
                if (!std.mem.eql(u8, record.desired_hash, desired_hash[0..])) {
                    return provider_mod.DiffResult.init(context.allocator, .update, &.{"Cloud SQL write-only password reference or user configuration changed"});
                }
            };
        }
        if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash)) return provider_mod.DiffResult.init(context.allocator, .noop, &.{});
        const replacement = switch (kind) {
            .instance => changedAny(node.inputs, observed.observed_inputs, &.{ "project_id", "instance_id", "database_version", "region", "allocated_ip_range" }) or removingPrivateNetwork(node, observed),
            .replica => changedAny(node.inputs, observed.observed_inputs, &.{ "project_id", "instance_id", "database_version", "region", "primary_instance_id" }) or removingPrivateNetwork(node, observed),
            .database => changedAny(node.inputs, observed.observed_inputs, &.{ "project_id", "instance_id", "name" }),
            .user => changedAny(node.inputs, observed.observed_inputs, &.{ "project_id", "instance_id", "name", "host", "user_type" }),
            .certificate => true,
        };
        return provider_mod.DiffResult.init(
            context.allocator,
            if (replacement) .replace else .update,
            if (replacement) &.{"Cloud SQL immutable identity, region, allocated range or certificate differs"} else &.{"Cloud SQL mutable configuration differs"},
        );
    }

    pub fn create(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        const kind = try kindFor(node);
        if (kind == .certificate) return self.createCertificate(context, node);
        const path = try createPathAlloc(context.allocator, node, kind);
        defer context.allocator.free(path);
        const body = try bodyAlloc(self, context, node, kind, null);
        defer secureFree(context.allocator, body, kind == .user);
        var response = try self.request(context, .{ .api = .sql_admin, .method = "POST", .path = path, .body = body });
        defer response.deinit(context.allocator);
        const started = try operationStartAlloc(context.allocator, response.body, false);
        defer context.allocator.free(started.name);
        const physical = try deterministicPhysicalAlloc(context.allocator, node, kind);
        defer context.allocator.free(physical);
        return pendingResult(context, node, physical, started.name, &.{});
    }

    pub fn update(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) ProviderError!provider_mod.ResourceResult {
        const kind = try kindFor(node);
        if (kind == .certificate) return error.InvalidConfiguration;
        const path = try updatePathAlloc(context.allocator, node, kind, observed.physical_id);
        defer context.allocator.free(path);
        const body = try bodyAlloc(self, context, node, kind, observed);
        defer secureFree(context.allocator, body, kind == .user);
        var response = try self.request(context, .{ .api = .sql_admin, .method = if (kind == .instance or kind == .replica or kind == .database) "PATCH" else "PUT", .path = path, .body = body });
        defer response.deinit(context.allocator);
        const started = try operationStartAlloc(context.allocator, response.body, false);
        defer context.allocator.free(started.name);
        return pendingResult(context, node, observed.physical_id, started.name, observed.outputs);
    }

    pub fn delete(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!void {
        const kind = try kindFor(node);
        const physical = try canonicalPhysicalAlloc(context.allocator, node, kind, physical_id);
        defer context.allocator.free(physical);
        try validatePhysical(context.allocator, node, kind, physical);
        const path = try deletePathAlloc(context.allocator, node, kind, physical);
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .sql_admin, .method = "DELETE", .path = path }) catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer response.deinit(context.allocator);
        const started = try operationStartAlloc(context.allocator, response.body, false);
        defer context.allocator.free(started.name);
        if (!started.done) try self.waitOperation(context, node, started.name);
    }

    pub fn importResource(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!provider_mod.ResourceResult {
        const kind = try kindFor(node);
        const physical = try canonicalPhysicalAlloc(context.allocator, node, kind, physical_id);
        defer context.allocator.free(physical);
        try validatePhysical(context.allocator, node, kind, physical);
        const prior = context.operation_handle;
        context.operation_handle = null;
        defer context.operation_handle = prior;
        var read_result = try self.read(context, node, physical);
        defer read_result.deinit();
        return switch (read_result) {
            .absent => error.NotFound,
            .present => |present| present.clone(context.allocator),
        };
    }

    fn createCertificate(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        const path = try createPathAlloc(context.allocator, node, .certificate);
        defer context.allocator.free(path);
        const body = try bodyAlloc(self, context, node, .certificate, null);
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .sql_admin, .method = "POST", .path = path, .body = body });
        defer {
            std.crypto.secureZero(u8, @constCast(response.body));
            response.deinit(context.allocator);
        }
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const root = jsonObject(parsed.value) orelse return error.ProviderBug;
        const client_cert = jsonObject(root.get("clientCert") orelse return error.ProviderBug) orelse return error.ProviderBug;
        const cert_info = jsonObject(client_cert.get("certInfo") orelse return error.ProviderBug) orelse return error.ProviderBug;
        const private_key = jsonString(client_cert.get("certPrivateKey")) orelse return error.ProviderBug;
        defer std.crypto.secureZero(u8, @constCast(private_key));
        const fingerprint = jsonString(cert_info.get("sha1Fingerprint")) orelse return error.ProviderBug;
        const started = try operationStartAlloc(context.allocator, response.body, true);
        defer context.allocator.free(started.name);
        const secret_resource = try resolveStringInput(context, node.inputs, "private_key_secret");
        const secret_reference = self.persistSecretVersion(context, secret_resource, private_key) catch |err| {
            const recovery = std.fmt.allocPrint(context.allocator, "Cloud SQL client certificate exists; recover or delete fingerprint={s} operation={s}", .{ fingerprint, started.name }) catch null;
            defer if (recovery) |message| context.allocator.free(message);
            context.recordDiagnostic(.{
                .category = .remote_operation,
                .service = "sqladmin.googleapis.com",
                .request_id = started.name,
                .message = recovery orelse "Cloud SQL client certificate exists but private-key persistence failed",
            });
            return err;
        };
        defer if (secret_reference.version) |version| context.allocator.free(version);
        const physical = try std.fmt.allocPrint(context.allocator, "projects/{s}/instances/{s}/sslCerts/{s}", .{
            try requiredString(node.inputs, "project_id"),
            try requiredString(node.inputs, "instance_id"),
            fingerprint,
        });
        defer context.allocator.free(physical);
        const outputs = [_]state.StateOutput{
            .{ .name = "sha1_fingerprint", .value = .{ .string = fingerprint } },
            .{ .name = "certificate", .value = .{ .string = jsonString(cert_info.get("cert")) orelse "" } },
            .{ .name = "expiration_time", .value = .{ .string = jsonString(cert_info.get("expirationTime")) orelse "" } },
            .{ .name = "private_key_version", .value = .{ .secret_ref = secret_reference } },
        };
        return pendingResult(context, node, physical, started.name, &outputs);
    }

    fn persistSecretVersion(self: Handler, context: *provider_mod.OperationContext, secret_resource: []const u8, private_key: []const u8) ProviderError!value.SecretReference {
        if (!validSecretResource(secret_resource)) return error.InvalidConfiguration;
        const encoded_size = std.base64.standard.Encoder.calcSize(private_key.len);
        const encoded = context.allocator.alloc(u8, encoded_size) catch return error.OutOfMemory;
        defer secureFree(context.allocator, encoded, true);
        _ = std.base64.standard.Encoder.encode(encoded, private_key);
        const body = std.json.Stringify.valueAlloc(context.allocator, .{ .payload = .{ .data = encoded } }, .{}) catch return error.OutOfMemory;
        defer secureFree(context.allocator, body, true);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}:addVersion", .{secret_resource});
        defer context.allocator.free(path);
        var response = try self.request(context, .{ .api = .secret_manager, .method = "POST", .path = path, .body = body });
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const name = jsonString((jsonObject(parsed.value) orelse return error.ProviderBug).get("name")) orelse return error.ProviderBug;
        const marker = "/versions/";
        const index = std.mem.lastIndexOf(u8, name, marker) orelse return error.ProviderBug;
        if (!std.mem.eql(u8, name[0..index], secret_resource) or name.len == index + marker.len) return error.ProviderBug;
        const version = context.allocator.dupe(u8, name[index + marker.len ..]) catch return error.OutOfMemory;
        return .{
            .provider = "gcp-secret-manager",
            .resource = secret_resource,
            .version = version,
        };
    }

    fn waitOperation(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, handle: []const u8) ProviderError!void {
        var target = operation.Target.cloudSqlAlloc(
            context.allocator,
            self.client.endpoints.sql_admin,
            try requiredString(node.inputs, "project_id"),
            handle,
        ) catch return error.OutOfMemory;
        defer target.deinit(context.allocator);
        var completed = try operation.waitAlloc(self.client, context, target, self.operation_policy);
        defer completed.deinit(context.allocator);
    }

    fn request(self: Handler, context: *provider_mod.OperationContext, request_value: client_mod.Request) ProviderError!zstd.Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, request_value, &diagnostic);
    }
};

pub fn supports(node: resource.ResourceNode) bool {
    return std.mem.eql(u8, node.type_name, instance_type) or
        std.mem.eql(u8, node.type_name, replica_type) or
        std.mem.eql(u8, node.type_name, database_type) or
        std.mem.eql(u8, node.type_name, user_type) or
        std.mem.eql(u8, node.type_name, certificate_type);
}

fn kindFor(node: resource.ResourceNode) ProviderError!Kind {
    if (std.mem.eql(u8, node.type_name, instance_type)) return .instance;
    if (std.mem.eql(u8, node.type_name, replica_type)) return .replica;
    if (std.mem.eql(u8, node.type_name, database_type)) return .database;
    if (std.mem.eql(u8, node.type_name, user_type)) return .user;
    if (std.mem.eql(u8, node.type_name, certificate_type)) return .certificate;
    return error.InvalidConfiguration;
}

fn createPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    const project = try requiredString(node.inputs, "project_id");
    return switch (kind) {
        .instance, .replica => std.fmt.allocPrint(allocator, "/v1/projects/{s}/instances", .{project}),
        .database => std.fmt.allocPrint(allocator, "/v1/projects/{s}/instances/{s}/databases", .{ project, try requiredString(node.inputs, "instance_id") }),
        .user => std.fmt.allocPrint(allocator, "/v1/projects/{s}/instances/{s}/users", .{ project, try requiredString(node.inputs, "instance_id") }),
        .certificate => std.fmt.allocPrint(allocator, "/v1/projects/{s}/instances/{s}/sslCerts", .{ project, try requiredString(node.inputs, "instance_id") }),
    } catch error.OutOfMemory;
}

fn getPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind, physical: []const u8) ProviderError![]const u8 {
    const project = try requiredString(node.inputs, "project_id");
    const instance = try requiredString(node.inputs, "instance_id");
    return switch (kind) {
        .instance, .replica => std.fmt.allocPrint(allocator, "/v1/projects/{s}/instances/{s}", .{ project, instance }),
        .database => std.fmt.allocPrint(allocator, "/v1/projects/{s}/instances/{s}/databases/{s}", .{ project, instance, try requiredString(node.inputs, "name") }),
        .user => userGetPathAlloc(allocator, node),
        .certificate => std.fmt.allocPrint(allocator, "/v1/projects/{s}/instances/{s}/sslCerts/{s}", .{ project, instance, std.fs.path.basename(physical) }),
    } catch error.OutOfMemory;
}

fn updatePathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind, physical: []const u8) ProviderError![]const u8 {
    return switch (kind) {
        .instance, .replica, .database => getPathAlloc(allocator, node, kind, physical),
        .user => userMutationPathAlloc(allocator, node),
        .certificate => error.InvalidConfiguration,
    };
}

fn deletePathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind, physical: []const u8) ProviderError![]const u8 {
    return switch (kind) {
        .instance, .replica, .database, .certificate => getPathAlloc(allocator, node, kind, physical),
        .user => userMutationPathAlloc(allocator, node),
    };
}

fn userGetPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]const u8 {
    const encoded_name = try percentEncodeAlloc(allocator, try requiredString(node.inputs, "name"));
    defer allocator.free(encoded_name);
    const encoded_host = try percentEncodeAlloc(allocator, try requiredString(node.inputs, "host"));
    defer allocator.free(encoded_host);
    return std.fmt.allocPrint(allocator, "/v1/projects/{s}/instances/{s}/users/{s}?host={s}", .{
        try requiredString(node.inputs, "project_id"),
        try requiredString(node.inputs, "instance_id"),
        encoded_name,
        encoded_host,
    }) catch error.OutOfMemory;
}

fn userMutationPathAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]const u8 {
    const encoded_name = try percentEncodeAlloc(allocator, try requiredString(node.inputs, "name"));
    defer allocator.free(encoded_name);
    const encoded_host = try percentEncodeAlloc(allocator, try requiredString(node.inputs, "host"));
    defer allocator.free(encoded_host);
    return std.fmt.allocPrint(allocator, "/v1/projects/{s}/instances/{s}/users?name={s}&host={s}", .{
        try requiredString(node.inputs, "project_id"),
        try requiredString(node.inputs, "instance_id"),
        encoded_name,
        encoded_host,
    }) catch error.OutOfMemory;
}

fn bodyAlloc(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, observed: ?*const provider_mod.ResourceResult) ProviderError![]u8 {
    if (kind == .user) return userBodyAlloc(self, context, node);
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var body: std.json.ObjectMap = .empty;
    switch (kind) {
        .instance, .replica => {
            try body.put(arena, "name", .{ .string = try requiredString(node.inputs, "instance_id") });
            try body.put(arena, "databaseVersion", .{ .string = try requiredString(node.inputs, "database_version") });
            try body.put(arena, "region", .{ .string = try requiredString(node.inputs, "region") });
            try body.put(arena, "deletionProtectionEnabled", .{ .bool = try requiredBool(node.inputs, "deletion_protection") });
            const primary = try resolveStringInput(context, node.inputs, "primary_instance_id");
            if (kind == .replica) try body.put(arena, "masterInstanceName", .{ .string = primary });
            var settings: std.json.ObjectMap = .empty;
            if (observed) |present| {
                const version = outputInteger(present, "settings_version") orelse return error.Conflict;
                const version_text = try std.fmt.allocPrint(arena, "{d}", .{version});
                try settings.put(arena, "settingsVersion", .{ .string = version_text });
            }
            try settings.put(arena, "tier", .{ .string = try requiredString(node.inputs, "tier") });
            try settings.put(arena, "edition", .{ .string = try requiredString(node.inputs, "edition") });
            try settings.put(arena, "availabilityType", .{ .string = try requiredString(node.inputs, "availability") });
            try settings.put(arena, "dataDiskType", .{ .string = try requiredString(node.inputs, "disk_type") });
            const disk_size = try std.fmt.allocPrint(arena, "{d}", .{try requiredInteger(node.inputs, "disk_size_gb")});
            try settings.put(arena, "dataDiskSizeGb", .{ .string = disk_size });
            try settings.put(arena, "storageAutoResize", .{ .bool = try requiredBool(node.inputs, "disk_autoresize") });
            try settings.put(arena, "connectorEnforcement", .{ .string = try requiredString(node.inputs, "connector_enforcement") });
            try settings.put(arena, "databaseFlags", try databaseFlagsJson(arena, node.inputs));
            var maintenance: std.json.ObjectMap = .empty;
            try maintenance.put(arena, "day", .{ .integer = try requiredInteger(node.inputs, "maintenance_day") });
            try maintenance.put(arena, "hour", .{ .integer = try requiredInteger(node.inputs, "maintenance_hour") });
            try maintenance.put(arena, "updateTrack", .{ .string = try requiredString(node.inputs, "maintenance_update_track") });
            try settings.put(arena, "maintenanceWindow", .{ .object = maintenance });
            var backup: std.json.ObjectMap = .empty;
            try backup.put(arena, "enabled", .{ .bool = try requiredBool(node.inputs, "backup_enabled") });
            try backup.put(arena, "startTime", .{ .string = try requiredString(node.inputs, "backup_start_time") });
            try backup.put(arena, "pointInTimeRecoveryEnabled", .{ .bool = try requiredBool(node.inputs, "point_in_time_recovery") });
            var retention: std.json.ObjectMap = .empty;
            try retention.put(arena, "retainedBackups", .{ .integer = try requiredInteger(node.inputs, "retained_backups") });
            try backup.put(arena, "backupRetentionSettings", .{ .object = retention });
            try backup.put(arena, "transactionLogRetentionDays", .{ .integer = try requiredInteger(node.inputs, "transaction_log_retention_days") });
            try settings.put(arena, "backupConfiguration", .{ .object = backup });
            var ip: std.json.ObjectMap = .empty;
            try ip.put(arena, "ipv4Enabled", .{ .bool = try requiredBool(node.inputs, "ipv4_enabled") });
            const network = try requiredString(node.inputs, "private_network");
            if (network.len > 0) try ip.put(arena, "privateNetwork", .{ .string = network });
            const allocated = try requiredString(node.inputs, "allocated_ip_range");
            if (allocated.len > 0) try ip.put(arena, "allocatedIpRange", .{ .string = allocated });
            try ip.put(arena, "enablePrivatePathForGoogleCloudServices", .{ .bool = try requiredBool(node.inputs, "enable_private_path") });
            try ip.put(arena, "sslMode", .{ .string = try requiredString(node.inputs, "ssl_mode") });
            try ip.put(arena, "authorizedNetworks", try authorizedNetworksJson(arena, node.inputs));
            try settings.put(arena, "ipConfiguration", .{ .object = ip });
            try body.put(arena, "settings", .{ .object = settings });
        },
        .database => {
            try body.put(arena, "name", .{ .string = try requiredString(node.inputs, "name") });
            try body.put(arena, "instance", .{ .string = try requiredString(node.inputs, "instance_id") });
            try body.put(arena, "project", .{ .string = try requiredString(node.inputs, "project_id") });
            try body.put(arena, "charset", .{ .string = try requiredString(node.inputs, "charset") });
            try body.put(arena, "collation", .{ .string = try requiredString(node.inputs, "collation") });
        },
        .user => unreachable,
        .certificate => try body.put(arena, "commonName", .{ .string = try requiredString(node.inputs, "common_name") }),
    }
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = body }, .{}) catch error.OutOfMemory;
}

fn userBodyAlloc(self: Handler, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError![]u8 {
    const database_user_type = try requiredString(node.inputs, "user_type");
    if (!std.mem.eql(u8, database_user_type, "BUILT_IN")) {
        return std.json.Stringify.valueAlloc(context.allocator, .{
            .name = try requiredString(node.inputs, "name"),
            .instance = try requiredString(node.inputs, "instance_id"),
            .project = try requiredString(node.inputs, "project_id"),
            .host = try requiredString(node.inputs, "host"),
            .type = database_user_type,
        }, .{}) catch error.OutOfMemory;
    }
    const source = self.secret_source orelse return error.InvalidConfiguration;
    const reference = try resolveSecretInput(context, node.inputs, "password");
    var password = try source.resolve(context, context.allocator, reference);
    defer password.deinit();
    return std.json.Stringify.valueAlloc(context.allocator, .{
        .name = try requiredString(node.inputs, "name"),
        .instance = try requiredString(node.inputs, "instance_id"),
        .project = try requiredString(node.inputs, "project_id"),
        .host = try requiredString(node.inputs, "host"),
        .type = database_user_type,
        .password = password.bytes,
    }, .{}) catch error.OutOfMemory;
}

fn resultFromJson(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    kind: Kind,
    physical: []const u8,
    body: []const u8,
    certificate_secret: ?value.SecretReference,
) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    try validatePhysical(context.allocator, node, kind, physical);
    var normalized = try normalizedInputsAlloc(context, node, kind, root);
    defer normalized.deinit(context.allocator);
    return switch (kind) {
        .instance, .replica => instanceResult(context, node, physical, root, normalized),
        .database => provider_mod.ResourceResult.init(context.allocator, physical, normalized, &.{
            .{ .name = "name", .value = .{ .string = jsonString(root.get("name")) orelse try requiredString(node.inputs, "name") } },
            .{ .name = "self_link", .value = .{ .string = jsonString(root.get("selfLink")) orelse "" } },
        }, null),
        .user => provider_mod.ResourceResult.init(context.allocator, physical, normalized, &.{
            .{ .name = "name", .value = .{ .string = jsonString(root.get("name")) orelse try requiredString(node.inputs, "name") } },
            .{ .name = "user_type", .value = .{ .string = jsonString(root.get("type")) orelse try requiredString(node.inputs, "user_type") } },
        }, null),
        .certificate => blk: {
            const reference = certificate_secret orelse try certificateSecretReference(context, node);
            break :blk provider_mod.ResourceResult.init(context.allocator, physical, normalized, &.{
                .{ .name = "sha1_fingerprint", .value = .{ .string = jsonString(root.get("sha1Fingerprint")) orelse std.fs.path.basename(physical) } },
                .{ .name = "certificate", .value = .{ .string = jsonString(root.get("cert")) orelse "" } },
                .{ .name = "expiration_time", .value = .{ .string = jsonString(root.get("expirationTime")) orelse "" } },
                .{ .name = "private_key_version", .value = .{ .secret_ref = reference } },
            }, null);
        },
    };
}

fn instanceResult(context: *provider_mod.OperationContext, node: resource.ResourceNode, physical: []const u8, root: std.json.ObjectMap, normalized: value.Value) ProviderError!provider_mod.ResourceResult {
    const settings = jsonObject(root.get("settings") orelse return error.ProviderBug) orelse return error.ProviderBug;
    const settings_version = try jsonInteger(settings.get("settingsVersion")) orelse return error.ProviderBug;
    const addresses = jsonArray(root.get("ipAddresses"));
    return provider_mod.ResourceResult.init(context.allocator, physical, normalized, &.{
        .{ .name = "name", .value = .{ .string = physical } },
        .{ .name = "instance_id", .value = .{ .string = jsonString(root.get("name")) orelse try requiredString(node.inputs, "instance_id") } },
        .{ .name = "connection_name", .value = .{ .string = jsonString(root.get("connectionName")) orelse "" } },
        .{ .name = "private_ip", .value = .{ .string = addressOfType(addresses, "PRIVATE") } },
        .{ .name = "public_ip", .value = .{ .string = addressOfType(addresses, "PRIMARY") } },
        .{ .name = "server_ca_cert", .value = .{ .string = nestedString(root, "serverCaCert", "cert") } },
        .{ .name = "state", .value = .{ .string = jsonString(root.get("state")) orelse "" } },
        .{ .name = "settings_version", .value = .{ .integer = settings_version } },
    }, null);
}

fn normalizedInputsAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, root: std.json.ObjectMap) ProviderError!value.Value {
    return switch (kind) {
        .instance, .replica => normalizedInstanceInputsAlloc(context, node, root),
        .database => normalizedDatabaseInputsAlloc(context, node, root),
        .user => normalizedUserInputsAlloc(context, node, root),
        .certificate => node.inputs.clone(context.allocator) catch |err| switch (err) {
            error.DuplicateField => error.ProviderBug,
            error.OutOfMemory => error.OutOfMemory,
        },
    };
}

fn normalizedInstanceInputsAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, root: std.json.ObjectMap) ProviderError!value.Value {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const settings = jsonObject(root.get("settings") orelse return error.ProviderBug) orelse return error.ProviderBug;
    const backup = jsonObject(settings.get("backupConfiguration") orelse return error.ProviderBug) orelse return error.ProviderBug;
    const retention = jsonObject(backup.get("backupRetentionSettings") orelse return error.ProviderBug) orelse return error.ProviderBug;
    const ip = jsonObject(settings.get("ipConfiguration") orelse return error.ProviderBug) orelse return error.ProviderBug;
    const maintenance = if (settings.get("maintenanceWindow")) |present| jsonObject(present) else null;
    const flags = try flagsValueFromJson(arena, settings.get("databaseFlags"));
    const networks = try networksValueFromJson(arena, ip.get("authorizedNetworks"));
    const fields = [_]value.Field{
        .{ .name = "allocated_ip_range", .value = .{ .string = jsonString(ip.get("allocatedIpRange")) orelse try requiredString(node.inputs, "allocated_ip_range") } },
        .{ .name = "authorized_networks", .value = networks },
        .{ .name = "availability", .value = .{ .string = jsonString(settings.get("availabilityType")) orelse try requiredString(node.inputs, "availability") } },
        .{ .name = "backup_enabled", .value = .{ .boolean = jsonBool(backup.get("enabled")) orelse false } },
        .{ .name = "backup_start_time", .value = .{ .string = jsonString(backup.get("startTime")) orelse "" } },
        .{ .name = "connector_enforcement", .value = .{ .string = jsonString(settings.get("connectorEnforcement")) orelse "NOT_REQUIRED" } },
        .{ .name = "database_flags", .value = flags },
        .{ .name = "database_version", .value = .{ .string = jsonString(root.get("databaseVersion")) orelse try requiredString(node.inputs, "database_version") } },
        .{ .name = "deletion_protection", .value = .{ .boolean = jsonBool(root.get("deletionProtectionEnabled")) orelse false } },
        .{ .name = "disk_autoresize", .value = .{ .boolean = jsonBool(settings.get("storageAutoResize")) orelse false } },
        .{ .name = "disk_size_gb", .value = .{ .integer = (try jsonInteger(settings.get("dataDiskSizeGb"))) orelse 0 } },
        .{ .name = "disk_type", .value = .{ .string = jsonString(settings.get("dataDiskType")) orelse "" } },
        .{ .name = "edition", .value = .{ .string = jsonString(settings.get("edition")) orelse "ENTERPRISE" } },
        .{ .name = "enable_private_path", .value = .{ .boolean = jsonBool(ip.get("enablePrivatePathForGoogleCloudServices")) orelse false } },
        .{ .name = "instance_id", .value = .{ .string = jsonString(root.get("name")) orelse try requiredString(node.inputs, "instance_id") } },
        .{ .name = "ipv4_enabled", .value = .{ .boolean = jsonBool(ip.get("ipv4Enabled")) orelse false } },
        .{ .name = "maintenance_day", .value = .{ .integer = (try jsonInteger(if (maintenance) |present| present.get("day") else null)) orelse try requiredInteger(node.inputs, "maintenance_day") } },
        .{ .name = "maintenance_hour", .value = .{ .integer = (try jsonInteger(if (maintenance) |present| present.get("hour") else null)) orelse try requiredInteger(node.inputs, "maintenance_hour") } },
        .{ .name = "maintenance_update_track", .value = .{ .string = if (maintenance) |present| jsonString(present.get("updateTrack")) orelse try requiredString(node.inputs, "maintenance_update_track") else try requiredString(node.inputs, "maintenance_update_track") } },
        .{ .name = "point_in_time_recovery", .value = .{ .boolean = jsonBool(backup.get("pointInTimeRecoveryEnabled")) orelse false } },
        .{ .name = "primary_instance_id", .value = inputValue(node.inputs, "primary_instance_id") orelse .{ .string = jsonString(root.get("masterInstanceName")) orelse "" } },
        .{ .name = "private_network", .value = .{ .string = jsonString(ip.get("privateNetwork")) orelse "" } },
        .{ .name = "project_id", .value = .{ .string = try requiredString(node.inputs, "project_id") } },
        .{ .name = "region", .value = .{ .string = jsonString(root.get("region")) orelse try requiredString(node.inputs, "region") } },
        .{ .name = "retained_backups", .value = .{ .integer = (try jsonInteger(retention.get("retainedBackups"))) orelse 0 } },
        .{ .name = "ssl_mode", .value = .{ .string = jsonString(ip.get("sslMode")) orelse "ALLOW_UNENCRYPTED_AND_ENCRYPTED" } },
        .{ .name = "tier", .value = .{ .string = jsonString(settings.get("tier")) orelse "" } },
        .{ .name = "transaction_log_retention_days", .value = .{ .integer = (try jsonInteger(backup.get("transactionLogRetentionDays"))) orelse 0 } },
    };
    return value.Value.initOwned(context.allocator, .{ .object = &fields }) catch |err| switch (err) {
        error.DuplicateField => error.ProviderBug,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn normalizedDatabaseInputsAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, root: std.json.ObjectMap) ProviderError!value.Value {
    const fields = [_]value.Field{
        .{ .name = "charset", .value = .{ .string = jsonString(root.get("charset")) orelse "" } },
        .{ .name = "collation", .value = .{ .string = jsonString(root.get("collation")) orelse "" } },
        .{ .name = "instance_id", .value = .{ .string = jsonString(root.get("instance")) orelse try requiredString(node.inputs, "instance_id") } },
        .{ .name = "name", .value = .{ .string = jsonString(root.get("name")) orelse try requiredString(node.inputs, "name") } },
        .{ .name = "project_id", .value = .{ .string = jsonString(root.get("project")) orelse try requiredString(node.inputs, "project_id") } },
    };
    return value.Value.initOwned(context.allocator, .{ .object = &fields }) catch |err| switch (err) {
        error.DuplicateField => error.ProviderBug,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn normalizedUserInputsAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, root: std.json.ObjectMap) ProviderError!value.Value {
    const fields = [_]value.Field{
        .{ .name = "host", .value = .{ .string = jsonString(root.get("host")) orelse try requiredString(node.inputs, "host") } },
        .{ .name = "instance_id", .value = .{ .string = jsonString(root.get("instance")) orelse try requiredString(node.inputs, "instance_id") } },
        .{ .name = "name", .value = .{ .string = jsonString(root.get("name")) orelse try requiredString(node.inputs, "name") } },
        .{ .name = "password", .value = inputValue(node.inputs, "password") orelse .{ .string = "" } },
        .{ .name = "project_id", .value = .{ .string = jsonString(root.get("project")) orelse try requiredString(node.inputs, "project_id") } },
        .{ .name = "user_type", .value = .{ .string = jsonString(root.get("type")) orelse try requiredString(node.inputs, "user_type") } },
    };
    return value.Value.initOwned(context.allocator, .{ .object = &fields }) catch |err| switch (err) {
        error.DuplicateField => error.ProviderBug,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn pendingResult(context: *provider_mod.OperationContext, node: resource.ResourceNode, physical: []const u8, handle: []const u8, outputs: []const state.StateOutput) ProviderError!provider_mod.ResourceResult {
    var result = try provider_mod.ResourceResult.init(context.allocator, physical, node.inputs, outputs, handle);
    result.completed = false;
    return result;
}

fn physicalForReadAlloc(context: *provider_mod.OperationContext, node: resource.ResourceNode, kind: Kind, override: ?[]const u8) ProviderError!?[]const u8 {
    if (override) |provided| return @as(?[]const u8, try canonicalPhysicalAlloc(context.allocator, node, kind, provided));
    if (context.physical_id) |provided| return @as(?[]const u8, try canonicalPhysicalAlloc(context.allocator, node, kind, provided));
    if (kind == .certificate) return null;
    return @as(?[]const u8, try deterministicPhysicalAlloc(context.allocator, node, kind));
}

fn deterministicPhysicalAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind) ProviderError![]const u8 {
    const project = try requiredString(node.inputs, "project_id");
    const instance = try requiredString(node.inputs, "instance_id");
    return switch (kind) {
        .instance, .replica => std.fmt.allocPrint(allocator, "projects/{s}/instances/{s}", .{ project, instance }),
        .database => std.fmt.allocPrint(allocator, "projects/{s}/instances/{s}/databases/{s}", .{ project, instance, try requiredString(node.inputs, "name") }),
        .user => std.fmt.allocPrint(allocator, "projects/{s}/instances/{s}/users/{s}/{s}", .{ project, instance, try requiredString(node.inputs, "user_type"), try requiredString(node.inputs, "name") }),
        .certificate => error.InvalidConfiguration,
    } catch error.OutOfMemory;
}

fn canonicalPhysicalAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind, physical: []const u8) ProviderError![]const u8 {
    const without_prefix = if (std.mem.startsWith(u8, physical, "//sqladmin.googleapis.com/")) physical["//sqladmin.googleapis.com/".len..] else physical;
    if ((kind == .instance or kind == .replica) and std.mem.indexOfScalar(u8, without_prefix, '/') == null) {
        return std.fmt.allocPrint(allocator, "projects/{s}/instances/{s}", .{ try requiredString(node.inputs, "project_id"), without_prefix }) catch error.OutOfMemory;
    }
    return allocator.dupe(u8, without_prefix) catch error.OutOfMemory;
}

fn validatePhysical(allocator: std.mem.Allocator, node: resource.ResourceNode, kind: Kind, physical: []const u8) ProviderError!void {
    if (kind != .certificate) {
        const expected = try deterministicPhysicalAlloc(allocator, node, kind);
        defer allocator.free(expected);
        if (!std.mem.eql(u8, expected, physical)) return error.InvalidConfiguration;
        return;
    }
    const prefix = try std.fmt.allocPrint(allocator, "projects/{s}/instances/{s}/sslCerts/", .{
        try requiredString(node.inputs, "project_id"),
        try requiredString(node.inputs, "instance_id"),
    });
    defer allocator.free(prefix);
    if (!std.mem.startsWith(u8, physical, prefix) or physical.len == prefix.len) return error.InvalidConfiguration;
}

fn operationStartAlloc(allocator: std.mem.Allocator, body: []const u8, nested: bool) ProviderError!OperationStart {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.ProviderBug;
    const operation_object = if (nested) jsonObject(root.get("operation") orelse return error.ProviderBug) orelse return error.ProviderBug else root;
    const name = allocator.dupe(u8, jsonString(operation_object.get("name")) orelse return error.ProviderBug) catch return error.OutOfMemory;
    return .{ .name = name, .done = if (jsonString(operation_object.get("status"))) |status| std.mem.eql(u8, status, "DONE") else false };
}

fn certificateSecretReference(context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!value.SecretReference {
    if (context.state) |store| if (store.get(node.id)) |record| for (record.outputs) |present| {
        if (std.mem.eql(u8, present.name, "private_key_version") and present.value == .secret_ref) return present.value.secret_ref;
    };
    const version = try requiredString(node.inputs, "imported_private_key_version");
    if (version.len == 0) return error.InvalidConfiguration;
    return .{
        .provider = "gcp-secret-manager",
        .resource = try resolveStringInput(context, node.inputs, "private_key_secret"),
        .version = version,
    };
}

fn databaseFlagsJson(allocator: std.mem.Allocator, inputs: value.Value) ProviderError!std.json.Value {
    const list = try requiredList(inputs, "database_flags");
    var array = std.json.Array.init(allocator);
    for (list) |item| {
        var object: std.json.ObjectMap = .empty;
        try object.put(allocator, "name", .{ .string = try requiredString(item, "name") });
        try object.put(allocator, "value", .{ .string = try requiredString(item, "value") });
        try array.append(.{ .object = object });
    }
    return .{ .array = array };
}

fn authorizedNetworksJson(allocator: std.mem.Allocator, inputs: value.Value) ProviderError!std.json.Value {
    const list = try requiredList(inputs, "authorized_networks");
    var array = std.json.Array.init(allocator);
    for (list) |item| {
        var object: std.json.ObjectMap = .empty;
        try object.put(allocator, "name", .{ .string = try requiredString(item, "name") });
        try object.put(allocator, "value", .{ .string = try requiredString(item, "value") });
        const expiration = try requiredString(item, "expiration_time");
        if (expiration.len > 0) try object.put(allocator, "expirationTime", .{ .string = expiration });
        try array.append(.{ .object = object });
    }
    return .{ .array = array };
}

fn flagsValueFromJson(allocator: std.mem.Allocator, json: ?std.json.Value) ProviderError!value.Value {
    const source = jsonArray(json);
    const items = try allocator.alloc(value.Value, source.len);
    for (source, 0..) |item, index| {
        const object = jsonObject(item) orelse return error.ProviderBug;
        const fields = try allocator.alloc(value.Field, 2);
        fields[0] = .{ .name = "name", .value = .{ .string = jsonString(object.get("name")) orelse return error.ProviderBug } };
        fields[1] = .{ .name = "value", .value = .{ .string = jsonString(object.get("value")) orelse return error.ProviderBug } };
        items[index] = .{ .object = fields };
    }
    std.mem.sort(value.Value, items, {}, lessThanFlagValue);
    return .{ .list = items };
}

fn networksValueFromJson(allocator: std.mem.Allocator, json: ?std.json.Value) ProviderError!value.Value {
    const source = jsonArray(json);
    const items = try allocator.alloc(value.Value, source.len);
    for (source, 0..) |item, index| {
        const object = jsonObject(item) orelse return error.ProviderBug;
        const fields = try allocator.alloc(value.Field, 3);
        fields[0] = .{ .name = "expiration_time", .value = .{ .string = jsonString(object.get("expirationTime")) orelse "" } };
        fields[1] = .{ .name = "name", .value = .{ .string = jsonString(object.get("name")) orelse "" } };
        fields[2] = .{ .name = "value", .value = .{ .string = jsonString(object.get("value")) orelse return error.ProviderBug } };
        items[index] = .{ .object = fields };
    }
    std.mem.sort(value.Value, items, {}, lessThanNetworkValue);
    return .{ .list = items };
}

fn lessThanFlagValue(_: void, left: value.Value, right: value.Value) bool {
    return std.mem.order(u8, valueObjectString(left, "name"), valueObjectString(right, "name")) == .lt;
}

fn lessThanNetworkValue(_: void, left: value.Value, right: value.Value) bool {
    const value_order = std.mem.order(u8, valueObjectString(left, "value"), valueObjectString(right, "value"));
    if (value_order != .eq) return value_order == .lt;
    return std.mem.order(u8, valueObjectString(left, "name"), valueObjectString(right, "name")) == .lt;
}

fn valueObjectString(candidate: value.Value, name: []const u8) []const u8 {
    const fields = switch (candidate) {
        .object => |present| present,
        else => return "",
    };
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return switch (field.value) {
        .string => |text| text,
        else => "",
    };
    return "";
}

fn resolveStringInput(context: *provider_mod.OperationContext, inputs: value.Value, name: []const u8) ProviderError![]const u8 {
    return switch (inputValue(inputs, name) orelse return error.InvalidConfiguration) {
        .string => |text| text,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}

fn resolveSecretInput(context: *provider_mod.OperationContext, inputs: value.Value, name: []const u8) ProviderError!value.SecretReference {
    return switch (inputValue(inputs, name) orelse return error.InvalidConfiguration) {
        .secret_ref => |reference| reference,
        .output_ref => |reference| context.resolveOutputSecret(reference),
        else => error.InvalidConfiguration,
    };
}

fn requiredString(inputs: value.Value, name: []const u8) ProviderError![]const u8 {
    return switch (inputValue(inputs, name) orelse return error.InvalidConfiguration) {
        .string => |text| text,
        else => error.InvalidConfiguration,
    };
}

fn requiredBool(inputs: value.Value, name: []const u8) ProviderError!bool {
    return switch (inputValue(inputs, name) orelse return error.InvalidConfiguration) {
        .boolean => |present| present,
        else => error.InvalidConfiguration,
    };
}

fn requiredInteger(inputs: value.Value, name: []const u8) ProviderError!i64 {
    return switch (inputValue(inputs, name) orelse return error.InvalidConfiguration) {
        .integer => |present| present,
        else => error.InvalidConfiguration,
    };
}

fn requiredList(inputs: value.Value, name: []const u8) ProviderError![]const value.Value {
    return switch (inputValue(inputs, name) orelse return error.InvalidConfiguration) {
        .list => |present| present,
        else => error.InvalidConfiguration,
    };
}

fn inputValue(inputs: value.Value, name: []const u8) ?value.Value {
    const fields = switch (inputs) {
        .object => |present| present,
        else => return null,
    };
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return null;
}

fn outputInteger(result: *const provider_mod.ResourceResult, name: []const u8) ?i64 {
    for (result.outputs) |present| if (std.mem.eql(u8, present.name, name)) return switch (present.value) {
        .integer => |integer| integer,
        else => null,
    };
    return null;
}

fn changedAny(desired: value.Value, observed: value.Value, fields: []const []const u8) bool {
    for (fields) |field| if (!valuesEqual(inputValue(desired, field), inputValue(observed, field))) return true;
    return false;
}

fn removingPrivateNetwork(node: resource.ResourceNode, observed: *const provider_mod.ResourceResult) bool {
    const desired = inputValue(node.inputs, "private_network") orelse return false;
    const present = inputValue(observed.observed_inputs, "private_network") orelse return false;
    return desired == .string and present == .string and desired.string.len == 0 and present.string.len > 0;
}

fn valuesEqual(left: ?value.Value, right: ?value.Value) bool {
    const lhs = left orelse return right == null;
    const rhs = right orelse return false;
    var left_hash = lhs.sha256(std.heap.page_allocator) catch return false;
    var right_hash = rhs.sha256(std.heap.page_allocator) catch return false;
    return std.mem.eql(u8, &left_hash, &right_hash);
}

fn jsonObject(candidate: std.json.Value) ?std.json.ObjectMap {
    return switch (candidate) {
        .object => |object| object,
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
        .bool => |boolean| boolean,
        else => null,
    };
}

fn jsonArray(candidate: ?std.json.Value) []const std.json.Value {
    const present = candidate orelse return &.{};
    return switch (present) {
        .array => |array| array.items,
        else => &.{},
    };
}

fn jsonInteger(candidate: ?std.json.Value) ProviderError!?i64 {
    const present = candidate orelse return null;
    return switch (present) {
        .integer => |integer| integer,
        .string => |text| std.fmt.parseInt(i64, text, 10) catch return error.ProviderBug,
        else => error.ProviderBug,
    };
}

fn addressOfType(addresses: []const std.json.Value, expected: []const u8) []const u8 {
    for (addresses) |address| {
        const object = jsonObject(address) orelse continue;
        const kind = jsonString(object.get("type")) orelse continue;
        if (std.mem.eql(u8, kind, expected)) return jsonString(object.get("ipAddress")) orelse "";
    }
    return "";
}

fn nestedString(root: std.json.ObjectMap, object_name: []const u8, field_name: []const u8) []const u8 {
    const object = jsonObject(root.get(object_name) orelse return "") orelse return "";
    return jsonString(object.get(field_name)) orelse "";
}

fn percentEncodeAlloc(allocator: std.mem.Allocator, input: []const u8) ProviderError![]u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (input) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try output.append(allocator, byte);
        } else {
            try output.appendSlice(allocator, &.{ '%', hex[byte >> 4], hex[byte & 0x0f] });
        }
    }
    return output.toOwnedSlice(allocator) catch error.OutOfMemory;
}

fn validSecretResource(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "projects/") and std.mem.indexOf(u8, name, "/secrets/") != null and std.mem.indexOfAny(u8, name, "\n\r\x00") == null;
}

fn secureFree(allocator: std.mem.Allocator, bytes: []u8, sensitive: bool) void {
    if (sensitive) std.crypto.secureZero(u8, bytes);
    allocator.free(bytes);
}
