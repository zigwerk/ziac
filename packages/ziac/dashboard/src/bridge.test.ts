import { expect, test } from "bun:test";
import {
  estateAccessState,
  loadDashboardPayloadFromBridge,
  parseZiacLogSnapshot,
  requestEstateScan,
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
