const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const AuthKind = enum {
    oidc,
    oauth,
};

pub const JobArgs = struct {
    name: []const u8,
    location: ?[]const u8 = null,
    description: []const u8 = "",
    schedule: []const u8,
    time_zone: []const u8 = "Etc/UTC",
    service_url: output.Output([]const u8, .public),
    path: []const u8,
    service_account: []const u8,
    auth_kind: AuthKind = .oidc,
    oauth_scope: []const u8 = "https://www.googleapis.com/auth/cloud-platform",
    body_json: []const u8 = "{}",
    attempt_deadline_seconds: u16 = 900,
};

pub const Job = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    state: Outputs.State.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: JobArgs) !Job {
        try provider.validate();
        const location = args.location orelse provider.primary_region;
        try validateToken(args.name, 1, 500, "-_");
        try validateToken(location, 1, 64, "-");
        if (args.schedule.len == 0 or args.schedule.len > 128 or std.mem.indexOfAny(u8, args.schedule, "\x00\r\n") != null) return error.InvalidSchedule;
        if (!std.mem.eql(u8, args.time_zone, "Etc/UTC")) return error.InvalidTimeZone;
        if (args.path.len < 2 or args.path[0] != '/' or std.mem.indexOfAny(u8, args.path, "\x00\r\n?#") != null) return error.InvalidPath;
        if (!validServiceAccount(args.service_account, provider.project_id)) return error.InvalidServiceAccount;
        if (args.attempt_deadline_seconds < 15 or args.attempt_deadline_seconds > 1800) return error.InvalidDeadline;
        if (args.description.len > 500 or std.mem.indexOfScalar(u8, args.description, 0) != null) return error.InvalidDescription;
        if (args.auth_kind == .oauth and (!std.mem.startsWith(u8, args.oauth_scope, "https://www.googleapis.com/auth/") or std.mem.indexOfAny(u8, args.oauth_scope, "\x00\r\n ") != null)) return error.InvalidOAuthScope;
        if (args.body_json.len == 0 or args.body_json.len > 1024 * 1024) return error.InvalidBody;
        var parsed_body = std.json.parseFromSlice(std.json.Value, allocator, args.body_json, .{}) catch return error.InvalidBody;
        parsed_body.deinit();
        const service_url = switch (args.service_url) {
            .value => |known| value.Value{ .string = known },
            .resource_ref => |reference| value.Value{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
            .unknown_reason => return error.OutputNotKnown,
        };
        const fields = [_]value.Field{
            .{ .name = "attempt_deadline_seconds", .value = .{ .integer = args.attempt_deadline_seconds } },
            .{ .name = "auth_kind", .value = .{ .string = @tagName(args.auth_kind) } },
            .{ .name = "body_json", .value = .{ .string = args.body_json } },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "location", .value = .{ .string = location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "oauth_scope", .value = .{ .string = args.oauth_scope } },
            .{ .name = "path", .value = .{ .string = args.path } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "schedule", .value = .{ .string = args.schedule } },
            .{ .name = "service_account", .value = .{ .string = args.service_account } },
            .{ .name = "service_url", .value = service_url },
            .{ .name = "time_zone", .value = .{ .string = args.time_zone } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.scheduler.Job.{s}.{s}", .{ location, args.name });
        defer allocator.free(id);
        const node = try resource.ResourceNode.initOwned(allocator, .{
            .id = id,
            .provider = .gcp,
            .type_name = "gcp.scheduler.Job",
            .logical_id = args.name,
            .inputs = .{ .object = &fields },
        });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .state = Outputs.State.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Job, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn validateToken(input: []const u8, minimum: usize, maximum: usize, extra: []const u8) !void {
    if (input.len < minimum or input.len > maximum) return error.InvalidName;
    for (input) |byte| if (!(std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, extra, byte) != null)) return error.InvalidName;
}

fn validServiceAccount(input: []const u8, project_id: []const u8) bool {
    return std.mem.endsWith(u8, input, ".iam.gserviceaccount.com") and
        std.mem.indexOfScalar(u8, input, '@') != null and
        std.mem.indexOf(u8, input, project_id) != null and
        std.mem.indexOfAny(u8, input, "\x00\r\n /") == null;
}
