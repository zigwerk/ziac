import { describe, expect, test } from "bun:test";
import { heroResources, heroRoutes, heroSlabs } from "./heroTopologyModel";

describe("landing hero topology", () => {
  test("uses stable unique identifiers", () => {
    const ids = [
      ...heroSlabs.map((slab) => slab.id),
      ...heroResources.map((resource) => resource.id),
      ...heroRoutes.map((route) => route.id),
    ];

    expect(new Set(ids).size).toBe(ids.length);
  });

  test("keeps every resource on a declared slab", () => {
    const slabIds = new Set(heroSlabs.map((slab) => slab.id));

    for (const resource of heroResources) {
      expect(slabIds.has(resource.slabId)).toBe(true);
    }
  });

  test("connects only declared resources", () => {
    const resourceIds = new Set(heroResources.map((resource) => resource.id));

    for (const route of heroRoutes) {
      expect(resourceIds.has(route.from)).toBe(true);
      expect(resourceIds.has(route.to)).toBe(true);
      expect(route.points.length).toBeGreaterThanOrEqual(3);
    }
  });

  test("stays inside the orthographic hero bounds", () => {
    for (const slab of heroSlabs) {
      expect(Math.abs(slab.position[0]) + slab.size[0] / 2).toBeLessThanOrEqual(9);
      expect(Math.abs(slab.position[2]) + slab.size[1] / 2).toBeLessThanOrEqual(8);
    }
  });
});
