const std = @import("std");
const provider_mod = @import("provider.zig");
const resource = @import("resource.zig");

pub fn ProviderSet(comptime declared_providers: anytype) type {
    const normalized = normalizeProviders(declared_providers);
    return struct {
        pub const ids = normalized;

        pub fn has(comptime provider_id: resource.ProviderId) bool {
            inline for (ids) |declared| {
                if (declared == provider_id) return true;
            }
            return false;
        }

        pub fn require(comptime provider_id: resource.ProviderId) void {
            if (has(provider_id)) return;
            switch (provider_id) {
                .gcp => @compileError("ZIAC110 GCP provider is not declared by this stack"),
                .cockroach => @compileError("ZIAC111 CockroachDB provider is not declared by this stack"),
                .local => @compileError("ZIAC112 local provider is not declared by this stack"),
            }
        }
    };
}

pub const GcpNamespace = struct {
    allocator: std.mem.Allocator,
    graph: *resource.ResourceGraph,
};

pub const CockroachNamespace = struct {
    allocator: std.mem.Allocator,
    graph: *resource.ResourceGraph,
};

pub const LocalNamespace = struct {
    allocator: std.mem.Allocator,
    graph: *resource.ResourceGraph,
};

pub fn Context(comptime Providers: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        graph: *resource.ResourceGraph,

        pub fn init(allocator: std.mem.Allocator, graph: *resource.ResourceGraph) Self {
            return .{ .allocator = allocator, .graph = graph };
        }

        pub fn gcp(self: *Self) GcpNamespace {
            comptime Providers.require(.gcp);
            return .{ .allocator = self.allocator, .graph = self.graph };
        }

        pub fn cockroach(self: *Self) CockroachNamespace {
            comptime Providers.require(.cockroach);
            return .{ .allocator = self.allocator, .graph = self.graph };
        }

        pub fn local(self: *Self) LocalNamespace {
            comptime Providers.require(.local);
            return .{ .allocator = self.allocator, .graph = self.graph };
        }
    };
}

pub fn runtimeRegistry(comptime Providers: type, implementations: anytype) provider_mod.ProviderRegistry {
    var registry = provider_mod.ProviderRegistry{};
    inline for (Providers.ids) |provider_id| {
        const field_name = @tagName(provider_id);
        if (!@hasField(@TypeOf(implementations), field_name)) {
            @compileError("missing runtime provider implementation for " ++ field_name);
        }
        registry.register(provider_id, @field(implementations, field_name));
    }
    return registry;
}

fn normalizeProviders(comptime declared_providers: anytype) [declared_providers.len]resource.ProviderId {
    var normalized: [declared_providers.len]resource.ProviderId = undefined;
    inline for (declared_providers, 0..) |provider_id, index| {
        normalized[index] = provider_id;
    }

    var left: usize = 0;
    while (left < normalized.len) : (left += 1) {
        var right = left + 1;
        while (right < normalized.len) : (right += 1) {
            if (normalized[left] == normalized[right]) {
                @compileError("ZIAC112 duplicate provider in stack provider set");
            }
            if (@intFromEnum(normalized[right]) < @intFromEnum(normalized[left])) {
                const temporary = normalized[left];
                normalized[left] = normalized[right];
                normalized[right] = temporary;
            }
        }
    }
    return normalized;
}
