const std = @import("std");
const ci = @import("ci.zig");
const gcp = @import("gcp/root.zig");
const output = @import("output.zig");
const resource = @import("resource.zig");
const state_mod = @import("state.zig");

pub const StackError = gcp.global.container_service.BuildError || gcp.artifact_registry.BuildError || ci.Error || error{
    UnknownStack,
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
        allocator.free(self.name);
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
    project_id: []const u8 = "ziac-dev",
    region: []const u8 = "europe-west1",
    service_account: ?[]const u8 = "hello-global@ziac-dev.iam.gserviceaccount.com",
    image: ?[]const u8 = null,
    regions: []const []const u8 = &.{},
    domain: ?[]const u8 = null,
    dns_zone: ?[]const u8 = null,
    http_redirect: bool = true,

    pub fn build(self: StackRegistry, allocator: std.mem.Allocator, args: StackArgs) StackError!StackProgram {
        if (std.mem.eql(u8, args.stack, "global-container")) return self.buildGlobalContainer(allocator, args.stage);
        if (!std.mem.eql(u8, args.stack, "hello-global")) return error.UnknownStack;

        const repository_name = try ci.scopedResourceNameAlloc(allocator, "hello-global", args.stage, 63);
        defer allocator.free(repository_name);
        const service_name = try ci.scopedResourceNameAlloc(allocator, "api", args.stage, 49);
        defer allocator.free(service_name);

        const provider = gcp.config.ProviderConfig{
            .project_id = self.project_id,
            .primary_region = self.region,
            .service_account = self.service_account,
        };

        var repo = try gcp.artifact_registry.DockerRepository.build(allocator, provider, .{
            .name = repository_name,
        });
        defer repo.deinit(allocator);

        const generated_image = if (self.image == null)
            try std.fmt.allocPrint(
                allocator,
                "{s}-docker.pkg.dev/{s}/{s}/api:latest",
                .{ self.region, self.project_id, repository_name },
            )
        else
            null;
        defer if (generated_image) |owned| allocator.free(owned);
        const image = self.image orelse generated_image.?;

        const env = [_]gcp.cloud_run.EnvVar{
            .{ .name = "DATABASE_URL", .value = "postgres://user:sentinel-secret-for-tests@localhost:26257/app", .secret = true },
        };
        var service = try gcp.cloud_run.Service.build(allocator, provider, .{
            .name = service_name,
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
        try appendLiteral(allocator, &outputs, "service_name", service_name, false);
        try appendLiteral(allocator, &outputs, "service_region", self.region, false);
        try appendReference(allocator, &outputs, "service_account", service.service_account.resource_ref, false);
        try appendLiteral(allocator, &outputs, "database_url", "postgres://user:sentinel-secret-for-tests@localhost:26257/app", true);

        return .{
            .allocator = allocator,
            .graph = graph,
            .outputs = outputs,
        };
    }

    fn buildGlobalContainer(
        self: StackRegistry,
        allocator: std.mem.Allocator,
        stage: []const u8,
    ) StackError!StackProgram {
        const component_name = try ci.scopedResourceNameAlloc(allocator, "api", stage, 49);
        defer allocator.free(component_name);
        const domain = try ci.previewDomainAlloc(allocator, self.domain orelse return error.MissingDomain, stage);
        defer allocator.free(domain);
        const provider = gcp.config.ProviderConfig{
            .project_id = self.project_id,
            .primary_region = self.region,
            .service_regions = self.regions,
            .network_tier = .premium,
            .service_account = self.service_account,
        };
        var component = try gcp.global.ContainerService.build(allocator, provider, .{
            .name = component_name,
            .image = self.image orelse return error.MissingImage,
            .regions = self.regions,
            .domain = domain,
            .dns_zone = self.dns_zone,
            .http_redirect = self.http_redirect,
        });
        defer component.deinit();

        var outputs = std.ArrayList(OutputDefinition).empty;
        errdefer {
            for (outputs.items) |*entry| entry.deinit(allocator);
            outputs.deinit(allocator);
        }
        try appendLiteral(allocator, &outputs, "url", component.url.value, false);
        try appendReference(allocator, &outputs, "ip_address", component.ip_address.resource_ref, false);
        try appendReference(allocator, &outputs, "certificate_status", component.certificate_status.resource_ref, false);
        for (self.regions) |region| {
            const output_name = try std.fmt.allocPrint(allocator, "service_url_{s}", .{region});
            defer allocator.free(output_name);
            const resource_id = try std.fmt.allocPrint(allocator, "gcp.run.Service.{s}.api", .{region});
            defer allocator.free(resource_id);
            try appendReference(allocator, &outputs, output_name, .{
                .resource_id = resource_id,
                .field = "service_url",
            }, false);
        }
        return .{
            .allocator = allocator,
            .graph = component.takeGraph(),
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
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    try outputs.append(allocator, .{
        .name = owned_name,
        .source = .{ .literal = owned_value },
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
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const resource_id = try allocator.dupe(u8, reference.resource_id);
    errdefer allocator.free(resource_id);
    const field = try allocator.dupe(u8, reference.field);
    errdefer allocator.free(field);
    try outputs.append(allocator, .{
        .name = owned_name,
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

pub const ConfiguredRegistryArgs = struct {
    project_id: []const u8,
    region: []const u8 = "europe-west1",
    service_account: ?[]const u8 = null,
    image: ?[]const u8 = null,
    regions: []const []const u8 = &.{},
    domain: ?[]const u8 = null,
    dns_zone: ?[]const u8 = null,
    http_redirect: bool = true,
};

pub fn configuredRegistry(args: ConfiguredRegistryArgs) StackRegistry {
    return .{
        .project_id = args.project_id,
        .region = args.region,
        .service_account = args.service_account,
        .image = args.image,
        .regions = args.regions,
        .domain = args.domain,
        .dns_zone = args.dns_zone,
        .http_redirect = args.http_redirect,
    };
}

pub fn regionsFromCsvAlloc(
    allocator: std.mem.Allocator,
    csv: []const u8,
) (std.mem.Allocator.Error || error{InvalidRegionList})![]const []const u8 {
    if (csv.len == 0) return error.InvalidRegionList;
    var count: usize = 0;
    var counter = std.mem.splitScalar(u8, csv, ',');
    while (counter.next()) |_| count += 1;
    const regions = try allocator.alloc([]const u8, count);
    errdefer allocator.free(regions);
    var iterator = std.mem.splitScalar(u8, csv, ',');
    var index: usize = 0;
    while (iterator.next()) |raw_region| : (index += 1) {
        const region = std.mem.trim(u8, raw_region, " \t");
        if (region.len == 0) return error.InvalidRegionList;
        regions[index] = region;
    }
    return regions;
}
