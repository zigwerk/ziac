const std = @import("std");
const ziac = @import("ziac");
const gcpx = @import("ziac_gcpx");
const App = @import("app");

const regions = [_][]const u8{ "europe-west1", "us-central1", "asia-northeast1" };
const Providers = ziac.stack.ProviderSet(.{ziac.resource.ProviderId.gcp});
const Bindings = struct {};
const Service = gcpx.global_zig_service.compatibility_import(App, Bindings, Providers);

pub fn build(allocator: std.mem.Allocator, init: std.process.Init, args: ziac.stack_registry.StackArgs) !ziac.stack_registry.StackProgram {
    if (!std.mem.eql(u8, args.stack, "global-api")) return error.UnknownStack;
    var source_root = try std.Io.Dir.cwd().openDir(init.io, ".", .{ .iterate = true });
    defer source_root.close(init.io);
    var component = try Service.build(allocator, .{
        .project_id = init.environ_map.get("ZIAC_GCP_PROJECT") orelse "ziac-dev",
        .primary_region = regions[0],
        .service_regions = &regions,
        .network_tier = .premium,
    }, .{
        .source = .{ .io = init.io, .root = source_root },
        .name = "api",
        .artifact_name = "app",
        .regions = &regions,
        .domain = init.environ_map.get("ZIAC_DOMAIN") orelse "api.example.invalid",
        .dns_zone = init.environ_map.get("ZIAC_DNS_ZONE"),
        .bindings = .{},
    });
    defer component.deinit();
    var outputs = std.ArrayList(ziac.stack_registry.OutputDefinition).empty;
    errdefer outputs.deinit(allocator);
    try outputs.append(allocator, .{ .name = try allocator.dupe(u8, "url"), .source = .{ .literal = try allocator.dupe(u8, component.url.value) } });
    return .{ .allocator = allocator, .graph = component.takeGraph(), .outputs = outputs };
}
