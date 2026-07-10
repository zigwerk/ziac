const std = @import("std");
const provider_error = @import("provider_error.zig");
const resource = @import("resource.zig");
const state = @import("state.zig");
const value = @import("value.zig");

pub const ProviderError = provider_error.ProviderError;

pub const DiffKind = enum {
    noop,
    update,
    replace,
};

pub const DiffResult = struct {
    allocator: std.mem.Allocator,
    kind: DiffKind,
    reasons: []const []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        kind: DiffKind,
        reasons: []const []const u8,
    ) ProviderError!DiffResult {
        const owned_reasons = try cloneStrings(allocator, reasons);
        return .{ .allocator = allocator, .kind = kind, .reasons = owned_reasons };
    }

    pub fn deinit(self: *DiffResult) void {
        freeStrings(self.allocator, self.reasons);
        self.* = undefined;
    }
};

pub const ResourceResult = struct {
    allocator: std.mem.Allocator,
    physical_id: []const u8,
    observed_inputs: value.Value,
    observed_hash: [32]u8,
    outputs: []const state.StateOutput,
    operation_handle: ?[]const u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        physical_id: []const u8,
        observed_inputs: value.Value,
        outputs: []const state.StateOutput,
        operation_handle: ?[]const u8,
    ) ProviderError!ResourceResult {
        const owned_physical_id = try allocator.dupe(u8, physical_id);
        errdefer allocator.free(owned_physical_id);
        var owned_inputs = value.Value.initOwned(allocator, observed_inputs) catch |err| switch (err) {
            error.DuplicateField => return error.InvalidConfiguration,
            error.OutOfMemory => return error.OutOfMemory,
        };
        errdefer owned_inputs.deinit(allocator);
        const observed_hash = owned_inputs.sha256(allocator) catch |err| switch (err) {
            error.DuplicateField => return error.InvalidConfiguration,
            error.OutOfMemory => return error.OutOfMemory,
        };
        const owned_outputs = try cloneOutputs(allocator, outputs);
        errdefer freeOutputs(allocator, owned_outputs);
        const owned_operation = if (operation_handle) |inner| try allocator.dupe(u8, inner) else null;
        errdefer if (owned_operation) |inner| allocator.free(inner);

        return .{
            .allocator = allocator,
            .physical_id = owned_physical_id,
            .observed_inputs = owned_inputs,
            .observed_hash = observed_hash,
            .outputs = owned_outputs,
            .operation_handle = owned_operation,
        };
    }

    pub fn clone(self: ResourceResult, allocator: std.mem.Allocator) ProviderError!ResourceResult {
        return init(
            allocator,
            self.physical_id,
            self.observed_inputs,
            self.outputs,
            self.operation_handle,
        );
    }

    pub fn deinit(self: *ResourceResult) void {
        self.allocator.free(self.physical_id);
        self.observed_inputs.deinit(self.allocator);
        freeOutputs(self.allocator, self.outputs);
        if (self.operation_handle) |inner| self.allocator.free(inner);
        self.* = undefined;
    }
};

pub const ReadResult = union(enum) {
    absent,
    present: ResourceResult,

    pub fn deinit(self: *ReadResult) void {
        switch (self.*) {
            .absent => {},
            .present => |*result| result.deinit(),
        }
        self.* = undefined;
    }
};

pub const Provider = struct {
    ptr: *anyopaque,
    readFn: *const fn (*anyopaque, std.mem.Allocator, resource.ResourceNode) ProviderError!ReadResult,
    diffFn: *const fn (*anyopaque, std.mem.Allocator, resource.ResourceNode, *const ResourceResult) ProviderError!DiffResult,
    createFn: *const fn (*anyopaque, std.mem.Allocator, resource.ResourceNode) ProviderError!ResourceResult,
    updateFn: *const fn (*anyopaque, std.mem.Allocator, resource.ResourceNode, *const ResourceResult) ProviderError!ResourceResult,
    deleteFn: *const fn (*anyopaque, resource.ResourceNode, []const u8) ProviderError!void,
    importFn: *const fn (*anyopaque, std.mem.Allocator, resource.ResourceNode, []const u8) ProviderError!ResourceResult,

    pub fn read(
        self: Provider,
        allocator: std.mem.Allocator,
        node: resource.ResourceNode,
    ) ProviderError!ReadResult {
        return self.readFn(self.ptr, allocator, node);
    }

    pub fn diff(
        self: Provider,
        allocator: std.mem.Allocator,
        node: resource.ResourceNode,
        observed: *const ResourceResult,
    ) ProviderError!DiffResult {
        return self.diffFn(self.ptr, allocator, node, observed);
    }

    pub fn create(
        self: Provider,
        allocator: std.mem.Allocator,
        node: resource.ResourceNode,
    ) ProviderError!ResourceResult {
        return self.createFn(self.ptr, allocator, node);
    }

    pub fn update(
        self: Provider,
        allocator: std.mem.Allocator,
        node: resource.ResourceNode,
        observed: *const ResourceResult,
    ) ProviderError!ResourceResult {
        return self.updateFn(self.ptr, allocator, node, observed);
    }

    pub fn delete(self: Provider, node: resource.ResourceNode, physical_id: []const u8) ProviderError!void {
        return self.deleteFn(self.ptr, node, physical_id);
    }

    pub fn importResource(
        self: Provider,
        allocator: std.mem.Allocator,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!ResourceResult {
        return self.importFn(self.ptr, allocator, node, physical_id);
    }
};

pub const ProviderRegistry = struct {
    providers: [@typeInfo(resource.ProviderId).@"enum".fields.len]?Provider =
        [_]?Provider{null} ** @typeInfo(resource.ProviderId).@"enum".fields.len,

    pub fn register(self: *ProviderRegistry, id: resource.ProviderId, provider: Provider) void {
        self.providers[@intFromEnum(id)] = provider;
    }

    pub fn get(self: ProviderRegistry, id: resource.ProviderId) ProviderError!Provider {
        return self.providers[@intFromEnum(id)] orelse error.InvalidConfiguration;
    }
};

const RemoteRecord = struct {
    allocator: std.mem.Allocator,
    resource_id: []const u8,
    result: ResourceResult,

    fn deinit(self: *RemoteRecord) void {
        self.allocator.free(self.resource_id);
        self.result.deinit();
        self.* = undefined;
    }
};

pub const FakeProvider = struct {
    allocator: std.mem.Allocator,
    remotes: std.StringHashMap(RemoteRecord),
    fail_next: ?ProviderError = null,
    replace_changes: bool = false,
    reads: usize = 0,
    creates: usize = 0,
    updates: usize = 0,
    deletes: usize = 0,
    imports: usize = 0,

    pub fn init(allocator: std.mem.Allocator) FakeProvider {
        return .{
            .allocator = allocator,
            .remotes = std.StringHashMap(RemoteRecord).init(allocator),
        };
    }

    pub fn deinit(self: *FakeProvider) void {
        var iterator = self.remotes.valueIterator();
        while (iterator.next()) |remote| remote.deinit();
        self.remotes.deinit();
        self.* = undefined;
    }

    pub fn provider(self: *FakeProvider) Provider {
        return .{
            .ptr = self,
            .readFn = read,
            .diffFn = diff,
            .createFn = create,
            .updateFn = update,
            .deleteFn = delete,
            .importFn = importResource,
        };
    }

    fn takeFailure(self: *FakeProvider) ProviderError!void {
        if (self.fail_next) |err| {
            self.fail_next = null;
            return err;
        }
    }

    fn read(
        raw: *anyopaque,
        allocator: std.mem.Allocator,
        node: resource.ResourceNode,
    ) ProviderError!ReadResult {
        const self: *FakeProvider = @ptrCast(@alignCast(raw));
        try self.takeFailure();
        self.reads += 1;
        const remote = self.remotes.get(node.id) orelse return .absent;
        return .{ .present = try remote.result.clone(allocator) };
    }

    fn diff(
        raw: *anyopaque,
        allocator: std.mem.Allocator,
        node: resource.ResourceNode,
        observed: *const ResourceResult,
    ) ProviderError!DiffResult {
        const self: *FakeProvider = @ptrCast(@alignCast(raw));
        try self.takeFailure();
        if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash)) {
            return DiffResult.init(allocator, .noop, &.{});
        }
        return DiffResult.init(
            allocator,
            if (self.replace_changes) .replace else .update,
            &.{"desired inputs changed"},
        );
    }

    fn create(
        raw: *anyopaque,
        allocator: std.mem.Allocator,
        node: resource.ResourceNode,
    ) ProviderError!ResourceResult {
        const self: *FakeProvider = @ptrCast(@alignCast(raw));
        try self.takeFailure();
        if (self.remotes.contains(node.id)) return error.Conflict;
        self.creates += 1;

        const physical_id = try std.fmt.allocPrint(self.allocator, "fake/{s}", .{node.id});
        defer self.allocator.free(physical_id);
        try self.insertRemote(node, physical_id);
        return (self.remotes.get(node.id) orelse return error.ProviderBug).result.clone(allocator);
    }

    fn update(
        raw: *anyopaque,
        allocator: std.mem.Allocator,
        node: resource.ResourceNode,
        observed: *const ResourceResult,
    ) ProviderError!ResourceResult {
        _ = observed;
        const self: *FakeProvider = @ptrCast(@alignCast(raw));
        try self.takeFailure();
        const remote = self.remotes.getPtr(node.id) orelse return error.NotFound;
        self.updates += 1;

        const inputs = value.Value.initOwned(self.allocator, node.inputs) catch |err| switch (err) {
            error.DuplicateField => return error.InvalidConfiguration,
            error.OutOfMemory => return error.OutOfMemory,
        };
        remote.result.observed_inputs.deinit(self.allocator);
        remote.result.observed_inputs = inputs;
        remote.result.observed_hash = node.inputs_hash;
        return remote.result.clone(allocator);
    }

    fn delete(
        raw: *anyopaque,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!void {
        _ = physical_id;
        const self: *FakeProvider = @ptrCast(@alignCast(raw));
        try self.takeFailure();
        self.deletes += 1;
        if (self.remotes.fetchRemove(node.id)) |removed| {
            var remote = removed.value;
            remote.deinit();
        }
    }

    fn importResource(
        raw: *anyopaque,
        allocator: std.mem.Allocator,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!ResourceResult {
        const self: *FakeProvider = @ptrCast(@alignCast(raw));
        try self.takeFailure();
        if (self.remotes.contains(node.id)) return error.Conflict;
        self.imports += 1;
        try self.insertRemote(node, physical_id);
        return (self.remotes.get(node.id) orelse return error.ProviderBug).result.clone(allocator);
    }

    fn insertRemote(
        self: *FakeProvider,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!void {
        const resource_id = try self.allocator.dupe(u8, node.id);
        errdefer self.allocator.free(resource_id);
        const output_source = [_]state.StateOutput{
            .{ .name = "physical_id", .value = .{ .string = physical_id } },
        };
        var result = try ResourceResult.init(
            self.allocator,
            physical_id,
            node.inputs,
            output_source[0..],
            null,
        );
        errdefer result.deinit();
        const remote = RemoteRecord{
            .allocator = self.allocator,
            .resource_id = resource_id,
            .result = result,
        };
        try self.remotes.put(resource_id, remote);
    }
};

fn cloneStrings(
    allocator: std.mem.Allocator,
    source: []const []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    const strings = try allocator.alloc([]const u8, source.len);
    errdefer allocator.free(strings);
    var initialized: usize = 0;
    errdefer {
        for (strings[0..initialized]) |inner| allocator.free(inner);
    }
    for (source, 0..) |inner, index| {
        strings[index] = try allocator.dupe(u8, inner);
        initialized += 1;
    }
    return strings;
}

fn freeStrings(allocator: std.mem.Allocator, strings: []const []const u8) void {
    for (strings) |inner| allocator.free(inner);
    allocator.free(strings);
}

fn cloneOutputs(
    allocator: std.mem.Allocator,
    source: []const state.StateOutput,
) ProviderError![]const state.StateOutput {
    const outputs = try allocator.alloc(state.StateOutput, source.len);
    errdefer allocator.free(outputs);
    var initialized: usize = 0;
    errdefer {
        for (outputs[0..initialized]) |*output| {
            allocator.free(output.name);
            output.value.deinit(allocator);
        }
    }
    for (source, 0..) |output, index| {
        const name = try allocator.dupe(u8, output.name);
        errdefer allocator.free(name);
        var owned_value = value.Value.initOwned(allocator, output.value) catch |err| switch (err) {
            error.DuplicateField => return error.InvalidConfiguration,
            error.OutOfMemory => return error.OutOfMemory,
        };
        errdefer owned_value.deinit(allocator);
        outputs[index] = .{ .name = name, .value = owned_value };
        initialized += 1;
    }
    return outputs;
}

fn freeOutputs(allocator: std.mem.Allocator, outputs: []const state.StateOutput) void {
    const mutable_outputs: []state.StateOutput = @constCast(outputs);
    for (mutable_outputs) |*output| {
        allocator.free(output.name);
        output.value.deinit(allocator);
    }
    allocator.free(outputs);
}
