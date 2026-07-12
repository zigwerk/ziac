import { describe, expect, test } from "bun:test";

async function source(relativePath: string): Promise<string> {
  const file = Bun.file(new URL(relativePath, import.meta.url));
  return (await file.exists()) ? file.text() : "";
}

const pageSource = await source("./HowItWorks.tsx");
const routeSource = await source("./routes/how-it-works.tsx");
const configSource = await source("../app.config.ts");
const sitemapSource = await source("../public/sitemap.xml");
const landingSource = await source("./ProductLanding.tsx");
const chromeSource = await source("./MarketingChrome.tsx");

describe("Ziac how-it-works journey", () => {
  test("starts with an honest private-beta scaffold flow", () => {
    expect(pageSource).toContain("Private beta CLI flow");
    expect(pageSource).toContain("ziac init global-api --template gcp-global");
    expect(pageSource).toContain("ziac.project.json");
    expect(pageSource).toContain("GCP, Ziac, and Zig skills");
  });

  test("supports any major agent harness through one kernel", () => {
    expect(pageSource).toContain("Codex");
    expect(pageSource).toContain("Claude Code");
    expect(pageSource).toContain("Gemini CLI");
    expect(pageSource).toContain('role="tablist"');
    expect(pageSource).toContain("One kernel. Any harness.");
  });

  test("explains visual control, global provisioning, and agentic debugging", () => {
    expect(pageSource).toContain("Agents build. Humans verify.");
    expect(pageSource).toContain("ziac dev --watch");
    expect(pageSource).toContain("Premium global load balancer");
    expect(pageSource).toContain("nearest healthy region");
    expect(pageSource).toContain("automatic diagnosis");
    expect(pageSource).toContain("/ziac-operations.png");
    expect(pageSource).toContain("<HeroTopology");
  });

  test("keeps existing, managed, referenced, and third-party infrastructure distinct", () => {
    expect(pageSource).toContain("Observed GCP");
    expect(pageSource).toContain("Managed by Ziac");
    expect(pageSource).toContain("Referenced, not owned");
    expect(pageSource).toContain("Third-party account groups");
    expect(pageSource).toContain("SaaS isn't dead. It evolved.");
  });

  test("is prerendered, discoverable, and linked from the product page", () => {
    expect(routeSource).toContain("How Ziac works");
    expect(routeSource).toContain('rel="canonical"');
    expect(routeSource).toContain("application/ld+json");
    expect(configSource).toContain('"/how-it-works"');
    expect(sitemapSource).toContain("<loc>https://ziac.dev/how-it-works</loc>");
    expect(landingSource).toContain("MarketingHeader");
    expect(chromeSource).toContain('label: "How it works", href: "/how-it-works"');
  });
});
