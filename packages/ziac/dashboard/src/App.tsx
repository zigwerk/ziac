import { Show, createEffect, createMemo, createResource, createSignal, onCleanup, onMount } from "solid-js";
import { ZiacWorkbench } from "./ZiacWorkbench";
import { applyWorkspacePatch, loadDashboardPayload, requestEstateScan, subscribeWorkspacePatches } from "./bridge";
import { deriveZiacDashboardModel } from "./ziacVisualArtifact";

export function App() {
  const [payload, { refetch }] = createResource(loadDashboardPayload);
  const [liveArtifact, setLiveArtifact] = createSignal<string | null>(null);
  createEffect(() => {
    const loaded = payload();
    if (loaded) setLiveArtifact(loaded.artifactJson);
  });
  onMount(() => {
    const unsubscribe = subscribeWorkspacePatches((patchJson) => {
      const current = liveArtifact();
      const next = current === null ? null : applyWorkspacePatch(current, patchJson);
      if (next === null) void refetch();
      else setLiveArtifact(next);
    });
    onCleanup(unsubscribe);
  });
  const parsed = createMemo(() => {
    const loaded = payload() ?? payload.latest;
    if (!loaded) return null;
    try {
      const raw: unknown = JSON.parse(liveArtifact() ?? loaded.artifactJson);
      return {
        model: deriveZiacDashboardModel(raw),
        session: loaded.session,
        error: null as string | null,
      };
    } catch (error) {
      return {
        model: null,
        session: loaded.session,
        error: error instanceof Error ? error.message : "failed to parse Ziac artifact",
      };
    }
  });

  const refreshEstate = async () => {
    try {
      const result = await requestEstateScan();
      if (!result.ok) return false;
      await refetch();
      return true;
    } catch {
      return false;
    }
  };

  return (
    <main class="ziac-dashboard-app">
      <Show when={payload.loading && !payload.latest}>
        <div class="ziac-dashboard-state">Loading Ziac infrastructure…</div>
      </Show>
      <Show when={payload.error}>
        <div class="ziac-dashboard-state error">{payload.error instanceof Error ? payload.error.message : "Ziac dashboard host is unavailable"}</div>
      </Show>
      <Show when={parsed()?.error}>
        <div class="ziac-dashboard-state error">{parsed()?.error}</div>
      </Show>
      <Show when={parsed()?.model}>
        {(model) => <ZiacWorkbench model={model()} session={parsed()?.session ?? null} onEstateRefresh={refreshEstate} />}
      </Show>
    </main>
  );
}
