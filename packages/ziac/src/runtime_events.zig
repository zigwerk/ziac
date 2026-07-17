const std = @import("std");
const fx = @import("zigeffect_std").fx;

/// Stable infrastructure semantics emitted by reusable Ziac adapters. Product
/// applications never construct these facts; they emerge from planning,
/// provider, workflow and state boundaries interpreted by the owning runtime.
pub const Kind = enum {
    plan,
    resource_operation,
    provider_rpc,
    retry,
    long_running_operation,
    state_commit,
    drift,
    workflow_checkpoint,
};

pub const Fact = struct {
    kind: Kind,
    label: []const u8,
    status: []const u8,
    detail: []const u8 = "",
    service_key: []const u8 = "",
    type_name: []const u8 = "",
    parent_id: ?u64 = null,
};

pub fn typeName(kind: Kind) []const u8 {
    return switch (kind) {
        .plan => "ziac.plan",
        .resource_operation => "ziac.resource.operation",
        .provider_rpc => "ziac.provider.rpc",
        .retry => "ziac.retry",
        .long_running_operation => "ziac.lro",
        .state_commit => "ziac.state.commit",
        .drift => "ziac.drift",
        .workflow_checkpoint => "ziac.workflow.checkpoint",
    };
}

pub fn kindFromEvent(event: fx.CausalEvent) ?Kind {
    if (event.kind != .span_recorded) return null;
    inline for (std.meta.tags(Kind)) |kind| {
        if (std.mem.eql(u8, event.type_name, typeName(kind))) return kind;
    }
    return null;
}

/// Copyable, recording-only semantic capability. It cannot inspect, configure
/// or release the runtime-owned causal store. `parent_id` creates one resource
/// branch beneath the application plan while the underlying recorder retains
/// run/fiber/scope/trace lineage.
pub const Recorder = struct {
    causal: ?fx.kernel.CausalRecorder = null,
    parent_id: ?u64 = null,

    pub const disabled: Recorder = .{};

    pub fn fromContext(ctx: anytype) Recorder {
        return .{ .causal = ctx.causalRecorder() };
    }

    /// Deterministic test adapter. Production code derives recorders from an
    /// effect context so lineage is captured automatically.
    pub fn fromStore(store: *fx.CausalStore) Recorder {
        return .{ .causal = fx.kernel.CausalRecorder.fromStore(store) };
    }

    pub fn child(self: Recorder, parent_id: ?u64) Recorder {
        var derived = self;
        derived.parent_id = parent_id orelse self.parent_id;
        return derived;
    }

    pub fn record(self: Recorder, fact: Fact) ?u64 {
        const recorder = self.causal orelse return null;
        return recorder.record(.{
            .kind = .span_recorded,
            .parent_id = fact.parent_id orelse self.parent_id,
            .cause_event_id = fact.parent_id orelse self.parent_id,
            .label = fact.label,
            .type_name = if (fact.type_name.len == 0) typeName(fact.kind) else fact.type_name,
            .status = fact.status,
            .redacted_detail = fact.detail,
            .service_key = fact.service_key,
            .domain_entity_ref = fact.label,
        }) catch null;
    }

    pub fn plan(self: Recorder, label: []const u8, status: []const u8, detail: []const u8) ?u64 {
        return self.record(.{ .kind = .plan, .label = label, .status = status, .detail = detail, .service_key = "ziac/StateStore" });
    }

    pub fn resourceOperation(self: Recorder, resource_id: []const u8, operation: []const u8, status: []const u8) ?u64 {
        return self.record(.{ .kind = .resource_operation, .label = resource_id, .status = status, .detail = operation, .service_key = "ziac/ProviderRegistry" });
    }

    pub fn providerRpc(self: Recorder, resource_id: []const u8, method: []const u8, status: []const u8) ?u64 {
        return self.record(.{ .kind = .provider_rpc, .label = resource_id, .status = status, .detail = method, .service_key = "ziac/ProviderRegistry" });
    }

    pub fn retry(self: Recorder, resource_id: []const u8, operation: []const u8, status: []const u8) ?u64 {
        return self.record(.{ .kind = .retry, .label = resource_id, .status = status, .detail = operation, .service_key = "ziac/ProviderRegistry" });
    }

    pub fn longRunningOperation(self: Recorder, resource_id: []const u8, operation: []const u8, status: []const u8) ?u64 {
        return self.record(.{ .kind = .long_running_operation, .label = resource_id, .status = status, .detail = operation, .service_key = "ziac/ProviderRegistry" });
    }

    pub fn stateCommit(self: Recorder, resource_id: []const u8, state: []const u8, status: []const u8) ?u64 {
        return self.record(.{ .kind = .state_commit, .label = resource_id, .status = status, .detail = state, .service_key = "ziac/StateStore" });
    }

    pub fn drift(self: Recorder, resource_id: []const u8, status: []const u8, detail: []const u8) ?u64 {
        return self.record(.{ .kind = .drift, .label = resource_id, .status = status, .detail = detail, .service_key = "ziac/ProviderRegistry" });
    }

    pub fn workflowCheckpoint(self: Recorder, workflow_name: []const u8, status: []const u8, detail: []const u8) ?u64 {
        return self.record(.{ .kind = .workflow_checkpoint, .label = workflow_name, .status = status, .detail = detail, .service_key = "ziac/WorkflowRuntime" });
    }

    pub fn workflow(self: Recorder, allocator: std.mem.Allocator, journal: fx.workflow.JournalStore) WorkflowRecording {
        return WorkflowRecording.init(allocator, journal, self);
    }
};

/// Runtime decoration for a durable workflow. It owns only the adapter around
/// the caller-owned journal; the managed runtime continues to own recording and
/// graph persistence.
pub const WorkflowRecording = struct {
    allocator: std.mem.Allocator,
    inner: fx.workflow.JournalStore,
    recorder: Recorder,
    causal_journal: ?fx.workflow.CausalJournalStore = null,

    pub fn init(allocator: std.mem.Allocator, inner: fx.workflow.JournalStore, recorder: Recorder) WorkflowRecording {
        return .{
            .allocator = allocator,
            .inner = inner,
            .recorder = recorder,
            .causal_journal = if (recorder.causal) |causal|
                fx.workflow.CausalJournalStore.initRecorder(allocator, inner, causal, null)
            else
                null,
        };
    }

    pub fn deinit(self: *WorkflowRecording) void {
        if (self.causal_journal) |*value| value.deinit();
        self.* = undefined;
    }

    pub fn journal(self: *WorkflowRecording) fx.workflow.JournalStore {
        return if (self.causal_journal) |*value| value.asJournalStore() else self.inner;
    }

    pub fn latestCausalId(self: *const WorkflowRecording) ?u64 {
        return if (self.causal_journal) |*value| value.latestCausalId() else self.recorder.parent_id;
    }

    pub fn recordDecision(
        self: *WorkflowRecording,
        comptime DefinitionType: type,
        definition: *const DefinitionType,
        decision: anytype,
        parent_id: ?u64,
    ) !?u64 {
        const causal = self.recorder.causal orelse return parent_id;
        return try fx.statechart.recordDecision(
            DefinitionType,
            causal,
            self.allocator,
            definition,
            decision,
            self.latestCausalId() orelse parent_id,
        );
    }
};

test "semantic recorder creates a typed parented infrastructure path" {
    var store = fx.CausalStore.init(std.testing.allocator);
    defer store.deinit();
    const recorder = Recorder.fromStore(&store);
    const plan_id = recorder.plan("stack", "success", "deterministic-plan");
    const operation_id = recorder.child(plan_id).resourceOperation("gcp.test.Resource.service", "create", "started");
    const provider_id = recorder.child(operation_id).providerRpc("gcp.test.Resource.service", "create", "success");
    _ = recorder.child(provider_id).stateCommit("gcp.test.Resource.service", "created", "success");

    var snapshot = try store.snapshot(std.testing.allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 4), snapshot.events.len);
    try std.testing.expectEqual(Kind.plan, kindFromEvent(snapshot.events[0]).?);
    try std.testing.expectEqual(Kind.resource_operation, kindFromEvent(snapshot.events[1]).?);
    try std.testing.expectEqual(Kind.provider_rpc, kindFromEvent(snapshot.events[2]).?);
    try std.testing.expectEqual(Kind.state_commit, kindFromEvent(snapshot.events[3]).?);
    try std.testing.expectEqual(snapshot.events[0].id, snapshot.events[1].parent_id.?);
    try std.testing.expectEqual(snapshot.events[1].id, snapshot.events[2].parent_id.?);
    try std.testing.expectEqual(snapshot.events[2].id, snapshot.events[3].parent_id.?);
}
