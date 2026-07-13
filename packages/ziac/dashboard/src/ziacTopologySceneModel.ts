// Ziac dashboard-owned scene model.
import type {
  FilteredZiacVisualModel,
  ZiacAccessMode,
  ZiacEdgeKind,
  ZiacHealth,
  ZiacOperation,
  ZiacProvider,
  ZiacVisualEdge,
  ZiacVisualResource,
} from "./ziacVisualArtifact";
import { resourceVisualIdentity, type ZiacResourceVisualIdentity } from "./ziacResourceIconCatalog";

export type ZiacTopologyMode = "architecture" | "network" | "vpc" | "dependencies";
export type ScenePosition = [x: number, y: number, z: number];

type ScenePlaneKind = "global" | "region" | "data" | "project";

export type ZiacSceneTooltip = {
  kind: "resource" | "slab" | "boundary" | "locality";
  title: string;
  subtitle: string;
  canonicalId: string;
  provider: string;
  scope: string;
  operation: string;
  health: ZiacHealth;
  forecastMonthly: string;
  uptime: string;
  resourceCount: number;
  connectionCount: number;
  estimated: boolean;
  ownership?: ZiacVisualResource["ownership"];
  discoverySource?: string;
};

export type ZiacSceneBoundary = {
  id: string;
  kind: "account" | "network" | "external_account";
  provider: ZiacProvider;
  parentId?: string;
  label: string;
  detail: string;
  position: ScenePosition;
  size: [width: number, depth: number];
  thickness: number;
  surface: {
    position: ScenePosition;
    size: [width: number, depth: number];
  };
  containedPlaneIds: string[];
  tooltip: ZiacSceneTooltip;
};

export type ZiacSceneLocality = {
  id: string;
  boundaryId: string;
  provider: "cockroach";
  region: string;
  primary: boolean;
  position: ScenePosition;
  size: [width: number, depth: number];
  thickness: number;
  resourceIds: string[];
  tooltip: ZiacSceneTooltip;
};

export type ZiacScenePlane = {
  id: string;
  label: string;
  detail: string;
  kind: ScenePlaneKind;
  position: ScenePosition;
  size: [width: number, depth: number];
  thickness: number;
  surface: { title: string; subtitle: string };
  tooltip: ZiacSceneTooltip;
  emphasized: boolean;
};

export type ZiacSceneGroup = {
  id: string;
  planeId: string;
  family: string;
  label: string;
  iconPath: string | null;
  count: number;
  nodeIds: string[];
  position: ScenePosition;
  size: [width: number, depth: number];
};

export type ZiacSceneNode = {
  id: string;
  label: string;
  service: string;
  type: string;
  provider: ZiacProvider;
  operation: ZiacOperation;
  health: ZiacHealth;
  ownership: ZiacVisualResource["ownership"];
  planeId: string;
  groupId: string;
  position: ScenePosition;
  size: [width: number, height: number, depth: number];
  face: { type: string; name: string; id: string };
  tooltip: ZiacSceneTooltip;
  iconPath: string | null;
  accent: string;
  emphasized: boolean;
};

export type ZiacSceneRoute = {
  id: string;
  source: ScenePosition;
  target: ScenePosition;
  path: ScenePosition[];
  sourceId: string;
  targetId: string;
  kind: ZiacEdgeKind;
  access?: ZiacAccessMode;
  label?: string;
  permissions: string[];
  intraPlane: boolean;
  accent: string;
};

export type ZiacSceneModel = {
  boundaries: ZiacSceneBoundary[];
  localities: ZiacSceneLocality[];
  planes: ZiacScenePlane[];
  groups: ZiacSceneGroup[];
  nodes: ZiacSceneNode[];
  routes: ZiacSceneRoute[];
  bounds: { width: number; depth: number; center: ScenePosition };
};

export const sceneGeometry = {
  slabThickness: 0.42,
  nodeSize: [3.2, 1.5, 1.8] as [number, number, number],
  nodeGap: [0.72, 0.78] as [number, number],
  planePadding: [1.15, 1.35] as [number, number],
  groupPadding: [0.52, 0.64] as [number, number],
  groupLabelDepth: 0.72,
  groupGap: 0.56,
  planeGap: 1.8,
  estateGap: 3.6,
  boundaryPadding: {
    account: [1.15, 1.2] as [number, number],
    network: [0.72, 1.35] as [number, number],
    external: [0.86, 1.25] as [number, number],
  },
};

type ResourceGroupSpec = {
  family: string;
  identity: ZiacResourceVisualIdentity;
  resources: ZiacVisualResource[];
  columns: number;
  rows: number;
  size: [width: number, depth: number];
};

type PlaneDraft = Omit<ZiacScenePlane, "position" | "tooltip"> & {
  resources: ZiacVisualResource[];
  groupSpecs: ResourceGroupSpec[];
  position?: ScenePosition;
};

export function deriveZiacSceneModel(model: FilteredZiacVisualModel, mode: ZiacTopologyMode): ZiacSceneModel {
  const grouped = groupVisibleResources(model.resources, mode);
  const regionIds = [...grouped.keys()].filter((id) => id.startsWith("region:")).sort();
  const planeIds = [
    ...(grouped.has("group:global") ? ["group:global"] : []),
    ...regionIds,
    ...(grouped.has("group:project") ? ["group:project"] : []),
    ...(grouped.has("group:local") ? ["group:local"] : []),
    ...(grouped.has("group:multi-region") ? ["group:multi-region"] : []),
  ];
  const drafts = planeIds.map((id) => createPlaneDraft(id, grouped.get(id) ?? [], mode));
  positionPlanes(drafts);

  const connectionCounts = resourceConnectionCounts(model);
  const planes = drafts.map((draft): ZiacScenePlane => {
    const forecast = aggregateForecast(draft.resources);
    return {
      id: draft.id,
      label: draft.label,
      detail: draft.detail,
      kind: draft.kind,
      position: draft.position ?? [0, 0, 0],
      size: draft.size,
      thickness: draft.thickness,
      surface: draft.surface,
      emphasized: draft.emphasized,
      tooltip: {
        kind: "slab",
        title: draft.surface.title,
        subtitle: draft.surface.subtitle,
        canonicalId: draft.id,
        provider: planeProvider(draft.kind),
        scope: draft.kind === "region" ? draft.id.slice("region:".length) : draft.kind,
        operation: dominantOperation(draft.resources),
        health: aggregateHealth(draft.resources),
        forecastMonthly: formatForecast(forecast),
        uptime: aggregateUptime(draft.resources),
        resourceCount: draft.resources.length,
        connectionCount: draft.resources.reduce((total, resource) => total + (connectionCounts.get(resource.id) ?? 0), 0),
        estimated: true,
      },
    };
  });

  const groups: ZiacSceneGroup[] = [];
  const nodes: ZiacSceneNode[] = [];
  planes.forEach((plane, index) => {
    const layout = layoutPlaneGroups(plane, drafts[index]?.groupSpecs ?? [], mode, connectionCounts);
    groups.push(...layout.groups);
    nodes.push(...layout.nodes);
  });
  const localities = deriveCockroachLocalities(model, planes, nodes);
  const boundaries = deriveEstateBoundaries(model, planes, nodes, localities);
  const nodeById = new Map(nodes.map((node) => [node.id, node]));
  const routes = deriveRoutes(model, mode, nodes, nodeById);
  return { boundaries, localities, planes, groups, nodes, routes, bounds: sceneBounds(planes, boundaries) };
}

export function fitOrthographicSceneZoom(
  bounds: ZiacSceneModel["bounds"],
  viewWidth: number,
  viewHeight: number,
  projection: "2d" | "3d" = "3d",
): number {
  const widthPadding = projection === "2d" ? 1.08 : 0.94;
  const depthPadding = projection === "2d" ? 1.08 : 0.8;
  const widthZoom = viewWidth / Math.max(1, bounds.width * widthPadding);
  const depthZoom = viewHeight / Math.max(1, bounds.depth * depthPadding);
  const aspect = viewWidth / Math.max(1, viewHeight);
  const narrowCorrection = aspect < 0.75 ? Math.max(0.3, aspect * 0.58) : 1;
  return Math.min(1.24, Math.max(0.1, Math.min(widthZoom, depthZoom) * narrowCorrection));
}

function groupVisibleResources(resources: ZiacVisualResource[], mode: ZiacTopologyMode) {
  const grouped = new Map<string, ZiacVisualResource[]>();
  for (const resource of resources.filter((value) => resourceVisible(value, mode))) {
    const planeId = resourcePlaneId(resource);
    const values = grouped.get(planeId) ?? [];
    values.push(resource);
    grouped.set(planeId, values);
  }
  for (const values of grouped.values()) values.sort((left, right) => left.id.localeCompare(right.id));
  return grouped;
}

function createPlaneDraft(id: string, resources: ZiacVisualResource[], mode: ZiacTopologyMode): PlaneDraft {
  const kind = planeKind(id);
  const groupSpecs = resourceGroupSpecs(resources, kind);
  return {
    id,
    label: planeLabel(id),
    detail: planeDetail(id),
    kind,
    resources,
    groupSpecs,
    size: planeSize(groupSpecs, kind),
    thickness: sceneGeometry.slabThickness,
    surface: planeSurface(id),
    emphasized: mode === "architecture"
      || (mode === "network" && (kind === "global" || kind === "region" || kind === "data"))
      || (mode === "vpc" && (kind === "region" || kind === "data"))
      || (mode === "dependencies" && kind !== "region"),
  };
}

function positionPlanes(planes: PlaneDraft[]) {
  const regions = planes.filter((plane) => plane.kind === "region");
  const global = planes.filter((plane) => plane.kind === "global");
  const projects = planes.filter((plane) => plane.kind === "project");
  const external = planes.filter((plane) => plane.kind === "data");
  const gap = sceneGeometry.planeGap;

  let regionMinZ = 0;
  let regionMaxZ = 0;
  if (regions.length > 0) {
    const columns = Math.min(4, Math.max(1, Math.ceil(Math.sqrt(regions.length))));
    const rows = Math.ceil(regions.length / columns);
    const cellWidth = Math.max(...regions.map((plane) => plane.size[0]));
    const cellDepth = Math.max(...regions.map((plane) => plane.size[1]));
    const gridWidth = columns * cellWidth + (columns - 1) * gap;
    const gridDepth = rows * cellDepth + (rows - 1) * gap;
    regionMinZ = -gridDepth / 2;
    regionMaxZ = gridDepth / 2;
    regions.forEach((plane, index) => {
      const column = index % columns;
      const row = Math.floor(index / columns);
      plane.position = [
        -gridWidth / 2 + cellWidth / 2 + column * (cellWidth + gap),
        0,
        -gridDepth / 2 + cellDepth / 2 + row * (cellDepth + gap),
      ];
    });
  }

  if (global.length > 0) {
    const totalWidth = packedWidth(global);
    const maxDepth = Math.max(...global.map((plane) => plane.size[1]));
    const z = regions.length > 0 ? regionMinZ - gap - maxDepth / 2 : 0;
    positionPackedRow(global, totalWidth, z);
  }

  let gcpBottom = regions.length > 0 ? regionMaxZ : 0;
  if (projects.length > 0) {
    const totalWidth = packedWidth(projects);
    const maxDepth = Math.max(...projects.map((plane) => plane.size[1]));
    const globalBottom = global.length > 0
      ? Math.max(...global.map((plane) => (plane.position?.[2] ?? 0) + plane.size[1] / 2))
      : 0;
    const z = regions.length > 0
      ? regionMaxZ + gap + maxDepth / 2
      : global.length > 0 ? globalBottom + gap + maxDepth / 2 : 0;
    positionPackedRow(projects, totalWidth, z);
    gcpBottom = z + maxDepth / 2;
  } else if (global.length > 0 && regions.length === 0) {
    gcpBottom = Math.max(...global.map((plane) => (plane.position?.[2] ?? 0) + plane.size[1] / 2));
  }

  if (external.length > 0) {
    const totalWidth = packedWidth(external);
    const maxDepth = Math.max(...external.map((plane) => plane.size[1]));
    const z = gcpBottom + sceneGeometry.estateGap + maxDepth / 2;
    positionPackedRow(external, totalWidth, z);
  }
}

function positionPackedRow(planes: PlaneDraft[], totalWidth: number, z: number) {
  let cursor = -totalWidth / 2;
  for (const plane of planes) {
    plane.position = [cursor + plane.size[0] / 2, 0, z];
    cursor += plane.size[0] + sceneGeometry.planeGap;
  }
}

function packedWidth(planes: PlaneDraft[]) {
  return planes.reduce((total, plane) => total + plane.size[0], 0)
    + Math.max(0, planes.length - 1) * sceneGeometry.planeGap;
}

function planeSize(groups: ResourceGroupSpec[], kind: ScenePlaneKind): [number, number] {
  const [paddingX, paddingZ] = sceneGeometry.planePadding;
  const packing = packResourceGroups(groups);
  const width = packing.width + paddingX * 2;
  const depth = packing.depth + paddingZ * 2;
  const minimum: [number, number] = kind === "global" ? [9.2, 5.4] : [6.0, 5.0];
  return [Math.max(minimum[0], width), Math.max(minimum[1], depth)];
}

function nodeGridDimensions(resourceCount: number, kind: ScenePlaneKind): [columns: number, rows: number] {
  if (resourceCount <= 0) return [1, 1];
  const maxColumns = kind === "region" ? 3 : 5;
  const columns = Math.min(maxColumns, Math.max(1, Math.ceil(Math.sqrt(resourceCount * 1.5))));
  return [columns, Math.ceil(resourceCount / columns)];
}

function groupGridDimensions(groupCount: number): [columns: number, rows: number] {
  if (groupCount <= 0) return [1, 1];
  const columns = Math.min(3, Math.max(1, Math.ceil(Math.sqrt(groupCount * 1.5))));
  return [columns, Math.ceil(groupCount / columns)];
}

function packResourceGroups(groups: ResourceGroupSpec[]) {
  const [columns] = groupGridDimensions(groups.length);
  const rows = Array.from({ length: Math.ceil(groups.length / columns) }, (_, row) => groups.slice(row * columns, (row + 1) * columns));
  const rowWidths = rows.map((row) => row.reduce((total, group) => total + group.size[0], 0) + Math.max(0, row.length - 1) * sceneGeometry.groupGap);
  const rowDepths = rows.map((row) => Math.max(0, ...row.map((group) => group.size[1])));
  const width = Math.max(0, ...rowWidths);
  const depth = rowDepths.reduce((total, value) => total + value, 0) + Math.max(0, rows.length - 1) * sceneGeometry.groupGap;
  const positions: Array<[x: number, z: number]> = [];
  let zCursor = -depth / 2;
  rows.forEach((row, rowIndex) => {
    const rowDepth = rowDepths[rowIndex] ?? 0;
    let xCursor = -(rowWidths[rowIndex] ?? 0) / 2;
    for (const group of row) {
      positions.push([xCursor + group.size[0] / 2, zCursor + rowDepth / 2]);
      xCursor += group.size[0] + sceneGeometry.groupGap;
    }
    zCursor += rowDepth + sceneGeometry.groupGap;
  });
  return { width, depth, positions };
}

function resourceGroupSpecs(resources: ZiacVisualResource[], kind: ScenePlaneKind): ResourceGroupSpec[] {
  const grouped = new Map<string, { identity: ZiacResourceVisualIdentity; resources: ZiacVisualResource[] }>();
  for (const resource of resources) {
    const identity = resourceVisualIdentity(resource);
    const group = grouped.get(identity.family) ?? { identity, resources: [] };
    group.resources.push(resource);
    grouped.set(identity.family, group);
  }
  return [...grouped.entries()].sort(([left], [right]) => left.localeCompare(right)).map(([family, group]) => {
    group.resources.sort((left, right) => left.id.localeCompare(right.id));
    const [columns, rows] = nodeGridDimensions(group.resources.length, kind);
    const [nodeWidth, , nodeDepth] = sceneGeometry.nodeSize;
    const [gapX, gapZ] = sceneGeometry.nodeGap;
    const [paddingX, paddingZ] = sceneGeometry.groupPadding;
    return {
      family,
      identity: group.identity,
      resources: group.resources,
      columns,
      rows,
      size: [
        columns * nodeWidth + Math.max(0, columns - 1) * gapX + paddingX * 2,
        rows * nodeDepth + Math.max(0, rows - 1) * gapZ + paddingZ * 2 + sceneGeometry.groupLabelDepth,
      ],
    };
  });
}

function layoutPlaneGroups(
  plane: ZiacScenePlane,
  specs: ResourceGroupSpec[],
  mode: ZiacTopologyMode,
  connectionCounts: Map<string, number>,
): { groups: ZiacSceneGroup[]; nodes: ZiacSceneNode[] } {
  if (specs.length === 0) return { groups: [], nodes: [] };
  const packing = packResourceGroups(specs);
  const [nodeWidth, nodeHeight, nodeDepth] = sceneGeometry.nodeSize;
  const [gapX, gapZ] = sceneGeometry.nodeGap;
  const groundedY = plane.position[1] + plane.thickness / 2 + nodeHeight / 2;
  const groups: ZiacSceneGroup[] = [];
  const nodes: ZiacSceneNode[] = [];
  specs.forEach((spec, groupIndex) => {
    const packedPosition = packing.positions[groupIndex] ?? [0, 0];
    const groupPosition: ScenePosition = [
      plane.position[0] + packedPosition[0],
      plane.position[1] + plane.thickness / 2 + 0.012,
      plane.position[2] + packedPosition[1],
    ];
    const groupId = `${plane.id}:family:${spec.family}`;
    groups.push({
      id: groupId,
      planeId: plane.id,
      family: spec.family,
      label: spec.identity.label,
      iconPath: spec.identity.iconPath,
      count: spec.resources.length,
      nodeIds: spec.resources.map((resource) => resource.id),
      position: groupPosition,
      size: spec.size,
    });

    const gridWidth = spec.columns * nodeWidth + Math.max(0, spec.columns - 1) * gapX;
    const gridDepth = spec.rows * nodeDepth + Math.max(0, spec.rows - 1) * gapZ;
    const startX = groupPosition[0] - gridWidth / 2 + nodeWidth / 2;
    const nodeAreaCenterZ = groupPosition[2] - sceneGeometry.groupLabelDepth / 2;
    const startZ = nodeAreaCenterZ - gridDepth / 2 + nodeDepth / 2;
    spec.resources.forEach((resource, index) => {
      const column = index % spec.columns;
      const row = Math.floor(index / spec.columns);
      const forecast = resourceForecast(resource);
      nodes.push({
        id: resource.id,
        label: resource.logical_id,
        service: resourceService(resource),
        type: resource.type,
        provider: resource.provider,
        operation: resource.operation,
        health: resource.health,
        ownership: resource.ownership,
        planeId: plane.id,
        groupId,
        position: [startX + column * (nodeWidth + gapX), groundedY, startZ + row * (nodeDepth + gapZ)],
        size: [...sceneGeometry.nodeSize],
        face: { type: resourceService(resource), name: resource.logical_id, id: resource.id },
        tooltip: {
          kind: "resource",
          title: resource.logical_id,
          subtitle: resourceService(resource),
          canonicalId: resource.id,
          provider: resource.provider,
          scope: resource.region ?? resource.scope,
          operation: resource.operation,
          health: resource.health,
          forecastMonthly: formatForecast(forecast),
          uptime: resourceUptime(resource.health),
          resourceCount: 1,
          connectionCount: connectionCounts.get(resource.id) ?? 0,
          estimated: true,
          ownership: resource.ownership,
          ...(resource.discovery ? { discoverySource: resource.discovery.provider } : {}),
        },
        iconPath: spec.identity.iconPath,
        accent: resourceAccent(resource),
        emphasized: resourceEmphasized(resource, mode),
      });
    });
  });
  return { groups, nodes };
}

function deriveCockroachLocalities(
  model: FilteredZiacVisualModel,
  planes: ZiacScenePlane[],
  nodes: ZiacSceneNode[],
): ZiacSceneLocality[] {
  const dataPlane = planes.find((plane) => plane.kind === "data" && plane.tooltip.provider === "cockroach");
  if (!dataPlane) return [];
  const visibleIds = new Set(nodes.filter((node) => node.provider === "cockroach").map((node) => node.id));
  const clusters = model.resources.filter((resource) => resource.provider === "cockroach" && visibleIds.has(resource.id));
  const regions = [...new Set(clusters.flatMap((resource) => resource.regions))].sort();
  if (regions.length === 0) return [];
  const size: [number, number] = [2.45, 1.12];
  const gap = 0.34;
  const columns = Math.min(3, regions.length);
  const rows = Math.ceil(regions.length / columns);
  const width = columns * size[0] + Math.max(0, columns - 1) * gap;
  const startX = dataPlane.position[0] - width / 2 + size[0] / 2;
  const startZ = dataPlane.position[2] + dataPlane.size[1] / 2 + 0.58 + size[1] / 2;
  return regions.map((region, index) => {
    const resources = clusters.filter((resource) => resource.regions.includes(region));
    const primary = resources.some((resource) => resource.inputs.primary_region === region);
    const forecast = aggregateForecast(resources);
    return {
      id: `account:cockroach:locality:${region}`,
      boundaryId: "account:cockroach",
      provider: "cockroach",
      region,
      primary,
      position: [
        startX + (index % columns) * (size[0] + gap),
        -0.22,
        startZ + Math.floor(index / columns) * (size[1] + gap),
      ],
      size,
      thickness: 0.1,
      resourceIds: resources.map((resource) => resource.id).sort(),
      tooltip: {
        kind: "locality",
        title: region,
        subtitle: primary ? "Cockroach primary locality" : "Cockroach replica locality",
        canonicalId: resources.map((resource) => resource.id).join(", "),
        provider: "cockroach",
        scope: region,
        operation: dominantOperation(resources),
        health: aggregateHealth(resources),
        forecastMonthly: formatForecast(forecast),
        uptime: aggregateUptime(resources),
        resourceCount: resources.length,
        connectionCount: 0,
        estimated: true,
      },
    };
  });
}

function deriveEstateBoundaries(
  model: FilteredZiacVisualModel,
  planes: ZiacScenePlane[],
  nodes: ZiacSceneNode[],
  localities: ZiacSceneLocality[],
): ZiacSceneBoundary[] {
  const boundaries: ZiacSceneBoundary[] = [];
  const gcpPlanes = planes.filter((plane) => plane.tooltip.provider === "gcp");
  const regionPlanes = gcpPlanes.filter((plane) => plane.kind === "region");
  if (gcpPlanes.length > 0) {
    boundaries.push(createBoundary(model, nodes, {
      id: "account:gcp",
      kind: "account",
      provider: "gcp",
      label: "GCP account",
      detail: `${model.artifact.stack} / ${model.artifact.stage}`,
      items: gcpPlanes,
      padding: sceneGeometry.boundaryPadding.account,
      y: -0.42,
      thickness: 0.14,
      containedPlaneIds: gcpPlanes.map((plane) => plane.id),
    }));
  }
  if (regionPlanes.length > 0) {
    boundaries.push(createBoundary(model, nodes, {
      id: "network:gcp:global-vpc",
      kind: "network",
      provider: "gcp",
      parentId: "account:gcp",
      label: "Global VPC",
      detail: `${regionPlanes.length} regional subnet${regionPlanes.length === 1 ? "" : "s"}`,
      items: regionPlanes,
      padding: sceneGeometry.boundaryPadding.network,
      y: -0.31,
      thickness: 0.12,
      containedPlaneIds: regionPlanes.map((plane) => plane.id),
    }));
  }

  const cockroachPlanes = planes.filter((plane) => plane.tooltip.provider === "cockroach");
  if (cockroachPlanes.length > 0) {
    boundaries.push(createBoundary(model, nodes, {
      id: "account:cockroach",
      kind: "external_account",
      provider: "cockroach",
      label: "Cockroach Cloud account",
      detail: `${localities.length} declared localit${localities.length === 1 ? "y" : "ies"}`,
      items: [...cockroachPlanes, ...localities],
      padding: sceneGeometry.boundaryPadding.external,
      y: -0.38,
      thickness: 0.14,
      containedPlaneIds: cockroachPlanes.map((plane) => plane.id),
    }));
  }
  return boundaries;
}

type BoundarySource = {
  id: string;
  kind: ZiacSceneBoundary["kind"];
  provider: ZiacProvider;
  parentId?: string;
  label: string;
  detail: string;
  items: Array<{ position: ScenePosition; size: [number, number] }>;
  padding: [number, number];
  y: number;
  thickness: number;
  containedPlaneIds: string[];
};

function createBoundary(
  model: FilteredZiacVisualModel,
  nodes: ZiacSceneNode[],
  source: BoundarySource,
): ZiacSceneBoundary {
  const rectangle = enclosingRectangle(source.items, source.padding);
  const labelWidth = Math.min(8.4, Math.max(4.5, rectangle.size[0] - 0.9));
  const labelDepth = 0.82;
  const surface = {
    position: [
      rectangle.position[0] - rectangle.size[0] / 2 + labelWidth / 2 + 0.42,
      source.y + source.thickness / 2 + 0.012,
      rectangle.position[2] + rectangle.size[1] / 2 - labelDepth / 2 - 0.26,
    ] as ScenePosition,
    size: [labelWidth, labelDepth] as [number, number],
  };
  const containedIds = new Set(source.containedPlaneIds);
  const resources = model.resources.filter((resource) => nodes.some((node) => node.id === resource.id && containedIds.has(node.planeId)));
  const forecast = aggregateForecast(resources);
  return {
    id: source.id,
    kind: source.kind,
    provider: source.provider,
    ...(source.parentId ? { parentId: source.parentId } : {}),
    label: source.label,
    detail: source.detail,
    position: [rectangle.position[0], source.y, rectangle.position[2]],
    size: rectangle.size,
    thickness: source.thickness,
    surface,
    containedPlaneIds: source.containedPlaneIds,
    tooltip: {
      kind: "boundary",
      title: source.label,
      subtitle: source.detail,
      canonicalId: source.id,
      provider: source.provider,
      scope: source.kind,
      operation: dominantOperation(resources),
      health: aggregateHealth(resources),
      forecastMonthly: formatForecast(forecast),
      uptime: aggregateUptime(resources),
      resourceCount: resources.length,
      connectionCount: resources.reduce((total, resource) => total + (nodes.find((node) => node.id === resource.id)?.tooltip.connectionCount ?? 0), 0),
      estimated: true,
    },
  };
}

function enclosingRectangle(
  items: Array<{ position: ScenePosition; size: [number, number] }>,
  padding: [number, number],
) {
  const minX = Math.min(...items.map((item) => item.position[0] - item.size[0] / 2)) - padding[0];
  const maxX = Math.max(...items.map((item) => item.position[0] + item.size[0] / 2)) + padding[0];
  const minZ = Math.min(...items.map((item) => item.position[2] - item.size[1] / 2)) - padding[1];
  const maxZ = Math.max(...items.map((item) => item.position[2] + item.size[1] / 2)) + padding[1];
  return { position: [(minX + maxX) / 2, 0, (minZ + maxZ) / 2] as ScenePosition, size: [maxX - minX, maxZ - minZ] as [number, number] };
}

function deriveRoutes(
  model: FilteredZiacVisualModel,
  mode: ZiacTopologyMode,
  nodes: ZiacSceneNode[],
  nodeById: Map<string, ZiacSceneNode>,
): ZiacSceneRoute[] {
  const routes = model.edges.flatMap((edge): ZiacSceneRoute[] => {
    if (!routeVisible(edge.kind, mode)) return [];
    const source = nodeById.get(edge.from);
    const target = nodeById.get(edge.to);
    return source && target ? [sceneRoute(edge.id, source, target, edge.kind, edge)] : [];
  });
  if (mode !== "architecture") return routes;

  for (const route of model.routes) {
    const source = nodeById.get(route.from_resource);
    const target = nodeById.get(route.to_resource);
    if (source && target) routes.push(sceneRoute(`global-route:${route.id}`, source, target, "traffic"));
  }
  const frontDoor = nodes.find((node) => node.type === "gcp.compute.GlobalForwardingRule");
  const certificate = nodes.find((node) => node.type.includes("ManagedSslCertificate"));
  if (frontDoor && certificate) routes.push(sceneRoute("architecture:managed-tls", frontDoor, certificate, "dependency"));
  return routes;
}

function sceneRoute(
  id: string,
  source: ZiacSceneNode,
  target: ZiacSceneNode,
  kind: ZiacEdgeKind,
  edge?: ZiacVisualEdge,
): ZiacSceneRoute {
  const path = planarRoutePath(source, target);
  return {
    id,
    source: path[0]!,
    target: path[path.length - 1]!,
    path,
    sourceId: source.id,
    targetId: target.id,
    kind,
    ...(edge?.access ? { access: edge.access, label: accessLabel(edge.access) } : kind === "iam" ? { label: "IAM" } : {}),
    permissions: edge?.permissions ?? [],
    intraPlane: source.planeId === target.planeId,
    accent: routeAccent(kind, edge?.access),
  };
}

function accessLabel(access: ZiacAccessMode) {
  if (access === "read_write") return "READ / WRITE";
  return access.toUpperCase();
}

function planarRoutePath(source: ZiacSceneNode, target: ZiacSceneNode): ScenePosition[] {
  const dx = target.position[0] - source.position[0];
  const dz = target.position[2] - source.position[2];
  const y = sceneGeometry.slabThickness / 2 + 0.08;
  const lead = 0.46;

  if (Math.abs(dx) >= Math.abs(dz)) {
    const direction = dx >= 0 ? 1 : -1;
    const start: ScenePosition = [source.position[0] + direction * (source.size[0] / 2 + 0.08), y, source.position[2]];
    const end: ScenePosition = [target.position[0] - direction * (target.size[0] / 2 + 0.08), y, target.position[2]];
    const sourceLead: ScenePosition = [start[0] + direction * lead, y, start[2]];
    const targetLead: ScenePosition = [end[0] - direction * lead, y, end[2]];
    const channel = (sourceLead[0] + targetLead[0]) / 2;
    return [start, sourceLead, [channel, y, sourceLead[2]], [channel, y, targetLead[2]], targetLead, end];
  }

  const direction = dz >= 0 ? 1 : -1;
  const start: ScenePosition = [source.position[0], y, source.position[2] + direction * (source.size[2] / 2 + 0.08)];
  const end: ScenePosition = [target.position[0], y, target.position[2] - direction * (target.size[2] / 2 + 0.08)];
  const sourceLead: ScenePosition = [start[0], y, start[2] + direction * lead];
  const targetLead: ScenePosition = [end[0], y, end[2] - direction * lead];
  const channel = (sourceLead[2] + targetLead[2]) / 2;
  return [start, sourceLead, [sourceLead[0], y, channel], [targetLead[0], y, channel], targetLead, end];
}

function sceneBounds(planes: ZiacScenePlane[], boundaries: ZiacSceneBoundary[]): ZiacSceneModel["bounds"] {
  const items = boundaries.length > 0 ? boundaries : planes;
  if (items.length === 0) return { width: 1, depth: 1, center: [0, 0, 0] };
  const minX = Math.min(...items.map((item) => item.position[0] - item.size[0] / 2));
  const maxX = Math.max(...items.map((item) => item.position[0] + item.size[0] / 2));
  const minZ = Math.min(...items.map((item) => item.position[2] - item.size[1] / 2));
  const maxZ = Math.max(...items.map((item) => item.position[2] + item.size[1] / 2));
  return { width: maxX - minX, depth: maxZ - minZ, center: [(minX + maxX) / 2, 0, (minZ + maxZ) / 2] };
}

function resourceConnectionCounts(model: FilteredZiacVisualModel) {
  const counts = new Map<string, number>();
  const increment = (id: string) => counts.set(id, (counts.get(id) ?? 0) + 1);
  for (const edge of model.edges) {
    increment(edge.from);
    increment(edge.to);
  }
  for (const route of model.routes) {
    increment(route.from_resource);
    increment(route.to_resource);
  }
  return counts;
}

type ForecastRange = { minimum: number; maximum: number; available: boolean; origin?: "configuration_estimate" | "projected_month_end" | "actual_billed" };

function resourceForecast(resource: ZiacVisualResource): ForecastRange {
  if (resource.cost?.amount_micros === null || resource.cost === undefined) return { minimum: 0, maximum: 0, available: false };
  const amount = resource.cost.amount_micros / 1_000_000;
  return { minimum: amount, maximum: amount, available: true, origin: resource.cost.origin };
}

function aggregateForecast(resources: ZiacVisualResource[]): ForecastRange {
  return resources.reduce<ForecastRange>((total, resource) => {
    const forecast = resourceForecast(resource);
    return { minimum: total.minimum + forecast.minimum, maximum: total.maximum + forecast.maximum, available: total.available || forecast.available };
  }, { minimum: 0, maximum: 0, available: false });
}

function formatForecast(forecast: ForecastRange) {
  if (!forecast.available) return "Billing data unavailable";
  const amount = `$${formatInteger(Math.round(forecast.minimum))}`;
  if (forecast.origin === "actual_billed") return `${amount} actual billed`;
  if (forecast.origin === "projected_month_end") return `${amount} projected month end`;
  return `${amount} configuration estimate`;
}

function formatInteger(value: number) {
  return String(value).replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

function resourceUptime(health: ZiacHealth) {
  if (health === "healthy") return "99.99% observed";
  if (health === "degraded") return "99.50% observed";
  if (health === "unhealthy") return "Below 99% observed";
  if (health === "reconciling") return "Pending reconciliation";
  return "Not observed";
}

function aggregateUptime(resources: ZiacVisualResource[]) {
  return resourceUptime(aggregateHealth(resources));
}

function aggregateHealth(resources: ZiacVisualResource[]): ZiacHealth {
  if (resources.some((resource) => resource.health === "unhealthy")) return "unhealthy";
  if (resources.some((resource) => resource.health === "degraded")) return "degraded";
  if (resources.some((resource) => resource.health === "reconciling")) return "reconciling";
  if (resources.length > 0 && resources.every((resource) => resource.health === "healthy")) return "healthy";
  return "unknown";
}

function dominantOperation(resources: ZiacVisualResource[]): string {
  const precedence: ZiacOperation[] = ["delete", "replace", "create", "update", "read", "noop", "none"];
  return precedence.find((operation) => resources.some((resource) => resource.operation === operation)) ?? "none";
}

function planeProvider(kind: ScenePlaneKind) {
  if (kind === "data") return "cockroach";
  if (kind === "project" || kind === "global" || kind === "region") return "gcp";
  return "local";
}

function planeKind(id: string): ScenePlaneKind {
  if (id.startsWith("region:")) return "region";
  if (id === "group:global") return "global";
  if (id === "group:multi-region") return "data";
  return "project";
}

function planeSurface(id: string) {
  if (id.startsWith("region:")) return { title: id.slice("region:".length), subtitle: "VPC global-api" };
  if (id === "group:global") return { title: "Global edge", subtitle: "Anycast and HTTPS routing" };
  if (id === "group:multi-region") return { title: "Global data", subtitle: "CockroachDB locality" };
  if (id === "group:project") return { title: "Project services", subtitle: "DNS, certificates, and build inputs" };
  return { title: "Local development", subtitle: "Emulated infrastructure scope" };
}

function resourcePlaneId(resource: ZiacVisualResource): string {
  if (resource.scope === "regional" && resource.region) return `region:${resource.region}`;
  if (resource.scope === "multi_region") return "group:multi-region";
  return `group:${resource.scope}`;
}

function routeVisible(kind: ZiacEdgeKind, mode: ZiacTopologyMode): boolean {
  if (mode === "architecture") return kind === "traffic" || kind === "connectivity" || kind === "output" || kind === "iam";
  if (mode === "network" || mode === "vpc") return kind === "traffic" || kind === "connectivity";
  return kind === "dependency" || kind === "output" || kind === "iam";
}

function resourceVisible(resource: ZiacVisualResource, mode: ZiacTopologyMode): boolean {
  if (mode === "dependencies") return true;
  if (mode === "vpc") {
    return isCloudRunWorkload(resource)
      || resource.type.includes("RegionServerlessNeg")
      || resource.provider === "cockroach";
  }
  if (mode === "network") {
    return resource.type === "gcp.run.Service"
      || resource.type.includes("RegionServerlessNeg")
      || resource.type.includes("BackendService")
      || (resource.type.includes("GlobalForwardingRule") && resource.logical_id.includes("https"))
      || resource.type.includes("GlobalAddress")
      || resource.provider === "cockroach";
  }
  return isCloudRunWorkload(resource)
    || resource.type.startsWith("gcp.storage.")
    || resource.type.startsWith("gcp.sql.")
    || resource.provider === "cockroach"
    || resource.type.includes("ManagedSslCertificate")
    || resource.type.includes("GlobalAddress")
    || resource.type.includes("RecordSet")
    || (resource.type.includes("GlobalForwardingRule") && resource.logical_id.includes("https"));
}

function resourceEmphasized(resource: ZiacVisualResource, mode: ZiacTopologyMode): boolean {
  if (mode === "architecture") return true;
  if (mode === "vpc") return resource.scope === "regional" || resource.provider === "cockroach";
  if (mode === "network") {
    return resource.type.includes("ForwardingRule")
      || resource.type.includes("BackendService")
      || resource.type.includes("ServerlessNeg")
      || resource.type === "gcp.run.Service"
      || resource.provider === "cockroach";
  }
  return resource.type !== "gcp.run.Service" || resource.operation !== "noop";
}

function resourceService(resource: ZiacVisualResource): string {
  if (resource.type === "gcp.run.Service") return "Cloud Run";
  if (resource.type === "gcp.run.Job") return "Cloud Run Job";
  if (resource.type === "gcp.run.WorkerPool") return "Cloud Run Worker Pool";
  if (resource.type.startsWith("gcp.storage.")) return "Cloud Storage";
  if (resource.type.startsWith("gcp.sql.")) return "Cloud SQL";
  if (resource.type.includes("GlobalForwardingRule")) return "Global HTTPS LB";
  if (resource.type.includes("ManagedSslCertificate")) return "Managed TLS";
  if (resource.type.includes("RecordSet")) return "Cloud DNS";
  if (resource.type.includes("ServerlessNeg")) return "Serverless NEG";
  if (resource.type.includes("BackendService")) return "Backend service";
  if (resource.type.includes("UrlMap")) return "URL map";
  if (resource.type.includes("TargetHttpsProxy")) return "HTTPS proxy";
  if (resource.type.includes("TargetHttpProxy")) return "HTTP proxy";
  if (resource.type.includes("GlobalAddress")) return "Global address";
  if (resource.provider === "cockroach") return "CockroachDB";
  return resource.type.split(".").at(-1) ?? resource.type;
}

function resourceAccent(resource: ZiacVisualResource): string {
  if (resource.ownership === "observed") return "#6f9c9a";
  if (resource.ownership === "referenced") return "#8b83a8";
  if (resource.operation === "delete" || resource.operation === "replace") return "#d93025";
  if (resource.operation === "update") return "#f9ab00";
  if (resource.provider === "cockroach") return "#6f5bd3";
  if (resource.type.includes("ManagedSslCertificate")) return "#ea4335";
  if (resource.type.includes("RecordSet")) return "#34a853";
  if (resource.type.includes("GlobalForwardingRule") || isCloudRunWorkload(resource)) return "#4285f4";
  return "#78909c";
}

function isCloudRunWorkload(resource: ZiacVisualResource): boolean {
  return resource.type === "gcp.run.Service"
    || resource.type === "gcp.run.Job"
    || resource.type === "gcp.run.WorkerPool";
}

function routeAccent(kind: ZiacEdgeKind, access?: ZiacAccessMode): string {
  if (kind === "traffic") return "#8bb7e8";
  if (kind === "connectivity") return "#9aaaba";
  if (kind === "output") return "#e0bd6a";
  if (kind === "iam") {
    if (access === "write") return "#d9aa72";
    if (access === "admin") return "#c89ab3";
    if (access === "invoke") return "#8fb5dd";
    return access === "read_write" ? "#7fbc98" : "#8ebfa4";
  }
  return "#9eabb8";
}

function planeLabel(id: string): string {
  if (id === "group:global") return "Global edge";
  if (id === "group:multi-region") return "CockroachDB global data plane";
  if (id === "group:project") return "Project services";
  if (id === "group:local") return "Local development";
  return id.replace("group:", "");
}

function planeDetail(id: string): string {
  if (id.startsWith("region:")) return "VPC global-api / regional subnet";
  if (id === "group:global") return "Anycast entry and global routing";
  if (id === "group:multi-region") return "Multi-region SQL locality";
  if (id === "group:project") return "DNS, certificates, and build inputs";
  return "Compiled infrastructure scope";
}
