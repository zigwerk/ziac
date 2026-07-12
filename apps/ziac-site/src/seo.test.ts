import { describe, expect, test } from "bun:test";

async function source(relativePath: string): Promise<string> {
  const file = Bun.file(new URL(relativePath, import.meta.url));
  return (await file.exists()) ? file.text() : "";
}

const appConfig = await source("../app.config.ts");
const packageSource = await source("../package.json");
const appRoot = await source("./app.tsx");
const routeSource = await source("./routes/index.tsx");
const robotsSource = await source("../public/robots.txt");
const sitemapSource = await source("../public/sitemap.xml");

describe("Ziac marketing SEO contract", () => {
  test("uses SolidStart SSR with a prerendered marketing route", () => {
    expect(appConfig).toContain('from "@solidjs/start/config"');
    for (const route of ["/", "/how-it-works", "/why-zig", "/why-zigeffect", "/causal-graph", "/case-studies/yachdee-court-series"]) {
      expect(appConfig).toContain(`"${route}"`);
    }
    expect(appConfig).toContain('conditions: ["solid"]');
    expect(appConfig).toContain('noExternal: ["lucide-solid"]');
    expect(appRoot).toContain("<FileRoutes");
    expect(appRoot).toContain("<MetaProvider");
    expect(routeSource).toContain('from "../ProductLanding"');
    expect(packageSource).toContain('"build": "vinxi build"');
    expect(packageSource).toContain('"preview": "serve .output/public -l 4320"');
  });

  test("ships route-owned search and social metadata", () => {
    expect(routeSource).toContain("<Title>");
    expect(routeSource).toContain('name="description"');
    expect(routeSource).toContain('rel="canonical"');
    expect(routeSource).toContain('property="og:title"');
    expect(routeSource).toContain('name="twitter:card"');
    expect(routeSource).toContain("application/ld+json");
  });

  test("publishes explicit crawler discovery files", () => {
    expect(robotsSource).toContain("User-agent: *");
    expect(robotsSource).toContain("Sitemap: https://ziac.dev/sitemap.xml");
    expect(sitemapSource).toContain("<loc>https://ziac.dev/</loc>");
  });
});
