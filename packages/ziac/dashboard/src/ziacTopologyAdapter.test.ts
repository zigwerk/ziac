// Standalone Ziac dashboard topology adapter coverage.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { ziacTopologyData, ziacTopologyLayout } from "./ziacTopologyModel";
import { deriveZiacVisualModel, filterZiacVisualModel, parseZiacVisualArtifact } from "./ziacVisualArtifact";

const model = () => {
  const raw = JSON.parse(readFileSync(new URL("../public/sample-ziac-global.json", import.meta.url), "utf8"));
  return filterZiacVisualModel(deriveZiacVisualModel(parseZiacVisualArtifact(raw)), {
    text: "",
    provider: "all",
    region: "all",
    operation: "all",
    health: "all",
  });
};

test("ziac topology adapter maps resources into stable geographic groups", () => {
  const data = ziacTopologyData(model(), null);

  expect(data.nodes).toHaveLength(17);
  expect(data.edges).toHaveLength(20);
  expect(data.combos?.map((combo) => combo.id)).toEqual([
    "group:global",
    "group:multi-region",
    "group:project",
    "region:asia-northeast1",
    "region:europe-west1",
    "region:us-central1",
  ]);
  expect(data.nodes.find((node) => node.id === "gcp.run.Service.europe-west1.api")?.combo).toBe("region:europe-west1");
  expect(data.nodes.find((node) => node.id === "cockroach.Cluster.global-data")?.combo).toBe("group:multi-region");
});

test("ziac topology adapter exposes provider operation health and edge semantics", () => {
  const data = ziacTopologyData(model(), "cockroach.Cluster.global-data");
  const selected = data.nodes.find((node) => node.id === "cockroach.Cluster.global-data");
  const traffic = data.edges.find((edge) => edge.data?.kind === "traffic");
  const output = data.edges.find((edge) => edge.data?.kind === "output");

  expect(selected?.data).toMatchObject({ provider: "cockroach", operation: "create", health: "unknown" });
  expect(selected?.states).toContain("selected");
  expect(selected?.style?.lineWidth).toBe(3);
  expect(traffic?.style?.stroke).not.toBe(output?.style?.stroke);
  expect(traffic?.style?.endArrow).toBe(true);
});

test("ziac topology uses a deterministic left-to-right infrastructure layout", () => {
  expect(ziacTopologyLayout()).toMatchObject({ type: "dagre", rankdir: "LR" });
});
