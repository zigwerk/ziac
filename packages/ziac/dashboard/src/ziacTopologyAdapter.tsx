// Ziac dashboard-owned topology adapter.
import { Show } from "solid-js";
import { Graph } from "@dschz/solid-g6";
import { ziacTopologyData, ziacTopologyLayout } from "./ziacTopologyModel";
import type { FilteredZiacVisualModel } from "./ziacVisualArtifact";

export function ZiacTopologyCanvas(props: {
  model: FilteredZiacVisualModel;
  selectedId: string | null;
  onSelect: (id: string) => void;
}) {
  return (
    <Show when={props.model} keyed>
      {(model) => (
        <Graph
          data={ziacTopologyData(model, props.selectedId)}
          layout={ziacTopologyLayout()}
          behaviors={["drag-canvas", "zoom-canvas", "drag-element", "click-select"]}
          plugins={["minimap"]}
          events={{
            "node:click": (event) => {
              const target = ("target" in event ? event.target : null) as unknown as { id?: unknown } | null;
              if (target && typeof target.id === "string") props.onSelect(target.id);
            },
          }}
          style={{ width: "100%", height: "100%" }}
        />
      )}
    </Show>
  );
}
