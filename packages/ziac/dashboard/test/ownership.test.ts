import { expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

const dashboardRoot = resolve(import.meta.dir, "..");
const repositoryRoot = resolve(dashboardRoot, "../../..");

function read(relativePath: string): string {
  return readFileSync(resolve(dashboardRoot, relativePath), "utf8");
}

test("Ziac owns a standalone dashboard entry point and stylesheet", () => {
  expect(existsSync(resolve(dashboardRoot, "index.html"))).toBe(true);
  expect(existsSync(resolve(dashboardRoot, "vite.config.ts"))).toBe(true);
  expect(existsSync(resolve(dashboardRoot, "src/main.tsx"))).toBe(true);
  expect(existsSync(resolve(dashboardRoot, "src/styles.css"))).toBe(true);

  const entry = read("src/main.tsx");
  expect(entry).toContain('import "./styles.css"');
  expect(entry).not.toContain("zigeffect/workbench");

  const styles = read("src/styles.css");
  expect(styles).toContain("#root");
  expect(styles).toContain(".ziac-workspace");
  expect(styles).toContain("display: grid");
});

test("ZigEffect Workbench has no Ziac dashboard routes or source imports", () => {
  const workbenchRoot = resolve(repositoryRoot, "packages/zigeffect/workbench");
  const app = readFileSync(resolve(workbenchRoot, "src/App.tsx"), "utf8");
  const bridge = readFileSync(resolve(workbenchRoot, "src/workbenchBridge.ts"), "utf8");

  expect(app).not.toContain("ZiacWorkbench");
  expect(app).not.toContain("parseZiacVisualArtifact");
  expect(bridge).not.toContain("sample-ziac");
  expect(bridge).not.toContain("ziac_scan_estate");
});

test("the two dashboard source trees do not import one another", () => {
  const ziacSources = [
    "src/main.tsx",
    "src/App.tsx",
    "src/ZiacWorkbench.tsx",
    "src/bridge.ts",
  ].map(read).join("\n");
  expect(ziacSources).not.toContain("packages/zigeffect");
  expect(ziacSources).not.toContain("zigeffect/workbench");
});

