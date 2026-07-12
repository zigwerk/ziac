// Standalone Ziac dashboard model coverage.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { deriveZiacGlobalMapModel } from "./ziacGlobalMapModel";
import { deriveZiacVisualModel, filterZiacVisualModel, parseZiacVisualArtifact } from "./ziacVisualArtifact";

function filteredModel() {
  const raw = JSON.parse(readFileSync(new URL("../public/sample-ziac-global.json", import.meta.url), "utf8"));
  return filterZiacVisualModel(deriveZiacVisualModel(parseZiacVisualArtifact(raw)), {
    text: "", provider: "all", region: "all", operation: "all", health: "all",
  });
}

test("global map model plots regional deployments without inventing a front-door coordinate", () => {
  const model = deriveZiacGlobalMapModel(filteredModel(), null);

  expect(model.frontDoor?.id).toEndWith("api-https");
  expect(model.regionMarkers).toHaveLength(3);
  expect(model.routes).toHaveLength(3);
  expect(model.routes.every((route) => route.provenance === "inferred")).toBe(true);
  expect(model.routes.every((route) => route.sourcePosition[0] !== route.targetPosition[0])).toBe(true);
  expect(model.regionMarkers.some((marker) => marker.id === model.frontDoor?.id)).toBe(false);
});

test("global map model selects a regional service and keeps provider locality visible", () => {
  const selectedId = "gcp.run.Service.europe-west1.api";
  const model = deriveZiacGlobalMapModel(filteredModel(), selectedId);
  const europe = model.regionMarkers.find((marker) => marker.region === "europe-west1");

  expect(europe?.selected).toBe(true);
  expect(europe?.cloudRunResources).toContain(selectedId);
  expect(europe?.cockroachResources).toContain("cockroach.Cluster.global-data");
  expect(europe?.resourceCount).toBeGreaterThan(2);
});

test("global map model retains unknown regions as unmapped evidence", () => {
  const model = filteredModel();
  model.regionNodes.push({ id: "moon-west1", location: null, resources: [], operations: [], health: "unknown" });
  const map = deriveZiacGlobalMapModel(model, null);

  expect(map.unmappedRegions).toEqual(["moon-west1"]);
  expect(map.regionMarkers.some((marker) => marker.region === "moon-west1")).toBe(false);
});
