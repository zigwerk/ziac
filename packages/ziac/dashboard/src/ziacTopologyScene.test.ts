// Standalone Ziac dashboard scene coverage.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { deriveZiacSceneModel, fitOrthographicSceneZoom } from "./ziacTopologySceneModel";
import {
  deriveZiacVisualModel,
  filterZiacVisualModel,
  parseZiacVisualArtifact,
  type FilteredZiacVisualModel,
  type ZiacVisualEdge,
  type ZiacVisualResource,
} from "./ziacVisualArtifact";

const filteredModel = () => {
  const raw = JSON.parse(readFileSync(new URL("../public/sample-ziac-global.json", import.meta.url), "utf8"));
  return filterZiacVisualModel(deriveZiacVisualModel(parseZiacVisualArtifact(raw)), {
    text: "",
    provider: "all",
    region: "all",
    operation: "all",
    health: "all",
  });
};

test("Three topology scene derives a deterministic high-level architecture", () => {
  const scene = deriveZiacSceneModel(filteredModel(), "architecture");

  expect(scene.nodes).toHaveLength(8);
  expect(scene.planes.map((plane) => plane.id)).toEqual([
    "group:global",
    "region:asia-northeast1",
    "region:europe-west1",
    "region:us-central1",
    "group:project",
    "group:multi-region",
  ]);
  expect(scene.nodes.find((node) => node.id === "gcp.run.Service.europe-west1.api")?.planeId).toBe("region:europe-west1");
  expect(scene.nodes.find((node) => node.id === "cockroach.Cluster.global-data")?.planeId).toBe("group:multi-region");
  expect(scene.nodes.some((node) => node.id === "gcp.compute.TargetHttpsProxy.api-https")).toBe(false);
  expect(scene.routes.filter((route) => route.kind === "traffic")).toHaveLength(3);
  expect(scene.bounds.width).toBeGreaterThan(18);
  expect(scene.bounds.depth).toBeGreaterThan(10);
});

test("resource objects own face identity and sit exactly on their scope slab", () => {
  const scene = deriveZiacSceneModel(filteredModel(), "architecture");

  for (const node of scene.nodes) {
    const plane = scene.planes.find((value) => value.id === node.planeId);
    expect(plane).toBeDefined();
    const planeTop = plane!.position[1] + plane!.thickness / 2;
    const nodeBottom = node.position[1] - node.size[1] / 2;
    expect(Math.abs(planeTop - nodeBottom)).toBeLessThan(0.001);
    expect(node.face).toEqual({ type: node.service, name: node.label, id: node.id });
    expect(node.tooltip.forecastMonthly).toBe("Billing data unavailable");
    expect(node.tooltip.uptime.length).toBeGreaterThan(0);
  }

  const europe = scene.planes.find((plane) => plane.id === "region:europe-west1");
  expect(europe?.surface).toMatchObject({ title: "europe-west1", subtitle: "VPC global-api" });
  expect(europe?.tooltip.resourceCount).toBe(1);
  expect(europe?.tooltip.forecastMonthly).toBe("Billing data unavailable");
});

test("topology modes preserve resources while changing emphasized routes and planes", () => {
  const network = deriveZiacSceneModel(filteredModel(), "network");
  const vpc = deriveZiacSceneModel(filteredModel(), "vpc");
  const dependencies = deriveZiacSceneModel(filteredModel(), "dependencies");

  expect(network.routes.every((route) => ["traffic", "connectivity"].includes(route.kind))).toBe(true);
  expect(vpc.planes.filter((plane) => plane.kind === "region")).toHaveLength(3);
  expect(vpc.nodes.filter((node) => node.emphasized).some((node) => node.type === "gcp.run.Service")).toBe(true);
  expect(dependencies.nodes).toHaveLength(17);
  expect(dependencies.routes.every((route) => ["dependency", "output", "iam"].includes(route.kind))).toBe(true);
});

test("orthographic scene fitting keeps the global topology visible on narrow screens", () => {
  const bounds = deriveZiacSceneModel(filteredModel(), "architecture").bounds;
  const isometric = fitOrthographicSceneZoom(bounds, 26, 17);
  const topDown = fitOrthographicSceneZoom(bounds, 26, 17, "2d");

  expect(isometric).toBeGreaterThan(0.45);
  expect(topDown).toBeLessThan(isometric * 0.86);
  expect(fitOrthographicSceneZoom(bounds, 9, 17)).toBeLessThan(0.13);
});

test("capacity-aware layout scales to many regions and resources without overlap", () => {
  const scene = deriveZiacSceneModel(expandedModel(), "architecture");
  const regionPlanes = scene.planes.filter((plane) => plane.kind === "region");

  expect(regionPlanes).toHaveLength(12);
  expect(new Set(regionPlanes.map((plane) => plane.position[2])).size).toBeGreaterThan(1);
  expect(scene.nodes.length).toBeGreaterThanOrEqual(48);
  expect(Number.isFinite(scene.bounds.width)).toBe(true);
  expect(Number.isFinite(scene.bounds.depth)).toBe(true);

  for (let leftIndex = 0; leftIndex < scene.planes.length; leftIndex += 1) {
    const left = scene.planes[leftIndex]!;
    for (let rightIndex = leftIndex + 1; rightIndex < scene.planes.length; rightIndex += 1) {
      const right = scene.planes[rightIndex]!;
      expect(rectanglesOverlap(left.position, left.size, right.position, right.size)).toBe(false);
    }
  }

  for (const plane of scene.planes) {
    const nodes = scene.nodes.filter((node) => node.planeId === plane.id);
    for (const node of nodes) {
      expect(Math.abs(node.position[0] - plane.position[0]) + node.size[0] / 2).toBeLessThanOrEqual(plane.size[0] / 2 + 0.001);
      expect(Math.abs(node.position[2] - plane.position[2]) + node.size[2] / 2).toBeLessThanOrEqual(plane.size[1] / 2 + 0.001);
    }
    for (let leftIndex = 0; leftIndex < nodes.length; leftIndex += 1) {
      for (let rightIndex = leftIndex + 1; rightIndex < nodes.length; rightIndex += 1) {
        const left = nodes[leftIndex]!;
        const right = nodes[rightIndex]!;
        expect(rectanglesOverlap(left.position, [left.size[0], left.size[2]], right.position, [right.size[0], right.size[2]])).toBe(false);
      }
    }
  }
});

test("resources are grouped by provider product within each slab", () => {
  const scene = deriveZiacSceneModel(mixedRegionalModel(), "architecture");
  const europeGroups = scene.groups.filter((group) => group.planeId === "region:europe-west1");

  expect(europeGroups.map((group) => [group.family, group.count])).toEqual([
    ["gcp.run", 5],
    ["gcp.storage", 3],
  ]);
  expect(europeGroups.map((group) => group.label)).toEqual(["Cloud Run", "Cloud Storage"]);

  for (const group of europeGroups) {
    const nodes = scene.nodes.filter((node) => node.groupId === group.id);
    expect(nodes.map((node) => node.id).sort()).toEqual([...group.nodeIds].sort());
    for (const node of nodes) {
      expect(rectangleContains(group.position, group.size, node.position, [node.size[0], node.size[2]])).toBe(true);
    }
  }
  expect(rectanglesOverlap(europeGroups[0]!.position, europeGroups[0]!.size, europeGroups[1]!.position, europeGroups[1]!.size)).toBe(false);
});

test("same-slab IAM access becomes a labelled local permission route", () => {
  const scene = deriveZiacSceneModel(mixedRegionalModel(), "architecture");
  const route = scene.routes.find((value) => value.id === "runtime-bucket-access");

  expect(route).toMatchObject({
    kind: "iam",
    access: "read_write",
    label: "READ / WRITE",
    intraPlane: true,
    permissions: ["storage.objects.create", "storage.objects.get"],
  });
  expect(scene.nodes.find((node) => node.id === "gcp.run.Service.europe-west1.api-0")?.iconPath).toBe("/provider-icons/gcp/cloud-run.png");
  expect(scene.nodes.find((node) => node.id === "gcp.storage.Bucket.europe-west1.assets-0")?.iconPath).toBe("/provider-icons/gcp/cloud-storage.png");
});

test("topology routes are planar orthogonal traces with pastel semantics", () => {
  const scene = deriveZiacSceneModel(filteredModel(), "architecture");

  for (const route of scene.routes) {
    expect(route.path.length).toBeGreaterThanOrEqual(4);
    expect(route.path[0]).toEqual(route.source);
    expect(route.path.at(-1)).toEqual(route.target);
    expect(new Set(route.path.map((point) => point[1].toFixed(4))).size).toBe(1);
    for (let index = 1; index < route.path.length; index += 1) {
      const previous = route.path[index - 1]!;
      const current = route.path[index]!;
      const changesX = Math.abs(current[0] - previous[0]) > 0.001;
      const changesZ = Math.abs(current[2] - previous[2]) > 0.001;
      expect(changesX && changesZ).toBe(false);
    }
  }

  expect(scene.routes.find((route) => route.kind === "traffic")?.accent).toBe("#8bb7e8");
  expect(scene.routes.find((route) => route.kind === "dependency")?.accent).toBe("#9eabb8");
});

test("GCP account and global VPC boundaries encode nested ownership", () => {
  const scene = deriveZiacSceneModel(filteredModel(), "architecture");
  const gcp = scene.boundaries.find((boundary) => boundary.id === "account:gcp");
  const vpc = scene.boundaries.find((boundary) => boundary.id === "network:gcp:global-vpc");
  const cockroach = scene.boundaries.find((boundary) => boundary.id === "account:cockroach");

  expect(gcp).toMatchObject({ kind: "account", provider: "gcp", label: "GCP account" });
  expect(vpc).toMatchObject({ kind: "network", provider: "gcp", parentId: "account:gcp", label: "Global VPC" });
  expect(cockroach).toMatchObject({ kind: "external_account", provider: "cockroach", label: "Cockroach Cloud account" });
  expect(rectangleContains(gcp!.position, gcp!.size, vpc!.position, vpc!.size)).toBe(true);
  expect(rectanglesOverlap(gcp!.position, gcp!.size, cockroach!.position, cockroach!.size)).toBe(false);

  const regionalPlaneIds = scene.planes.filter((plane) => plane.kind === "region").map((plane) => plane.id);
  expect(vpc!.containedPlaneIds).toEqual(regionalPlaneIds);
  expect(vpc!.containedPlaneIds).not.toContain("group:global");
  expect(vpc!.containedPlaneIds).not.toContain("group:project");
  for (const plane of scene.planes.filter((value) => value.kind !== "data")) {
    expect(gcp!.containedPlaneIds).toContain(plane.id);
    expect(rectangleContains(gcp!.position, gcp!.size, plane.position, plane.size)).toBe(true);
  }
  expect(cockroach!.containedPlaneIds).toEqual(["group:multi-region"]);
});

test("Cockroach account projects declared regions without duplicating cluster resources", () => {
  const scene = deriveZiacSceneModel(filteredModel(), "architecture");
  const account = scene.boundaries.find((boundary) => boundary.id === "account:cockroach")!;
  const localities = scene.localities.filter((locality) => locality.boundaryId === account.id);

  expect(localities.map((locality) => locality.region)).toEqual([
    "asia-northeast1",
    "europe-west1",
    "us-central1",
  ]);
  expect(localities.find((locality) => locality.primary)?.region).toBe("europe-west1");
  expect(localities.every((locality) => locality.resourceIds.length === 1 && locality.resourceIds[0] === "cockroach.Cluster.global-data")).toBe(true);
  expect(scene.nodes.filter((node) => node.provider === "cockroach")).toHaveLength(1);
  for (const locality of localities) {
    expect(rectangleContains(account.position, account.size, locality.position, locality.size)).toBe(true);
  }
  for (let left = 0; left < localities.length; left += 1) {
    for (let right = left + 1; right < localities.length; right += 1) {
      expect(rectanglesOverlap(localities[left]!.position, localities[left]!.size, localities[right]!.position, localities[right]!.size)).toBe(false);
    }
  }
});

test("boundary labels occupy reserved gutters without intersecting child slabs", () => {
  const scene = deriveZiacSceneModel(filteredModel(), "architecture");

  for (const boundary of scene.boundaries) {
    expect(rectangleContains(boundary.position, boundary.size, boundary.surface.position, boundary.surface.size)).toBe(true);
    const containedPlanes = scene.planes.filter((plane) => boundary.containedPlaneIds.includes(plane.id));
    const containedLocalities = scene.localities.filter((locality) => locality.boundaryId === boundary.id);
    for (const item of [...containedPlanes, ...containedLocalities]) {
      expect(rectanglesOverlap(boundary.surface.position, boundary.surface.size, item.position, item.size)).toBe(false);
    }
  }
});

test("Three topology renderer maps identity to object faces and exposes hover intelligence", () => {
  const value = readFileSync(new URL("./ziacTopologyScene.tsx", import.meta.url), "utf8");

  expect(value).toContain('from "three"');
  expect(value).toContain("OrthographicCamera");
  expect(value).toContain("RoundedBoxGeometry");
  expect(value).toContain("CanvasTexture");
  expect(value).toContain("createResourceFaceTexture");
  expect(value).toContain("node.ownership");
  expect(value).toContain('"OBSERVED"');
  expect(value).toContain("createSlabSurfaceTexture");
  expect(value).toContain("addResourceTopIcon");
  expect(value).toContain("TextureLoader");
  expect(value).toContain("addGroupZone");
  expect(value).toContain("createGroupSurfaceTexture");
  expect(value).toContain("createPermissionTexture");
  expect(value).toContain("Line2");
  expect(value).toContain("LineGeometry");
  expect(value).toContain("LineMaterial");
  expect(value).toContain("route.path");
  expect(value).toContain("addFlatArrowhead");
  expect(value).toContain("addFlatPermissionBadge");
  expect(value).not.toContain("CatmullRomCurve3");
  expect(value).not.toContain("TubeGeometry");
  expect(value).not.toContain("ConeGeometry");
  expect(value).toContain("addEstateMoat");
  expect(value).toContain("createEstateSurfaceTexture");
  expect(value).toContain("boundary.surface.size");
  expect(value).toContain("boundary.surface.position");
  expect(value).toContain("addCockroachLocality");
  expect(value).not.toContain("slabTexture.rotation = Math.PI");
  expect(value).not.toContain("CSS2DRenderer");
  expect(value).toContain("Raycaster");
  expect(value).toContain("ziac-scene-tooltip");
  expect(value).toContain("Actual spend appears only from an authorized detailed Cloud Billing export");
  expect(value).toContain("Uptime");
  expect(value).toContain('aria-label="3D infrastructure topology"');
  expect(value).toContain("ResizeObserver");
  expect(value).toContain('camera.up.set(0, projection === "2d" ? 0 : 1, projection === "2d" ? -1 : 0)');
  expect(value).toContain('controls.maxPolarAngle = projection === "2d" ? Math.PI : Math.PI / 2.15');
  expect(value).toContain("controls.minZoom = 0.1");
  expect(value).toContain('if (currentProjection === "3d") controls.update()');
  expect(value).toContain('controls.enabled = projection === "3d"');
  expect(value).toContain("if (currentModel) fitModel(camera, controls, currentModel, true, projection)");
});

function expandedModel(): FilteredZiacVisualModel {
  const base = filteredModel();
  const regions = [
    "asia-east1", "asia-northeast1", "asia-south1", "asia-southeast1",
    "australia-southeast1", "europe-north1", "europe-west1", "europe-west2",
    "northamerica-northeast1", "southamerica-east1", "us-central1", "us-east1",
  ];
  const template = base.resources.find((resource) => resource.type === "gcp.run.Service")!;
  const globalResources = base.resources.filter((resource) => resource.scope !== "regional" && resource.scope !== "multi_region");
  const regionalResources = regions.flatMap((region) => Array.from({ length: 4 }, (_, index): ZiacVisualResource => ({
    ...template,
    id: `gcp.run.Service.${region}.service-${index}`,
    logical_id: `service-${index}`,
    region,
    regions: [region],
  })));
  const dataResources = base.resources.filter((resource) => resource.scope === "multi_region");
  const resources = [...globalResources, ...regionalResources, ...dataResources];
  const regionNodes = regions.map((region) => ({
    id: region,
    location: null,
    resources: regionalResources.filter((resource) => resource.region === region),
    operations: ["create" as const],
    health: "unknown" as const,
  }));
  return {
    ...base,
    artifact: {
      ...base.artifact,
      regions,
      resources,
      edges: [],
      routes: [],
      summary: { resources: resources.length, edges: 0, regions: regions.length },
    },
    resources,
    edges: [],
    routes: [],
    regionNodes,
    resourceIds: new Set(resources.map((resource) => resource.id)),
  };
}

function mixedRegionalModel(): FilteredZiacVisualModel {
  const base = filteredModel();
  const cloudRunTemplate = base.resources.find((resource) => resource.type === "gcp.run.Service")!;
  const region = "europe-west1";
  const services = Array.from({ length: 5 }, (_, index): ZiacVisualResource => ({
    ...cloudRunTemplate,
    id: `gcp.run.Service.${region}.api-${index}`,
    logical_id: `api-${index}`,
    region,
    regions: [region],
  }));
  const buckets = Array.from({ length: 3 }, (_, index): ZiacVisualResource => ({
    ...cloudRunTemplate,
    id: `gcp.storage.Bucket.${region}.assets-${index}`,
    type: "gcp.storage.Bucket",
    logical_id: `assets-${index}`,
    inputs: { name: `assets-${index}`, location: region },
    region,
    regions: [region],
  }));
  const resources = [...services, ...buckets];
  const edges: ZiacVisualEdge[] = [{
    id: "runtime-bucket-access",
    from: services[0]!.id,
    to: buckets[0]!.id,
    kind: "iam",
    access: "read_write",
    permissions: ["storage.objects.create", "storage.objects.get"],
  }];
  return {
    ...base,
    artifact: {
      ...base.artifact,
      regions: [region],
      resources,
      edges,
      routes: [],
      summary: { resources: resources.length, edges: edges.length, regions: 1 },
    },
    resources,
    edges,
    routes: [],
    regionNodes: [{ id: region, location: null, resources, operations: ["create"], health: "unknown" }],
    resourceIds: new Set(resources.map((resource) => resource.id)),
  };
}

function rectanglesOverlap(
  leftPosition: readonly [number, number, number],
  leftSize: readonly [number, number],
  rightPosition: readonly [number, number, number],
  rightSize: readonly [number, number],
): boolean {
  const separatedX = Math.abs(leftPosition[0] - rightPosition[0]) >= (leftSize[0] + rightSize[0]) / 2;
  const separatedZ = Math.abs(leftPosition[2] - rightPosition[2]) >= (leftSize[1] + rightSize[1]) / 2;
  return !separatedX && !separatedZ;
}

function rectangleContains(
  outerPosition: readonly [number, number, number],
  outerSize: readonly [number, number],
  innerPosition: readonly [number, number, number],
  innerSize: readonly [number, number],
) {
  return Math.abs(innerPosition[0] - outerPosition[0]) + innerSize[0] / 2 <= outerSize[0] / 2 + 0.001
    && Math.abs(innerPosition[2] - outerPosition[2]) + innerSize[1] / 2 <= outerSize[1] / 2 + 0.001;
}
