const std = @import("std");
const gcp = @import("gcp/root.zig");
const resource = @import("resource.zig");

pub const StackError = error{
    UnknownStack,
    DuplicateResource,
    MissingResource,
    OutOfMemory,
    MissingProjectId,
    MissingRegion,
    MissingName,
    MissingImage,
    InvalidPort,
    DuplicateEnvVar,
    MissingLabel,
    PremiumTierRequired,
};

pub const StackArgs = struct {
    stack: []const u8,
    stage: []const u8,
};

pub const OutputEntry = struct {
    name: []const u8,
    value: []const u8,
    secret: bool = false,
};

pub const StackProgram = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    outputs: std.ArrayList(OutputEntry),
    owned_resource_ids: std.ArrayList([]const u8),

    pub fn deinit(self: *StackProgram) void {
        self.graph.deinit();
        for (self.outputs.items) |entry| {
            self.allocator.free(entry.value);
        }
        self.outputs.deinit(self.allocator);
        for (self.owned_resource_ids.items) |id| {
            self.allocator.free(id);
        }
        self.owned_resource_ids.deinit(self.allocator);
    }
};

pub const StackRegistry = struct {
    pub fn build(_: StackRegistry, allocator: std.mem.Allocator, args: StackArgs) StackError!StackProgram {
        if (!std.mem.eql(u8, args.stack, "hello-global")) return error.UnknownStack;

        const provider = gcp.config.ProviderConfig{
            .project_id = "ziac-dev",
            .primary_region = "europe-west1",
            .service_account = "hello-global@ziac-dev.iam.gserviceaccount.com",
        };

        const repo = try gcp.artifact_registry.DockerRepository.build(allocator, provider, .{
            .name = "hello-global",
        });
        defer allocator.free(repo.repository_url);

        const image = try std.fmt.allocPrint(allocator, "{s}/api:latest", .{repo.repository_url});
        defer allocator.free(image);

        const env = [_]gcp.cloud_run.EnvVar{
            .{ .name = "DATABASE_URL", .value = "postgres://user:sentinel-secret-for-tests@localhost:26257/app", .secret = true },
        };
        const service = try gcp.cloud_run.Service.build(allocator, provider, .{
            .name = "api",
            .image = image,
            .env = env[0..],
        });
        defer allocator.free(service.service_url);
        defer allocator.free(service.service_account);

        var owned_resource_ids = std.ArrayList([]const u8).empty;
        errdefer {
            for (owned_resource_ids.items) |id| allocator.free(id);
            owned_resource_ids.deinit(allocator);
        }
        try owned_resource_ids.append(allocator, repo.node.id);
        try owned_resource_ids.append(allocator, service.node.id);

        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        graph.addResource(repo.node) catch |err| switch (err) {
            error.DuplicateResource => return error.DuplicateResource,
            error.MissingResource => return error.MissingResource,
            error.OutOfMemory => return error.OutOfMemory,
            error.DependencyCycle => unreachable,
        };
        graph.addResource(service.node) catch |err| switch (err) {
            error.DuplicateResource => return error.DuplicateResource,
            error.MissingResource => return error.MissingResource,
            error.OutOfMemory => return error.OutOfMemory,
            error.DependencyCycle => unreachable,
        };
        graph.addDependency(service.node.id, repo.node.id) catch |err| switch (err) {
            error.DuplicateResource => return error.DuplicateResource,
            error.MissingResource => return error.MissingResource,
            error.OutOfMemory => return error.OutOfMemory,
            error.DependencyCycle => unreachable,
        };

        var outputs = std.ArrayList(OutputEntry).empty;
        errdefer {
            for (outputs.items) |entry| allocator.free(entry.value);
            outputs.deinit(allocator);
        }
        try appendOutput(allocator, &outputs, "repository_url", repo.repository_url, false);
        try appendOutput(allocator, &outputs, "service_url", service.service_url, false);
        try appendOutput(allocator, &outputs, "service_name", "api", false);
        try appendOutput(allocator, &outputs, "service_region", "europe-west1", false);
        try appendOutput(allocator, &outputs, "service_account", service.service_account, false);
        try appendOutput(allocator, &outputs, "database_url", "postgres://user:sentinel-secret-for-tests@localhost:26257/app", true);

        return .{
            .allocator = allocator,
            .graph = graph,
            .outputs = outputs,
            .owned_resource_ids = owned_resource_ids,
        };
    }
};

fn appendOutput(
    allocator: std.mem.Allocator,
    outputs: *std.ArrayList(OutputEntry),
    name: []const u8,
    value: []const u8,
    secret: bool,
) std.mem.Allocator.Error!void {
    try outputs.append(allocator, .{
        .name = name,
        .value = try allocator.dupe(u8, value),
        .secret = secret,
    });
}

pub fn fixtureRegistry() StackRegistry {
    return .{};
}
