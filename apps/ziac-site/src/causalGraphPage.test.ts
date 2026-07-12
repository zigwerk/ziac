import { describe, expect, test } from "bun:test";

async function source(relativePath: string): Promise<string> {
  const file = Bun.file(new URL(relativePath, import.meta.url));
  return (await file.exists()) ? file.text() : "";
}

const productSource = await source("./ProductLanding.tsx");
const effectSource = await source("./WhyZigEffect.tsx");
const causalSource = await source("./CausalGraph.tsx");
const routeSource = await source("./routes/causal-graph.tsx");
const appConfig = await source("../app.config.ts");
const sitemap = await source("../public/sitemap.xml");

describe("Ziac causal graph explainer", () => {
  test("turns the homepage causal proof claim into a real route", () => {
    expect(productSource).toContain('href="/causal-graph"');
    expect(productSource).toContain("causal proof");
    expect(effectSource).toContain('href="/causal-graph"');
  });

  test("connects runtime and infrastructure evidence through one deployment lineage", () => {
    expect(causalSource).toContain("Causal proof, not agent confidence.");
    expect(causalSource).toContain("Two graphs. One lineage.");
    expect(causalSource).toContain("ZigEffect runtime graph");
    expect(causalSource).toContain("Ziac infrastructure graph");

    for (const stage of [
      "Objective",
      "Requirement",
      "Agent proposal",
      "Comptime proof",
      "Saved plan",
      "Provider RPC",
      "Cloud Run revision",
      "Traffic and health",
      "Verified handoff",
    ]) {
      expect(causalSource).toContain(stage);
    }
  });

  test("shows how agents query, repair, replay, and verify", () => {
    expect(causalSource).toContain("graph cause");
    expect(causalSource).toContain("graph children");
    expect(causalSource).toContain("semantic diff");
    expect(causalSource).toContain("counterfactual");
    expect(causalSource).toContain("exact replay");
    expect(causalSource).toContain("requirement-linked assertions");
    expect(causalSource).toContain("plan digest");
  });

  test("uses real product evidence and states proof limits", () => {
    expect(causalSource).toContain('/ziac-operations.png');
    expect(causalSource).toContain("dropped, sampled, or truncated");
    expect(causalSource).toContain("cannot become a pass");
    expect(causalSource).toContain("redacted");
  });

  test("publishes independent metadata and prerendered discovery", () => {
    expect(routeSource).toContain("Causal graph and agent verification - Ziac");
    expect(routeSource).toContain("TechArticle");
    expect(routeSource).toContain("<Title>");
    expect(routeSource).toContain('name="description"');
    expect(routeSource).toContain('rel="canonical"');
    expect(routeSource).toContain('property="og:title"');
    expect(routeSource).toContain('name="twitter:card"');
    expect(appConfig).toContain('"/causal-graph"');
    expect(sitemap).toContain("https://ziac.dev/causal-graph");
  });
});
