// Ziac dashboard-owned global map model.
import type {
  FilteredZiacVisualModel,
  RegionLocation,
  ZiacHealth,
  ZiacOperation,
  ZiacRouteProvenance,
  ZiacVisualResource,
} from "./ziacVisualArtifact";

export type MapPosition = [longitude: number, latitude: number];

export type ZiacMapRegionMarker = {
  id: string;
  region: string;
  label: string;
  position: MapPosition;
  resourceCount: number;
  cloudRunResources: string[];
  cockroachResources: string[];
  primaryResourceId: string | null;
  operation: ZiacOperation;
  health: ZiacHealth;
  selected: boolean;
};

export type ZiacMapRoute = {
  id: string;
  sourcePosition: MapPosition;
  targetPosition: MapPosition;
  sourceResourceId: string;
  targetResourceId: string;
  targetRegion: string;
  provenance: ZiacRouteProvenance;
  selected: boolean;
};

export type ZiacGlobalMapModel = {
  frontDoor: ZiacVisualResource | null;
  regionMarkers: ZiacMapRegionMarker[];
  routes: ZiacMapRoute[];
  unmappedRegions: string[];
};

export function deriveZiacGlobalMapModel(model: FilteredZiacVisualModel, selectedId: string | null): ZiacGlobalMapModel {
  const regionMarkers = model.regionNodes.flatMap((node): ZiacMapRegionMarker[] => {
    if (!node.location) return [];
    const cloudRunResources = node.resources.filter((resource) => resource.type === "gcp.run.Service").map((resource) => resource.id);
    const cockroachResources = node.resources.filter((resource) => resource.provider === "cockroach").map((resource) => resource.id);
    const primaryResourceId = cloudRunResources[0] ?? node.resources[0]?.id ?? null;
    return [{
      id: `region:${node.id}`,
      region: node.id,
      label: node.location.label,
      position: [node.location.longitude, node.location.latitude],
      resourceCount: node.resources.length,
      cloudRunResources,
      cockroachResources,
      primaryResourceId,
      operation: dominantOperation(node.resources),
      health: node.health,
      selected: selectedId !== null && node.resources.some((resource) => resource.id === selectedId),
    }];
  });
  const markerByRegion = new Map(regionMarkers.map((marker) => [marker.region, marker]));
  const frontDoor = model.frontDoor && model.resourceIds.has(model.frontDoor.id) ? model.frontDoor : null;
  const routes = model.routes.flatMap((route): ZiacMapRoute[] => {
    const marker = markerByRegion.get(route.to_region);
    if (!marker) return [];
    return [{
      id: route.id,
      sourcePosition: illustrativeIngress(marker.position),
      targetPosition: marker.position,
      sourceResourceId: route.from_resource,
      targetResourceId: route.to_resource,
      targetRegion: route.to_region,
      provenance: route.provenance,
      selected: selectedId === route.from_resource || selectedId === route.to_resource,
    }];
  });
  return {
    frontDoor,
    regionMarkers,
    routes,
    unmappedRegions: model.regionNodes.filter((node) => node.location === null).map((node) => node.id),
  };
}

function dominantOperation(resources: ZiacVisualResource[]): ZiacOperation {
  const precedence: ZiacOperation[] = ["delete", "replace", "create", "update", "read", "noop", "none"];
  return precedence.find((operation) => resources.some((resource) => resource.operation === operation)) ?? "none";
}

function illustrativeIngress(target: MapPosition): MapPosition {
  const [longitude, latitude] = target;
  if (longitude < -30) return [Math.max(-170, longitude - 28), Math.min(75, latitude + 11)];
  if (longitude > 60) return [longitude - 34, Math.max(-55, latitude - 14)];
  return [longitude - 26, Math.min(75, latitude + 12)];
}

export function locationPosition(location: RegionLocation): MapPosition {
  return [location.longitude, location.latitude];
}
