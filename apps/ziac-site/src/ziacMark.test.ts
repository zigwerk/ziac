import { describe, expect, test } from "bun:test";
import { orientationStep } from "./ZiacMark";

describe("Ziac animated mark", () => {
  test("keeps every frame inside the declared orientation set", () => {
    for (const elapsed of [-20, -1, 0, 1, 3199, 3200, 25600, 999999]) {
      const step = orientationStep(elapsed);
      expect(step.from).toBeGreaterThanOrEqual(0);
      expect(step.from).toBeLessThan(4);
      expect(step.to).toBeGreaterThanOrEqual(0);
      expect(step.to).toBeLessThan(4);
      expect(step.progress).toBeGreaterThanOrEqual(0);
      expect(step.progress).toBeLessThanOrEqual(1);
    }
  });
});
