import { For, Show, Suspense, createMemo, createSignal, lazy, onCleanup, onMount } from "solid-js";
import {
  Activity,
  Bell,
  Boxes,
  Box,
  ChevronDown,
  ChevronLeft,
  ChevronRight,
  CircleDot,
  Cloud,
  CloudCog,
  Database,
  Filter,
  Globe2,
  Layers3,
  LockKeyhole,
  LogIn,
  Map,
  Menu,
  Network,
  PanelBottom,
  PanelLeft,
  PanelRight,
  Play,
  RefreshCw,
  Rocket,
  Route,
  Search,
  ServerCog,
  ShieldCheck,
  TerminalSquare,
  Workflow,
  X,
} from "lucide-solid";
import { ZiacTopologyScene } from "./ziacTopologyScene";
import { deriveZiacSceneModel, type ZiacTopologyMode } from "./ziacTopologySceneModel";
import {
  filterZiacVisualModel,
  type FilteredZiacVisualModel,
  type ZiacHealth,
  type ZiacEstateScope,
  type ZiacOperation,
  type ZiacProvider,
  type ZiacVisualModel,
  type ZiacVisualResource,
} from "./ziacVisualArtifact";
import { estateAccessState, loadLiveLogSnapshot, requestEstateAccess, type ZiacLogEvent, type ZiacSession } from "./bridge";

const ZiacGlobalMap = lazy(async () => {
  const module = await import("./ziacGlobalMap");
  return { default: module.ZiacGlobalMap };
});

type InfrastructureView = "canvas" | "map" | "operations";
type InspectorTab = "overview" | "traffic" | "revisions" | "yaml";
type DockTab = "deployments" | "logs" | "agents";

export function ZiacWorkbench(props: { model: ZiacVisualModel; session: ZiacSession | null; onEstateRefresh: () => Promise<boolean> }) {
  const estateAccess = estateAccessState(props.session);
  const [liveSession, setLiveSession] = createSignal(props.session);
  const [view, setView] = createSignal<InfrastructureView>("canvas");
  const [mode, setMode] = createSignal<ZiacTopologyMode>("architecture");
  const [estateScope, setEstateScope] = createSignal<ZiacEstateScope>(estateAccess.ready && props.model.ownershipCounts.observed > 0 ? "combined" : "managed");
  const [selectedResourceId, setSelectedResourceId] = createSignal<string | null>(props.model.frontDoor?.id ?? props.model.resources[0]?.id ?? null);
  const [text, setText] = createSignal("");
  const [provider, setProvider] = createSignal<ZiacProvider | "all">("all");
  const [region, setRegion] = createSignal<string | "all">("all");
  const [operation, setOperation] = createSignal<ZiacOperation | "all">("all");
  const [health, setHealth] = createSignal<ZiacHealth | "all">("all");
  const [navigatorOpen, setNavigatorOpen] = createSignal(false);
  const [inspectorOpen, setInspectorOpen] = createSignal(true);
  const [dockOpen, setDockOpen] = createSignal(true);
  const [inspectorTab, setInspectorTab] = createSignal<InspectorTab>("overview");
  const [dockTab, setDockTab] = createSignal<DockTab>("deployments");
  const [deploying, setDeploying] = createSignal(false);
  const [scanning, setScanning] = createSignal(false);
  const [scanFailed, setScanFailed] = createSignal(false);
  const [estateGateOpen, setEstateGateOpen] = createSignal(false);
  const [estateRequestState, setEstateRequestState] = createSignal<"idle" | "sent" | "host_required">("idle");
  let deployTimer: ReturnType<typeof setTimeout> | undefined;

  onCleanup(() => {
    if (deployTimer) clearTimeout(deployTimer);
  });
  onMount(() => {
    let active = true;
    const refresh = async () => {
      const snapshot = await loadLiveLogSnapshot();
      if (!active || snapshot === null) return;
      setLiveSession((current) => ({ ...(current ?? {}), ...snapshot }));
    };
    void refresh();
    const interval = setInterval(() => void refresh(), 750);
    onCleanup(() => {
      active = false;
      clearInterval(interval);
    });
  });

  const filtered = createMemo(() => filterZiacVisualModel(props.model, {
    text: text(),
    provider: provider(),
    region: region(),
    operation: operation(),
    health: health(),
    estate: estateScope(),
  }));
  const sceneResourceIds = createMemo(() => new Set(deriveZiacSceneModel(filtered(), mode()).nodes.map((node) => node.id)));
  const effectiveSelectedResourceId = createMemo(() => {
    const requested = selectedResourceId();
    if (requested && filtered().resourceIds.has(requested) && (view() !== "canvas" || sceneResourceIds().has(requested))) return requested;
    if (view() === "canvas") {
      const frontDoorId = props.model.frontDoor?.id;
      if (frontDoorId && sceneResourceIds().has(frontDoorId)) return frontDoorId;
      return sceneResourceIds().values().next().value ?? null;
    }
    return filtered().resources[0]?.id ?? null;
  });
  const selected = createMemo(() => filtered().resources.find((resource) => resource.id === effectiveSelectedResourceId()) ?? null);
  const deploy = () => {
    if (deploying()) return;
    setDeploying(true);
    setDockOpen(true);
    setDockTab("deployments");
    deployTimer = setTimeout(() => setDeploying(false), 2600);
  };
  const scan = async () => {
    if (scanning()) return;
    setScanning(true);
    setScanFailed(false);
    const refreshed = await props.onEstateRefresh();
    setScanFailed(!refreshed);
    setScanning(false);
  };
  const selectEstateScope = (next: ZiacEstateScope) => {
    if (next !== "managed" && !estateAccess.ready) {
      setEstateGateOpen(true);
      return;
    }
    setEstateScope(next);
    if (next === "existing") setDockOpen(false);
  };
  const requestAccess = async () => {
    setEstateRequestState(await requestEstateAccess(estateAccess.reason) ? "sent" : "host_required");
  };

  return (
    <section class="ziac-workspace">
      <header class="ziac-global-bar">
        <button type="button" class="ziac-icon-button ziac-menu-button" title="Open product navigation"><Menu size={17} /></button>
        <div class="ziac-brand">
          <span class="ziac-mark"><Workflow size={17} strokeWidth={2.3} /></span>
          <strong>Ziac</strong>
        </div>
        <button type="button" class="ziac-stack-switch" title="Switch stack and stage">
          <CloudCog size={15} />
          <strong>{props.model.artifact.stack}</strong>
          <span>{props.model.artifact.stage}</span>
          <ChevronDown size={13} />
        </button>
        <label class="ziac-command-search">
          <Search size={15} />
          <input
            aria-label="Search infrastructure"
            value={text()}
            onInput={(event) => setText(event.currentTarget.value)}
            placeholder="Search resources, agents, logs..."
          />
          <kbd>⌘K</kbd>
        </label>
        <div class="ziac-global-state">
          <span class="ziac-health-state"><CircleDot size={12} />Healthy</span>
          <span class="ziac-plan-state"><small>{estateScope() === "existing" ? "observed" : props.model.artifact.truth_mode}</small><strong>{estateScope() === "existing" ? `${filtered().resources.length} resources` : `${props.model.operationCounts.create} changes`}</strong></span>
          <button type="button" class="ziac-deploy-button" classList={{ running: deploying() || scanning(), scan: estateScope() === "existing", failed: scanFailed() }} title={scanFailed() ? "Estate scan failed" : undefined} onClick={() => estateScope() === "existing" ? void scan() : deploy()}>
            <Show when={estateScope() === "existing"} fallback={<Show when={!deploying()} fallback={<Activity size={15} />}><Rocket size={15} /></Show>}>
              <RefreshCw size={15} classList={{ spinning: scanning() }} />
            </Show>
            <span>{estateScope() === "existing" ? scanning() ? "Scanning" : "Refresh scan" : deploying() ? "Deploying" : "Deploy plan"}</span>
          </button>
          <button type="button" class="ziac-icon-button" title="Notifications"><Bell size={16} /><i /></button>
          <button type="button" class="ziac-avatar" title="Account">SK</button>
        </div>
      </header>

      <div class="ziac-context-bar">
        <div class="ziac-view-switch" aria-label="Ziac infrastructure view">
          <ViewButton active={view() === "canvas"} label="Canvas" icon={<Box size={14} />} onClick={() => setView("canvas")} />
          <ViewButton active={view() === "map"} label="Global Map" icon={<Globe2 size={14} />} onClick={() => setView("map")} />
          <ViewButton active={view() === "operations"} label="Operations" icon={<Activity size={14} />} onClick={() => setView("operations")} />
        </div>
        <div class="ziac-estate-switch" aria-label="Estate scope">
          <EstateScopeButton value="managed" label="Ziac" scope={estateScope()} onSelect={selectEstateScope} />
          <EstateScopeButton value="existing" label="Existing" scope={estateScope()} locked={!estateAccess.ready} pro onSelect={selectEstateScope} />
          <EstateScopeButton value="combined" label="Combined" scope={estateScope()} locked={!estateAccess.ready} onSelect={selectEstateScope} />
        </div>
        <div class="ziac-mode-switch" aria-label="Topology mode">
          <ModeButton value="architecture" label="Architecture" mode={mode()} onSelect={setMode} />
          <ModeButton value="network" label="Network" mode={mode()} onSelect={setMode} />
          <ModeButton value="vpc" label="VPC" mode={mode()} onSelect={setMode} />
          <ModeButton value="dependencies" label="Dependencies" mode={mode()} onSelect={setMode} />
        </div>
        <button type="button" class="ziac-estate-access" classList={{ ready: estateAccess.ready }} onClick={() => setEstateGateOpen(true)}>
          <Show when={estateAccess.ready} fallback={<LockKeyhole size={12} />}><CircleDot size={12} /></Show>
          <span>{estateAccess.ready ? "Google connected" : "Estate Pro"}</span>
          <small>{estateAccess.projectId ?? "Locked"}</small>
        </button>
      </div>

      <div class="ziac-main-grid" classList={{ "navigator-collapsed": !navigatorOpen(), "inspector-collapsed": !inspectorOpen() }}>
        <IconRail
          model={props.model}
          navigatorOpen={navigatorOpen()}
          inspectorOpen={inspectorOpen()}
          onToggleNavigator={() => setNavigatorOpen(!navigatorOpen())}
          onToggleInspector={() => setInspectorOpen(!inspectorOpen())}
          onView={setView}
        />
        <Show when={navigatorOpen()}>
          <ResourceNavigator
            model={filtered()}
            source={props.model}
            selectedId={effectiveSelectedResourceId()}
            provider={provider()}
            region={region()}
            operation={operation()}
            health={health()}
            onSelect={setSelectedResourceId}
            onProvider={setProvider}
            onRegion={setRegion}
            onOperation={setOperation}
            onHealth={setHealth}
            onClose={() => setNavigatorOpen(false)}
          />
        </Show>

        <main class="ziac-stage">
          <Show when={view() === "canvas"}>
            <ZiacTopologyScene model={filtered()} mode={mode()} selectedId={effectiveSelectedResourceId()} onSelect={setSelectedResourceId} />
          </Show>
          <Show when={view() === "map"}>
            <Suspense fallback={<div class="ziac-map-loading">Loading global map</div>}>
              <ZiacGlobalMap model={filtered()} selectedId={effectiveSelectedResourceId()} onSelect={setSelectedResourceId} />
            </Suspense>
          </Show>
          <Show when={view() === "operations"}>
            <OperationsPanel session={liveSession()} onSelectResource={setSelectedResourceId} />
          </Show>
          <ResourceFallback model={filtered()} selectedId={effectiveSelectedResourceId()} onSelect={setSelectedResourceId} />
        </main>

        <Show when={inspectorOpen()}>
          <ResourceInspector
            resource={selected()}
            model={props.model}
            tab={inspectorTab()}
            onTab={setInspectorTab}
            onSelect={setSelectedResourceId}
            onClose={() => setInspectorOpen(false)}
          />
        </Show>
      </div>

      <DeploymentDock
        open={dockOpen()}
        tab={dockTab()}
        deploying={deploying()}
        model={props.model}
        session={liveSession()}
        onTab={setDockTab}
        onToggle={() => setDockOpen(!dockOpen())}
        onSelectResource={setSelectedResourceId}
      />
      <Show when={estateGateOpen()}>
        <EstateAccessGate
          access={estateAccess}
          requestState={estateRequestState()}
          onRequest={requestAccess}
          onClose={() => setEstateGateOpen(false)}
        />
      </Show>
    </section>
  );
}

function ViewButton(props: { active: boolean; label: string; icon: unknown; onClick: () => void }) {
  return <button type="button" aria-label={props.label} classList={{ active: props.active }} onClick={props.onClick}>{props.icon as never}<span>{props.label}</span></button>;
}

function ModeButton(props: { value: ZiacTopologyMode; label: string; mode: ZiacTopologyMode; onSelect: (mode: ZiacTopologyMode) => void }) {
  return <button type="button" classList={{ active: props.mode === props.value }} onClick={() => props.onSelect(props.value)}>{props.label}</button>;
}

function EstateScopeButton(props: {
  value: ZiacEstateScope;
  label: string;
  scope: ZiacEstateScope;
  locked?: boolean;
  pro?: boolean;
  onSelect: (scope: ZiacEstateScope) => void;
}) {
  return <button
    type="button"
    classList={{ active: props.scope === props.value, locked: props.locked }}
    aria-pressed={props.scope === props.value}
    aria-disabled={props.locked}
    disabled={props.locked}
    onClick={() => props.onSelect(props.value)}
  >{props.locked && <LockKeyhole size={11} />}<span>{props.label}</span>{props.pro && <em>Pro</em>}</button>;
}

function EstateAccessGate(props: {
  access: ReturnType<typeof estateAccessState>;
  requestState: "idle" | "sent" | "host_required";
  onRequest: () => void;
  onClose: () => void;
}) {
  const action = () => {
    if (props.access.reason === "google_sign_in_required") return "Continue with Google";
    if (props.access.reason === "pro_required") return "Upgrade to Pro";
    if (props.access.reason === "gcp_connection_required") return "Connect GCP project";
    return "Refresh access";
  };
  return <div class="ziac-estate-gate-backdrop" role="presentation" onClick={props.onClose}>
    <section class="ziac-estate-gate" role="dialog" aria-modal="true" aria-labelledby="ziac-estate-gate-title" onClick={(event) => event.stopPropagation()}>
      <header><div><span>Estate scan <em>Pro</em></span><h2 id="ziac-estate-gate-title">Existing GCP infrastructure</h2></div><button type="button" title="Close estate access" onClick={props.onClose}><X size={15} /></button></header>
      <dl>
        <dt>Identity</dt><dd>{props.access.ready ? "Google connected" : "Google sign-in required"}</dd>
        <dt>Plan</dt><dd>{props.access.ready ? "Pro active" : "Pro entitlement required"}</dd>
        <dt>Project</dt><dd>{props.access.projectId ?? "Not connected"}</dd>
        <dt>Access</dt><dd>Cloud Asset Inventory viewer</dd>
      </dl>
      <Show when={!props.access.ready} fallback={<div class="ziac-estate-ready"><CircleDot size={14} /><span><strong>Read-only connection ready</strong><small>{props.access.projectId}</small></span></div>}>
        <button type="button" class="ziac-estate-auth-command" onClick={props.onRequest}><LogIn size={15} />{action()}</button>
        <Show when={props.requestState === "sent"}><p>Authorization opened by the connected Ziac host.</p></Show>
        <Show when={props.requestState === "host_required"}><p>Connect through the desktop Ziac host to start Google authorization.</p></Show>
      </Show>
      <footer>Tokens remain in the Zig host. The Workbench receives only redacted resource observations.</footer>
    </section>
  </div>;
}

function IconRail(props: {
  model: ZiacVisualModel;
  navigatorOpen: boolean;
  inspectorOpen: boolean;
  onToggleNavigator: () => void;
  onToggleInspector: () => void;
  onView: (view: InfrastructureView) => void;
}) {
  return <nav class="ziac-icon-rail" aria-label="Workbench tools">
    <button type="button" classList={{ active: props.navigatorOpen }} onClick={props.onToggleNavigator} title="Resource navigator"><PanelLeft size={15} /><span>{props.model.resources.length}</span></button>
    <button type="button" onClick={() => props.onView("canvas")} title="Topology layers"><Layers3 size={15} /><span>{props.model.edges.length}</span></button>
    <button type="button" onClick={() => props.onView("map")} title="Global regions"><Map size={15} /><span>{props.model.regionNodes.length}</span></button>
    <button type="button" onClick={() => props.onView("operations")} title="Agent operations"><TerminalSquare size={15} /><span>{props.model.artifact.state_serial}</span></button>
    <div />
    <button type="button" classList={{ active: props.inspectorOpen }} onClick={props.onToggleInspector} title="Resource inspector"><PanelRight size={15} /></button>
  </nav>;
}

function ResourceNavigator(props: {
  model: FilteredZiacVisualModel;
  source: ZiacVisualModel;
  selectedId: string | null;
  provider: string;
  region: string;
  operation: string;
  health: string;
  onSelect: (id: string) => void;
  onProvider: (value: ZiacProvider | "all") => void;
  onRegion: (value: string) => void;
  onOperation: (value: ZiacOperation | "all") => void;
  onHealth: (value: ZiacHealth | "all") => void;
  onClose: () => void;
}) {
  const groups = createMemo(() => resourceGroups(props.model.resources));
  return <aside class="ziac-resource-navigator">
    <header><span>Resources</span><strong>{props.model.resources.length}</strong><button type="button" onClick={props.onClose} title="Close navigator"><ChevronLeft size={15} /></button></header>
    <details class="ziac-filter-drawer">
      <summary><Filter size={13} />Filters<span>{activeFilterCount(props)}</span></summary>
      <FilterSelect label="Provider" value={props.provider} onChange={(value) => props.onProvider(value as ZiacProvider | "all")} options={[
        ["all", "All providers"], ["gcp", "Google Cloud"], ["cockroach", "CockroachDB"], ["local", "Local"],
      ]} />
      <FilterSelect label="Region" value={props.region} onChange={props.onRegion} options={[
        ["all", "All regions"], ...props.source.artifact.regions.map((value) => [value, value] as [string, string]),
      ]} />
      <FilterSelect label="Operation" value={props.operation} onChange={(value) => props.onOperation(value as ZiacOperation | "all")} options={[
        ["all", "All operations"], ["create", "Create"], ["update", "Update"], ["replace", "Replace"], ["delete", "Delete"], ["noop", "Unchanged"],
      ]} />
      <FilterSelect label="Health" value={props.health} onChange={(value) => props.onHealth(value as ZiacHealth | "all")} options={[
        ["all", "All health"], ["healthy", "Healthy"], ["degraded", "Degraded"], ["unhealthy", "Unhealthy"], ["reconciling", "Reconciling"], ["unknown", "Unknown"],
      ]} />
    </details>
    <div class="ziac-resource-tree" aria-label="Infrastructure resources">
      <For each={groups()}>{(group) => <section>
        <header><span>{group.label}</span><strong>{group.resources.length}</strong></header>
        <For each={group.resources}>{(resource) => <button type="button" classList={{ selected: resource.id === props.selectedId }} onClick={() => props.onSelect(resource.id)}>
          <ResourceIcon resource={resource} />
          <span><strong>{resource.logical_id}</strong><small>{resource.region ?? resource.scope}</small></span>
          <i class={`health-${resource.health}`} />
        </button>}</For>
      </section>}</For>
    </div>
    <Show when={props.source.warnings.length > 0}><div class="ziac-warning-list"><For each={props.source.warnings}>{(warning) => <span>{warning}</span>}</For></div></Show>
  </aside>;
}

function ResourceIcon(props: { resource: ZiacVisualResource }) {
  if (props.resource.provider === "cockroach") return <Database size={15} />;
  if (props.resource.type === "gcp.run.Service") return <Cloud size={15} />;
  if (props.resource.type.includes("ForwardingRule") || props.resource.type.includes("BackendService")) return <Route size={15} />;
  if (props.resource.type.includes("SslCertificate")) return <ShieldCheck size={15} />;
  if (props.resource.type.includes("RecordSet")) return <Globe2 size={15} />;
  if (props.resource.type.includes("ServerlessNeg")) return <Network size={15} />;
  return <ServerCog size={15} />;
}

function resourceGroups(resources: ZiacVisualResource[]) {
  const definitions = [
    ["compute", "Compute", (resource: ZiacVisualResource) => resource.type === "gcp.run.Service" || resource.type.includes("ServerlessNeg")],
    ["network", "Networking", (resource: ZiacVisualResource) => resource.type.includes("compute.") && resource.type !== "gcp.run.Service" && !resource.type.includes("ServerlessNeg")],
    ["data", "Data", (resource: ZiacVisualResource) => resource.provider === "cockroach"],
    ["project", "Project services", (resource: ZiacVisualResource) => resource.scope === "project"],
  ] as const;
  return definitions.map(([id, label, matches]) => ({ id, label, resources: resources.filter(matches).sort((a, b) => a.logical_id.localeCompare(b.logical_id)) }))
    .filter((group) => group.resources.length > 0);
}

function activeFilterCount(props: { provider: string; region: string; operation: string; health: string }) {
  return [props.provider, props.region, props.operation, props.health].filter((value) => value !== "all").length;
}

function FilterSelect(props: { label: string; value: string; options: [string, string][]; onChange: (value: string) => void }) {
  return <label class="ziac-filter-control"><span>{props.label}</span><select value={props.value} onChange={(event) => props.onChange(event.currentTarget.value)}><For each={props.options}>{([value, label]) => <option value={value}>{label}</option>}</For></select></label>;
}

function ResourceInspector(props: {
  resource: ZiacVisualResource | null;
  model: ZiacVisualModel;
  tab: InspectorTab;
  onTab: (tab: InspectorTab) => void;
  onSelect: (id: string) => void;
  onClose: () => void;
}) {
  const dependencies = createMemo(() => props.resource ? props.model.edges.filter((edge) => edge.from === props.resource?.id) : []);
  const consumers = createMemo(() => props.resource ? props.model.edges.filter((edge) => edge.to === props.resource?.id) : []);
  const routes = createMemo(() => props.resource ? props.model.routes.filter((route) => route.from_resource === props.resource?.id || route.to_resource === props.resource?.id) : []);
  return <aside class="ziac-resource-inspector">
    <header class="ziac-inspector-header">
      <div><small>{props.resource ? resourceService(props.resource) : "Resource"}</small><strong>{props.resource?.logical_id ?? "Nothing selected"}</strong></div>
      <Show when={props.resource}><span class={`health-${props.resource?.health}`}><i />{props.resource?.health}</span></Show>
      <button type="button" onClick={props.onClose} title="Close inspector"><X size={15} /></button>
    </header>
    <div class="ziac-inspector-tabs">
      <InspectorTabButton value="overview" label="Overview" tab={props.tab} onSelect={props.onTab} />
      <InspectorTabButton value="traffic" label="Traffic" tab={props.tab} onSelect={props.onTab} />
      <InspectorTabButton value="revisions" label="Revisions" tab={props.tab} onSelect={props.onTab} />
      <InspectorTabButton value="yaml" label="YAML" tab={props.tab} onSelect={props.onTab} />
    </div>
    <Show when={props.resource} fallback={<div class="ziac-empty compact">Select a resource on the canvas.</div>}>
      {(resource) => <div class="ziac-inspector-body">
        <Show when={props.tab === "overview"}>
          <div class="ziac-metric-grid">
            <InspectorMetric label="RPS" value={resource().type === "gcp.run.Service" ? "523" : "—"} />
            <InspectorMetric label="p95" value={resource().type === "gcp.run.Service" ? "128 ms" : "—"} />
            <InspectorMetric label="Errors" value={resource().type === "gcp.run.Service" ? "0.12%" : "0"} />
            <InspectorMetric label="CPU" value={resource().type === "gcp.run.Service" ? "42%" : "—"} />
          </div>
          <InspectorSection title="Resource details" count={0}>
            <dl class="ziac-inspector-grid">
              <dt>Operation</dt><dd><span class={`ziac-operation-${resource().operation}`}>{resource().operation}</span></dd>
              <dt>Ownership</dt><dd><span class={`ziac-ownership-${resource().ownership}`}>{resource().ownership}</span></dd>
              <dt>Health</dt><dd>{resource().health}</dd>
              <dt>Scope</dt><dd>{resource().region ?? resource().scope}</dd>
              <dt>Type</dt><dd><code>{resource().type}</code></dd>
              <dt>Resource ID</dt><dd><code>{resource().id}</code></dd>
              <Show when={resource().discovery}>{(discovery) => <>
                <dt>Discovery source</dt><dd>{discovery().provider.replaceAll("_", " ")}</dd>
                <dt>Project</dt><dd><code>{discovery().project_id}</code></dd>
              </>}</Show>
            </dl>
          </InspectorSection>
          <InspectorSection title="Dependencies" count={dependencies().length}><For each={dependencies()}>{(edge) => <InspectorLink id={edge.to} kind={edge.kind} onSelect={props.onSelect} />}</For></InspectorSection>
          <InspectorSection title="Consumers" count={consumers().length}><For each={consumers()}>{(edge) => <InspectorLink id={edge.from} kind={edge.kind} onSelect={props.onSelect} />}</For></InspectorSection>
          <Show when={resource().ownership === "managed"} fallback={<InspectorSection title="Read-only observation" count={0}><div class="ziac-readonly-observation"><LockKeyhole size={14} /><span>Not owned by this Ziac stack</span></div></InspectorSection>}>
            <InspectorSection title="Lifecycle" count={0}><div class="ziac-lifecycle-list"><span>Protect <strong>{resource().lifecycle.protect ? "on" : "off"}</strong></span><span>Retain <strong>{resource().lifecycle.retain_on_delete ? "on" : "off"}</strong></span><span>Replace first <strong>{resource().lifecycle.replace_before_delete ? "on" : "off"}</strong></span></div></InspectorSection>
          </Show>
        </Show>
        <Show when={props.tab === "traffic"}>
          <section class="ziac-inspector-copy"><h3>Request routing</h3><p>Routes are {props.model.artifact.truth_mode === "traffic" ? "observed" : "compiled or inferred"} from the current artifact.</p></section>
          <For each={routes()} fallback={<div class="ziac-empty compact">No global routes touch this resource.</div>}>{(route) => <button type="button" class="ziac-route-row" onClick={() => props.onSelect(route.to_resource)}><Route size={14} /><span><strong>{route.to_region}</strong><small>{route.provenance}</small></span><ChevronRight size={13} /></button>}</For>
        </Show>
        <Show when={props.tab === "revisions"}>
          <section class="ziac-revision-card"><header><span>Current plan revision</span><strong>{props.model.artifact.graph_digest.slice(0, 10)}</strong></header><dl><dt>State serial</dt><dd>{props.model.artifact.state_serial}</dd><dt>Operation</dt><dd>{resource().operation}</dd><dt>Reasons</dt><dd>{resource().reasons.length || "No replacement reasons"}</dd></dl></section>
          <For each={resource().reasons}>{(reason) => <p class="ziac-reason">{reason}</p>}</For>
        </Show>
        <Show when={props.tab === "yaml"}><pre class="ziac-yaml-view">{resourceYaml(resource())}</pre></Show>
      </div>}
    </Show>
  </aside>;
}

function InspectorTabButton(props: { value: InspectorTab; label: string; tab: InspectorTab; onSelect: (tab: InspectorTab) => void }) {
  return <button type="button" classList={{ active: props.tab === props.value }} onClick={() => props.onSelect(props.value)}>{props.label}</button>;
}

function InspectorMetric(props: { label: string; value: string }) {
  return <div><span>{props.label}</span><strong>{props.value}</strong><i /></div>;
}

function InspectorSection(props: { title: string; count: number; children: unknown }) {
  return <section class="ziac-inspector-section"><header><h3>{props.title}</h3>{props.count > 0 && <span>{props.count}</span>}</header>{props.children as never}</section>;
}

function InspectorLink(props: { id: string; kind: string; onSelect: (id: string) => void }) {
  return <button type="button" class="ziac-inspector-link" onClick={() => props.onSelect(props.id)}><span>{props.kind}</span><code>{props.id}</code><ChevronRight size={13} /></button>;
}

function resourceService(resource: ZiacVisualResource) {
  if (resource.type === "gcp.run.Service") return "Cloud Run service";
  if (resource.type.includes("GlobalForwardingRule")) return "Global load balancer";
  if (resource.provider === "cockroach") return "CockroachDB cluster";
  return resource.type.split(".").at(-1) ?? resource.type;
}

function resourceYaml(resource: ZiacVisualResource) {
  return [
    `apiVersion: ziac.dev/v1`,
    `kind: ${resourceService(resource).replaceAll(" ", "")}`,
    `metadata:`,
    `  id: ${resource.id}`,
    `  logicalId: ${resource.logical_id}`,
    `spec:`,
    `  provider: ${resource.provider}`,
    `  scope: ${resource.scope}`,
    ...(resource.region ? [`  region: ${resource.region}`] : []),
    `  operation: ${resource.operation}`,
    `  inputs: ${JSON.stringify(resource.inputs, null, 2).replaceAll("\n", "\n    ")}`,
  ].join("\n");
}

function DeploymentDock(props: {
  open: boolean;
  tab: DockTab;
  deploying: boolean;
  model: ZiacVisualModel;
  session: ZiacSession | null;
  onTab: (tab: DockTab) => void;
  onToggle: () => void;
  onSelectResource: (id: string) => void;
}) {
  return <section class="ziac-operation-dock" classList={{ collapsed: !props.open }} aria-label="Operational dock">
    <header>
      <div class="ziac-dock-tabs">
        <DockTabButton value="deployments" label="Deployments" count={props.deploying ? 1 : props.model.operationCounts.create} tab={props.tab} onSelect={props.onTab} />
        <DockTabButton value="logs" label="Live logs" count={props.session?.logs?.length ?? 0} tab={props.tab} onSelect={props.onTab} live />
        <DockTabButton value="agents" label="Agent runs" count={props.session?.agent ? 1 : 0} tab={props.tab} onSelect={props.onTab} />
      </div>
      <button type="button" onClick={props.onToggle} title={props.open ? "Collapse operational dock" : "Open operational dock"}><PanelBottom size={14} />{props.open ? <ChevronDown size={13} /> : <ChevronRight size={13} />}</button>
    </header>
    <Show when={props.open}>
      <div class="ziac-dock-body">
        <Show when={props.tab === "deployments"}>
          <div class="ziac-deployment-run">
            <div class="ziac-deploy-progress ziac-dock-run-state" classList={{ running: props.deploying }}><Play size={13} /><span><strong>{props.deploying ? "Deploying global-api" : "Plan ready"}</strong><small>{props.model.operationCounts.create} create · {props.model.resources.length} resources</small></span><em>{props.deploying ? "35%" : "validated"}</em></div>
            <div class="ziac-progress-track"><i style={{ width: props.deploying ? "35%" : "100%" }} /></div>
          </div>
          <div class="ziac-deploy-events ziac-dock-stepper">
            <DockEvent time="12:22:31" tone="plan" title="Plan" detail="Comptime graph validated" />
            <DockEvent time="12:22:34" tone="build" title="Build" detail="OCI image available" />
            <DockEvent time="12:22:38" tone="revision" title="Revision" detail="Cloud Run rollout staged" />
            <DockEvent time="12:22:41" tone="traffic" title="Traffic" detail="Awaiting regional health" />
          </div>
        </Show>
        <Show when={props.tab === "logs"}>
          <div class="ziac-dock-log-list"><For each={(props.session?.logs ?? []).slice(-6)} fallback={<div class="ziac-empty compact">No live log evidence retained.</div>}>{(event) => <button type="button" onClick={() => event.resource_id && props.onSelectResource(event.resource_id)}><code>{String(event.sequence).padStart(4, "0")}</code><span class={`severity-${event.severity}`}>{event.severity}</span><strong>{event.source}</strong><p>{event.message}</p></button>}</For></div>
        </Show>
        <Show when={props.tab === "agents"}>
          <div class="ziac-dock-agent"><TerminalSquare size={17} /><span><small>{props.session?.agent?.state ?? "No active run"}</small><strong>{props.session?.agent?.objective ?? "Agent session evidence will appear here."}</strong></span><code>{props.session?.agent?.session_id ?? "offline"}</code></div>
        </Show>
      </div>
    </Show>
  </section>;
}

function DockTabButton(props: { value: DockTab; label: string; count: number; tab: DockTab; live?: boolean; onSelect: (tab: DockTab) => void }) {
  return <button type="button" classList={{ active: props.tab === props.value }} onClick={() => props.onSelect(props.value)}>{props.label}<span>{props.count}</span>{props.live && <i />}</button>;
}

function DockEvent(props: { time: string; tone: string; title: string; detail: string }) {
  return <div class={`ziac-dock-event tone-${props.tone}`}><small>{props.time}</small><i /><span><strong>{props.title}</strong><em>{props.detail}</em></span></div>;
}

function OperationsPanel(props: { session: ZiacSession | null; onSelectResource: (id: string) => void }) {
  const logs = () => props.session?.logs ?? [];
  const summary = () => props.session?.log_summary ?? { retained: logs().length, dropped: 0, suppressed: 0 };
  return <div class="ziac-operations" aria-label="Agent operations">
    <section class="ziac-agent-command-strip" aria-label="Agent session">
      <Show when={props.session?.agent} fallback={<div class="ziac-agent-primary empty"><span class="ziac-agent-kicker"><TerminalSquare size={14} />Agent session</span><strong>No active agent session</strong><code>offline</code></div>}>
        {(agent) => <>
          <div class="ziac-agent-primary">
            <span class="ziac-agent-kicker"><TerminalSquare size={14} />Agent session <b>{agent().state}</b></span>
            <strong>{agent().objective}</strong>
            <code>{agent().session_id}</code>
          </div>
          <div class="ziac-agent-next"><span>Next action</span><strong>{agent().next_action ?? "Awaiting evidence"}</strong><ChevronRight size={14} /></div>
        </>}
      </Show>
      <section class="ziac-evidence-inline" aria-label="Evidence completeness"><StatusMetric label="Retained" value={String(summary().retained)} /><StatusMetric label="Dropped" value={String(summary().dropped)} tone={summary().dropped === 0 ? "safe" : "plan"} /><StatusMetric label="Suppressed" value={String(summary().suppressed)} /></section>
    </section>
    <section class="ziac-log-timeline">
      <header class="ziac-log-toolbar"><div><Activity size={14} /><h2>Causal timeline</h2><span>{logs().length} events</span></div><span>Newest last</span></header>
      <div class="ziac-log-events"><Show when={logs().length > 0} fallback={<div class="ziac-empty">No causal events have been retained.</div>}><For each={logs()}>{(event) => <OperationEvent event={event} onSelectResource={props.onSelectResource} />}</For></Show></div>
    </section>
  </div>;
}

function OperationEvent(props: { event: ZiacLogEvent; onSelectResource: (id: string) => void }) {
  return <article class={`ziac-log-event severity-${props.event.severity}`}>
    <span class="ziac-log-sequence">{props.event.sequence}</span>
    <header class="ziac-log-source"><strong>{props.event.source}</strong><span>{props.event.severity}</span>{props.event.region && <em>{props.event.region}</em>}</header>
    <div class="ziac-log-message"><p>{props.event.message}</p><footer><code>{props.event.event_id}</code>{props.event.trace_id && <code>{props.event.trace_id}</code>}</footer></div>
    <Show when={props.event.resource_id}>{(resourceId) => <button type="button" class="ziac-log-inspect" aria-label="Inspect related resource" title="Inspect resource" onClick={() => props.onSelectResource(resourceId())}><PanelRight size={14} /></button>}</Show>
  </article>;
}

function StatusMetric(props: { label: string; value: string; tone?: "plan" | "safe" }) {
  return <div class={`ziac-status-metric ${props.tone ?? ""}`}><span>{props.label}</span><strong>{props.value}</strong></div>;
}

function ResourceFallback(props: { model: FilteredZiacVisualModel; selectedId: string | null; onSelect: (id: string) => void }) {
  return <details class="ziac-resource-fallback"><summary><Boxes size={15} />Resource index</summary><div class="ziac-resource-table" aria-label="Infrastructure resources"><For each={props.model.resources}>{(resource) => <button type="button" classList={{ selected: resource.id === props.selectedId }} onClick={() => props.onSelect(resource.id)}><span>{resource.provider}</span><strong>{resource.logical_id}</strong><small>{resource.region ?? resource.scope}</small><em class={`ziac-operation-${resource.operation}`}>{resource.operation}</em></button>}</For></div></details>;
}
