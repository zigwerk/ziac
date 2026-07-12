# Ziac Yachdee and Court Series Case Study Plan

## Scope

Add one production-ready case study route to the existing SolidStart Ziac marketing site. Reuse the shared marketing chrome and live topology. Do not alter the product dashboard or infrastructure engine.

## Implementation

1. Add a source contract test that fails until the route, SEO, product chapters, architecture facts, honesty language, assets, navigation, prerendering, and sitemap entry exist.
2. Copy the approved Yachdee and Court Series photography into `apps/ziac-site/public/case-studies/`.
3. Add `CaseStudy.tsx` with the hero, proof strip, two product chapters, live architecture, agent precision, cost/locality, build-status, and final action sections.
4. Add the SolidStart route with metadata and TechArticle JSON-LD.
5. Extend `MarketingRoute` and the shared navigation.
6. Add responsive styles in the existing site stylesheet, using established tokens and reveal behaviour.
7. Add the route to static prerendering and the sitemap.

## Verification

1. Run the focused case study test and then the full Ziac site test suite.
2. Run `bun run typecheck` from `apps/ziac-site`.
3. Run `bun run build` from `apps/ziac-site` and verify the new route is prerendered.
4. Open the route in the in-app browser at desktop and mobile sizes.
5. Check the Three.js canvas for nonblank pixels and inspect hero crop, typography, section rhythm, image crops, overflow, and navigation.
6. Fix visual defects and repeat screenshots before handoff.
