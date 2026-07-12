// Ziac dashboard-owned topology model.
import type { FilteredZiacVisualModel, ZiacEdgeKind, ZiacOperation, ZiacProvider, ZiacVisualResource } from "./ziacVisualArtifact";

export function ziacTopologyData(model: FilteredZiacVisualModel, selectedId: string | null) {
  const comboIds = [...new Set(model.resources.map(resourceCombo))].sort();
  return {
    combos: comboIds.map((id) => ({
      id,
      type: "rect",
      data: { label: comboLabel(id) },
      style: {
        fill: comboFill(id), fillOpacity: 0.58, stroke: comboStroke(id), lineWidth: 1, radius: 6,
        padding: [38, 18, 18, 18] as [number, number, number, number], labelText: comboLabel(id), labelFill: "#384541",
        labelFontSize: 11, labelFontWeight: 700, labelPlacement: "top-left" as const,
      },
    })),
    nodes: model.resources.map((resource) => ({
      id: resource.id,
      type: "rect",
      combo: resourceCombo(resource),
      states: resource.id === selectedId ? ["selected"] : [],
      data: {
        label: resource.logical_id, provider: resource.provider, resourceType: resource.type,
        operation: resource.operation, health: resource.health, region: resource.region ?? resource.scope,
      },
      style: {
        size: [196, 62] as [number, number], radius: 5, fill: providerFill(resource.provider),
        stroke: operationStroke(resource.operation, resource.provider),
        lineWidth: resource.id === selectedId ? 3 : 1.5,
        shadowColor: resource.id === selectedId ? "rgba(20, 32, 29, 0.18)" : "transparent",
        shadowBlur: resource.id === selectedId ? 8 : 0,
        labelText: `${resourceGlyph(resource)}  ${resource.logical_id}`,
        labelFill: "#17211f", labelFontSize: 12, labelFontWeight: 700,
        labelPlacement: "center" as const, cursor: "pointer" as const,
      },
    })),
    edges: model.edges.map((edge) => ({
      id: edge.id,
      source: edge.from,
      target: edge.to,
      type: "polyline",
      data: { kind: edge.kind },
      style: {
        stroke: edgeStroke(edge.kind), lineWidth: edge.kind === "traffic" ? 2.2 : 1.4,
        lineDash: edgeDash(edge.kind), radius: 8, endArrow: true,
        opacity: edge.kind === "dependency" ? 0.7 : 0.92,
      },
    })),
  };
}

export function ziacTopologyLayout() {
  return { type: "dagre" as const, rankdir: "LR" as const, ranksep: 76, nodesep: 34 };
}

function resourceCombo(resource: ZiacVisualResource): string {
  if (resource.scope === "regional" && resource.region) return `region:${resource.region}`;
  if (resource.scope === "multi_region") return "group:multi-region";
  return `group:${resource.scope}`;
}

function comboLabel(id: string): string {
  if (id.startsWith("region:")) return id.slice("region:".length);
  if (id === "group:global") return "Global edge";
  if (id === "group:multi-region") return "Multi-region data";
  if (id === "group:project") return "Project resources";
  if (id === "group:local") return "Local resources";
  return id.replace("group:", "");
}

function comboFill(id: string): string {
  if (id === "group:multi-region") return "#fff1ee";
  if (id.startsWith("region:")) return "#eef6ff";
  if (id === "group:global") return "#edf8f4";
  return "#f5f6f3";
}

function comboStroke(id: string): string {
  if (id === "group:multi-region") return "#d77a6f";
  if (id.startsWith("region:")) return "#85aee8";
  if (id === "group:global") return "#4d9b83";
  return "#b6beb8";
}

function providerFill(provider: ZiacProvider): string {
  if (provider === "gcp") return "#f8fbff";
  if (provider === "cockroach") return "#fff7f5";
  return "#f5faf5";
}

function operationStroke(operation: ZiacOperation, provider: ZiacProvider): string {
  if (operation === "create") return "#188038";
  if (operation === "update") return "#b06000";
  if (operation === "replace" || operation === "delete") return "#c5221f";
  if (provider === "gcp") return "#4285f4";
  if (provider === "cockroach") return "#d74a49";
  return "#5f6f65";
}

function edgeStroke(kind: ZiacEdgeKind): string {
  if (kind === "traffic") return "#087f8c";
  if (kind === "output") return "#3f6fbc";
  if (kind === "connectivity") return "#b84a52";
  if (kind === "iam") return "#a86800";
  return "#7d8984";
}

function edgeDash(kind: ZiacEdgeKind): number[] | undefined {
  if (kind === "dependency") return [5, 5];
  if (kind === "output") return [2, 4];
  return undefined;
}

function resourceGlyph(resource: ZiacVisualResource): string {
  if (resource.type === "gcp.run.Service") return "RUN";
  if (resource.type.includes("ForwardingRule")) return "EDGE";
  if (resource.type.includes("BackendService")) return "LB";
  if (resource.type.includes("ServerlessNeg")) return "NEG";
  if (resource.type.includes("Certificate")) return "TLS";
  if (resource.type.includes("RecordSet")) return "DNS";
  if (resource.provider === "cockroach") return "CRDB";
  return resource.provider.toUpperCase();
}
