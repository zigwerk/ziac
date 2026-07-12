import { describe, expect, test } from "bun:test";

const readSource = async (path: string) => {
  const file = Bun.file(new URL(path, import.meta.url));
  return await file.exists() ? await file.text() : "";
};

const pageSource = await readSource("./CaseStudy.tsx");
const routeSource = await readSource("./routes/case-studies/yachdee-court-series.tsx");
const chromeSource = await readSource("./MarketingChrome.tsx");
const configSource = await readSource("../app.config.ts");
const sitemapSource = await readSource("../public/sitemap.xml");
const styleSource = await readSource("./styles.css");

describe("Yachdee and Court Series case study", () => {
  test("ships an indexable, prerendered case study route", () => {
    expect(routeSource).toContain("Yachdee and Court Series build globally with Ziac");
    expect(routeSource).toContain("TechArticle");
    expect(routeSource).toContain("/case-studies/yachdee-court-series");
    expect(configSource).toContain('"/case-studies/yachdee-court-series"');
    expect(sitemapSource).toContain("https://ziac.dev/case-studies/yachdee-court-series");
  });

  test("tells both grounded product stories", () => {
    expect(pageSource).toContain("Yachdee × Court Series");
    expect(pageSource).toContain("Two products. One global infrastructure model.");
    expect(pageSource).toContain("A vessel record should travel without feeling far away.");
    expect(pageSource).toContain("A live match cannot wait for a distant backend.");
    expect(pageSource).toContain("vessel vault");
    expect(pageSource).toContain("dual score sign-off");
    expect(pageSource).toContain('/case-studies/yachdee-hero.webp');
    expect(pageSource).toContain('/case-studies/yachdee-delivery.webp');
    expect(pageSource).toContain('/case-studies/court-series-court.webp');
  });

  test("makes the shared global architecture concrete", () => {
    expect(pageSource).toContain("One global entry. Regional execution. Data with a home.");
    expect(pageSource).toContain("<HeroTopology");
    expect(pageSource).toContain("Premium global HTTPS");
    expect(pageSource).toContain("Cloud Run");
    expect(pageSource).toContain("CockroachDB");
    expect(pageSource).toContain("Direct VPC");
    expect(pageSource).toContain("Private Service Connect");
    expect(pageSource).toContain("App.Env");
    expect(pageSource).toContain("causal verification");
  });

  test("uses careful cost and delivery claims with primary sources", () => {
    expect(pageSource).toContain("Low idle compute, deliberate database spend.");
    expect(pageSource).toContain("scale to zero");
    expect(pageSource).toContain("minimum instances");
    expect(pageSource).toContain("This is a build story, not a retrospective benchmark.");
    expect(pageSource).toContain("under active development");
    expect(pageSource).toContain("docs.cloud.google.com/run/docs/about-instance-autoscaling");
    expect(pageSource).toContain("docs.cloud.google.com/load-balancing/docs/https");
    expect(pageSource).toContain("cockroachlabs.com/docs/stable/multiregion-overview");
    expect(pageSource).not.toContain("% cheaper");
    expect(pageSource).not.toContain("already serves");
  });

  test("integrates with shared navigation and responsive styling", () => {
    expect(chromeSource).toContain('"case-study"');
    expect(chromeSource).toContain('href: "/case-studies/yachdee-court-series"');
    expect(styleSource).toContain(".case-study-hero");
    expect(styleSource).toContain(".case-study-chapter");
    expect(styleSource).toContain(".case-study-canvas");
    expect(styleSource).toContain("@media (max-width: 760px)");
  });
});
