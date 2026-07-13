const std = @import("std");
const client_mod = @import("client.zig");
const provider_mod = @import("../provider.zig");

const ProviderError = provider_mod.ProviderError;

pub const Target = union(enum) {
    project: []const u8,
    folder: []const u8,
    organization: []const u8,
    service_account: []const u8,

    pub fn forProject(id: []const u8) Target {
        return .{ .project = id };
    }

    pub fn forFolder(id: []const u8) Target {
        return .{ .folder = id };
    }

    pub fn forOrganization(id: []const u8) Target {
        return .{ .organization = id };
    }

    pub fn serviceAccount(resource_name: []const u8) Target {
        return .{ .service_account = resource_name };
    }
};

pub const PermissionReport = struct {
    granted: []const []const u8,
    missing: []const []const u8,

    pub fn deinit(self: *PermissionReport, allocator: std.mem.Allocator) void {
        freeStrings(allocator, self.granted);
        freeStrings(allocator, self.missing);
        self.* = undefined;
    }

    pub fn hasGranted(self: PermissionReport, permission: []const u8) bool {
        return contains(self.granted, permission);
    }

    pub fn hasMissing(self: PermissionReport, permission: []const u8) bool {
        return contains(self.missing, permission);
    }
};

pub const LivePermissionPreflight = struct {
    client: *client_mod.Client,

    pub fn init(client: *client_mod.Client) LivePermissionPreflight {
        return .{ .client = client };
    }

    pub fn testResource(
        self: *LivePermissionPreflight,
        context: *provider_mod.OperationContext,
        target: Target,
        permissions: []const []const u8,
    ) ProviderError!PermissionReport {
        try context.checkActive();
        const canonical = try canonicalPermissionsAlloc(context.allocator, permissions);
        defer freeStrings(context.allocator, canonical);
        const path = try targetPathAlloc(context.allocator, target);
        defer context.allocator.free(path);
        const body = std.json.Stringify.valueAlloc(context.allocator, .{ .permissions = canonical }, .{}) catch return error.OutOfMemory;
        defer context.allocator.free(body);
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        var response = try self.client.requestJsonAlloc(context, .{
            .api = targetApi(target),
            .method = "POST",
            .path = path,
            .body = body,
        }, &diagnostic);
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |object| object,
            else => return error.ProviderBug,
        };
        const granted_values = if (root.get("permissions")) |entry| switch (entry) {
            .array => |array| array.items,
            else => return error.ProviderBug,
        } else &.{};
        var granted: std.ArrayList([]const u8) = .empty;
        errdefer deinitList(context.allocator, &granted);
        var missing: std.ArrayList([]const u8) = .empty;
        errdefer deinitList(context.allocator, &missing);
        for (canonical) |permission| {
            var found = false;
            for (granted_values) |entry| {
                const text = switch (entry) {
                    .string => |value| value,
                    else => return error.ProviderBug,
                };
                if (std.mem.eql(u8, text, permission)) {
                    found = true;
                    break;
                }
            }
            if (found) try appendOwned(context.allocator, &granted, permission) else try appendOwned(context.allocator, &missing, permission);
        }
        const owned_granted = try granted.toOwnedSlice(context.allocator);
        errdefer freeStrings(context.allocator, owned_granted);
        return .{
            .granted = owned_granted,
            .missing = try missing.toOwnedSlice(context.allocator),
        };
    }
};

fn targetApi(target: Target) client_mod.Api {
    return switch (target) {
        .project, .folder, .organization => .resource_manager,
        .service_account => .iam,
    };
}

fn targetPathAlloc(allocator: std.mem.Allocator, target: Target) ProviderError![]const u8 {
    return switch (target) {
        .project => |id| std.fmt.allocPrint(allocator, "/v3/projects/{s}:testIamPermissions", .{id}),
        .folder => |id| std.fmt.allocPrint(allocator, "/v3/folders/{s}:testIamPermissions", .{id}),
        .organization => |id| std.fmt.allocPrint(allocator, "/v3/organizations/{s}:testIamPermissions", .{id}),
        .service_account => |name| std.fmt.allocPrint(allocator, "/v1/{s}:testIamPermissions", .{name}),
    } catch error.OutOfMemory;
}

fn canonicalPermissionsAlloc(allocator: std.mem.Allocator, permissions: []const []const u8) ProviderError![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer deinitList(allocator, &list);
    for (permissions) |permission| {
        if (permission.len == 0) return error.InvalidConfiguration;
        if (!contains(list.items, permission)) try appendOwned(allocator, &list, permission);
    }
    std.mem.sort([]const u8, list.items, {}, lessThan);
    return list.toOwnedSlice(allocator);
}

fn appendOwned(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), text: []const u8) std.mem.Allocator.Error!void {
    const owned = try allocator.dupe(u8, text);
    errdefer allocator.free(owned);
    try list.append(allocator, owned);
}

fn contains(strings: []const []const u8, expected: []const u8) bool {
    for (strings) |text| if (std.mem.eql(u8, text, expected)) return true;
    return false;
}

fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn deinitList(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8)) void {
    for (list.items) |text| allocator.free(text);
    list.deinit(allocator);
}

fn freeStrings(allocator: std.mem.Allocator, strings: []const []const u8) void {
    for (strings) |text| allocator.free(text);
    allocator.free(strings);
}
