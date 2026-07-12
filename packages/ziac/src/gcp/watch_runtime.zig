const std = @import("std");
const client_mod = @import("client.zig");
const operation = @import("operation.zig");
const provider = @import("../provider.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");
const watch_deploy = @import("../watch_deploy.zig");

pub const InitError = std.mem.Allocator.Error || error{
    MissingWatchService,
    InvalidWatchService,
    WatchProjectMismatch,
};

const ServiceTarget = struct {
    project_id: []const u8,
    region: []const u8,
    name: []const u8,
    prior_revision: ?[]const u8 = null,
    candidate_revision: ?[]const u8 = null,
    etag: ?[]const u8 = null,

    fn deinit(self: *ServiceTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.project_id);
        allocator.free(self.region);
        allocator.free(self.name);
        if (self.prior_revision) |revision| allocator.free(revision);
        if (self.candidate_revision) |revision| allocator.free(revision);
        if (self.etag) |etag| allocator.free(etag);
        self.* = undefined;
    }

    fn clearRollout(self: *ServiceTarget, allocator: std.mem.Allocator) void {
        if (self.prior_revision) |revision| allocator.free(revision);
        if (self.candidate_revision) |revision| allocator.free(revision);
        if (self.etag) |etag| allocator.free(etag);
        self.prior_revision = null;
        self.candidate_revision = null;
        self.etag = null;
    }
};

pub const LiveRuntime = struct {
    allocator: std.mem.Allocator,
    client: *client_mod.Client,
    context: *provider.OperationContext,
    targets: []ServiceTarget,
    operation_policy: operation.Policy = .{},

    pub fn initAlloc(
        client: *client_mod.Client,
        context: *provider.OperationContext,
        graph: *const resource.ResourceGraph,
    ) InitError!LiveRuntime {
        return initForProjectAlloc(client, context, graph, null);
    }

    pub fn initForProjectAlloc(
        client: *client_mod.Client,
        context: *provider.OperationContext,
        graph: *const resource.ResourceGraph,
        expected_project: ?[]const u8,
    ) InitError!LiveRuntime {
        var count: usize = 0;
        for (graph.resources.items) |node| {
            if (std.mem.eql(u8, node.type_name, "gcp.run.Service")) count += 1;
        }
        if (count == 0) return error.MissingWatchService;
        const targets = try context.allocator.alloc(ServiceTarget, count);
        errdefer context.allocator.free(targets);
        var initialized: usize = 0;
        errdefer for (targets[0..initialized]) |*target| target.deinit(context.allocator);
        for (graph.resources.items) |node| {
            if (!std.mem.eql(u8, node.type_name, "gcp.run.Service")) continue;
            const project_id = inputString(node.inputs, "project_id") orelse return error.InvalidWatchService;
            const region = inputString(node.inputs, "region") orelse return error.InvalidWatchService;
            const name = inputString(node.inputs, "name") orelse return error.InvalidWatchService;
            if (expected_project) |expected| {
                if (!std.mem.eql(u8, expected, project_id)) return error.WatchProjectMismatch;
            }
            targets[initialized] = .{
                .project_id = try context.allocator.dupe(u8, project_id),
                .region = context.allocator.dupe(u8, region) catch |err| {
                    context.allocator.free(targets[initialized].project_id);
                    return err;
                },
                .name = undefined,
            };
            targets[initialized].name = context.allocator.dupe(u8, name) catch |err| {
                context.allocator.free(targets[initialized].project_id);
                context.allocator.free(targets[initialized].region);
                return err;
            };
            initialized += 1;
        }
        return .{
            .allocator = context.allocator,
            .client = client,
            .context = context,
            .targets = targets,
        };
    }

    pub fn deinit(self: *LiveRuntime) void {
        for (self.targets) |*target| target.deinit(self.allocator);
        self.allocator.free(self.targets);
        self.* = undefined;
    }

    pub fn runtime(self: *LiveRuntime) watch_deploy.Runtime {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn regionCount(self: *const LiveRuntime) usize {
        return self.targets.len;
    }

    fn pushImage(raw: *anyopaque, image_ref: []const u8) !void {
        _ = raw;
        if (!isImmutableImage(image_ref)) return error.MutableWatchImage;
    }

    fn createRevision(raw: *anyopaque, image_ref: []const u8, no_traffic: bool) !void {
        const self: *LiveRuntime = @ptrCast(@alignCast(raw));
        if (!no_traffic) return error.TrafficMustRemainZero;
        for (self.targets) |*target| {
            target.clearRollout(self.allocator);
            var current = try self.getServiceAlloc(target.*);
            defer current.deinit(self.allocator);
            const body = try revisionBodyAlloc(self.allocator, &current, image_ref);
            defer self.allocator.free(body);
            var completed = try self.patchAndWaitAlloc(target.*, "template%2Ctraffic", body);
            defer completed.deinit(self.allocator);
            if (!std.mem.eql(u8, completed.image, image_ref)) return error.WatchRevisionImageMismatch;
            target.prior_revision = try self.allocator.dupe(u8, current.ready_revision);
            errdefer {
                self.allocator.free(target.prior_revision.?);
                target.prior_revision = null;
            }
            target.candidate_revision = try self.allocator.dupe(u8, completed.ready_revision);
            target.etag = try self.allocator.dupe(u8, completed.etag);
        }
    }

    fn waitReady(raw: *anyopaque, image_ref: []const u8) !bool {
        const self: *LiveRuntime = @ptrCast(@alignCast(raw));
        for (self.targets) |*target| {
            const candidate = target.candidate_revision orelse return error.WatchRevisionMissing;
            var observed = try self.getServiceAlloc(target.*);
            defer observed.deinit(self.allocator);
            if (observed.reconciling or !std.mem.eql(u8, observed.condition, "CONDITION_SUCCEEDED") or
                !std.mem.eql(u8, observed.created_revision, candidate) or
                !std.mem.eql(u8, observed.ready_revision, candidate) or
                !std.mem.eql(u8, observed.image, image_ref)) return false;
            if (target.etag) |etag| self.allocator.free(etag);
            target.etag = try self.allocator.dupe(u8, observed.etag);
        }
        return true;
    }

    fn promoteTraffic(raw: *anyopaque, image_ref: []const u8) !void {
        const self: *LiveRuntime = @ptrCast(@alignCast(raw));
        for (self.targets) |*target| {
            const candidate = target.candidate_revision orelse return error.WatchRevisionMissing;
            const etag = target.etag orelse return error.WatchRevisionMissing;
            const body = try trafficBodyAlloc(self.allocator, target.*, etag, candidate);
            defer self.allocator.free(body);
            var completed = try self.patchAndWaitAlloc(target.*, "traffic", body);
            defer completed.deinit(self.allocator);
            if (completed.reconciling or !std.mem.eql(u8, completed.condition, "CONDITION_SUCCEEDED") or
                !std.mem.eql(u8, completed.ready_revision, candidate) or
                !std.mem.eql(u8, completed.image, image_ref)) return error.WatchPromotionUnhealthy;
        }
    }

    fn nowMillis(raw: *anyopaque) u64 {
        const self: *LiveRuntime = @ptrCast(@alignCast(raw));
        return self.context.nowMillis();
    }

    fn getServiceAlloc(self: *LiveRuntime, target: ServiceTarget) !ServiceSnapshot {
        const path = try servicePathAlloc(self.allocator, target);
        defer self.allocator.free(path);
        var response = try self.request(.{ .api = .run, .method = "GET", .path = path });
        defer response.deinit(self.allocator);
        return ServiceSnapshot.parseAlloc(self.allocator, response.body);
    }

    fn patchAndWaitAlloc(
        self: *LiveRuntime,
        target: ServiceTarget,
        update_mask: []const u8,
        body: []const u8,
    ) !ServiceSnapshot {
        const path = try std.fmt.allocPrint(
            self.allocator,
            "/v2/projects/{s}/locations/{s}/services/{s}?updateMask={s}",
            .{ target.project_id, target.region, target.name, update_mask },
        );
        defer self.allocator.free(path);
        var response = try self.request(.{ .api = .run, .method = "PATCH", .path = path, .body = body });
        defer response.deinit(self.allocator);
        const operation_name = try operationNameAlloc(self.allocator, response.body);
        defer self.allocator.free(operation_name);
        const base = try std.fmt.allocPrint(self.allocator, "{s}/v2", .{std.mem.trimEnd(u8, self.client.endpoints.run, "/")});
        defer self.allocator.free(base);
        var operation_target = try operation.Target.genericAlloc(self.allocator, base, operation_name);
        defer operation_target.deinit(self.allocator);
        var completed = try operation.waitAlloc(self.client, self.context, operation_target, self.operation_policy);
        defer completed.deinit(self.allocator);
        return serviceFromOperationAlloc(self.allocator, completed.payload);
    }

    fn request(self: *LiveRuntime, request_value: client_mod.Request) !@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(self.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(self.context, request_value, &diagnostic);
    }
};

const vtable: watch_deploy.Runtime.VTable = .{
    .push_image = LiveRuntime.pushImage,
    .create_revision = LiveRuntime.createRevision,
    .wait_ready = LiveRuntime.waitReady,
    .promote_traffic = LiveRuntime.promoteTraffic,
    .now_millis = LiveRuntime.nowMillis,
};

const ServiceSnapshot = struct {
    name: []const u8,
    etag: []const u8,
    created_revision: []const u8,
    ready_revision: []const u8,
    image: []const u8,
    condition: []const u8,
    reconciling: bool,
    template_json: []const u8,

    fn parseAlloc(allocator: std.mem.Allocator, body: []const u8) !ServiceSnapshot {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidWatchServiceResponse;
        defer parsed.deinit();
        const root = jsonObject(parsed.value) orelse return error.InvalidWatchServiceResponse;
        const template_value = root.get("template") orelse return error.InvalidWatchServiceResponse;
        const template = jsonObject(template_value) orelse return error.InvalidWatchServiceResponse;
        const containers = jsonArray(template.get("containers")) orelse return error.InvalidWatchServiceResponse;
        if (containers.items.len == 0) return error.InvalidWatchServiceResponse;
        const container = jsonObject(containers.items[0]) orelse return error.InvalidWatchServiceResponse;
        const terminal = jsonObject(root.get("terminalCondition") orelse return error.InvalidWatchServiceResponse) orelse return error.InvalidWatchServiceResponse;
        return .{
            .name = try dupeJsonString(allocator, root.get("name")),
            .etag = try dupeJsonString(allocator, root.get("etag")),
            .created_revision = try dupeJsonString(allocator, root.get("latestCreatedRevision")),
            .ready_revision = try dupeJsonString(allocator, root.get("latestReadyRevision")),
            .image = try dupeJsonString(allocator, container.get("image")),
            .condition = try dupeJsonString(allocator, terminal.get("state")),
            .reconciling = jsonBool(root.get("reconciling")) orelse return error.InvalidWatchServiceResponse,
            .template_json = try std.json.Stringify.valueAlloc(allocator, template_value, .{}),
        };
    }

    fn deinit(self: *ServiceSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.etag);
        allocator.free(self.created_revision);
        allocator.free(self.ready_revision);
        allocator.free(self.image);
        allocator.free(self.condition);
        allocator.free(self.template_json);
        self.* = undefined;
    }
};

fn revisionBodyAlloc(allocator: std.mem.Allocator, current: *const ServiceSnapshot, image_ref: []const u8) ![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, current.template_json, .{}) catch return error.InvalidWatchServiceResponse;
    defer parsed.deinit();
    const template = jsonObjectPtr(&parsed.value) orelse return error.InvalidWatchServiceResponse;
    const containers_value = template.getPtr("containers") orelse return error.InvalidWatchServiceResponse;
    const containers = jsonArrayPtr(containers_value) orelse return error.InvalidWatchServiceResponse;
    if (containers.items.len == 0) return error.InvalidWatchServiceResponse;
    const container = jsonObjectPtr(&containers.items[0]) orelse return error.InvalidWatchServiceResponse;
    const image = container.getPtr("image") orelse return error.InvalidWatchServiceResponse;
    image.* = .{ .string = image_ref };
    const template_json = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
    defer allocator.free(template_json);
    const name_json = try std.json.Stringify.valueAlloc(allocator, current.name, .{});
    defer allocator.free(name_json);
    const etag_json = try std.json.Stringify.valueAlloc(allocator, current.etag, .{});
    defer allocator.free(etag_json);
    const revision_json = try std.json.Stringify.valueAlloc(allocator, current.ready_revision, .{});
    defer allocator.free(revision_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"name\":{s},\"etag\":{s},\"template\":{s},\"traffic\":[{{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION\",\"revision\":{s},\"percent\":100}}]}}",
        .{ name_json, etag_json, template_json, revision_json },
    );
}

fn trafficBodyAlloc(
    allocator: std.mem.Allocator,
    target: ServiceTarget,
    etag: []const u8,
    revision: []const u8,
) ![]const u8 {
    const name = try serviceNameAlloc(allocator, target);
    defer allocator.free(name);
    const name_json = try std.json.Stringify.valueAlloc(allocator, name, .{});
    defer allocator.free(name_json);
    const etag_json = try std.json.Stringify.valueAlloc(allocator, etag, .{});
    defer allocator.free(etag_json);
    const revision_json = try std.json.Stringify.valueAlloc(allocator, revision, .{});
    defer allocator.free(revision_json);
    return std.fmt.allocPrint(
        allocator,
        "{{\"name\":{s},\"etag\":{s},\"traffic\":[{{\"type\":\"TRAFFIC_TARGET_ALLOCATION_TYPE_REVISION\",\"revision\":{s},\"percent\":100}}]}}",
        .{ name_json, etag_json, revision_json },
    );
}

fn operationNameAlloc(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidWatchOperation;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.InvalidWatchOperation;
    return dupeJsonString(allocator, root.get("name"));
}

fn serviceFromOperationAlloc(allocator: std.mem.Allocator, body: []const u8) !ServiceSnapshot {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidWatchOperation;
    defer parsed.deinit();
    const root = jsonObject(parsed.value) orelse return error.InvalidWatchOperation;
    const response = root.get("response") orelse return error.InvalidWatchOperation;
    const service_json = try std.json.Stringify.valueAlloc(allocator, response, .{});
    defer allocator.free(service_json);
    return ServiceSnapshot.parseAlloc(allocator, service_json);
}

fn servicePathAlloc(allocator: std.mem.Allocator, target: ServiceTarget) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "/v2/projects/{s}/locations/{s}/services/{s}",
        .{ target.project_id, target.region, target.name },
    );
}

fn serviceNameAlloc(allocator: std.mem.Allocator, target: ServiceTarget) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "projects/{s}/locations/{s}/services/{s}",
        .{ target.project_id, target.region, target.name },
    );
}

fn inputString(inputs: value.Value, name: []const u8) ?[]const u8 {
    const fields = switch (inputs) {
        .object => |object| object,
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

fn dupeJsonString(allocator: std.mem.Allocator, maybe_value: ?std.json.Value) ![]const u8 {
    const text = if (maybe_value) |present| switch (present) {
        .string => |string| string,
        else => return error.InvalidWatchServiceResponse,
    } else return error.InvalidWatchServiceResponse;
    return allocator.dupe(u8, text);
}

fn jsonObject(json_value: std.json.Value) ?std.json.ObjectMap {
    return switch (json_value) {
        .object => |object| object,
        else => null,
    };
}

fn jsonObjectPtr(json_value: *std.json.Value) ?*std.json.ObjectMap {
    return switch (json_value.*) {
        .object => |*object| object,
        else => null,
    };
}

fn jsonArray(maybe_value: ?std.json.Value) ?std.json.Array {
    const present = maybe_value orelse return null;
    return switch (present) {
        .array => |array| array,
        else => null,
    };
}

fn jsonArrayPtr(json_value: *std.json.Value) ?*std.json.Array {
    return switch (json_value.*) {
        .array => |*array| array,
        else => null,
    };
}

fn jsonBool(maybe_value: ?std.json.Value) ?bool {
    const present = maybe_value orelse return null;
    return switch (present) {
        .bool => |boolean| boolean,
        else => null,
    };
}

fn isImmutableImage(image: []const u8) bool {
    const marker = "@sha256:";
    const index = std.mem.lastIndexOf(u8, image, marker) orelse return false;
    if (index == 0 or image.len != index + marker.len + 64) return false;
    for (image[index + marker.len ..]) |character| if (!std.ascii.isHex(character)) return false;
    return true;
}
