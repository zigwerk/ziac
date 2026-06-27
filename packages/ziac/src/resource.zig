const std = @import("std");

pub const ResourceGraphError = error{
    DuplicateResource,
    MissingResource,
    DependencyCycle,
    OutOfMemory,
};

pub const ResourceNode = struct {
    id: []const u8,
    type_name: []const u8,
    logical_id: []const u8,
};

pub const DependencyEdge = struct {
    from: []const u8,
    to: []const u8,
};

pub const ResourceGraph = struct {
    allocator: std.mem.Allocator,
    resources: std.ArrayList(ResourceNode),
    dependencies: std.ArrayList(DependencyEdge),

    pub fn init(allocator: std.mem.Allocator) ResourceGraph {
        return .{
            .allocator = allocator,
            .resources = std.ArrayList(ResourceNode).empty,
            .dependencies = std.ArrayList(DependencyEdge).empty,
        };
    }

    pub fn deinit(self: *ResourceGraph) void {
        self.resources.deinit(self.allocator);
        self.dependencies.deinit(self.allocator);
    }

    pub fn addResource(self: *ResourceGraph, node: ResourceNode) ResourceGraphError!void {
        if (self.indexOf(node.id) != null) return error.DuplicateResource;
        try self.resources.append(self.allocator, node);
    }

    pub fn addDependency(self: *ResourceGraph, from: []const u8, to: []const u8) ResourceGraphError!void {
        if (self.indexOf(from) == null) return error.MissingResource;
        if (self.indexOf(to) == null) return error.MissingResource;
        try self.dependencies.append(self.allocator, .{ .from = from, .to = to });
    }

    pub fn validateAcyclic(self: *const ResourceGraph) ResourceGraphError!void {
        for (self.resources.items) |node| {
            if (try self.hasPath(node.id, node.id, 0)) return error.DependencyCycle;
        }
    }

    fn indexOf(self: *const ResourceGraph, id: []const u8) ?usize {
        for (self.resources.items, 0..) |node, index| {
            if (std.mem.eql(u8, node.id, id)) return index;
        }
        return null;
    }

    fn hasPath(self: *const ResourceGraph, start: []const u8, target: []const u8, depth: usize) ResourceGraphError!bool {
        if (depth > self.resources.items.len) return error.DependencyCycle;
        for (self.dependencies.items) |edge| {
            if (!std.mem.eql(u8, edge.from, start)) continue;
            if (std.mem.eql(u8, edge.to, target)) return true;
            if (try self.hasPath(edge.to, target, depth + 1)) return true;
        }
        return false;
    }
};
