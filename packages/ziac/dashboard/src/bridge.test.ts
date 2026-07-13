import { expect, test } from "bun:test";
import {
  applyWorkspacePatch,
  cancelDashboardOperation,
  estateAccessState,
  loadDashboardPayloadFromBridge,
  loadDashboardOperation,
  parseZiacLogSnapshot,
  requestEstateScan,
  runDashboardOperation,
  startDashboardWatch,
  subscribeWorkspacePatches,
} from "./bridge";

test("standalone dashboard loads only Ziac-owned samples", async () => {
  const loaded: string[] = [];
  const base = await loadDashboardPayloadFromBridge({}, async (sample) => {
    loaded.push(sample);
    return JSON.stringify({ schema: "ziac.visual.v1" });
  }, "?sample=ziac");
  const estate = await loadDashboardPayloadFromBridge({}, async (sample) => {
    loaded.push(sample);
    return JSON.stringify({ schema: "ziac.visual.v1" });
  }, "?sample=estate");
  const workspace = await loadDashboardPayloadFromBridge({}, async (sample) => {
    loaded.push(sample);
    return JSON.stringify({ schema: "ziac.workspace-visual.v1" });
  }, "?sample=workspace");

  expect(loaded).toEqual(["sample-ziac-global.json", "sample-ziac-estate.json", "sample-ziac-workspace.json"]);
  expect(base.session?.schema).toBe("ziac.dashboard-session.v1");
  expect(estate.session?.artifact_path).toBe("sample-ziac-estate.json");
  expect(workspace.session?.artifact_path).toBe("sample-ziac-workspace.json");
});

test("dashboard operations send typed requests and require command receipts", async () => {
  let sent = "";
  const receipt = await runDashboardOperation({
    schema: "ziac.dashboard-operation-request.v1",
    operation: "plan",
    project: "control-plane",
    stack: "control-plane",
    stage: "prod",
    provider: "gcp",
  }, {
    ziac_operation_plan: async (request) => {
      sent = request;
      return JSON.stringify({
        schema: "ziac.command.v2",
        command: "plan",
        status: "success",
        stack: "control-plane",
        stage: "prod",
        create: 12,
        update: 0,
        delete: 0,
        noop: 0,
        plan_digest: "a".repeat(64),
        plan_path: ".ziac/dashboard/plans/control-plane-prod.ziac-plan.json",
        approval_required: false,
      });
    },
  });
  expect(JSON.parse(sent)).toMatchObject({ operation: "plan", provider: "gcp" });
  expect(receipt.plan_digest).toBe("a".repeat(64));
});

test("standalone dashboard never substitutes a fixture for a missing live host", async () => {
  let sampleCalls = 0;
  await expect(loadDashboardPayloadFromBridge({}, async () => {
    sampleCalls += 1;
    return "{}";
  })).rejects.toThrow("Ziac dashboard host is not connected");
  expect(sampleCalls).toBe(0);
});

test("standalone dashboard uses Ziac-namespaced host functions", async () => {
  const calls: string[] = [];
  const payload = await loadDashboardPayloadFromBridge({
    webui: {
      call: async (name) => {
        calls.push(name);
        if (name === "ziac_load_artifact") return JSON.stringify({ schema: "ziac.visual.v1" });
        if (name === "ziac_load_session") return JSON.stringify({ schema: "ziac.dashboard-session.v1" });
        throw new Error(`unexpected call: ${name}`);
      },
    },
  });

  expect(calls).toEqual(["ziac_load_artifact", "ziac_load_session"]);
  expect(payload.session?.schema).toBe("ziac.dashboard-session.v1");
});

test("estate access fails closed and scan receipts stay mutation isolated", async () => {
  expect(estateAccessState(null)).toMatchObject({ ready: false, reason: "google_sign_in_required" });
  expect(estateAccessState({ estate_access: {
    identity_provider: "google",
    authenticated: true,
    entitlement: "pro",
    connection: "connected",
    project_id: "acme-foundation-prod",
    last_scan_millis: 1783764000000,
  } })).toMatchObject({ ready: true, projectId: "acme-foundation-prod" });

  const result = await requestEstateScan({
    ziac_scan_estate: async () => JSON.stringify({
      schema: "ziac.estate-scan-receipt.v1",
      project_id: "acme-foundation-prod",
      resources: 17,
      ownership: "observed",
      mutation_authorized: false,
    }),
  });
  expect(result).toEqual({ ok: true, resources: 17, projectId: "acme-foundation-prod" });
});

test("Ziac log snapshots are bounded and reject credential material", () => {
  const snapshot = parseZiacLogSnapshot(JSON.stringify({
    schema: "ziac.log.v1",
    sequence: 7,
    event_id: "revision-ready",
    timestamp_millis: 12,
    source: "cloud_run",
    severity: "info",
    message: "revision ready",
    dropped_count: 2,
    suppressed_count: 1,
  }));
  expect(snapshot?.log_summary).toEqual({ retained: 1, dropped: 2, suppressed: 1 });
  expect(parseZiacLogSnapshot('{"schema":"ziac.log.v1","authorization":"Bearer secret"}')).toBeNull();
});

test("workspace patches replace project slices and reject stale bases", () => {
  const current = JSON.stringify({
    schema: "ziac.workspace-visual.v1",
    format_version: 1,
    workspace: "ziac-cloud",
    created_at_millis: 1,
    revision: "a".repeat(64),
    projects: [
      { project: "api", path: "platform/api", stack: "api", stage: "prod", artifact: { schema: "ziac.visual.v1", resources: [{ id: "old" }] } },
      { project: "data", path: "platform/data", stack: "data", stage: "prod", artifact: { schema: "ziac.visual.v1", resources: [] } },
    ],
    links: [],
  });
  const patch = JSON.stringify({
    schema: "ziac.workspace-patch.v1",
    base_revision: "a".repeat(64),
    revision: "b".repeat(64),
    workspace: "ziac-cloud",
    created_at_millis: 2,
    changed_projects: [{ project: "api", path: "platform/api", stack: "api", stage: "prod", artifact: { schema: "ziac.visual.v1", resources: [{ id: "new" }] } }],
    removed_project_ids: [],
    project_order: ["api", "data"],
    links: [],
  });
  const updated = applyWorkspacePatch(current, patch);
  expect(updated).not.toBeNull();
  expect(JSON.parse(updated!).revision).toBe("b".repeat(64));
  expect(JSON.parse(updated!).projects[0].artifact.resources[0].id).toBe("new");
  expect(applyWorkspacePatch(updated!, patch)).toBeNull();
  expect(applyWorkspacePatch(current, patch.replace("new", "token: secret"))).toBeNull();
});

test("watch operations start asynchronously, expose status, and cancel by host id", async () => {
  const calls: string[] = [];
  const operation = {
    schema: "ziac.dashboard-operation.v1",
    operation_id: "op-00000001",
    kind: "watch",
    phase: "running",
    project: "control-plane",
    stack: "control-plane",
    stage: "prod",
    started_at_millis: 42,
  } as const;
  const bridge = {
    ziac_operation_watch: async (request: string) => {
      calls.push(`watch:${JSON.parse(request).operation}`);
      return JSON.stringify(operation);
    },
    ziac_operation_status: async (request: string) => {
      calls.push(`status:${JSON.parse(request).operation_id}`);
      return JSON.stringify(operation);
    },
    ziac_operation_cancel: async (request: string) => {
      calls.push(`cancel:${JSON.parse(request).operation_id}`);
      return JSON.stringify({ ...operation, phase: "cancelling" });
    },
  };
  const started = await startDashboardWatch({
    schema: "ziac.dashboard-operation-request.v1",
    operation: "watch",
    project: "control-plane",
    stack: "control-plane",
    stage: "prod",
    provider: "gcp",
    plan_digest: "a".repeat(64),
  }, bridge);
  expect(started.phase).toBe("running");
  expect((await loadDashboardOperation(started.operation_id, bridge)).operation_id).toBe(started.operation_id);
  expect((await cancelDashboardOperation(started.operation_id, bridge)).phase).toBe("cancelling");
  expect(calls).toEqual(["watch:watch", "status:op-00000001", "cancel:op-00000001"]);
});

test("workspace patch subscriptions are removable and ignore non-string events", () => {
  const target = new EventTarget();
  const received: string[] = [];
  const unsubscribe = subscribeWorkspacePatches((patch) => received.push(patch), target);
  const valid = new Event("ziac-workspace-patch");
  Object.defineProperty(valid, "detail", { value: "{\"schema\":\"ziac.workspace-patch.v1\"}" });
  target.dispatchEvent(valid);
  const invalid = new Event("ziac-workspace-patch");
  Object.defineProperty(invalid, "detail", { value: { patch: "ignored" } });
  target.dispatchEvent(invalid);
  unsubscribe();
  target.dispatchEvent(valid);
  expect(received).toEqual(["{\"schema\":\"ziac.workspace-patch.v1\"}"]);
});
