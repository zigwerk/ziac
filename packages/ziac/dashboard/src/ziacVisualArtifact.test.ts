// Standalone Ziac dashboard artifact coverage.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import {
  deriveZiacDashboardModel,
  deriveZiacVisualModel,
  filterZiacVisualModel,
  gcpRegionLocation,
  parseZiacVisualArtifact,
} from "./ziacVisualArtifact";

const sampleJson = () => readFileSync(new URL("../public/sample-ziac-global.json", import.meta.url), "utf8");
const estateJson = () => readFileSync(new URL("../public/sample-ziac-estate.json", import.meta.url), "utf8");

test("parseZiacVisualArtifact validates the generated global topology", () => {
  const artifact = parseZiacVisualArtifact(JSON.parse(sampleJson()));

  expect(artifact.schema).toBe("ziac.visual.v1");
  expect(artifact.stack).toBe("global-api");
  expect(artifact.summary.resources).toBe(17);
  expect(artifact.regions).toEqual(["asia-northeast1", "europe-west1", "us-central1"]);
  expect(artifact.resources.find((resource) => resource.type === "cockroach.Cluster")?.scope).toBe("multi_region");
  expect(artifact.edges.some((edge) => edge.kind === "traffic")).toBe(true);
  expect(artifact.edges.some((edge) => edge.kind === "output")).toBe(true);
  expect(artifact.routes).toHaveLength(3);
  expect(artifact.routes.every((route) => route.from_resource.endsWith("api-https"))).toBe(true);
});

test("deriveZiacVisualModel maps regions routes summaries and provider families", () => {
  const model = deriveZiacVisualModel(parseZiacVisualArtifact(JSON.parse(sampleJson())));

  expect(model.regionNodes).toHaveLength(3);
  expect(model.regionNodes.every((node) => node.location !== null)).toBe(true);
  expect(model.routes).toHaveLength(3);
  expect(model.operationCounts.create).toBe(17);
  expect(model.providerCounts.gcp).toBe(16);
  expect(model.providerCounts.cockroach).toBe(1);
  expect(model.warnings).toEqual([]);
  expect(model.frontDoor?.type).toBe("gcp.compute.GlobalForwardingRule");
});

test("filterZiacVisualModel keeps edges routes and resources synchronized", () => {
  const model = deriveZiacVisualModel(parseZiacVisualArtifact(JSON.parse(sampleJson())));
  const filtered = filterZiacVisualModel(model, {
    text: "api",
    provider: "gcp",
    region: "europe-west1",
    operation: "create",
    health: "all",
  });

  expect(filtered.resources.length).toBeGreaterThan(0);
  expect(filtered.resources.every((resource) => resource.provider === "gcp")).toBe(true);
  expect(filtered.resources.every((resource) => resource.scope === "global" || resource.regions.includes("europe-west1"))).toBe(true);
  expect(filtered.edges.every((edge) => filtered.resourceIds.has(edge.from) && filtered.resourceIds.has(edge.to))).toBe(true);
  expect(filtered.routes.every((route) => filtered.resourceIds.has(route.to_resource))).toBe(true);
});

test("visual model keeps unknown regions visible with an actionable warning", () => {
  const raw = JSON.parse(sampleJson());
  raw.regions.push("moon-west1");
  raw.summary.regions = raw.regions.length;
  raw.resources[14].region = "moon-west1";
  raw.resources[14].regions = ["moon-west1"];
  raw.routes[0].to_region = "moon-west1";
  const model = deriveZiacVisualModel(parseZiacVisualArtifact(raw));

  expect(model.regionNodes.find((node) => node.id === "moon-west1")?.location).toBeNull();
  expect(model.warnings).toContain("No map coordinates are registered for GCP region moon-west1.");
});

test("parser rejects duplicate resources dangling edges and secret-bearing fields", () => {
  const duplicate = JSON.parse(sampleJson());
  duplicate.resources.push(duplicate.resources[0]);
  expect(() => parseZiacVisualArtifact(duplicate)).toThrow("duplicate resource id");

  const dangling = JSON.parse(sampleJson());
  dangling.edges[0].to = "gcp.run.Service.missing";
  expect(() => parseZiacVisualArtifact(dangling)).toThrow("unknown resource");

  const secret = JSON.parse(sampleJson());
  secret.resources[0].inputs.api_token = "plaintext-token";
  expect(() => parseZiacVisualArtifact(secret)).toThrow("unredacted secret-like field");
});

test("GCP region catalogue exposes stable real-world coordinates", () => {
  expect(gcpRegionLocation("europe-west1")).toEqual({ longitude: 4.47, latitude: 50.48, label: "Belgium" });
  expect(gcpRegionLocation("us-central1")?.longitude).toBeLessThan(-90);
  expect(gcpRegionLocation("asia-northeast1")?.longitude).toBeGreaterThan(130);
  expect(gcpRegionLocation("unknown-region")).toBeNull();
});

test("parser accepts bounded permission metadata and rejects unknown access modes", () => {
  const raw = JSON.parse(sampleJson());
  raw.edges[0] = {
    ...raw.edges[0],
    kind: "iam",
    access: "read_write",
    permissions: ["storage.objects.create", "storage.objects.get"],
  };
  const parsed = parseZiacVisualArtifact(raw);

  expect(parsed.edges[0]?.access).toBe("read_write");
  expect(parsed.edges[0]?.permissions).toEqual(["storage.objects.create", "storage.objects.get"]);

  raw.edges[0]!.access = "superuser";
  expect(() => parseZiacVisualArtifact(raw)).toThrow("edges[0].access");
});

test("estate ownership defaults to managed and filters existing infrastructure without dangling graph data", () => {
  const raw = JSON.parse(sampleJson());
  raw.resources.push({
    ...raw.resources.find((resource: { type: string }) => resource.type === "gcp.run.Service"),
    id: "gcp.run.Service.europe-west1.legacy-api",
    logical_id: "legacy-api",
    operation: "read",
    ownership: "observed",
    discovery: {
      provider: "cloud_asset_inventory",
      project_id: "acme-foundation-prod",
      observed_at_millis: 1783764000000,
      source_name: "//run.googleapis.com/projects/acme-foundation-prod/locations/europe-west1/services/legacy-api",
    },
  });
  raw.resources.push({
    ...raw.resources.find((resource: { type: string }) => resource.type === "gcp.run.Service"),
    id: "gcp.run.Service.europe-west1.shared-auth",
    logical_id: "shared-auth",
    operation: "read",
    ownership: "referenced",
    discovery: {
      provider: "cloud_asset_inventory",
      project_id: "acme-foundation-prod",
      observed_at_millis: 1783764000000,
      source_name: "//run.googleapis.com/projects/acme-foundation-prod/locations/europe-west1/services/shared-auth",
    },
  });
  raw.summary.resources = raw.resources.length;
  raw.edges.push({
    id: "observed-to-managed",
    from: "gcp.run.Service.europe-west1.legacy-api",
    to: "gcp.run.Service.europe-west1.api",
    kind: "connectivity",
  });
  raw.summary.edges = raw.edges.length;

  const model = deriveZiacVisualModel(parseZiacVisualArtifact(raw));
  expect(model.resources[0]?.ownership).toBe("managed");
  expect(model.ownershipCounts).toEqual({ managed: 17, observed: 1, referenced: 1 });

  const filters = { text: "", provider: "all" as const, region: "all", operation: "all" as const, health: "all" as const };
  const managed = filterZiacVisualModel(model, { ...filters, estate: "managed" });
  const existing = filterZiacVisualModel(model, { ...filters, estate: "existing" });
  const combined = filterZiacVisualModel(model, { ...filters, estate: "combined" });

  expect(managed.resources).toHaveLength(17);
  expect(existing.resources.map((resource) => resource.ownership).sort()).toEqual(["observed", "referenced"]);
  expect(combined.resources).toHaveLength(19);
  expect(existing.edges.every((edge) => existing.resourceIds.has(edge.from) && existing.resourceIds.has(edge.to))).toBe(true);
  expect(combined.edges.some((edge) => edge.id === "observed-to-managed")).toBe(true);
});

test("observed resources require bounded redacted discovery metadata", () => {
  const raw = JSON.parse(sampleJson());
  raw.resources[0].ownership = "observed";
  expect(() => parseZiacVisualArtifact(raw)).toThrow("discovery");

  raw.resources[0].discovery = {
    provider: "cloud_asset_inventory",
    project_id: "acme-foundation-prod",
    observed_at_millis: 1783764000000,
    source_name: "//compute.googleapis.com/projects/acme-foundation-prod/global/addresses/api-ip",
    credential_url: "https://example.invalid/token",
  };
  expect(() => parseZiacVisualArtifact(raw)).toThrow("unredacted secret-like field");

  raw.resources[0].ownership = "adopted";
  delete raw.resources[0].discovery.credential_url;
  expect(() => parseZiacVisualArtifact(raw)).toThrow("ownership");
});

test("connected estate fixture keeps observed and managed infrastructure distinct", () => {
  const model = deriveZiacVisualModel(parseZiacVisualArtifact(JSON.parse(estateJson())));
  expect(model.ownershipCounts).toEqual({ managed: 5, observed: 6, referenced: 1 });
  expect(model.resources.find((resource) => resource.type === "gcp.sql.Instance")?.ownership).toBe("observed");
  expect(model.edges.some((edge) => edge.id === "managed-assets")).toBe(true);
});

test("workspace artifacts merge projects with collision-safe identities", () => {
  const payments = JSON.parse(sampleJson());
  const platform = JSON.parse(sampleJson());
  payments.resources = payments.resources.slice(0, 2);
  payments.edges = payments.edges.filter((edge: { from: string; to: string }) =>
    payments.resources.some((resource: { id: string }) => resource.id === edge.from) &&
    payments.resources.some((resource: { id: string }) => resource.id === edge.to));
  payments.routes = [];
  payments.regions = ["europe-west1"];
  payments.summary = { resources: payments.resources.length, edges: payments.edges.length, regions: 1 };
  platform.resources = platform.resources.slice(0, 2);
  platform.edges = platform.edges.filter((edge: { from: string; to: string }) =>
    platform.resources.some((resource: { id: string }) => resource.id === edge.from) &&
    platform.resources.some((resource: { id: string }) => resource.id === edge.to));
  platform.routes = [];
  platform.regions = ["europe-west1"];
  platform.summary = { resources: platform.resources.length, edges: platform.edges.length, regions: 1 };

  const model = deriveZiacDashboardModel({
    schema: "ziac.workspace-visual.v1",
    format_version: 1,
    workspace: "ziac-cloud",
    created_at_millis: 42,
    projects: [
      { project: "payments", path: "services/payments/infra", stack: "payments-api", stage: "dev", artifact: payments },
      { project: "platform", path: "platform", stack: "foundation", stage: "dev", artifact: platform },
    ],
    links: [{
      id: "payments-network",
      from: { project: "payments", resource: payments.resources[0].id },
      to: { project: "platform", resource: platform.resources[0].id },
      kind: "dependency",
    }],
  });

  expect(model.workspace?.id).toBe("ziac-cloud");
  expect(model.projects.map((project) => project.id)).toEqual(["payments", "platform"]);
  expect(model.resources).toHaveLength(4);
  expect(model.resources.every((resource) => resource.id.startsWith(`${resource.project_id}::`))).toBe(true);
  expect(model.edges.some((edge) => edge.id === "workspace::payments-network")).toBe(true);
});

test("project slices can include dependencies and consumers without dangling graph data", () => {
  const raw = JSON.parse(sampleJson());
  const project = (id: string, resource: Record<string, unknown>) => ({
    project: id,
    path: id,
    stack: id,
    stage: "dev",
    artifact: {
      ...raw,
      resources: [resource],
      edges: [],
      routes: [],
      regions: resource.regions as string[],
      summary: { resources: 1, edges: 0, regions: (resource.regions as string[]).length },
    },
  });
  const paymentsResource = { ...raw.resources[0], id: "service", logical_id: "payments" };
  const platformResource = { ...raw.resources[1], id: "network", logical_id: "network" };
  const searchResource = { ...raw.resources[2], id: "search", logical_id: "search" };
  const model = deriveZiacDashboardModel({
    schema: "ziac.workspace-visual.v1",
    format_version: 1,
    workspace: "ziac-cloud",
    created_at_millis: 42,
    projects: [project("payments", paymentsResource), project("platform", platformResource), project("search", searchResource)],
    links: [
      { id: "payments-platform", from: { project: "payments", resource: "service" }, to: { project: "platform", resource: "network" }, kind: "dependency" },
      { id: "search-platform", from: { project: "search", resource: "search" }, to: { project: "platform", resource: "network" }, kind: "dependency" },
    ],
  });
  const filters = { text: "", provider: "all" as const, region: "all", operation: "all" as const, health: "all" as const, projects: ["platform"] };

  const selected = filterZiacVisualModel(model, { ...filters, projectScope: "selected" });
  const dependencies = filterZiacVisualModel(model, { ...filters, projects: ["payments"], projectScope: "dependencies" });
  const connected = filterZiacVisualModel(model, { ...filters, projectScope: "connected" });

  expect(selected.resources.map((resource) => resource.project_id)).toEqual(["platform"]);
  expect(dependencies.resources.map((resource) => resource.project_id).sort()).toEqual(["payments", "platform"]);
  expect(connected.resources.map((resource) => resource.project_id).sort()).toEqual(["payments", "platform", "search"]);
  expect(connected.edges.every((edge) => connected.resourceIds.has(edge.from) && connected.resourceIds.has(edge.to))).toBe(true);
});
