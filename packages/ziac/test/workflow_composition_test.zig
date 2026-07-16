const std = @import("std");
const ziac = @import("ziac");
const zstd = @import("zigeffect_std");

const scenario = zstd.Testing.Scenario{
    .id = "watch-deploy-statechart-workflow",
    .label = "watch deployment is a replay-safe statechart workflow",
    .requirement = "ziac-durable-workflow-control",
    .acceptance_check = "check-ziac-durable-workflow-control",
    .component = "ziac",
    .command = "test",
};

const image = "europe-west1-docker.pkg.dev/project-dev/apps/api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const acceptance_source = zstd.Testing.Contract.SourceReference{
    .id = "ziac-workflow-acceptance",
    .path = "packages/ziac/test/workflow_composition_test.zig",
    .line = 31,
    .column = 1,
};

fn envelope() ziac.agent_contract.CapabilityEnvelope {
    return .{
        .id = "watch-workflow-test",
        .stages = &.{"dev"},
        .projects = &.{"project-dev"},
        .providers = &.{.gcp},
        .permissions = .{ .apply = true },
        .budget = .{ .max_updates = 1, .max_regions = 1 },
        .expires_at_millis = 20_000,
        .approved_plan_digest = "watch-plan",
    };
}

test "watch deployment composes a typed statechart with replay-safe workflow activities" {
    var evidence = try zstd.Testing.TestContext.initFromProject(std.testing.allocator, std.testing.io, std.Io.Dir.cwd(), .{
        .project = "ziac",
        .suite = "ziac-tests",
        .scenario = scenario,
        .seed = 216,
    });
    defer evidence.deinit();
    const assertions = zstd.Testing.AssertionRecorder.init(&evidence);

    const empty = zstd.fx.kernel.Layer.empty();
    var runtime = try zstd.ManagedRuntime(@TypeOf(empty)).make(
        std.testing.allocator,
        std.testing.io,
        std.Io.Dir.cwd(),
        empty,
        .{
            .causal_store = evidence.causalStore(),
            .graph = .{ .path = ".zigeffect/graph" },
        },
    );
    defer runtime.deinit();

    var journal_dir = std.testing.tmpDir(.{});
    defer journal_dir.cleanup();
    var statechart_dir = std.testing.tmpDir(.{});
    defer statechart_dir.cleanup();
    try ziac.watch_deploy.registerStatechart(std.testing.allocator, std.testing.io, statechart_dir.dir, 1024 * 1024);
    var catalog = try zstd.Statechart.readCatalogRecovering(std.testing.allocator, std.testing.io, statechart_dir.dir, 1024 * 1024);
    defer catalog.deinit();
    var provider = ziac.watch_deploy.ScriptedRuntime.init();
    provider.now_millis = 1_000;
    provider.push_millis = 100;
    provider.revision_millis = 200;
    provider.readiness_millis = 300;
    provider.traffic_millis = 50;

    const input = ziac.watch_deploy.ExecuteInput{
        .now_millis = 1_000,
        .stage = "dev",
        .project = "project-dev",
        .plan_digest = "watch-plan",
        .image_ref = image,
        .regions = 1,
    };
    const first = first_execution: {
        var journal = try zstd.fx.workflow.FileJournalStore.open(std.testing.allocator, std.testing.io, &journal_dir.dir, .{
            .fsync_policy = .after_append,
            .owner_id = "ziac-workflow-acceptance-first",
        });
        defer journal.deinit();
        break :first_execution try ziac.watch_deploy.executeWorkflow(std.testing.allocator, .{
            .journal = journal.asJournalStore(),
            .causal_store = evidence.causalStore(),
        }, provider.runtime(), envelope(), input);
    };
    const replayed = replay_execution: {
        var reopened = try zstd.fx.workflow.FileJournalStore.open(std.testing.allocator, std.testing.io, &journal_dir.dir, .{
            .fsync_policy = .after_append,
            .owner_id = "ziac-workflow-acceptance-reopened",
        });
        defer reopened.deinit();
        break :replay_execution try ziac.watch_deploy.executeWorkflow(std.testing.allocator, .{
            .journal = reopened.asJournalStore(),
            .causal_store = evidence.causalStore(),
        }, provider.runtime(), envelope(), input);
    };

    try assertions.boolean(.{
        .id = "ziac.workflow.rollout-complete",
        .label = "rollout statechart reaches complete",
        .source = acceptance_source,
        .repair_hint = "drive every committed workflow activity result back into the rollout statechart",
    }, first.status == .complete and replayed.status == .complete);
    try assertions.boolean(.{
        .id = "ziac.workflow.statechart-discoverable",
        .label = "rollout statechart is discoverable through the project catalog",
        .source = acceptance_source,
        .repair_hint = "register typed application machines without replacing other statechart catalog entries",
    }, catalog.value.definition("ziac.watch-deploy") != null);
    try assertions.boolean(.{
        .id = "ziac.workflow.activities-idempotent",
        .label = "workflow journal reopen does not repeat cloud mutations",
        .source = acceptance_source,
        .repair_hint = "derive stable activity idempotency keys from the immutable plan execution",
    }, provider.push_count == 1 and provider.revision_count == 1 and provider.readiness_count == 1 and provider.traffic_count == 1);
    _ = try assertions.event(.{
        .id = "ziac.workflow.statechart-causal",
        .label = "rollout transitions are causally queryable",
        .source = acceptance_source,
        .repair_hint = "record every typed statechart decision through the runtime-owned causal store",
    }, .{ .kind = .statechart_event_recorded, .label = "traffic-promoted", .status = "committed" });
    _ = try assertions.event(.{
        .id = "ziac.workflow.activity-causal",
        .label = "rollout activities are causally queryable",
        .source = acceptance_source,
        .repair_hint = "wrap the durable journal with the runtime-owned causal recorder",
    }, .{ .kind = .workflow_event_recorded, .label = "ziac.watch-deploy.promote-traffic", .status = "completed" });
    try assertions.eventPath(.{
        .id = "ziac.workflow.causal-model-joined",
        .label = "workflow activities and statechart decisions form one causal graph",
        .source = acceptance_source,
        .repair_hint = "parent each statechart decision to the durable activity result that produced its event",
    }, .{
        .kind = .workflow_event_recorded,
        .label = "ziac.watch-deploy.promote-traffic",
        .status = "completed",
    }, .{
        .kind = .statechart_event_recorded,
        .label = "traffic-promoted",
        .status = "committed",
    }, 16);
    try assertions.noPendingFibers(.{
        .id = "ziac.workflow.no-pending-fibers",
        .label = "rollout workflow leaves no pending fibers",
        .source = acceptance_source,
        .repair_hint = "join workflow work before closing the command scope",
    });
    try assertions.noFindings(.{
        .id = "ziac.workflow.no-findings",
        .label = "rollout workflow has no causal safety findings",
        .source = acceptance_source,
        .repair_hint = "complete or explicitly fail every statechart command and workflow activity",
    });

    try evidence.mapCausalEventIds(&runtime);
    try runtime.shutdown();
    try evidence.publish(std.testing.io, std.Io.Dir.cwd(), 1);
}
