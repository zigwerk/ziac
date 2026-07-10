const std = @import("std");
const fx = @import("zigeffect_std").fx;
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
    completed: bool = true,

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
        var result = try init(
            allocator,
            self.physical_id,
            self.observed_inputs,
            self.outputs,
            self.operation_handle,
        );
        result.completed = self.completed;
        return result;
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

pub const Cancellation = struct {
    ptr: *const anyopaque,
    isCancelledFn: *const fn (*const anyopaque) bool,

    pub fn isCancelled(self: Cancellation) bool {
        return self.isCancelledFn(self.ptr);
    }
};

pub const OperationContext = struct {
    allocator: std.mem.Allocator,
    state: ?*state.InMemoryStateStore = null,
    clock: ?*fx.Clock = null,
    cancellation: ?Cancellation = null,
    deadline_millis: ?u64 = null,
    physical_id: ?[]const u8 = null,
    operation_handle: ?[]const u8 = null,
    destructive_confirmation: bool = false,

    pub fn init(allocator: std.mem.Allocator) OperationContext {
        return .{ .allocator = allocator };
    }

    pub fn nowMillis(self: *const OperationContext) u64 {
        if (self.clock) |clock| return clock.nowMs();
        var clock = fx.Clock.system();
        return clock.nowMs();
    }

    pub fn sleep(self: *OperationContext, delay_millis: u64) void {
        if (self.clock) |clock| {
            clock.sleep(delay_millis);
            return;
        }
        var clock = fx.Clock.system();
        clock.sleep(delay_millis);
    }

    pub fn checkActive(self: *const OperationContext) ProviderError!void {
        if (self.cancellation) |cancellation| {
            if (cancellation.isCancelled()) return error.ProviderCancelled;
        }
        if (self.deadline_millis) |deadline| {
            if (self.nowMillis() >= deadline) return error.ProviderTimeout;
        }
    }

    pub fn resolveOutputString(
        self: *const OperationContext,
        reference: value.OutputReference,
    ) ProviderError![]const u8 {
        const store = self.state orelse return error.InvalidConfiguration;
        const record = store.get(reference.resource_id) orelse return error.InvalidConfiguration;
        for (record.outputs) |provider_output| {
            if (!std.mem.eql(u8, provider_output.name, reference.field)) continue;
            return switch (provider_output.value) {
                .string => |string| string,
                else => error.InvalidConfiguration,
            };
        }
        return error.InvalidConfiguration;
    }

    pub fn resolveOutputSecret(
        self: *const OperationContext,
        reference: value.OutputReference,
    ) ProviderError!value.SecretReference {
        const store = self.state orelse return error.InvalidConfiguration;
        const record = store.get(reference.resource_id) orelse return error.InvalidConfiguration;
        for (record.outputs) |provider_output| {
            if (!std.mem.eql(u8, provider_output.name, reference.field)) continue;
            return switch (provider_output.value) {
                .secret_ref => |secret| secret,
                else => error.InvalidConfiguration,
            };
        }
        return error.InvalidConfiguration;
    }
};

pub const Provider = struct {
    ptr: *anyopaque,
    readFn: *const fn (*anyopaque, *OperationContext, resource.ResourceNode) ProviderError!ReadResult,
    diffFn: *const fn (*anyopaque, *OperationContext, resource.ResourceNode, *const ResourceResult) ProviderError!DiffResult,
    createFn: *const fn (*anyopaque, *OperationContext, resource.ResourceNode) ProviderError!ResourceResult,
    updateFn: *const fn (*anyopaque, *OperationContext, resource.ResourceNode, *const ResourceResult) ProviderError!ResourceResult,
    deleteFn: *const fn (*anyopaque, *OperationContext, resource.ResourceNode, []const u8) ProviderError!void,
    importFn: *const fn (*anyopaque, *OperationContext, resource.ResourceNode, []const u8) ProviderError!ResourceResult,

    pub fn read(
        self: Provider,
        allocator: std.mem.Allocator,
        node: resource.ResourceNode,
    ) ProviderError!ReadResult {
        var context = OperationContext.init(allocator);
        return self.readWithContext(&context, node);
    }

    pub fn readWithContext(
        self: Provider,
        context: *OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!ReadResult {
        return self.readFn(self.ptr, context, node);
    }

    pub fn diff(
        self: Provider,
        allocator: std.mem.Allocator,
        node: resource.ResourceNode,
        observed: *const ResourceResult,
    ) ProviderError!DiffResult {
        var context = OperationContext.init(allocator);
        return self.diffWithContext(&context, node, observed);
    }

    pub fn diffWithContext(
        self: Provider,
        context: *OperationContext,
        node: resource.ResourceNode,
        observed: *const ResourceResult,
    ) ProviderError!DiffResult {
        return self.diffFn(self.ptr, context, node, observed);
    }

    pub fn create(
        self: Provider,
        allocator: std.mem.Allocator,
        node: resource.ResourceNode,
    ) ProviderError!ResourceResult {
        var context = OperationContext.init(allocator);
        return self.createWithContext(&context, node);
    }

    pub fn createWithContext(
        self: Provider,
        context: *OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!ResourceResult {
        return self.createFn(self.ptr, context, node);
    }

    pub fn update(
        self: Provider,
        allocator: std.mem.Allocator,
        node: resource.ResourceNode,
        observed: *const ResourceResult,
    ) ProviderError!ResourceResult {
        var context = OperationContext.init(allocator);
        return self.updateWithContext(&context, node, observed);
    }

    pub fn updateWithContext(
        self: Provider,
        context: *OperationContext,
        node: resource.ResourceNode,
        observed: *const ResourceResult,
    ) ProviderError!ResourceResult {
        return self.updateFn(self.ptr, context, node, observed);
    }

    pub fn delete(self: Provider, node: resource.ResourceNode, physical_id: []const u8) ProviderError!void {
        var context = OperationContext.init(std.heap.page_allocator);
        return self.deleteWithContext(&context, node, physical_id);
    }

    pub fn deleteWithContext(
        self: Provider,
        context: *OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!void {
        return self.deleteFn(self.ptr, context, node, physical_id);
    }

    pub fn importResource(
        self: Provider,
        allocator: std.mem.Allocator,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!ResourceResult {
        var context = OperationContext.init(allocator);
        return self.importWithContext(&context, node, physical_id);
    }

    pub fn importWithContext(
        self: Provider,
        context: *OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!ResourceResult {
        return self.importFn(self.ptr, context, node, physical_id);
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
    last_read_physical_id: ?[]const u8 = null,
    last_delete_destructive_confirmation: bool = false,
    operation_delay_millis: u64 = 0,
    result_operation_handle: ?[]const u8 = null,
    result_completed: bool = true,
    mutex: fx.SpinLock = .{},
    active_operations: usize = 0,
    max_concurrent_operations: usize = 0,
    operation_attempts: usize = 0,

    pub fn init(allocator: std.mem.Allocator) FakeProvider {
        return .{
            .allocator = allocator,
            .remotes = std.StringHashMap(RemoteRecord).init(allocator),
        };
    }

    pub fn deinit(self: *FakeProvider) void {
        if (self.last_read_physical_id) |physical_id| self.allocator.free(physical_id);
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

    pub fn operationAttempts(self: *FakeProvider) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.operation_attempts;
    }

    pub fn maxConcurrentOperations(self: *FakeProvider) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.max_concurrent_operations;
    }

    fn beginOperation(self: *FakeProvider, context: *OperationContext) ProviderError!void {
        self.mutex.lock();
        self.operation_attempts += 1;
        self.active_operations += 1;
        self.max_concurrent_operations = @max(self.max_concurrent_operations, self.active_operations);
        const delay_millis = self.operation_delay_millis;
        self.mutex.unlock();

        var remaining = delay_millis;
        while (remaining > 0) {
            context.checkActive() catch |err| {
                self.endOperation();
                return err;
            };
            const interval = @min(remaining, 2);
            context.sleep(interval);
            remaining -= interval;
        }
        context.checkActive() catch |err| {
            self.endOperation();
            return err;
        };
    }

    fn endOperation(self: *FakeProvider) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.active_operations -= 1;
    }

    fn takeFailureLocked(self: *FakeProvider) ProviderError!void {
        if (self.fail_next) |err| {
            self.fail_next = null;
            return err;
        }
    }

    fn read(
        raw: *anyopaque,
        context: *OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!ReadResult {
        const self: *FakeProvider = @ptrCast(@alignCast(raw));
        try self.beginOperation(context);
        defer self.endOperation();
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.takeFailureLocked();
        self.reads += 1;
        if (self.last_read_physical_id) |physical_id| self.allocator.free(physical_id);
        self.last_read_physical_id = if (context.physical_id) |physical_id|
            try self.allocator.dupe(u8, physical_id)
        else
            null;
        const remote = self.remotes.get(node.id) orelse return .absent;
        return .{ .present = try remote.result.clone(context.allocator) };
    }

    fn diff(
        raw: *anyopaque,
        context: *OperationContext,
        node: resource.ResourceNode,
        observed: *const ResourceResult,
    ) ProviderError!DiffResult {
        const self: *FakeProvider = @ptrCast(@alignCast(raw));
        try self.beginOperation(context);
        defer self.endOperation();
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.takeFailureLocked();
        if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash)) {
            return DiffResult.init(context.allocator, .noop, &.{});
        }
        return DiffResult.init(
            context.allocator,
            if (self.replace_changes) .replace else .update,
            &.{"desired inputs changed"},
        );
    }

    fn create(
        raw: *anyopaque,
        context: *OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!ResourceResult {
        const self: *FakeProvider = @ptrCast(@alignCast(raw));
        try self.beginOperation(context);
        defer self.endOperation();
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.takeFailureLocked();
        if (self.remotes.contains(node.id)) return error.Conflict;
        self.creates += 1;

        const physical_id = try std.fmt.allocPrint(self.allocator, "fake/{s}", .{node.id});
        defer self.allocator.free(physical_id);
        try self.insertRemote(node, physical_id);
        return (self.remotes.get(node.id) orelse return error.ProviderBug).result.clone(context.allocator);
    }

    fn update(
        raw: *anyopaque,
        context: *OperationContext,
        node: resource.ResourceNode,
        observed: *const ResourceResult,
    ) ProviderError!ResourceResult {
        _ = observed;
        const self: *FakeProvider = @ptrCast(@alignCast(raw));
        try self.beginOperation(context);
        defer self.endOperation();
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.takeFailureLocked();
        const remote = self.remotes.getPtr(node.id) orelse return error.NotFound;
        self.updates += 1;

        const inputs = value.Value.initOwned(self.allocator, node.inputs) catch |err| switch (err) {
            error.DuplicateField => return error.InvalidConfiguration,
            error.OutOfMemory => return error.OutOfMemory,
        };
        remote.result.observed_inputs.deinit(self.allocator);
        remote.result.observed_inputs = inputs;
        remote.result.observed_hash = node.inputs_hash;
        return remote.result.clone(context.allocator);
    }

    fn delete(
        raw: *anyopaque,
        context: *OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!void {
        _ = physical_id;
        const self: *FakeProvider = @ptrCast(@alignCast(raw));
        try self.beginOperation(context);
        defer self.endOperation();
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.takeFailureLocked();
        self.deletes += 1;
        self.last_delete_destructive_confirmation = context.destructive_confirmation;
        if (self.remotes.fetchRemove(node.id)) |removed| {
            var remote = removed.value;
            remote.deinit();
        }
    }

    fn importResource(
        raw: *anyopaque,
        context: *OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!ResourceResult {
        const self: *FakeProvider = @ptrCast(@alignCast(raw));
        try self.beginOperation(context);
        defer self.endOperation();
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.takeFailureLocked();
        if (self.remotes.contains(node.id)) return error.Conflict;
        self.imports += 1;
        try self.insertRemote(node, physical_id);
        return (self.remotes.get(node.id) orelse return error.ProviderBug).result.clone(context.allocator);
    }

    fn insertRemote(
        self: *FakeProvider,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!void {
        const resource_id = try self.allocator.dupe(u8, node.id);
        errdefer self.allocator.free(resource_id);
        var output_source: [3]state.StateOutput = undefined;
        output_source[0] = .{ .name = "physical_id", .value = .{ .string = physical_id } };
        var output_count: usize = 1;
        var dynamic_output: ?[]const u8 = null;
        defer if (dynamic_output) |value_string| self.allocator.free(value_string);

        if (std.mem.eql(u8, node.type_name, "gcp.artifact.Repository")) {
            const location = inputString(node, "location");
            const project_id = inputString(node, "project_id");
            const name = inputString(node, "name");
            if (location != null and project_id != null and name != null) {
                dynamic_output = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}-docker.pkg.dev/{s}/{s}",
                    .{ location.?, project_id.?, name.? },
                );
                output_source[output_count] = .{
                    .name = "repository_url",
                    .value = .{ .string = dynamic_output.? },
                };
                output_count += 1;
            }
        } else if (std.mem.eql(u8, node.type_name, "gcp.compute.GlobalAddress")) {
            output_source[output_count] = .{
                .name = "address",
                .value = .{ .string = "203.0.113.10" },
            };
            output_count += 1;
        } else if (std.mem.eql(u8, node.type_name, "gcp.compute.ManagedSslCertificate")) {
            output_source[output_count] = .{
                .name = "status",
                .value = .{ .string = "ACTIVE" },
            };
            output_count += 1;
            output_source[output_count] = .{
                .name = "domains_ready",
                .value = .{ .boolean = true },
            };
            output_count += 1;
        } else if (std.mem.eql(u8, node.type_name, "gcp.run.Service")) {
            const name = inputString(node, "name");
            const region = inputString(node, "region");
            const project_id = inputString(node, "project_id");
            const service_account = inputString(node, "service_account");
            if (name != null and region != null and project_id != null and service_account != null) {
                dynamic_output = try std.fmt.allocPrint(
                    self.allocator,
                    "https://{s}-{s}-{s}.run.app",
                    .{ name.?, region.?, project_id.? },
                );
                output_source[output_count] = .{
                    .name = "service_url",
                    .value = .{ .string = dynamic_output.? },
                };
                output_count += 1;
                output_source[output_count] = .{
                    .name = "service_account",
                    .value = .{ .string = service_account.? },
                };
                output_count += 1;
            }
        }
        var result = try ResourceResult.init(
            self.allocator,
            physical_id,
            node.inputs,
            output_source[0..output_count],
            self.result_operation_handle,
        );
        result.completed = self.result_completed;
        errdefer result.deinit();
        const remote = RemoteRecord{
            .allocator = self.allocator,
            .resource_id = resource_id,
            .result = result,
        };
        try self.remotes.put(resource_id, remote);
    }
};

fn inputString(node: resource.ResourceNode, name: []const u8) ?[]const u8 {
    return switch (node.inputs) {
        .object => |fields| for (fields) |field| {
            if (!std.mem.eql(u8, field.name, name)) continue;
            break switch (field.value) {
                .string => |string| string,
                else => null,
            };
        } else null,
        else => null,
    };
}

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
