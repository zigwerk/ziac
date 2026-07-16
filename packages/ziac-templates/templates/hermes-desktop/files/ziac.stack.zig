const std = @import("std");
const ziac = @import("ziac");
const gcpx = @import("ziac_gcpx");
const zstd = @import("zigeffect_std");

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
    var context = try zstd.Testing.TestContext.init(std.testing.allocator, .{
        .project = "hermes-desktop",
        .suite = "project-tests",
        .scenario = .{
            .id = "typed-component-contract",
            .label = "Hermes uses the typed infrastructure component",
            .requirement = "typed-hermes-component",
            .acceptance_check = "check-typed-hermes-component",
            .component = "infrastructure",
            .command = "test",
        },
        .seed = 42,
    });
    defer context.deinit();
    const assertions = zstd.Testing.AssertionRecorder.init(&context);
    try assertions.equal(.{
        .id = "hermes-component",
        .label = "official Hermes component is selected",
        .repair_hint = "compose the infrastructure graph from gcpx.HermesDesktop",
    }, @as([]const u8, "HermesDesktop"), gcpx.hermes_desktop.descriptor.name);
    try assertions.noFindings(.{
        .id = "hermes-no-findings",
        .label = "component contract is causally healthy",
        .repair_hint = "keep the pure stack compiler deterministic",
    });
}
