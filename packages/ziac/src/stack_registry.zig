const std = @import("std");
const resource = @import("resource.zig");

pub const StackError = error{
    UnknownStack,
    DuplicateResource,
    MissingResource,
    OutOfMemory,
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

    pub fn deinit(self: *StackProgram) void {
        self.graph.deinit();
        self.outputs.deinit(self.allocator);
    }
};

pub const StackRegistry = struct {
    pub fn build(_: StackRegistry, allocator: std.mem.Allocator, args: StackArgs) StackError!StackProgram {
        if (!std.mem.eql(u8, args.stack, "hello-global")) return error.UnknownStack;

        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        graph.addResource(.{
            .id = "gcp.run.Service.api",
            .type_name = "gcp.run.Service",
            .logical_id = "api",
        }) catch |err| switch (err) {
            error.DuplicateResource => return error.DuplicateResource,
            error.MissingResource => return error.MissingResource,
            error.OutOfMemory => return error.OutOfMemory,
            error.DependencyCycle => unreachable,
        };

        var outputs = std.ArrayList(OutputEntry).empty;
        errdefer outputs.deinit(allocator);
        try outputs.append(allocator, .{
            .name = "url",
            .value = "https://hello-global.example.local",
        });
        try outputs.append(allocator, .{
            .name = "database_url",
            .value = "postgres://user:sentinel-secret-for-tests@localhost:26257/app",
            .secret = true,
        });

        return .{ .allocator = allocator, .graph = graph, .outputs = outputs };
    }
};

pub fn fixtureRegistry() StackRegistry {
    return .{};
}
