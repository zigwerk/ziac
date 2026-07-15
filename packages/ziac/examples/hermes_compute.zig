const std = @import("std");
const ziac = @import("ziac");

pub fn build(
    allocator: std.mem.Allocator,
    init: std.process.Init,
    args: ziac.stack_registry.StackArgs,
) !ziac.stack_registry.StackProgram {
    if (!std.mem.eql(u8, args.stack, "hermes")) return error.UnknownStack;
    const project = init.environ_map.get("ZIAC_GCP_PROJECT") orelse "example-project";
    const region = init.environ_map.get("ZIAC_HERMES_REGION") orelse "europe-west1";
    const zone = init.environ_map.get("ZIAC_HERMES_ZONE") orelse "europe-west1-b";
    const ephemeral = std.mem.eql(
        u8,
        init.environ_map.get("ZIAC_HERMES_LIFECYCLE") orelse "protected",
        "ephemeral",
    );

    var deployment = try buildDeployment(allocator, .{
        .project_id = project,
        .primary_region = region,
    }, .{
        .region = region,
        .zone = zone,
        .machine_type = init.environ_map.get("ZIAC_HERMES_MACHINE_TYPE") orelse "e2-medium",
        .hermes_image = init.environ_map.get("ZIAC_HERMES_IMAGE") orelse ziac.gcp.hermes_compute.default_image,
        .proxy_image = init.environ_map.get("ZIAC_HERMES_PROXY_IMAGE") orelse ziac.gcp.hermes_compute.default_proxy_image,
        .domain = init.environ_map.get("ZIAC_HERMES_DOMAIN") orelse "hermes.example.com",
        .dns_zone = init.environ_map.get("ZIAC_HERMES_DNS_ZONE") orelse "example-com",
        .oauth_client_id = init.environ_map.get("ZIAC_HERMES_OAUTH_CLIENT_ID") orelse "agent:example",
        .protect = !ephemeral,
        .deletion_protection = !ephemeral,
        .retain_disk = !ephemeral,
        .retain_environment_secret = !ephemeral,
    });
    defer deployment.deinit();

    var outputs = std.ArrayList(ziac.stack_registry.OutputDefinition).empty;
    errdefer {
        for (outputs.items) |*entry| entry.deinit(allocator);
        outputs.deinit(allocator);
    }
    try appendOutput(allocator, &outputs, "instance", deployment.instance);
    try appendOutput(allocator, &outputs, "internal_ip", deployment.internal_ip);
    try appendOutput(allocator, &outputs, "public_ip", deployment.public_ip);
    try appendKnownOutput(allocator, &outputs, "desktop_url", deployment.desktop_url);
    try appendOutput(allocator, &outputs, "environment_secret", deployment.environment_secret);
    return .{
        .allocator = allocator,
        .graph = deployment.takeGraph(),
        .outputs = outputs,
    };
}

const Overrides = struct {
    region: []const u8 = "europe-west1",
    zone: []const u8 = "europe-west1-b",
    machine_type: []const u8 = "e2-medium",
    hermes_image: []const u8 = ziac.gcp.hermes_compute.default_image,
    proxy_image: []const u8 = ziac.gcp.hermes_compute.default_proxy_image,
    domain: []const u8 = "hermes.example.com",
    dns_zone: ?[]const u8 = "example-com",
    oauth_client_id: []const u8 = "agent:example",
    protect: bool = true,
    deletion_protection: bool = true,
    retain_disk: bool = true,
    retain_environment_secret: bool = true,
};

fn buildDeployment(
    allocator: std.mem.Allocator,
    provider: ziac.gcp.ProviderConfig,
    overrides: Overrides,
) !ziac.gcp.HermesCompute {
    return ziac.gcp.HermesCompute.build(allocator, provider, .{
        .name = "hermes",
        .region = overrides.region,
        .zone = overrides.zone,
        .machine_type = overrides.machine_type,
        .hermes_image = overrides.hermes_image,
        .proxy_image = overrides.proxy_image,
        .domain = overrides.domain,
        .dns_zone = overrides.dns_zone,
        .oauth_client_id = overrides.oauth_client_id,
        .environment_source = .{
            .provider = "env",
            .resource = "HERMES_ENV_FILE",
            .version = "1",
        },
        .startup_script = .known(.{
            .provider = "env",
            .resource = "ZIAC_HERMES_STARTUP_SCRIPT",
            .version = "1",
        }),
        .startup_script_sha256 = ziac.gcp.hermes_compute.reviewed_startup_script_sha256,
        .protect = overrides.protect,
        .deletion_protection = overrides.deletion_protection,
        .retain_disk = overrides.retain_disk,
        .retain_environment_secret = overrides.retain_environment_secret,
    });
}

fn appendKnownOutput(
    allocator: std.mem.Allocator,
    outputs: *std.ArrayList(ziac.stack_registry.OutputDefinition),
    name: []const u8,
    candidate: ziac.PublicOutput([]const u8),
) !void {
    const known = switch (candidate) {
        .value => |text| text,
        else => return error.OutputNotKnown,
    };
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const literal = try allocator.dupe(u8, known);
    errdefer allocator.free(literal);
    try outputs.append(allocator, .{ .name = owned_name, .source = .{ .literal = literal } });
}

fn appendOutput(
    allocator: std.mem.Allocator,
    outputs: *std.ArrayList(ziac.stack_registry.OutputDefinition),
    name: []const u8,
    candidate: ziac.PublicOutput([]const u8),
) !void {
    const reference = candidate.referenceOrNull() orelse return error.OutputNotKnown;
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const resource_id = try allocator.dupe(u8, reference.resource_id);
    errdefer allocator.free(resource_id);
    const field = try allocator.dupe(u8, reference.field);
    errdefer allocator.free(field);
    try outputs.append(allocator, .{
        .name = owned_name,
        .source = .{ .resource_ref = .{
            .resource_id = resource_id,
            .field = field,
        } },
    });
}

pub fn main() !void {
    var deployment = try buildDeployment(std.heap.page_allocator, .{
        .project_id = "example-project",
        .primary_region = "europe-west1",
    }, .{});
    defer deployment.deinit();
    std.debug.print("Hermes Compute: {d} resources, Desktop at {s}\n", .{
        deployment.graph.resources.items.len,
        deployment.desktop_url.value,
    });
}

test "Hermes example compiles through the public compatibility component" {
    var deployment = try buildDeployment(std.testing.allocator, .{
        .project_id = "example-project",
        .primary_region = "europe-west1",
    }, .{});
    defer deployment.deinit();
    try deployment.graph.validateAcyclic();
    try std.testing.expectEqual(@as(usize, 12), deployment.graph.resources.items.len);
}
