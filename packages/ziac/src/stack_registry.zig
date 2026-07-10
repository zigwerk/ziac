const std = @import("std");
const gcp = @import("gcp/root.zig");
const output = @import("output.zig");
const resource = @import("resource.zig");
const state_mod = @import("state.zig");

pub const StackError = error{
    UnknownStack,
    DuplicateResource,
    DuplicateField,
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

pub const OutputSource = union(enum) {
    literal: []const u8,
    resource_ref: output.OutputRef,
};

pub const OutputDefinition = struct {
    name: []const u8,
    source: OutputSource,
    secret: bool = false,

    fn deinit(self: *OutputDefinition, allocator: std.mem.Allocator) void {
        switch (self.source) {
            .literal => |literal| allocator.free(literal),
            .resource_ref => |reference| {
                allocator.free(reference.resource_id);
                allocator.free(reference.field);
            },
        }
        self.* = undefined;
    }
};

pub const StackProgram = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    outputs: std.ArrayList(OutputDefinition),

    pub fn deinit(self: *StackProgram) void {
        self.graph.deinit();
        for (self.outputs.items) |*entry| entry.deinit(self.allocator);
        self.outputs.deinit(self.allocator);
    }

    pub fn resolveOutputsAlloc(
        self: *const StackProgram,
        allocator: std.mem.Allocator,
        state: *state_mod.InMemoryStateStore,
    ) ![]OutputEntry {
        const resolved = try allocator.alloc(OutputEntry, self.outputs.items.len);
        errdefer allocator.free(resolved);
        var initialized: usize = 0;
        errdefer {
            for (resolved[0..initialized]) |entry| allocator.free(entry.value);
        }
        for (self.outputs.items, 0..) |definition, index| {
            resolved[index] = .{
                .name = definition.name,
                .value = try resolveOutputValue(allocator, state, definition.source),
                .secret = definition.secret,
            };
            initialized += 1;
        }
        return resolved;
    }

    pub fn freeResolvedOutputs(allocator: std.mem.Allocator, outputs: []OutputEntry) void {
        for (outputs) |entry| allocator.free(entry.value);
        allocator.free(outputs);
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

        var repo = try gcp.artifact_registry.DockerRepository.build(allocator, provider, .{
            .name = "hello-global",
        });
        defer repo.deinit(allocator);

        const image = "europe-west1-docker.pkg.dev/ziac-dev/hello-global/api:latest";

        const env = [_]gcp.cloud_run.EnvVar{
            .{ .name = "DATABASE_URL", .value = "postgres://user:sentinel-secret-for-tests@localhost:26257/app", .secret = true },
        };
        var service = try gcp.cloud_run.Service.build(allocator, provider, .{
            .name = "api",
            .image = image,
            .env = env[0..],
        });
        defer service.deinit(allocator);

        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        graph.addResource(repo.node) catch |err| switch (err) {
            error.DuplicateResource => return error.DuplicateResource,
            error.DuplicateField => return error.DuplicateField,
            error.MissingResource => return error.MissingResource,
            error.OutOfMemory => return error.OutOfMemory,
            error.DependencyCycle => unreachable,
        };
        graph.addResource(service.node) catch |err| switch (err) {
            error.DuplicateResource => return error.DuplicateResource,
            error.DuplicateField => return error.DuplicateField,
            error.MissingResource => return error.MissingResource,
            error.OutOfMemory => return error.OutOfMemory,
            error.DependencyCycle => unreachable,
        };
        graph.bindOutput(service.node.id, repo.repository_url) catch |err| switch (err) {
            error.DuplicateResource => return error.DuplicateResource,
            error.DuplicateField => return error.DuplicateField,
            error.MissingResource => return error.MissingResource,
            error.OutOfMemory => return error.OutOfMemory,
            error.DependencyCycle => unreachable,
        };

        var outputs = std.ArrayList(OutputDefinition).empty;
        errdefer {
            for (outputs.items) |*entry| entry.deinit(allocator);
            outputs.deinit(allocator);
        }
        try appendReference(allocator, &outputs, "repository_url", repo.repository_url.resource_ref, false);
        try appendReference(allocator, &outputs, "service_url", service.service_url.resource_ref, false);
        try appendLiteral(allocator, &outputs, "service_name", "api", false);
        try appendLiteral(allocator, &outputs, "service_region", "europe-west1", false);
        try appendReference(allocator, &outputs, "service_account", service.service_account.resource_ref, false);
        try appendLiteral(allocator, &outputs, "database_url", "postgres://user:sentinel-secret-for-tests@localhost:26257/app", true);

        return .{
            .allocator = allocator,
            .graph = graph,
            .outputs = outputs,
        };
    }
};

fn appendLiteral(
    allocator: std.mem.Allocator,
    outputs: *std.ArrayList(OutputDefinition),
    name: []const u8,
    value: []const u8,
    secret: bool,
) std.mem.Allocator.Error!void {
    try outputs.append(allocator, .{
        .name = name,
        .source = .{ .literal = try allocator.dupe(u8, value) },
        .secret = secret,
    });
}

fn appendReference(
    allocator: std.mem.Allocator,
    outputs: *std.ArrayList(OutputDefinition),
    name: []const u8,
    reference: output.OutputRef,
    secret: bool,
) std.mem.Allocator.Error!void {
    const resource_id = try allocator.dupe(u8, reference.resource_id);
    errdefer allocator.free(resource_id);
    const field = try allocator.dupe(u8, reference.field);
    errdefer allocator.free(field);
    try outputs.append(allocator, .{
        .name = name,
        .source = .{ .resource_ref = .{ .resource_id = resource_id, .field = field } },
        .secret = secret,
    });
}

fn resolveOutputValue(
    allocator: std.mem.Allocator,
    state: *state_mod.InMemoryStateStore,
    source: OutputSource,
) ![]const u8 {
    switch (source) {
        .literal => |literal| return allocator.dupe(u8, literal),
        .resource_ref => |reference| {
            const record = state.get(reference.resource_id) orelse return error.MissingOutput;
            for (record.outputs) |provider_output| {
                if (!std.mem.eql(u8, provider_output.name, reference.field)) continue;
                return switch (provider_output.value) {
                    .string => |string| allocator.dupe(u8, string),
                    .secret_ref => allocator.dupe(u8, "[SECRET_REF]"),
                    else => error.OutputTypeMismatch,
                };
            }
            return error.MissingOutput;
        },
    }
}

pub fn fixtureRegistry() StackRegistry {
    return .{};
}
