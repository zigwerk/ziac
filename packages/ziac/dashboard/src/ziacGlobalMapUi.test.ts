// Standalone Ziac dashboard UI coverage.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const source = () => readFileSync(new URL("./ziacGlobalMap.tsx", import.meta.url), "utf8");

test("global map uses MapLibre with deck.gl operational layers", () => {
  const value = source();

  expect(value).toContain("maplibre-gl");
  expect(value).toContain("MapboxOverlay");
  expect(value).toContain("ArcLayer");
  expect(value).toContain("ScatterplotLayer");
  expect(value).toContain("TextLayer");
});

test("global map uses a monochrome basemap and neutral inactive topology", () => {
  const value = source();

  expect(value).toContain("positron-gl-style");
  expect(value).toContain("MONOCHROME_ROUTE");
  expect(value).toContain("MONOCHROME_MARKER");
  expect(value).not.toContain("demotiles.maplibre.org/style.json");
});

test("global map exposes route provenance front door and accessible region table", () => {
  const value = source();

  expect(value).toContain('aria-label="Global deployment map"');
  expect(value).toContain("provenance");
  expect(value).toContain("Global front door");
  expect(value).toContain('aria-label="Global deployment regions"');
  expect(value).toContain("unmappedRegions");
});
