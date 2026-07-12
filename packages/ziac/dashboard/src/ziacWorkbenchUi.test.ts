// Standalone Ziac dashboard UI structure coverage.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const source = () => readFileSync(new URL("./ZiacWorkbench.tsx", import.meta.url), "utf8");
const styles = () => readFileSync(new URL("./styles.css", import.meta.url), "utf8");

test("Ziac Workbench exposes compact synchronized infrastructure controls", () => {
  const value = source();

  expect(value).toContain('aria-label="Ziac infrastructure view"');
  expect(value).toContain('aria-label="Search infrastructure"');
  expect(value).toContain("Canvas");
  expect(value).toContain("Global Map");
  expect(value).toContain("Operations");
  expect(value).toContain("Architecture");
  expect(value).toContain("Network");
  expect(value).toContain("VPC");
  expect(value).toContain("Dependencies");
  expect(value).toContain("Deploy plan");
  expect(value).toContain("selectedResourceId");
  expect(value).toContain("sceneResourceIds");
  expect(value).toContain('aria-label={props.label}');
  expect(value).toContain('aria-label="Estate scope"');
  expect(value).toContain('label="Ziac"');
  expect(value).toContain('label="Existing"');
  expect(value).toContain('label="Combined"');
  expect(value).toContain("estateAccessState");
  expect(value).toContain("when={estateGateOpen()}");
  expect(value).toContain("Google connected");
  expect(value).toContain("Pro");
  expect(value).toContain("Connect through the desktop Ziac host");
  expect(value).toContain("onEstateRefresh");
  expect(value).toContain('aria-label="Filter workspace projects"');
  expect(value).toContain("Selected only");
  expect(value).toContain("With dependencies");
  expect(value).toContain("Dependencies and consumers");
  expect(value).toContain("selectedProjectIds");
  expect(value).not.toContain("scanTimer");
});

test("Ziac operations view exposes agent state causal logs and completeness", () => {
  const value = source();

  expect(value).toContain("OperationsPanel");
  expect(value).toContain('aria-label="Agent operations"');
  expect(value).toContain("Causal timeline");
  expect(value).toContain("Evidence completeness");
  expect(value).toContain("Inspect resource");
  expect(value).toContain("ziac-agent-command-strip");
  expect(value).toContain("ziac-agent-primary");
  expect(value).toContain("ziac-agent-next");
  expect(value).toContain("ziac-evidence-inline");
  expect(value).toContain("ziac-log-toolbar");
  expect(value).toContain('aria-label="Inspect related resource"');
  expect(value).toContain("loadLiveLogSnapshot");
  expect(value).toContain("setLiveSession");
  expect(value).toContain("onMount");
});

test("Ziac topology includes Three scene inspector and accessible resource navigation", () => {
  const value = source();

  expect(value).toContain("ResourceInspector");
  expect(value).toContain("ZiacTopologyScene");
  expect(value).not.toContain("ZiacTopologyCanvas");
  expect(value).toContain('aria-label="Infrastructure resources"');
  expect(value).toContain("Overview");
  expect(value).toContain("Traffic");
  expect(value).toContain("Revisions");
  expect(value).toContain("YAML");
  expect(value).toContain("Dependencies");
  expect(value).toContain("Lifecycle");
  expect(value).toContain("Ownership");
  expect(value).toContain("Discovery source");
  expect(value).toContain("Read-only observation");
});

test("Ziac dashboard exposes deployment logs and agent dock tabs", () => {
  const value = source();

  expect(value).toContain('aria-label="Operational dock"');
  expect(value).toContain("Deployments");
  expect(value).toContain("Live logs");
  expect(value).toContain("Agent runs");
  expect(value).toContain("DeploymentDock");
  expect(value).toContain("ziac-dock-stepper");
  expect(value).toContain("ziac-dock-run-state");
});

test("Ziac workspace has dedicated responsive canvas and operational styles", () => {
  const value = styles();

  expect(value).toContain(".ziac-workspace");
  expect(value).toContain(".ziac-scene-shell");
  expect(value).toContain(".ziac-icon-rail");
  expect(value).toContain(".ziac-resource-navigator");
  expect(value).toContain(".ziac-operation-dock");
  expect(value).toContain(".ziac-resource-inspector");
  expect(value).toContain(".ziac-operation-create");
  expect(value).toContain(".ziac-operations");
  expect(value).toContain("--ziac-global-height: 40px");
  expect(value).toContain("--ziac-context-height: 34px");
  expect(value).toContain("--ziac-rail-width: 38px");
  expect(value).toContain("--ziac-dock-height: 108px");
  expect(value).toContain(".ziac-agent-command-strip");
  expect(value).toContain(".ziac-log-toolbar");
  expect(value).toContain(".ziac-dock-stepper");
  expect(value).toContain(".ziac-estate-switch");
  expect(value).toContain(".ziac-estate-access");
  expect(value).toContain(".ziac-project-filter-menu");
  expect(value).toContain(".ziac-project-options");
  expect(value).toContain(".ziac-log-inspect {\n  grid-column: 4;");
  expect(value).toContain("@media (max-width: 760px)");
});
