export type ZiacSession = {
  schema?: string;
  artifact_path?: string;
  artifact_bytes?: number;
  read_only?: boolean;
  warnings?: string[];
  agent?: {
    session_id: string;
    objective: string;
    state: string;
    next_action?: string;
  };
  log_summary?: {
    retained: number;
    dropped: number;
    suppressed: number;
  };
  logs?: ZiacLogEvent[];
  estate_access?: unknown;
};

export type ZiacEstateAccessState = {
  ready: boolean;
  reason: "ready" | "google_sign_in_required" | "pro_required" | "gcp_connection_required" | "invalid_access_projection";
  projectId?: string;
  lastScanMillis?: number;
};

export type ZiacLogEvent = {
  sequence: number;
  event_id: string;
  parent_event_id?: string;
  timestamp_millis: number;
  source: string;
  severity: string;
  message: string;
  resource_id?: string;
  region?: string;
  revision?: string;
  trace_id?: string;
};

export type ZiacDashboardPayload = {
  artifactJson: string;
  session: ZiacSession | null;
};

type WebuiApi = {
  call?: (name: string, ...args: unknown[]) => string | Promise<string>;
  isConnected?: () => boolean;
};

export type ZiacBridgeWindow = {
  webui?: WebuiApi;
  ziac_load_artifact?: () => string | Promise<string>;
  ziac_load_session?: () => string | Promise<string>;
  ziac_load_log_snapshot?: () => string | Promise<string>;
  ziac_scan_estate?: () => string | Promise<string>;
  ziac_request_estate_access?: (reason: ZiacEstateAccessState["reason"]) => string | Promise<string>;
};

type BridgeFunctionName = "ziac_load_artifact" | "ziac_load_session" | "ziac_load_log_snapshot" | "ziac_scan_estate";

export async function loadDashboardPayload(): Promise<ZiacDashboardPayload> {
  const bridge = window as ZiacBridgeWindow;
  await ensureWebuiScript();
  await waitForWebuiBridge(bridge);

  return loadDashboardPayloadFromBridge(bridge, loadSampleArtifact, currentSearch());
}

export async function loadDashboardPayloadFromBridge(
  bridge: ZiacBridgeWindow,
  loadSample: (sampleName: string) => Promise<string> = loadSampleArtifact,
  search = "",
): Promise<ZiacDashboardPayload> {

  const [artifactJson, sessionJson] = await Promise.all([
    callBridgeFunction(bridge, "ziac_load_artifact"),
    callBridgeFunction(bridge, "ziac_load_session"),
  ]);

  if (artifactJson !== null) {
    return { artifactJson, session: parseSession(sessionJson) };
  }

  const sampleName = sampleNameFromSearch(search);
  if (sampleName === null) throw new Error("Ziac dashboard host is not connected");
  return {
    artifactJson: await loadSample(sampleName),
    session: sampleSession(sampleName),
  };
}

export function estateAccessState(session: { estate_access?: unknown } | null): ZiacEstateAccessState {
  const value = session?.estate_access;
  if (value === undefined) return { ready: false, reason: "google_sign_in_required" };
  if (!isRecord(value) || containsCredentialKey(value)) return { ready: false, reason: "invalid_access_projection" };
  if (value.identity_provider !== "google" || typeof value.authenticated !== "boolean") return { ready: false, reason: "invalid_access_projection" };
  if (!value.authenticated) return { ready: false, reason: "google_sign_in_required" };
  if (value.entitlement !== "none" && value.entitlement !== "pro") return { ready: false, reason: "invalid_access_projection" };
  if (value.entitlement !== "pro") return { ready: false, reason: "pro_required" };
  if (value.connection !== "connected" && value.connection !== "disconnected") return { ready: false, reason: "invalid_access_projection" };
  if (value.connection !== "connected") return { ready: false, reason: "gcp_connection_required" };
  if (typeof value.project_id !== "string" || value.project_id.length === 0 || !Number.isSafeInteger(value.last_scan_millis) || Number(value.last_scan_millis) < 0) {
    return { ready: false, reason: "invalid_access_projection" };
  }
  return { ready: true, reason: "ready", projectId: value.project_id, lastScanMillis: Number(value.last_scan_millis) };
}

export async function requestEstateAccess(reason: ZiacEstateAccessState["reason"]): Promise<boolean> {
  const bridge = window as ZiacBridgeWindow;
  if (typeof bridge.webui?.call === "function") {
    await bridge.webui.call("ziac_request_estate_access", reason);
    return true;
  }
  if (typeof bridge.ziac_request_estate_access === "function") {
    await bridge.ziac_request_estate_access(reason);
    return true;
  }
  return false;
}

export type EstateScanResult =
  | { ok: true; resources: number; projectId: string }
  | { ok: false; reason: "host_unavailable" | "invalid_receipt" | "scan_failed" };

export async function requestEstateScan(bridge: ZiacBridgeWindow = window as ZiacBridgeWindow): Promise<EstateScanResult> {
  const payload = await callBridgeFunction(bridge, "ziac_scan_estate");
  if (payload === null) return { ok: false, reason: "host_unavailable" };
  if (payload.length === 0 || payload.length > 64 * 1024 || containsCredentialMaterial(payload)) return { ok: false, reason: "invalid_receipt" };
  try {
    const value: unknown = JSON.parse(payload);
    if (!isRecord(value)) return { ok: false, reason: "invalid_receipt" };
    if (value.schema === "ziac.estate-scan-error.v1") return { ok: false, reason: "scan_failed" };
    if (value.schema !== "ziac.estate-scan-receipt.v1" || value.mutation_authorized !== false || value.ownership !== "observed") {
      return { ok: false, reason: "invalid_receipt" };
    }
    if (typeof value.project_id !== "string" || value.project_id.length === 0 || !Number.isSafeInteger(value.resources) || Number(value.resources) < 0) {
      return { ok: false, reason: "invalid_receipt" };
    }
    return { ok: true, resources: Number(value.resources), projectId: value.project_id };
  } catch {
    return { ok: false, reason: "invalid_receipt" };
  }
}

export async function loadLiveLogSnapshot(bridge: ZiacBridgeWindow = window as ZiacBridgeWindow): Promise<ZiacSession | null> {
  const payload = await callBridgeFunction(bridge, "ziac_load_log_snapshot");
  return payload === null ? null : parseZiacLogSnapshot(payload);
}

export function parseZiacLogSnapshot(payload: string): ZiacSession | null {
  if (payload.length === 0 || payload.length > 8 * 1024 * 1024 || containsCredentialMaterial(payload)) return null;
  const lines = payload.split("\n").filter((line) => line.length > 0);
  if (lines.length === 0 || lines.length > 5_000) return null;
  const logs: ZiacLogEvent[] = [];
  let dropped = 0;
  let suppressed = 0;

  for (const line of lines) {
    let value: unknown;
    try {
      value = JSON.parse(line);
    } catch {
      return null;
    }
    if (!isRecord(value) || value.schema !== "ziac.log.v1" || containsCredentialKey(value)) return null;
    if (!Number.isSafeInteger(value.sequence) || Number(value.sequence) < 0 || !Number.isSafeInteger(value.timestamp_millis) ||
      typeof value.event_id !== "string" || value.event_id.length === 0 || typeof value.source !== "string" ||
      typeof value.severity !== "string" || typeof value.message !== "string") return null;
    const event: ZiacLogEvent = {
      sequence: Number(value.sequence),
      event_id: value.event_id,
      timestamp_millis: Number(value.timestamp_millis),
      source: value.source,
      severity: value.severity,
      message: value.message,
    };
    for (const key of ["parent_event_id", "resource_id", "region", "revision", "trace_id"] as const) {
      const entry = value[key];
      if (entry !== undefined && entry !== null && typeof entry !== "string") return null;
      if (typeof entry === "string") event[key] = entry;
    }
    logs.push(event);
    dropped = Math.max(dropped, safeCount(value.dropped_count));
    suppressed = Math.max(suppressed, safeCount(value.suppressed_count));
  }

  logs.sort((left, right) => left.sequence - right.sequence);
  return {
    schema: "ziac.dashboard-session.v1",
    read_only: true,
    log_summary: { retained: logs.length, dropped, suppressed },
    logs,
  };
}

function sampleNameFromSearch(search: string): string | null {
  const sample = new URLSearchParams(search).get("sample");
  if (sample === "workspace") return "sample-ziac-workspace.json";
  if (sample === "estate") return "sample-ziac-estate.json";
  if (sample === "permissions") return "sample-ziac-permissions.json";
  if (sample === "ziac" || sample === "global") return "sample-ziac-global.json";
  return null;
}

function sampleSession(sampleName: string): ZiacSession {
  const base: ZiacSession = {
    schema: "ziac.dashboard-session.v1",
    artifact_path: sampleName,
    read_only: true,
    warnings: ["development sample artifact"],
  };
  if (sampleName === "sample-ziac-estate.json") {
    return {
      ...base,
      estate_access: {
        identity_provider: "google",
        authenticated: true,
        entitlement: "pro",
        connection: "connected",
        project_id: "acme-foundation-prod",
        last_scan_millis: 1783764000000,
      },
    };
  }
  if (sampleName !== "sample-ziac-global.json") return base;
  return {
    ...base,
    agent: { session_id: "dev-global-api", objective: "Verify the global API rollout", state: "diagnosing", next_action: "Propose the minimum IAM repair" },
    log_summary: { retained: 4, dropped: 0, suppressed: 1 },
    logs: [
      { sequence: 18, event_id: "rpc-create", timestamp_millis: 1, source: "provider", severity: "info", message: "Cloud Run revision created with zero traffic", resource_id: "gcp.run.Service.europe-west1.api", region: "europe-west1", trace_id: "trace-rollout-42" },
      { sequence: 19, event_id: "revision-ready", parent_event_id: "rpc-create", timestamp_millis: 2, source: "cloud_run", severity: "info", message: "Revision readiness checks passed", resource_id: "gcp.run.Service.europe-west1.api", region: "europe-west1", revision: "api-00042", trace_id: "trace-rollout-42" },
      { sequence: 20, event_id: "request-failed", parent_event_id: "revision-ready", timestamp_millis: 3, source: "process", severity: "error", message: "DATABASE_URL binding could not access the declared secret version", resource_id: "gcp.run.Service.europe-west1.api", region: "europe-west1", revision: "api-00042", trace_id: "trace-request-91" },
      { sequence: 21, event_id: "iam-diagnosis", parent_event_id: "request-failed", timestamp_millis: 4, source: "agent", severity: "warn", message: "Runtime identity is missing secretmanager.versions.access", resource_id: "gcp.secret.Secret.database-url", region: "europe-west1", trace_id: "trace-request-91" },
    ],
  };
}

function parseSession(payload: string | null): ZiacSession | null {
  if (payload === null || payload.length === 0 || payload.length > 1024 * 1024 || containsCredentialMaterial(payload)) return null;
  try {
    const value: unknown = JSON.parse(payload);
    return isRecord(value) && !containsCredentialKey(value) ? value as ZiacSession : null;
  } catch {
    return null;
  }
}

async function callBridgeFunction(bridge: ZiacBridgeWindow, name: BridgeFunctionName): Promise<string | null> {
  if (typeof bridge.webui?.call === "function") return bridge.webui.call(name);
  const direct = bridge[name];
  return typeof direct === "function" ? direct() : null;
}

async function loadSampleArtifact(sampleName: string): Promise<string> {
  if (sampleName === "sample-ziac-workspace.json") {
    const response = await fetch("./sample-ziac-global.json");
    if (!response.ok) throw new Error(`failed to load Ziac sample (${response.status})`);
    const artifact: unknown = await response.json();
    const resourceId = isRecord(artifact) && Array.isArray(artifact.resources) && isRecord(artifact.resources[0]) && typeof artifact.resources[0].id === "string"
      ? artifact.resources[0].id
      : null;
    return JSON.stringify({
      schema: "ziac.workspace-visual.v1",
      format_version: 1,
      workspace: "ziac-cloud",
      created_at_millis: 1783764000000,
      projects: [
        { project: "payments", path: "services/payments/infra", stack: "global-api", stage: "dev", artifact },
        { project: "platform", path: "platform", stack: "foundation", stage: "dev", artifact },
      ],
      links: resourceId ? [{
        id: "payments-platform",
        from: { project: "payments", resource: resourceId },
        to: { project: "platform", resource: resourceId },
        kind: "dependency",
      }] : [],
    });
  }
  const response = await fetch(`./${sampleName}`);
  if (!response.ok) throw new Error(`failed to load Ziac sample (${response.status})`);
  return response.text();
}

async function ensureWebuiScript(): Promise<void> {
  if (document.querySelector<HTMLScriptElement>('script[data-ziac-webui="true"]')) return;
  await new Promise<void>((resolve) => {
    const script = document.createElement("script");
    script.src = "/webui.js";
    script.dataset.ziacWebui = "true";
    script.onload = () => resolve();
    script.onerror = () => resolve();
    document.head.append(script);
  });
}

async function waitForWebuiBridge(bridge: ZiacBridgeWindow, timeoutMs = 1000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (typeof bridge.webui?.call === "function" && (typeof bridge.webui.isConnected !== "function" || bridge.webui.isConnected())) return;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
}

function currentSearch(): string {
  return typeof window === "undefined" ? "" : window.location.search;
}

function containsCredentialKey(value: unknown): boolean {
  if (Array.isArray(value)) return value.some(containsCredentialKey);
  if (!isRecord(value)) return false;
  return Object.entries(value).some(([key, entry]) => /token|secret|password|credential|authorization|private[_-]?key/i.test(key) || containsCredentialKey(entry));
}

function containsCredentialMaterial(value: string): boolean {
  return /bearer\s+[a-z0-9._~+/=-]+|-----BEGIN [A-Z ]*PRIVATE KEY-----|(?:token|secret|password|credential)\s*[:=]/i.test(value);
}

function safeCount(value: unknown): number {
  return Number.isSafeInteger(value) && Number(value) >= 0 ? Number(value) : 0;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
