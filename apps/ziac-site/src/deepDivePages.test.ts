import { describe, expect, test } from "bun:test";

async function source(relativePath: string): Promise<string> {
  const file = Bun.file(new URL(relativePath, import.meta.url));
  return (await file.exists()) ? file.text() : "";
}

const chromeSource = await source("./MarketingChrome.tsx");
const productSource = await source("./ProductLanding.tsx");
const howSource = await source("./HowItWorks.tsx");
const zigSource = await source("./WhyZig.tsx");
const effectSource = await source("./WhyZigEffect.tsx");
const zigRoute = await source("./routes/why-zig.tsx");
const effectRoute = await source("./routes/why-zigeffect.tsx");
const appConfig = await source("../app.config.ts");
const sitemap = await source("../public/sitemap.xml");

describe("Ziac technical deep-dive pages", () => {
  test("uses one multi-page navigation contract", () => {
    expect(chromeSource).toContain('href="/"');
    expect(chromeSource).toContain('href: "/how-it-works"');
    expect(chromeSource).toContain('href: "/why-zig"');
    expect(chromeSource).toContain('href: "/why-zigeffect"');
    expect(chromeSource).toContain('href: "/#operations"');
    expect(productSource).toContain("MarketingHeader");
    expect(howSource).toContain("MarketingHeader");
  });

  test("makes the case for Zig without unsupported promises", () => {
    expect(zigSource).toContain("Agents can write more software.");
    expect(zigSource).toContain("The runtime should waste less.");
    expect(zigSource).toContain("Explicit allocation");
    expect(zigSource).toContain("Inspectable control flow");
    expect(zigSource).toContain("Cross-compilation");
    expect(zigSource).toContain("comptime");
    expect(zigSource).toContain("App.Env");
    expect(zigSource).toContain("global Cloud Run");
    expect(zigSource).toContain("HeroTopology");
    expect(zigSource).not.toContain("memory safe");
    expect(zigSource).not.toContain("fastest language");
  });

  test("explains the real ZigEffect execution model for agents", () => {
    expect(effectSource).toContain("Software agents need a runtime");
    expect(effectSource).toContain("they can interrogate.");
    expect(effectSource).toContain("Typed effects");
    expect(effectSource).toContain("scoped resources");
    expect(effectSource).toContain("causal event graph");
    expect(effectSource).toContain("Typed statecharts");
    expect(effectSource).toContain("VirtualWorld");
    expect(effectSource).toContain("AssertionRecorder");
    expect(effectSource).toContain("provider-neutral handoff");
    expect(effectSource).toContain("dropped, sampled, or truncated");
    expect(effectSource).toContain('/ziac-operations.png');
  });

  test("gives both routes independent search metadata", () => {
    for (const route of [zigRoute, effectRoute]) {
      expect(route).toContain("<Title>");
      expect(route).toContain('name="description"');
      expect(route).toContain('rel="canonical"');
      expect(route).toContain('property="og:title"');
      expect(route).toContain('name="twitter:card"');
      expect(route).toContain("application/ld+json");
    }
  });

  test("prerenders and publishes both routes", () => {
    expect(appConfig).toContain('"/why-zig"');
    expect(appConfig).toContain('"/why-zigeffect"');
    expect(sitemap).toContain("https://ziac.dev/why-zig");
    expect(sitemap).toContain("https://ziac.dev/why-zigeffect");
  });
});
