import { describe, expect, test } from "bun:test";

const appSource = await Bun.file(new URL("./ProductLanding.tsx", import.meta.url)).text();
const sceneSource = await Bun.file(new URL("./HeroTopology.tsx", import.meta.url)).text();
const styleSource = await Bun.file(new URL("./styles.css", import.meta.url)).text();
const chromeSource = await Bun.file(new URL("./MarketingChrome.tsx", import.meta.url)).text();
const markSource = await Bun.file(new URL("./ZiacMark.tsx", import.meta.url)).text();
const zigMarkSource = await Bun.file(new URL("../public/zig-mark.svg", import.meta.url)).text();
const noticesSource = await Bun.file(new URL("../THIRD_PARTY_NOTICES.md", import.meta.url)).text();

describe("Ziac product site contract", () => {
  test("leads with the selected product thesis", () => {
    expect(appSource).toContain("Your <span");
    expect(appSource).toContain("Google Cloud</span> estate");
    expect(appSource).toContain("compiled.");
    expect(appSource).toContain("Connect a GCP project");
    expect(appSource).toContain("Explore the canvas");
  });

  test("uses the live topology and real operations capture", () => {
    expect(appSource).toContain("<HeroTopology");
    expect(appSource).toContain('class="operations-canvas-view"');
    expect(appSource).toContain("Architecture canvas");
    expect(appSource).toContain("17 resources");
    expect(appSource).not.toContain('<img src="/ziac-operations.png"');
    expect(sceneSource).toContain('from "three"');
    expect(sceneSource).toContain("WebGLRenderer");
  });

  test("uses a live resource-cube identity in shared chrome", () => {
    expect(chromeSource).toContain("<ZiacMark");
    expect(markSource).toContain('from "three"');
    expect(markSource).toContain("WebGLRenderer");
    expect(markSource).toContain("CanvasTexture");
    expect(markSource).toContain('["Z", "I", "A", "C"]');
    expect(markSource).toContain("prefers-reduced-motion: reduce");
    expect(markSource).toContain("orientationSequence");
  });

  test("uses and attributes the official Zig mark", () => {
    expect(zigMarkSource).toContain('fill="#f7a41d"');
    expect(appSource).toContain('src="/zig-mark.svg"');
    expect(appSource).toContain('alt="Zig"');
    expect(noticesSource).toContain("ziglang/logo");
    expect(noticesSource).toContain("CC BY-SA 4.0");
  });

  test("closes with a specific read-only-first conversion band", () => {
    expect(appSource).toContain("Read-only first scan");
    expect(appSource).toContain("Bring one GCP project");
    expect(appSource).toContain("Observe the estate");
    expect(appSource).toContain("Compile the change");
    expect(appSource).toContain("Deploy with proof");
    expect(appSource).toContain("Nothing is changed until you approve a proved plan");
  });

  test("ships accessible conversion and navigation controls", () => {
    expect(appSource).toContain('role="dialog"');
    expect(appSource).toContain('aria-modal="true"');
    expect(appSource).toContain('type="email"');
    expect(appSource).toContain("Private beta");
  });

  test("provides motion with reduced-motion parity", () => {
    expect(appSource).toContain("IntersectionObserver");
    expect(styleSource).toContain("prefers-reduced-motion: reduce");
    expect(sceneSource).toContain("matchMedia");
    expect(sceneSource).toContain("setDrawRange");
  });

  test("positions Ziac as agent-native infrastructure at Zig speed", () => {
    expect(appSource).toContain("Zig speed");
    expect(appSource).toContain("Specialist agents");
    expect(appSource).toContain("causal graph");
    expect(appSource).toContain("truly global apps");
    expect(appSource).toContain("Cloud Run regions");
    expect(appSource).toContain('role="tablist"');
    expect(appSource).toContain('role="tab"');
  });

  test("markets the complete relocatable agent development kit", () => {
    expect(appSource).toContain("One install. Every agent equipped.");
    expect(appSource).toContain("Relocatable by design");
    expect(appSource).toContain("Ziac MCP server");
    expect(appSource).toContain("GCP Developer Researcher");
    expect(appSource).toContain("DEVELOPERKNOWLEDGE_API_KEY");
    expect(appSource).toContain('href="/how-it-works#scaffold"');
  });

  test("makes the Pulumi and Terraform differentiation concrete", () => {
    expect(appSource).toContain("Pulumi and Terraform are broad");
    expect(appSource).toContain("App + infrastructure");
    expect(appSource).toContain("One comptime contract");
    expect(appSource).toContain("Provider-native GCP");
    expect(appSource).toContain("Observed before managed");
    expect(appSource).toContain("ZIAC100 missing app binding");
    expect(appSource).toContain('role="table"');
  });

  test("makes comptime validation a fast agent feedback loop", () => {
    expect(appSource).toContain("Compile. Diagnose. Repair. Verify.");
    expect(appSource).toContain("before preview or a provider RPC");
    expect(appSource).toContain("typed causal evidence");
    expect(appSource).toContain("affected graph and deterministic tests");
    expect(appSource).toContain("Agent edit");
    expect(appSource).toContain("Targeted repair");
    expect(appSource).toContain('href="/causal-graph"');
  });

  test("makes Google Cloud the first provider rather than an adapter", () => {
    expect(appSource).toContain("Google Cloud is not our third provider");
    expect(appSource).toContain("AWS-first");
    expect(appSource).toContain("Azure");
    expect(appSource).toContain("GCP-native infrastructure diagrams");
    expect(appSource).toContain("Google API semantics first");
  });

  test("fuses GCP and Zig through a semantic accent system", () => {
    expect(appSource).toContain('class="site-shell product-page"');
    expect(appSource).toContain("hero-cloud");
    expect(appSource).toContain("hero-compiled");
    expect(appSource).toContain("hero-brand-bridge");
    expect(appSource).toContain("GCP graph");
    expect(appSource).toContain("Ziac comptime");
    expect(appSource).toContain("Zig service");
    expect(appSource).toContain("agent-icon-${agent.kind}");
    expect(styleSource).toContain("--gcp-cobalt");
    expect(styleSource).toContain("--zig-amber");
    expect(styleSource).toContain("--runtime-mint");
    expect(styleSource).toContain("--signal-coral");
    expect(styleSource).toContain(".product-page .hero h1 .hero-compiled");
    expect(sceneSource).toContain("amber:");
    expect(sceneSource).toContain('resource.tone === "edge" ? palette.amber');
  });
});
