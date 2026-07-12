# Ziac Product Landing Design

## Goal

Ship a standalone, deployable Ziac product site that turns the infrastructure canvas into the first-viewport product proof. The page should feel as considered as a Google Cloud product page without copying Google branding, trade dress, logos, or navigation.

The product thesis is agent-native infrastructure at Zig speed. Existing-estate discovery is the immediate wedge; the durable advantage is a team of specialist infrastructure agents that share one typed causal graph, generate reviewable Ziac code, validate provider contracts at compile time, and safely orchestrate truly global Cloud Run deployments.

Ziac is also explicitly Google Cloud first. The site should reject the idea that GCP is a third provider added after AWS and Azure. Google APIs, Cloud Run, global load balancing, IAM, billing, and GCP-native topology diagrams are core product primitives rather than generic multi-cloud adaptations.

## Audience

The primary visitor is a Zig developer or GCP platform engineer who already has infrastructure and needs to understand it before trusting a new deployment engine. The page must establish three facts quickly:

1. Ziac can observe an existing Google Cloud estate.
2. Ziac validates resource wiring and provider constraints at compile time.
3. Ziac can deploy Zig services globally with operational evidence.
4. Specialist agents can move quickly without losing quality because every decision, dependency, and rollout result remains attached to the causal graph.

## Visual Direction

- Bright white canvas with ink typography, restrained Google-adjacent blue, mint, and violet accents.
- Compact navigation and generous but controlled whitespace.
- The hero contains a live, unframed isometric topology. It must not be wrapped in the dashboard shell.
- The topology uses a square grid, stacked account/VPC/region slabs, labelled resource blocks, and soft planar connection routes.
- The operations section uses a real capture of the Ziac dashboard as product evidence.
- No gradients, decorative blobs, faux Google branding, or marketing-card sprawl.

## Motion Language

Motion explains system assembly and dependency flow:

- On entry, the grid settles first, then slabs and resources rise into place in topology order.
- Dependency routes draw after their endpoints are present.
- Pointer movement creates a small camera response; idle movement remains subtle.
- Scroll reveals use short opacity and vertical transitions with restrained staggering.
- The operations capture lifts slightly into place when it enters the viewport.
- All nonessential motion is disabled under `prefers-reduced-motion: reduce` while preserving final layout and hierarchy.

## Information Architecture

1. Compact header with product navigation and primary CTA.
2. Hero: product thesis, supporting copy, CTA pair, interactive topology.
3. Agent-native proof: interactive deployment scenarios showing specialist skills converging on one proved plan.
4. Competitive proof: an explicit, fair comparison with Pulumi and Terraform plus a real Ziac comptime contract example.
5. GCP-first statement: Google Cloud is the primary design target, including provider semantics and topology visualisation.
6. Operations proof: real dashboard capture and concise explanation.
7. Three-step workflow: observe, agents compile, deploy.
8. Compatibility statement for Zig, Google Cloud, Cloud Run, and CockroachDB.
9. Final private-beta CTA and compact footer.

## Interaction Contract

- `Connect a GCP project` opens an accessible private-beta dialog.
- The dialog accepts an email and project ID, validates required fields, and shows an inline success state without pretending OAuth is active.
- `Explore the canvas` scrolls to the operations proof.
- Header navigation anchors scroll to their corresponding sections.
- Mobile navigation is keyboard-operable and dismissible.
- Hovering a resource in the hero shows a concise resource tooltip.
- Agent scenario tabs switch between global API, residency, and cost-aware rollout plans with visible specialist-agent and proof outputs.
- Competitive rows distinguish Ziac's app-to-infrastructure contract, GCP specialization, global Cloud Run component, agent runtime, observed-estate model, and causal debugging from the broader Pulumi and Terraform execution models without claiming those tools lack their documented capabilities.

## Accessibility

- Semantic landmarks and heading order.
- Visible focus states and keyboard-accessible dialog controls.
- Canvas has a text alternative and does not carry essential copy.
- Minimum contrast suitable for WCAG AA on all body text and controls.
- Motion respects the operating-system reduced-motion preference.

## Acceptance Checks

- Production build completes with Bun and SolidStart.
- `/` is prerendered as crawlable HTML containing the complete hero copy and route metadata before client hydration.
- The route owns its title, description, canonical URL, robots directives, Open Graph metadata, Twitter metadata, and software-application structured data.
- Stable `robots.txt` and `sitemap.xml` assets expose the public marketing route to crawlers.
- TypeScript strict mode passes.
- Deterministic topology tests prove scene IDs, route endpoints, and bounded layout.
- UI contract tests prove the core copy, conversion controls, real product capture, live Three.js canvas, and reduced-motion support.
- Browser captures at desktop and mobile show no overlap or horizontal overflow.
- Canvas pixel sampling proves the Three.js render is nonblank.
- Browser interaction checks cover the primary CTA, form validation/success, navigation, and console errors.
- `design-qa.md` records a source-to-implementation comparison with `final result: passed`.

## Rendering Architecture

- SolidStart owns the document, route, server rendering, hydration, and production output.
- The marketing route is prerendered at build time because its content is static and should not require a server response to be indexed.
- `@solidjs/meta` owns route metadata so future product, pricing, documentation, and comparison routes can provide independent search and social contracts.
- Interactive controls and the Three.js topology hydrate on the client without hiding essential copy from the server-rendered document.
- The public site URL is configurable through `PUBLIC_SITE_URL`; the production default is `https://ziac.dev` until deployment configuration overrides it.

## How It Works Journey

The standalone `/how-it-works` route should explain Ziac as an agentic development platform rather than a conventional IaC wrapper.

1. Scaffold a global Zig backend through the private-beta `ziac init` flow.
2. Show the generated project contract, GCP/Ziac/Zig skills, harness adapters, global stack, tests, and dashboard connection.
3. Let visitors switch between Codex, Claude Code, and Gemini CLI while preserving one Ziac kernel, capability model, and visual truth.
4. Explain the governed loop from intent through compile, preflight, simulation, approval, deploy, observation, diagnosis, repair, verification, and handoff.
5. Use the real Operations capture and live topology to show agents driving the dashboard while humans monitor decisions, causal evidence, health, and rollout progress.
6. Make global provisioning concrete: Zig source, Artifact Registry, regional Cloud Run, Premium global load balancing, nearest-healthy routing, and CockroachDB locality.
7. Explain the combined estate: observed GCP resources remain read-only, Ziac-managed resources retain ownership, referenced resources cross the boundary without adoption, and third-party providers render in peer account groups.
8. Close with the product thesis: SaaS has evolved into agent-driven systems where agents build first and humans monitor, approve, and verify.

The page must remain honest about delivery status. `ziac init` is labelled as a private-beta scaffold flow; implemented CLI, MCP, development, saved-plan, Workbench, estate, and global deployment behavior may be described directly.

## Why Zig And ZigEffect Deep Dives

The product site is a small routed publication, not one endlessly growing landing page. Two dedicated routes carry the technical argument behind Ziac:

### `/why-zig`

The Zig page explains why agent-authored cloud applications should use an efficient, explicit systems language. Its argument is economic and operational rather than benchmark-led:

1. Agent generation makes source production cheaper, while runtime CPU, memory, cold-start, image, and operational costs continue for the life of the service.
2. Explicit allocation and control flow make generated code easier to inspect and reason about; the page must not claim blanket memory safety.
3. `comptime` lets Ziac validate application environment structs, infrastructure bindings, provider support, output scope, and topology before preview.
4. Cross-compilation and self-contained binaries fit immutable container delivery and multi-region Cloud Run deployments.
5. Zig remains useful without Ziac: the page should sell the language choice first and then show how Ziac compounds it.

The live topology remains the first-viewport visual proof. A real Ziac-flavoured Zig contract and an unframed runtime economics section carry the deeper argument. No unsupported benchmark numbers or universal "fastest language" claims are allowed.

### `/why-zigeffect`

The ZigEffect page explains the execution model that makes agent-authored Zig operable:

1. Direct-style typed effects make success, typed failure, environment, services, and resource scope inspectable.
2. The causal runtime records a queryable graph of effects, retries, fibers, resources, requirements, findings, and lineage so agents do not have to infer behavior from terminal prose.
3. Typed statecharts and durable workflows make long-running infrastructure and application control flow visible and replayable.
4. Deterministic Testing v2, fault matrices, virtual distributed worlds, model exploration, and replay receipts turn failures into bounded evidence.
5. Provider-neutral agent handoffs carry requirements, acceptance state, causal identifiers, replay commands, capability maturity, and honest limitations between Codex, Claude Code, Gemini, and future harnesses.
6. Evidence completeness is explicit: dropped events, sampling, truncation, unsupported cases, and adapter maturity must remain visible rather than being marketed as proof.

The real Ziac Operations capture is the hero product proof, followed by typed-effect, causal-runtime, statechart, testing, and handoff sections. The page should feel like a technical product narrative, not framework API documentation.

### Shared Navigation And Search Contract

- All four routes use one compact header and footer contract.
- Primary navigation links to Product, How it works, Why Zig, ZigEffect, and Dashboard.
- Each route owns title, description, canonical, Open Graph, Twitter, and appropriate JSON-LD metadata.
- Both deep-dive routes are prerendered and present in `sitemap.xml`.
- Desktop and mobile navigation expose every route without overflow.

## GCP And Zig Brand Fusion

The homepage should visually join its two technical foundations without copying either company's trade dress or turning the white interface into a multicolour campaign page. Colour is semantic:

- Ziac cobalt represents Google Cloud resources, provider semantics, network routes, and primary actions.
- Zig amber represents compiled artifacts, `comptime` validation, output wiring, rollout/build agents, and the final `compiled.` word in the hero.
- Runtime mint represents verified health, readiness, successful evidence, and data services.
- Signal coral is reserved for risk, change, replacement, or failure states and must remain rare.

The first viewport includes a compact unframed bridge from GCP graph to Ziac comptime to Zig service. The Three.js topology uses amber for the compiled global entry artifact and binding routes while keeping Cloud Run blue, data mint, and third-party services violet. Deeper sections repeat the same mapping through specialist-agent icons, the comptime proof, the GCP-first evidence rows, and the three-step global workflow.

The system must remain predominantly white and ink. No gradients, rainbow borders, copied Google or Zig logos, decorative colour blobs, or colour without product meaning. Cobalt remains the primary interaction colour; amber is an authored accent, not a second competing button system.

## Causal Graph Explainer

The homepage phrase `causal proof` links to a dedicated `/causal-graph` technical explainer. The page must turn that product claim into an inspectable deployment lineage rather than treating causality as generic AI language.

1. Explain the two complementary graphs: ZigEffect's runtime graph records typed effects, failures, services, scopes, retries, resources, assertions, and execution lineage; Ziac's infrastructure graph records desired resources, bindings, ownership, saved-plan identity, provider operations, revisions, traffic, health, and acceptance evidence.
2. Follow one global Cloud Run deployment from objective and requirement through agent proposal, comptime validation, saved plan, Google provider RPC/LRO, revision rollout, traffic and health verification, and a redacted handoff receipt.
3. Show how an agent uses graph queries to orient, find causes and consequences, compare semantic changes, test counterfactuals, propose the smallest repair, replay an exact scenario, and verify requirement-linked assertions.
4. Define proof through stable identifiers, typed semantic facts, parent/child relationships, source and requirement links, bounded evidence, replay commands, plan digests, and explicit human authority.
5. State evidence limits plainly: dropped, sampled, or truncated events remain disclosed; unsupported cases and exhausted exploration bounds cannot become a pass; capability maturity and redaction status travel with the handoff.

The route reuses the real Operations capture as first-viewport product evidence and the site's existing white, cobalt, amber, mint, and ink system. Its lineage diagrams are CSS-native editorial structures with real Lucide icons, not decorative SVGs or invented product screenshots. The route owns independent `TechArticle` metadata, is prerendered, and appears in `sitemap.xml`.

## Agent Compile Feedback Loop

The homepage comptime example must connect validation to Ziac's agent-native development model, not present the compiler as a passive safety feature. The copy and visual sequence should explain that Ziac and ZigEffect turn a binding failure into a short loop: edit source, compile against the application/infrastructure contract, diagnose from typed causal evidence, repair the exact boundary, and run affected deterministic verification before preview or a provider RPC. Avoid unsupported timing claims; speed comes from local, structured, scoped feedback rather than a benchmark number.

## Canvas, Brand, And Final Conversion Polish

The homepage Operations proof should show the live architecture canvas rather than a static Operations screenshot. It reuses the real Three.js topology and frames it as a compact architecture tool with resource, connection, ownership, routing, and health context. The copy should explain that humans can watch observed and Ziac-managed infrastructure assemble while agents work.

The Ziac mark becomes a small live Three.js resource cube. Its four side faces carry `Z`, `I`, `A`, and `C`; it moves through a slow deterministic sequence of orientations that feels varied without jitter, and it becomes static under reduced motion. The header and footer share this mark with stable dimensions and no layout shift.

When the site names Zig in the final compatibility and conversion sections, it uses the official Zig Project logomark sourced from `ziglang/logo`, preserves the artwork, and records the CC BY-SA 4.0 attribution. The mark must remain a supporting signal rather than imply Zig Project endorsement.

The private-beta close should no longer look like a generic tinted CTA card. It becomes an unframed editorial conversion band with a specific read-only-first promise, one strong action, and a concise observe/compile/deploy sequence.
