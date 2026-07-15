// Ziac dashboard-owned visual artifact contract.
export type ZiacTruthMode = "desired" | "plan" | "live" | "traffic";
export type ZiacProvider = "gcp" | "cockroach" | "local";
export type ZiacScope = "global" | "regional" | "multi_region" | "project" | "local";
export type ZiacOperation = "none" | "create" | "update" | "replace" | "delete" | "read" | "noop";
export type ZiacHealth = "unknown" | "healthy" | "degraded" | "unhealthy" | "reconciling";
export type ZiacEdgeKind = "dependency" | "output" | "traffic" | "iam" | "connectivity";
export type ZiacAccessMode = "read" | "write" | "read_write" | "invoke" | "admin";
export type ZiacRouteProvenance = "planned" | "inferred" | "observed";
export type ZiacOwnership = "managed" | "observed" | "referenced";
export type ZiacEstateScope = "managed" | "existing" | "combined";
export type ZiacProjectScope = "selected" | "dependencies" | "connected";

export type ZiacVisualProject = {
  id: string;
  path: string;
  stack: string;
  stage: string;
  resources: number;
};

export type ZiacVisualWorkspace = {
  id: string;
  created_at_millis: number;
};

export type ZiacResourceDiscovery = {
  provider: "cloud_asset_inventory";
  project_id: string;
  observed_at_millis: number;
  source_name: string;
};

export type ZiacResourceCost = {
  schema: "ziac.resource-cost.v1";
  origin: "configuration_estimate" | "projected_month_end" | "actual_billed";
  currency: string;
  amount_micros: number | null;
  confidence: "unavailable" | "explicit_usage" | "billing_partial_month" | "billing_complete";
  basis?: "usage_assumptions_required" | "documented_no_charge" | "service_no_charge";
  observed_at_millis: number;
  is_billing_export: boolean;
};

export type ZiacIamDetails = {
  ownership: "member" | "binding" | "policy";
  target: string;
  role?: string;
  condition_title?: string;
  principal_count: number;
};

export type ZiacDataEngineeringDetails = Record<string, unknown> & {
  kind: "dataflow_pipeline" | "dataproc_cluster" | "dataproc_autoscaling_policy" | "dataproc_workflow_template" | "dataform_repository" | "dataform_workspace" | "dataform_release_config" | "dataform_workflow_config" | "data_engineering_iam";
};

export type ZiacVisualResource = {
  id: string;
  provider: ZiacProvider;
  type: string;
  logical_id: string;
  scope: ZiacScope;
  region?: string;
  regions: string[];
  operation: ZiacOperation;
  health: ZiacHealth;
  ownership: ZiacOwnership;
  discovery?: ZiacResourceDiscovery;
  cost?: ZiacResourceCost;
  iam?: ZiacIamDetails;
  data_engineering?: ZiacDataEngineeringDetails;
  inputs: Record<string, unknown>;
  lifecycle: {
    protect: boolean;
    retain_on_delete: boolean;
    replace_before_delete: boolean;
  };
  reasons: string[];
  project_id?: string;
  project_path?: string;
  source_id?: string;
};

export type ZiacVisualEdge = {
  id: string;
  from: string;
  to: string;
  kind: ZiacEdgeKind;
  access?: ZiacAccessMode;
  permissions?: string[];
};

export type ZiacVisualRoute = {
  id: string;
  from_resource: string;
  to_resource: string;
  to_region: string;
  provenance: ZiacRouteProvenance;
};

export type ZiacVisualArtifact = {
  schema: "ziac.visual.v1";
  format_version: 1;
  truth_mode: ZiacTruthMode;
  created_at_millis: number;
  stack: string;
  stage: string;
  graph_digest: string;
  state_serial: number;
  summary: { resources: number; edges: number; regions: number };
  regions: string[];
  resources: ZiacVisualResource[];
  edges: ZiacVisualEdge[];
  routes: ZiacVisualRoute[];
  observations: unknown[];
  diagnostics: unknown[];
};

export type RegionLocation = {
  longitude: number;
  latitude: number;
  label: string;
};

export type ZiacRegionNode = {
  id: string;
  location: RegionLocation | null;
  resources: ZiacVisualResource[];
  operations: ZiacOperation[];
  health: ZiacHealth;
};

export type ZiacVisualModel = {
  artifact: ZiacVisualArtifact;
  resources: ZiacVisualResource[];
  edges: ZiacVisualEdge[];
  routes: ZiacVisualRoute[];
  regionNodes: ZiacRegionNode[];
  frontDoor: ZiacVisualResource | null;
  operationCounts: Record<ZiacOperation, number>;
  providerCounts: Record<ZiacProvider, number>;
  ownershipCounts: Record<ZiacOwnership, number>;
  warnings: string[];
  workspace: ZiacVisualWorkspace | null;
  projects: ZiacVisualProject[];
};

export type ZiacVisualFilters = {
  text: string;
  provider: ZiacProvider | "all";
  region: string | "all";
  operation: ZiacOperation | "all";
  health: ZiacHealth | "all";
  estate?: ZiacEstateScope;
  projects?: string[];
  projectScope?: ZiacProjectScope;
};

export type FilteredZiacVisualModel = ZiacVisualModel & { resourceIds: Set<string> };

const providers: ZiacProvider[] = ["gcp", "cockroach", "local"];
const scopes: ZiacScope[] = ["global", "regional", "multi_region", "project", "local"];
const operations: ZiacOperation[] = ["none", "create", "update", "replace", "delete", "read", "noop"];
const healthStates: ZiacHealth[] = ["unknown", "healthy", "degraded", "unhealthy", "reconciling"];
const edgeKinds: ZiacEdgeKind[] = ["dependency", "output", "traffic", "iam", "connectivity"];
const accessModes: ZiacAccessMode[] = ["read", "write", "read_write", "invoke", "admin"];
const routeProvenance: ZiacRouteProvenance[] = ["planned", "inferred", "observed"];
const ownershipStates: ZiacOwnership[] = ["managed", "observed", "referenced"];

const regionLocations: Record<string, RegionLocation> = {
  "africa-south1": { longitude: 18.42, latitude: -33.92, label: "Johannesburg" },
  "asia-east1": { longitude: 121.56, latitude: 25.04, label: "Taiwan" },
  "asia-east2": { longitude: 114.17, latitude: 22.32, label: "Hong Kong" },
  "asia-northeast1": { longitude: 139.65, latitude: 35.68, label: "Tokyo" },
  "asia-northeast2": { longitude: 135.5, latitude: 34.69, label: "Osaka" },
  "asia-northeast3": { longitude: 127.03, latitude: 37.5, label: "Seoul" },
  "asia-south1": { longitude: 72.88, latitude: 19.08, label: "Mumbai" },
  "asia-south2": { longitude: 77.1, latitude: 28.7, label: "Delhi" },
  "asia-southeast1": { longitude: 103.82, latitude: 1.35, label: "Singapore" },
  "asia-southeast2": { longitude: 106.85, latitude: -6.21, label: "Jakarta" },
  "australia-southeast1": { longitude: 151.21, latitude: -33.87, label: "Sydney" },
  "australia-southeast2": { longitude: 144.96, latitude: -37.81, label: "Melbourne" },
  "europe-central2": { longitude: 21.01, latitude: 52.23, label: "Warsaw" },
  "europe-north1": { longitude: 24.94, latitude: 60.17, label: "Finland" },
  "europe-southwest1": { longitude: -3.7, latitude: 40.42, label: "Madrid" },
  "europe-west1": { longitude: 4.47, latitude: 50.48, label: "Belgium" },
  "europe-west2": { longitude: -0.13, latitude: 51.51, label: "London" },
  "europe-west3": { longitude: 8.68, latitude: 50.11, label: "Frankfurt" },
  "europe-west4": { longitude: 5.29, latitude: 52.13, label: "Netherlands" },
  "europe-west6": { longitude: 8.54, latitude: 47.38, label: "Zurich" },
  "europe-west8": { longitude: 9.19, latitude: 45.46, label: "Milan" },
  "europe-west9": { longitude: 2.35, latitude: 48.86, label: "Paris" },
  "europe-west10": { longitude: 13.4, latitude: 52.52, label: "Berlin" },
  "europe-west12": { longitude: 12.5, latitude: 41.9, label: "Turin" },
  "me-central1": { longitude: 51.53, latitude: 25.29, label: "Doha" },
  "me-central2": { longitude: 34.79, latitude: 32.09, label: "Dammam" },
  "me-west1": { longitude: 34.78, latitude: 32.08, label: "Tel Aviv" },
  "northamerica-northeast1": { longitude: -73.57, latitude: 45.5, label: "Montreal" },
  "northamerica-northeast2": { longitude: -79.38, latitude: 43.65, label: "Toronto" },
  "northamerica-south1": { longitude: -99.13, latitude: 19.43, label: "Mexico" },
  "southamerica-east1": { longitude: -46.63, latitude: -23.55, label: "Sao Paulo" },
  "southamerica-west1": { longitude: -70.67, latitude: -33.45, label: "Santiago" },
  "us-central1": { longitude: -93.62, latitude: 41.59, label: "Iowa" },
  "us-east1": { longitude: -80.84, latitude: 35.23, label: "South Carolina" },
  "us-east4": { longitude: -77.49, latitude: 39.04, label: "Northern Virginia" },
  "us-east5": { longitude: -82.99, latitude: 39.96, label: "Columbus" },
  "us-south1": { longitude: -96.8, latitude: 32.78, label: "Dallas" },
  "us-west1": { longitude: -121.49, latitude: 38.58, label: "Oregon" },
  "us-west2": { longitude: -118.24, latitude: 34.05, label: "Los Angeles" },
  "us-west3": { longitude: -111.89, latitude: 40.76, label: "Salt Lake City" },
  "us-west4": { longitude: -115.14, latitude: 36.17, label: "Las Vegas" },
};

export function gcpRegionLocation(region: string): RegionLocation | null {
  return regionLocations[region] ?? null;
}

export function parseZiacVisualArtifact(raw: unknown): ZiacVisualArtifact {
  const root = objectValue(raw, "artifact");
  if (stringValue(root.schema, "schema") !== "ziac.visual.v1") throw new Error("unsupported Ziac visual schema");
  if (integerValue(root.format_version, "format_version") !== 1) throw new Error("unsupported Ziac visual format version");

  const resources = arrayValue(root.resources, "resources").map(parseResource);
  const resourceIds = uniqueIds(resources, "resource");
  const edges = arrayValue(root.edges, "edges").map(parseEdge);
  uniqueIds(edges, "edge");
  for (const edge of edges) {
    if (!resourceIds.has(edge.from) || !resourceIds.has(edge.to)) throw new Error(`edge ${edge.id} references unknown resource`);
  }
  const routes = arrayValue(root.routes, "routes").map(parseRoute);
  uniqueIds(routes, "route");
  for (const route of routes) {
    if (!resourceIds.has(route.from_resource) || !resourceIds.has(route.to_resource)) {
      throw new Error(`route ${route.id} references unknown resource`);
    }
  }

  const regions = stringArray(root.regions, "regions");
  const summaryObject = objectValue(root.summary, "summary");
  const summary = {
    resources: integerValue(summaryObject.resources, "summary.resources"),
    edges: integerValue(summaryObject.edges, "summary.edges"),
    regions: integerValue(summaryObject.regions, "summary.regions"),
  };
  if (summary.resources !== resources.length || summary.edges !== edges.length || summary.regions !== regions.length) {
    throw new Error("Ziac visual summary does not match artifact collections");
  }

  return {
    schema: "ziac.visual.v1",
    format_version: 1,
    truth_mode: enumValue(root.truth_mode, "truth_mode", ["desired", "plan", "live", "traffic"]),
    created_at_millis: integerValue(root.created_at_millis, "created_at_millis"),
    stack: nonEmptyString(root.stack, "stack"),
    stage: nonEmptyString(root.stage, "stage"),
    graph_digest: digestValue(root.graph_digest),
    state_serial: integerValue(root.state_serial, "state_serial"),
    summary,
    regions,
    resources,
    edges,
    routes,
    observations: arrayValue(root.observations, "observations"),
    diagnostics: arrayValue(root.diagnostics, "diagnostics"),
  };
}

export function deriveZiacVisualModel(artifact: ZiacVisualArtifact): ZiacVisualModel {
  const projectId = artifact.stack;
  const resources = artifact.resources.map((resource) => ({
    ...resource,
    project_id: resource.project_id ?? projectId,
    project_path: resource.project_path ?? ".",
    source_id: resource.source_id ?? resource.id,
  }));
  const operationCounts = Object.fromEntries(operations.map((operation) => [operation, 0])) as Record<ZiacOperation, number>;
  const providerCounts = Object.fromEntries(providers.map((provider) => [provider, 0])) as Record<ZiacProvider, number>;
  const ownershipCounts = Object.fromEntries(ownershipStates.map((ownership) => [ownership, 0])) as Record<ZiacOwnership, number>;
  for (const resource of resources) {
    operationCounts[resource.operation] += 1;
    providerCounts[resource.provider] += 1;
    ownershipCounts[resource.ownership] += 1;
  }
  const warnings: string[] = [];
  const regionNodes = artifact.regions.map((region): ZiacRegionNode => {
    const regionResources = resources.filter((resource) => resource.regions.includes(region));
    const location = gcpRegionLocation(region);
    if (!location) warnings.push(`No map coordinates are registered for GCP region ${region}.`);
    return {
      id: region,
      location,
      resources: regionResources,
      operations: unique(regionResources.map((resource) => resource.operation)),
      health: aggregateHealth(regionResources),
    };
  });
  const forwardingRules = resources.filter((resource) => resource.type === "gcp.compute.GlobalForwardingRule");
  const frontDoor = forwardingRules.find((resource) => resource.logical_id.includes("https") || resource.inputs.port === 443)
    ?? forwardingRules[0]
    ?? null;
  return {
    artifact,
    resources,
    edges: artifact.edges,
    routes: artifact.routes,
    regionNodes,
    frontDoor,
    operationCounts,
    providerCounts,
    ownershipCounts,
    warnings,
    workspace: null,
    projects: [{ id: projectId, path: ".", stack: artifact.stack, stage: artifact.stage, resources: resources.length }],
  };
}

export function deriveZiacDashboardModel(raw: unknown): ZiacVisualModel {
  const root = objectValue(raw, "artifact");
  if (root.schema === "ziac.visual.v1") return deriveZiacVisualModel(parseZiacVisualArtifact(root));
  if (stringValue(root.schema, "schema") !== "ziac.workspace-visual.v1") throw new Error("unsupported Ziac dashboard schema");
  if (integerValue(root.format_version, "format_version") !== 1) throw new Error("unsupported Ziac workspace format version");
  const workspaceId = nonEmptyString(root.workspace, "workspace");
  const createdAt = integerValue(root.created_at_millis, "created_at_millis");
  const entries = arrayValue(root.projects, "projects");
  if (entries.length === 0 || entries.length > 256) throw new Error("workspace projects must contain between 1 and 256 entries");

  const projects: ZiacVisualProject[] = [];
  const resources: ZiacVisualResource[] = [];
  const edges: ZiacVisualEdge[] = [];
  const routes: ZiacVisualRoute[] = [];
  const childArtifacts: ZiacVisualArtifact[] = [];
  const projectIds = new Set<string>();
  for (const [index, rawEntry] of entries.entries()) {
    const entry = objectValue(rawEntry, `projects[${index}]`);
    const id = nonEmptyString(entry.project, `projects[${index}].project`);
    if (projectIds.has(id)) throw new Error(`duplicate workspace project id: ${id}`);
    projectIds.add(id);
    const path = nonEmptyString(entry.path, `projects[${index}].path`);
    const stack = nonEmptyString(entry.stack, `projects[${index}].stack`);
    const stage = nonEmptyString(entry.stage, `projects[${index}].stage`);
    const artifact = parseZiacVisualArtifact(entry.artifact);
    childArtifacts.push(artifact);
    projects.push({ id, path, stack, stage, resources: artifact.resources.length });
    resources.push(...artifact.resources.map((resource) => ({
      ...resource,
      id: namespacedId(id, resource.id),
      project_id: id,
      project_path: path,
      source_id: resource.id,
    })));
    edges.push(...artifact.edges.map((edge) => ({
      ...edge,
      id: namespacedId(id, edge.id),
      from: namespacedId(id, edge.from),
      to: namespacedId(id, edge.to),
    })));
    routes.push(...artifact.routes.map((route) => ({
      ...route,
      id: namespacedId(id, route.id),
      from_resource: namespacedId(id, route.from_resource),
      to_resource: namespacedId(id, route.to_resource),
    })));
  }

  const links = root.links === undefined ? [] : arrayValue(root.links, "links");
  for (const [index, rawLink] of links.entries()) {
    const link = objectValue(rawLink, `links[${index}]`);
    const from = workspaceEndpoint(link.from, `links[${index}].from`, projectIds);
    const to = workspaceEndpoint(link.to, `links[${index}].to`, projectIds);
    edges.push({
      id: `workspace::${nonEmptyString(link.id, `links[${index}].id`)}`,
      from: namespacedId(from.project, from.resource),
      to: namespacedId(to.project, to.resource),
      kind: enumValue(link.kind, `links[${index}].kind`, edgeKinds),
    });
  }

  uniqueIds(resources, "resource");
  uniqueIds(edges, "edge");
  const resourceIds = new Set(resources.map((resource) => resource.id));
  for (const edge of edges) if (!resourceIds.has(edge.from) || !resourceIds.has(edge.to)) {
    throw new Error(`workspace edge ${edge.id} references unknown resource`);
  }
  const regions = unique(childArtifacts.flatMap((artifact) => artifact.regions)).sort();
  const first = childArtifacts[0]!;
  const merged: ZiacVisualArtifact = {
    schema: "ziac.visual.v1",
    format_version: 1,
    truth_mode: childArtifacts.every((artifact) => artifact.truth_mode === first.truth_mode) ? first.truth_mode : "desired",
    created_at_millis: createdAt,
    stack: workspaceId,
    stage: unique(projects.map((project) => project.stage)).length === 1 ? projects[0]!.stage : "mixed",
    graph_digest: first.graph_digest,
    state_serial: Math.max(...childArtifacts.map((artifact) => artifact.state_serial)),
    summary: { resources: resources.length, edges: edges.length, regions: regions.length },
    regions,
    resources,
    edges,
    routes,
    observations: childArtifacts.flatMap((artifact) => artifact.observations),
    diagnostics: childArtifacts.flatMap((artifact) => artifact.diagnostics),
  };
  const model = deriveZiacVisualModel(merged);
  return { ...model, workspace: { id: workspaceId, created_at_millis: createdAt }, projects };
}

export function filterZiacVisualModel(model: ZiacVisualModel, filters: ZiacVisualFilters): FilteredZiacVisualModel {
  const query = filters.text.trim().toLowerCase();
  const selectedProjects = filters.projects === undefined ? null : new Set(filters.projects);
  const projectResourceIds = selectedProjects === null
    ? new Set(model.resources.map((resource) => resource.id))
    : new Set(model.resources.filter((resource) => resource.project_id && selectedProjects.has(resource.project_id)).map((resource) => resource.id));
  expandProjectSlice(projectResourceIds, model.edges, filters.projectScope ?? "selected");
  const resources = model.resources.filter((resource) => {
    if (!projectResourceIds.has(resource.id)) return false;
    if (filters.estate === "managed" && resource.ownership !== "managed") return false;
    if (filters.estate === "existing" && resource.ownership === "managed") return false;
    if (filters.provider !== "all" && resource.provider !== filters.provider) return false;
    if (filters.region !== "all" && resource.scope !== "global" && !resource.regions.includes(filters.region)) return false;
    if (filters.operation !== "all" && resource.operation !== filters.operation) return false;
    if (filters.health !== "all" && resource.health !== filters.health) return false;
    if (!query) return true;
    return [resource.id, resource.type, resource.logical_id, resource.provider, resource.region ?? "", ...resource.reasons]
      .some((value) => value.toLowerCase().includes(query));
  });
  const resourceIds = new Set(resources.map((resource) => resource.id));
  return {
    ...model,
    resources,
    edges: model.edges.filter((edge) => resourceIds.has(edge.from) && resourceIds.has(edge.to)),
    routes: model.routes.filter((route) => resourceIds.has(route.from_resource) && resourceIds.has(route.to_resource)),
    regionNodes: model.regionNodes.map((node) => ({
      ...node,
      resources: node.resources.filter((resource) => resourceIds.has(resource.id)),
    })).filter((node) => node.resources.length > 0),
    resourceIds,
  };
}

function expandProjectSlice(resourceIds: Set<string>, edges: ZiacVisualEdge[], scope: ZiacProjectScope): void {
  if (scope === "selected") return;
  let changed = true;
  while (changed) {
    changed = false;
    for (const edge of edges) {
      if (resourceIds.has(edge.from) && !resourceIds.has(edge.to)) {
        resourceIds.add(edge.to);
        changed = true;
      }
      if (scope === "connected" && resourceIds.has(edge.to) && !resourceIds.has(edge.from)) {
        resourceIds.add(edge.from);
        changed = true;
      }
    }
  }
}

function namespacedId(project: string, id: string): string {
  return `${project}::${id}`;
}

function workspaceEndpoint(raw: unknown, path: string, projects: Set<string>): { project: string; resource: string } {
  const value = objectValue(raw, path);
  const project = nonEmptyString(value.project, `${path}.project`);
  if (!projects.has(project)) throw new Error(`${path}.project references unknown project`);
  return { project, resource: nonEmptyString(value.resource, `${path}.resource`) };
}

function parseResource(raw: unknown, index: number): ZiacVisualResource {
  const value = objectValue(raw, `resources[${index}]`);
  const inputs = objectValue(value.inputs, `resources[${index}].inputs`);
  assertRedacted(inputs, `resources[${index}].inputs`);
  const lifecycle = objectValue(value.lifecycle, `resources[${index}].lifecycle`);
  const region = value.region === undefined ? undefined : nonEmptyString(value.region, `resources[${index}].region`);
  const ownership = value.ownership === undefined
    ? "managed"
    : enumValue(value.ownership, `resources[${index}].ownership`, ownershipStates);
  const discovery = value.discovery === undefined
    ? undefined
    : parseDiscovery(value.discovery, index);
  const cost = value.cost === undefined ? undefined : parseCost(value.cost, index);
  const iam = value.iam === undefined ? undefined : parseIam(value.iam, index);
  const dataEngineering = value.data_engineering === undefined ? undefined : parseDataEngineering(value.data_engineering, index);
  if (ownership !== "managed" && discovery === undefined) {
    throw new Error(`resources[${index}].discovery is required for ${ownership} resources`);
  }
  return {
    id: nonEmptyString(value.id, `resources[${index}].id`),
    provider: enumValue(value.provider, `resources[${index}].provider`, providers),
    type: nonEmptyString(value.type, `resources[${index}].type`),
    logical_id: nonEmptyString(value.logical_id, `resources[${index}].logical_id`),
    scope: enumValue(value.scope, `resources[${index}].scope`, scopes),
    ...(region ? { region } : {}),
    regions: stringArray(value.regions, `resources[${index}].regions`),
    operation: enumValue(value.operation, `resources[${index}].operation`, operations),
    health: enumValue(value.health, `resources[${index}].health`, healthStates),
    ownership,
    ...(discovery ? { discovery } : {}),
    ...(cost ? { cost } : {}),
    ...(iam ? { iam } : {}),
    ...(dataEngineering ? { data_engineering: dataEngineering } : {}),
    inputs,
    lifecycle: {
      protect: booleanValue(lifecycle.protect, "lifecycle.protect"),
      retain_on_delete: booleanValue(lifecycle.retain_on_delete, "lifecycle.retain_on_delete"),
      replace_before_delete: booleanValue(lifecycle.replace_before_delete, "lifecycle.replace_before_delete"),
    },
    reasons: stringArray(value.reasons, `resources[${index}].reasons`),
  };
}

function parseIam(raw: unknown, index: number): ZiacIamDetails {
  const path = `resources[${index}].iam`;
  const value = objectValue(raw, path);
  const role = value.role === undefined ? undefined : nonEmptyString(value.role, `${path}.role`);
  const conditionTitle = value.condition_title === undefined
    ? undefined
    : nonEmptyString(value.condition_title, `${path}.condition_title`);
  const principalCount = integerValue(value.principal_count, `${path}.principal_count`);
  if (principalCount < 0 || principalCount > 100_000) throw new Error(`${path}.principal_count is out of bounds`);
  return {
    ownership: enumValue(value.ownership, `${path}.ownership`, ["member", "binding", "policy"]),
    target: nonEmptyString(value.target, `${path}.target`),
    ...(role ? { role } : {}),
    ...(conditionTitle ? { condition_title: conditionTitle } : {}),
    principal_count: principalCount,
  };
}

function parseCost(raw: unknown, index: number): ZiacResourceCost {
  const path = `resources[${index}].cost`;
  const value = objectValue(raw, path);
  const currency = nonEmptyString(value.currency, `${path}.currency`);
  if (!/^[A-Z]{3}$/.test(currency)) throw new Error(`${path}.currency must be ISO 4217`);
  const amount = value.amount_micros === null ? null : integerValue(value.amount_micros, `${path}.amount_micros`);
  const origin = enumValue(value.origin, `${path}.origin`, ["configuration_estimate", "projected_month_end", "actual_billed"]);
  const billingExport = booleanValue(value.is_billing_export, `${path}.is_billing_export`);
  const basis = value.basis === undefined
    ? undefined
    : enumValue(value.basis, `${path}.basis`, ["usage_assumptions_required", "documented_no_charge", "service_no_charge"]);
  if ((origin === "actual_billed" || origin === "projected_month_end") && !billingExport) throw new Error(`${path} actual cost requires billing export provenance`);
  return {
    schema: enumValue(value.schema, `${path}.schema`, ["ziac.resource-cost.v1"]),
    origin,
    currency,
    amount_micros: amount,
    confidence: enumValue(value.confidence, `${path}.confidence`, ["unavailable", "explicit_usage", "billing_partial_month", "billing_complete"]),
    ...(basis ? { basis } : {}),
    observed_at_millis: integerValue(value.observed_at_millis, `${path}.observed_at_millis`),
    is_billing_export: billingExport,
  };
}

function parseDataEngineering(raw: unknown, index: number): ZiacDataEngineeringDetails {
  const path = `resources[${index}].data_engineering`;
  const value = objectValue(raw, path);
  assertRedacted(value, path);
  return {
    ...value,
    kind: enumValue(value.kind, `${path}.kind`, ["dataflow_pipeline", "dataproc_cluster", "dataproc_autoscaling_policy", "dataproc_workflow_template", "dataform_repository", "dataform_workspace", "dataform_release_config", "dataform_workflow_config", "data_engineering_iam"]),
  };
}

function parseDiscovery(raw: unknown, index: number): ZiacResourceDiscovery {
  const path = `resources[${index}].discovery`;
  const value = objectValue(raw, path);
  assertRedacted(value, path);
  const allowed = new Set(["provider", "project_id", "observed_at_millis", "source_name"]);
  const unknown = Object.keys(value).find((key) => !allowed.has(key));
  if (unknown) throw new Error(`${path}.${unknown} is not supported`);
  return {
    provider: enumValue(value.provider, `${path}.provider`, ["cloud_asset_inventory"]),
    project_id: nonEmptyString(value.project_id, `${path}.project_id`),
    observed_at_millis: integerValue(value.observed_at_millis, `${path}.observed_at_millis`),
    source_name: nonEmptyString(value.source_name, `${path}.source_name`),
  };
}

function parseEdge(raw: unknown, index: number): ZiacVisualEdge {
  const value = objectValue(raw, `edges[${index}]`);
  const access = value.access === undefined
    ? undefined
    : enumValue(value.access, `edges[${index}].access`, accessModes);
  const permissions = value.permissions === undefined
    ? undefined
    : stringArray(value.permissions, `edges[${index}].permissions`).sort();
  if (permissions && permissions.length > 32) throw new Error(`edges[${index}].permissions exceeds 32 entries`);
  return {
    id: nonEmptyString(value.id, `edges[${index}].id`),
    from: nonEmptyString(value.from, `edges[${index}].from`),
    to: nonEmptyString(value.to, `edges[${index}].to`),
    kind: enumValue(value.kind, `edges[${index}].kind`, edgeKinds),
    ...(access ? { access } : {}),
    ...(permissions ? { permissions } : {}),
  };
}

function parseRoute(raw: unknown, index: number): ZiacVisualRoute {
  const value = objectValue(raw, `routes[${index}]`);
  return {
    id: nonEmptyString(value.id, `routes[${index}].id`),
    from_resource: nonEmptyString(value.from_resource, `routes[${index}].from_resource`),
    to_resource: nonEmptyString(value.to_resource, `routes[${index}].to_resource`),
    to_region: nonEmptyString(value.to_region, `routes[${index}].to_region`),
    provenance: enumValue(value.provenance, `routes[${index}].provenance`, routeProvenance),
  };
}

function aggregateHealth(resources: ZiacVisualResource[]): ZiacHealth {
  if (resources.some((resource) => resource.health === "unhealthy")) return "unhealthy";
  if (resources.some((resource) => resource.health === "degraded")) return "degraded";
  if (resources.some((resource) => resource.health === "reconciling")) return "reconciling";
  if (resources.length > 0 && resources.every((resource) => resource.health === "healthy")) return "healthy";
  return "unknown";
}

function assertRedacted(value: unknown, path: string): void {
  if (Array.isArray(value)) {
    value.forEach((entry, index) => assertRedacted(entry, `${path}[${index}]`));
    return;
  }
  if (!isRecord(value)) return;
  for (const [key, entry] of Object.entries(value)) {
    if (key === "$secret") {
      if (entry !== "redacted") throw new Error(`${path} contains an unredacted secret reference`);
      continue;
    }
    if (isSecretLikeKey(key) && !(isRecord(entry) && entry.$secret === "redacted")) {
      throw new Error(`${path}.${key} is an unredacted secret-like field`);
    }
    assertRedacted(entry, `${path}.${key}`);
  }
}

function isSecretLikeKey(key: string): boolean {
  return ["secret", "password", "token", "credential", "private_key", "database_url", "connection_string"]
    .some((needle) => key.toLowerCase().includes(needle));
}

function uniqueIds<T extends { id: string }>(values: T[], label: string): Set<string> {
  const ids = new Set<string>();
  for (const value of values) {
    if (ids.has(value.id)) throw new Error(`duplicate ${label} id: ${value.id}`);
    ids.add(value.id);
  }
  return ids;
}

function unique<T>(values: T[]): T[] {
  return [...new Set(values)];
}

function objectValue(value: unknown, path: string): Record<string, unknown> {
  if (!isRecord(value)) throw new Error(`${path} must be an object`);
  return value;
}

function arrayValue(value: unknown, path: string): unknown[] {
  if (!Array.isArray(value)) throw new Error(`${path} must be an array`);
  return value;
}

function stringArray(value: unknown, path: string): string[] {
  return arrayValue(value, path).map((entry, index) => nonEmptyString(entry, `${path}[${index}]`));
}

function stringValue(value: unknown, path: string): string {
  if (typeof value !== "string") throw new Error(`${path} must be a string`);
  return value;
}

function nonEmptyString(value: unknown, path: string): string {
  const result = stringValue(value, path);
  if (!result) throw new Error(`${path} must not be empty`);
  return result;
}

function integerValue(value: unknown, path: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) throw new Error(`${path} must be a non-negative integer`);
  return value;
}

function booleanValue(value: unknown, path: string): boolean {
  if (typeof value !== "boolean") throw new Error(`${path} must be a boolean`);
  return value;
}

function digestValue(value: unknown): string {
  const digest = stringValue(value, "graph_digest");
  if (!/^[a-f0-9]{64}$/.test(digest)) throw new Error("graph_digest must be a lowercase SHA-256 digest");
  return digest;
}

function enumValue<const T extends string>(value: unknown, path: string, allowed: readonly T[]): T {
  const result = stringValue(value, path);
  if (!allowed.includes(result as T)) throw new Error(`${path} has unsupported value ${result}`);
  return result as T;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
