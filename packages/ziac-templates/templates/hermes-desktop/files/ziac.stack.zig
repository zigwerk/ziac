const std = @import("std");
const ziac = @import("ziac");
const gcpx = @import("ziac_gcpx");

pub fn build(allocator: std.mem.Allocator, init: std.process.Init, args: ziac.stack_registry.StackArgs) !ziac.stack_registry.StackProgram {
    if (!std.mem.eql(u8, args.stack, "hermes-desktop")) return error.UnknownStack;
    const name = "hermes";
    var component = try gcpx.HermesDesktop.build(allocator, .{
        .project_id = init.environ_map.get("ZIAC_GCP_PROJECT") orelse "ziac-dev",
        .primary_region = "europe-west1",
    }, .{
        .name = name,
        .region = init.environ_map.get("ZIAC_HERMES_REGION") orelse "europe-west1",
        .zone = init.environ_map.get("ZIAC_HERMES_ZONE") orelse "europe-west1-b",
        .domain = init.environ_map.get("ZIAC_HERMES_DOMAIN") orelse "hermes.example.invalid",
        .dns_zone = init.environ_map.get("ZIAC_HERMES_DNS_ZONE"),
        .oauth_client_id = init.environ_map.get("ZIAC_HERMES_OAUTH_CLIENT_ID") orelse "agent:hermes-dev",
        .environment_source = .{ .provider = "env", .resource = "HERMES_ENV_FILE", .version = "1" },
        .startup_script = .known(.{ .provider = "env", .resource = "ZIAC_HERMES_STARTUP_SCRIPT", .version = "1" }),
        .startup_script_sha256 = ziac.gcp.hermes_compute.reviewed_startup_script_sha256,
    });
    defer component.deinit();
    var outputs = std.ArrayList(ziac.stack_registry.OutputDefinition).empty;
    errdefer outputs.deinit(allocator);
    try outputs.append(allocator, .{ .name = try allocator.dupe(u8, "desktop_url"), .source = .{ .literal = try allocator.dupe(u8, component.desktop_url.value) } });
    return .{ .allocator = allocator, .graph = component.takeGraph(), .outputs = outputs };
}

test "Hermes template uses the official component" {
    try std.testing.expectEqualStrings("HermesDesktop", gcpx.hermes_desktop.descriptor.name);
}
