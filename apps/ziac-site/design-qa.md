# Ziac Product Site Design QA

## Evidence

- Source visual truth: `/Users/seanknowles/.codex/generated_images/019efdf7-ffbb-7e62-8f42-29612ee2e530/exec-3aad1ccf-aa9b-477b-b0cc-aa74ee7d141c.png`
- Desktop implementation: `/tmp/ziac-site-desktop-final.png`
- Source-matched implementation: `/tmp/ziac-site-matched-864x730-final.png`
- Mobile implementation: `/tmp/ziac-site-mobile-final-static.png`
- Agent-native hero: `/tmp/ziac-agent-hero-desktop.png`
- Agent scenario workspace: `/tmp/ziac-agent-section-aligned.png`
- Mobile agent workspace: `/tmp/ziac-agent-mobile-fixed-v2.png`
- Competitive comparison: `/tmp/ziac-comparison-1129-v2.png`
- Mobile competitive rows: `/tmp/ziac-comparison-mobile-v2.png`
- Google Cloud-first hero: `/tmp/ziac-gcp-first-hero.png`
- Google Cloud-first proof band: `/tmp/ziac-gcp-first-1280.png`
- Mobile Google Cloud-first proof: `/tmp/ziac-gcp-first-mobile.png`
- Operations implementation: `/tmp/ziac-site-operations-864x730-final.png`
- Full hero comparison: `/tmp/ziac-site-hero-comparison-final.png`
- Focused operations comparison: `/tmp/ziac-site-operations-comparison-final.png`
- Canvas pixel evidence: `/tmp/ziac-site-canvas-v2.png`
- SolidStart development SSR evidence: `/tmp/ziac-solidstart-dev.html`
- SolidStart production prerender evidence: `/tmp/ziac-solidstart-preview.html`
- How-it-works desktop hero: in-app browser at `1280x720`
- How-it-works harness workspace: in-app browser at `1280x720`, Claude Code selected
- How-it-works mobile hero and harness: in-app browser at `390x844`
- Why Zig desktop hero: in-app browser at `1280x720`
- Why Zig mobile hero: in-app browser at `390x844`
- Why ZigEffect desktop hero and typed runtime section: in-app browser at `1280x720`
- Why ZigEffect mobile hero: in-app browser at `390x844`
- GCP/Zig fusion baseline hero: in-app browser at `1280x720`, white/cobalt state
- GCP/Zig fusion final hero: in-app browser at `1280x720`, semantic cobalt/amber/mint state
- GCP/Zig fusion agent workspace: in-app browser at `1280x720`
- GCP/Zig fusion mobile hero: in-app browser at `390x844`
- Causal graph desktop hero: in-app browser at `1440x1000`
- Causal graph mobile hero and two-graph lineage: in-app browser at `390x844`
- Agent compile feedback loop: in-app browser at `1440x1000` and `390x844`
- Live architecture canvas replacement: in-app browser at `1280x720`, `1294x1207`, and `390x844`
- Animated Ziac resource-cube mark: in-app browser header at 38x38 CSS pixels
- Zig lockup and private-beta conversion close: in-app browser at `1294x1207` and `390x844`
- Viewports: 1440x1000 desktop, 864x730 source-matched desktop, 390x844 mobile
- State: light theme, hero settled after entry animation; operations section after anchor navigation

## Findings

No actionable P0, P1, or P2 findings remain.

- Fonts and typography: the system sans stack reproduces the source's compact grotesk character, with matching heavy hero hierarchy, zero letter spacing on display text, restrained uppercase eyebrows, and readable small UI copy. The source-matched viewport preserves the intended line breaks.
- Spacing and layout rhythm: header density, two-column hero balance, CTA grouping, first-viewport height, proof-section spacing, and mobile vertical rhythm are aligned with the source. The page has no horizontal overflow at 1440px or 390px.
- Colors and visual tokens: ink, white, restrained blue, mint, violet, neutral borders, and low-opacity route colors match the source direction without copying Google branding. No gradients are used.
- Image quality and asset fidelity: the hero is a live antialiased Three.js topology rather than a flattened approximation. The operations proof uses the real Ziac workbench capture at native sharpness. Lucide supplies interface icons; no handcrafted SVG or placeholder asset is present.
- Copy and content: the selected hero thesis and CTA copy are preserved. Additional read-only safety, operations, and private-beta copy supports the real product conversion path without claiming OAuth is active.
- Agent-native positioning: the hero now names Zig speed and specialist agents, while the interactive scenario surface makes the causal-graph advantage concrete across global API, residency, and cost-aware rollout intents.
- Competitive differentiation: the comparison credits Pulumi's typed SDK and Automation API and Terraform's HCL, validation, plan, import, and state model while showing Ziac's narrower app-to-infrastructure comptime boundary. Every comparison links to the corresponding official documentation.
- Google Cloud-first positioning: the first viewport now states the provider priority directly, while the dedicated proof band turns it into three concrete commitments: Google API semantics, GCP-native infrastructure diagrams, and global Cloud Run primitives. The market observation is framed as Ziac's point of view rather than an unsupported universal claim.
- Search rendering: SolidStart prerenders the complete marketing route. Title, description, canonical URL, robots policy, Open Graph metadata, Twitter metadata, software-application JSON-LD, hero copy, and differentiation copy are all present in the initial HTML before hydration.
- How-it-works journey: the new route retains the live topology as the hero product signal, then moves through scaffold, harness, authority, operations, global provisioning, and mixed-estate ownership without nested cards or explanatory filler. The page is responsive at `1280x720` and `390x844`, with no clipping or horizontal overflow observed.
- Product honesty: the not-yet-shipped `ziac init` flow is labelled `Private beta CLI flow`; implemented agent orientation, watch mode, saved-plan authority, visual operations, and estate ownership concepts are presented directly.
- Multi-page architecture: Product, How it works, Why Zig, Why ZigEffect, and Dashboard now share one responsive navigation contract. Each technical route has an independent argument and avoids duplicating the homepage comparison content.
- Why Zig: the page makes an economic and operational case through explicit allocation, inspectable control flow, `comptime` application/infrastructure validation, cross-compilation, immutable images, and global Cloud Run placement. It uses no unsupported benchmark number, blanket memory claim, or universal language-speed superlative.
- Why ZigEffect: the page is grounded in implemented typed effects, layers, scoped resources, multiple executors, causal graphs, typed statecharts, Testing v2, `VirtualWorld`, `AssertionRecorder`, provider-neutral handoffs, maturity levels, and explicit evidence-completeness limits.
- GCP/Zig brand fusion: the homepage now uses product semantics instead of decorative brand colour. Cobalt identifies Google Cloud resources and provider paths, amber identifies the compiled global entry, `comptime`, build/rollout agents, and output wiring, mint identifies verified runtime/data state, and coral is reserved for pricing or risk signals.
- Brand independence: no Google or Zig logo was copied. The existing Ziac mark, white surface, ink typography, restrained borders, and product visuals remain dominant; the new colours behave as Ziac-owned operational tokens.
- Causal proof explainer: `/causal-graph` connects the ZigEffect runtime graph and Ziac infrastructure graph through one nine-stage Cloud Run lineage. The design uses compact evidence rows, flat editorial graph structures, the real Operations capture, and explicit evidence limits without introducing card sprawl or decorative diagrams.
- Agent compile feedback loop: the comptime contract now shows edit, compile, causal diagnosis, targeted repair, and affected verification as one compact sequence. Desktop keeps all five stages on one rail; mobile resolves them into a legible two-column grid with the final verification stage spanning the row. No horizontal overflow or console errors were observed.
- Homepage canvas proof: the static Operations screenshot has been replaced by the live Three.js architecture topology. Resource count, ownership legend, routing, and verification facts are attached to the same framed tool surface; the layout remains legible and nonblank at desktop and mobile widths.
- Brand identity: the shared header/footer mark is now a live Three.js resource cube with `Z`, `I`, `A`, and `C` faces, slow deterministic tumbling, stable dimensions, and reduced-motion fallback. Two sampled frames 3.4 seconds apart differed by 405 encoded bytes after the initial orientation bug was fixed.
- Zig identity and attribution: final compatibility and conversion sections use the official Zig Project logomark from `ziglang/logo`; `THIRD_PARTY_NOTICES.md` records its CC BY-SA 4.0 license and states that Ziac is independent.
- Conversion close: the generic tinted beta card is gone. The replacement is a full-width, unframed read-only-first band with a specific GCP project promise, Zig product signal, one primary action, and observe/compile/deploy evidence rows.

## Full-View Comparison

`/tmp/ziac-site-hero-comparison-final.png` places the 864x730 source hero and implementation side by side. Hierarchy, copy position, navigation density, canvas-first composition, CTA pair, and next-section cue agree. The live topology is intentionally simpler in static detail than the generated mock because it supports assembly, route drawing, camera response, and resource inspection.

## Focused Comparison

`/tmp/ziac-site-operations-comparison-final.png` compares the source operations proof with the rendered product section. The implementation preserves the compact workbench proportions and adds a short editorial heading above the real capture. This is an intentional content extension and does not reduce product fidelity.

## Interaction And Runtime Checks

- Primary `Connect a GCP project` CTA opens the accessible modal dialog.
- Email and GCP project inputs accept values and the submit path renders the success state.
- Escape/close controls and the mobile navigation are present and keyboard-addressable.
- `Explore the canvas` scrolls to the operations proof.
- Resource hover renders the topology tooltip.
- Global API, Residency, and Cost-aware rollout tabs each select one unique panel and expose the corresponding causal proof.
- Entry screenshots differ before and after the topology assembly, proving active scene motion.
- Reduced-motion support is present in both CSS and scene runtime.
- Canvas crop contains 487 sampled unique colors, proving a nonblank WebGL render.
- Console errors checked: zero.
- Codex, Claude Code, and Gemini CLI tabs expose one governed kernel; Claude Code selection was exercised and exposed the correct adapter, transcript, and selected state.
- Mobile navigation opens into one accessible navigation region and the first viewport keeps both calls to action and a meaningful portion of the live topology visible.
- Shared mobile navigation exposes one unique Why Zig and ZigEffect link; navigating from ZigEffect to Why Zig produced the correct route title and URL.
- Both technical heroes leave a visible proof-strip cue in the first mobile and desktop viewport.
- The homepage hero exposes a readable GCP graph to Ziac comptime to Zig service sequence at desktop and mobile widths.
- The topology keeps Cloud Run blue and third-party infrastructure violet while the global compiled entry and binding routes use amber; resource grouping and labels remain legible.
- Development SSR returns the complete route and SEO head with a 200 response.
- Static production preview returns the prerendered route, crawler discovery files, JavaScript/CSS assets, and social image with 200 responses.
- `/how-it-works` prerenders with canonical, social metadata, `HowTo` JSON-LD, and the full journey copy in initial HTML.
- `/why-zig` and `/why-zigeffect` prerender with canonical, social metadata, `TechArticle` JSON-LD, and full technical copy in initial HTML.
- The homepage exposes one unique `causal proof` link; clicking it navigates to `/causal-graph` with the expected independent title. The route has no horizontal overflow at `1440x1000` or `390x844`, and browser console warnings/errors are zero.
- `/causal-graph` prerenders with canonical, social metadata, `TechArticle` JSON-LD, and the complete two-graph, deployment-lineage, agent-query, proof-contract, and evidence-limit narrative.
- Desktop canvas crop contains 64 quantized colours and 14,493 nonwhite sampled pixels; mobile contains 64 quantized colours and 19,299 nonwhite sampled pixels, proving both responsive WebGL renders are nonblank.
- The redesigned beta action opens the existing accessible project-connection dialog and closes cleanly. A fresh verification tab reported zero browser warnings or errors after four seconds of cube and topology animation.

## Comparison History

1. P2: regional slabs lacked enough separation from the white canvas.
   - Fix: strengthened neutral slab materials and edge contrast.
   - Post-fix evidence: `/tmp/ziac-site-desktop-v2.png`.
2. P2: the CTA pair stacked at the 864px source width.
   - Fix: added a dedicated intermediate grid and compact CTA treatment before the mobile breakpoint.
   - Post-fix evidence: `/tmp/ziac-site-matched-864x730-final.png`.
3. P2: fixed/sticky header compositing produced black capture artifacts over the WebGL surface while scrolling.
   - Fix: matched the source's top-only header and removed the competing composited layer.
   - Post-fix evidence: `/tmp/ziac-site-operations-864x730-final.png`.
4. P2: the new single-column agent section inherited the console's min-content width and clipped mobile copy inside the outer shell.
   - Fix: constrained the responsive grid track and both children with `minmax(0, 1fr)` and explicit zero minimum widths.
   - Post-fix evidence: `/tmp/ziac-agent-mobile-fixed-v2.png`.
5. Competitive section review: no P0-P2 issue remained. The desktop surface is a scan-friendly table; mobile converts each row into a vertical Ziac/Pulumi/Terraform argument without horizontal overflow.
   - Evidence: `/tmp/ziac-comparison-1129-v2.png` and `/tmp/ziac-comparison-mobile-v2.png`.
6. Google Cloud-first positioning review: no P0-P2 issue remained. The desktop proof uses an unframed two-column band and the mobile layout resolves into three separated rows with no horizontal overflow.
   - Evidence: `/tmp/ziac-gcp-first-1280.png` and `/tmp/ziac-gcp-first-mobile.png`.
7. SolidStart migration review: visual structure and interaction contracts are unchanged; essential copy and metadata now render on the server and in the static production artifact before client hydration.
   - Evidence: `/tmp/ziac-solidstart-dev.html` and `/tmp/ziac-solidstart-preview.html`.

## Implementation Checklist

- [x] Source-matched desktop composition
- [x] Responsive mobile composition
- [x] Live, nonblank Three.js canvas
- [x] Purposeful entry, route, pointer, and scroll motion
- [x] Reduced-motion parity
- [x] Real operations product capture
- [x] Working primary conversion path
- [x] Working specialist-agent scenario tabs
- [x] Evidence-backed Pulumi and Terraform comparison
- [x] First-viewport and evidence-backed Google Cloud-first positioning
- [x] SolidStart SSR and static prerendering
- [x] Canonical, social, structured, robots, and sitemap metadata
- [x] Dedicated `/how-it-works` product journey
- [x] Interactive multi-harness agent surface
- [x] Existing, referenced, managed, and third-party ownership model
- [x] Desktop and mobile how-it-works visual QA
- [x] Shared multi-page navigation and route states
- [x] Dedicated Why Zig technical narrative
- [x] Dedicated Why ZigEffect technical narrative
- [x] Desktop and mobile deep-dive visual QA
- [x] Semantic GCP/Zig colour system
- [x] Baseline-to-fused hero comparison
- [x] Desktop and mobile brand-fusion QA
- [x] Dedicated causal graph and agent verification explainer
- [x] Homepage causal-proof link and responsive lineage QA
- [x] Agent-native comptime feedback-loop positioning and responsive QA
- [x] Live canvas replacement for the static Operations screenshot
- [x] Animated Ziac resource-cube identity with deterministic bounds test
- [x] Official attributed Zig logomark integration
- [x] Authored read-only-first conversion close
- [x] Zero console errors
- [x] No remaining P0/P1/P2 findings

## Follow-up Polish

- P3: replace the beta form handoff with real Google-backed OAuth once the backend consent and entitlement flow exists.
- P3: capture a production workbench image at 2x density when final marketing copy is locked.

final result: passed
