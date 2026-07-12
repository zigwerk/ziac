# Ziac Yachdee and Court Series Case Study Design

## Goal

Create a dedicated, indexable Ziac case study that explains how Yachdee and Court Series are using the same GCP-specialised infrastructure model for two different global products. The page must make the architecture concrete without inventing production scale, latency, cost, or customer metrics.

## Audience

- Founders and product engineers evaluating Ziac for a global Zig backend.
- GCP teams who need regional compute and data locality without maintaining a large platform team.
- Agent-first engineering teams who want infrastructure intent, validation, rollout evidence, and visual monitoring in one system.

## Narrative

The story is a paired build case:

1. Yachdee moves vessel records, documents, deliveries, payment state, and operational context among owners, captains, crew, and managers across countries.
2. Court Series coordinates local tennis discovery, check-in, live match state, dual score sign-off, disputes, and payouts while retaining a product model that can expand beyond an initial pilot.
3. Ziac gives both products one global HTTPS entry, regional Zig APIs on Cloud Run, deliberate CockroachDB locality, private regional data paths, compile-time boundary validation, and causal rollout evidence.

The page explicitly calls this an active build story. It will not claim completed global production rollout or measured savings.

## Experience

### Hero

A full-bleed real Yachdee image anchors the first viewport. The headline names both products and the supporting copy states the shared infrastructure model. The hero copy sits directly over the image with a solid translucent scrim, not in a card. The bottom of the viewport reveals the architecture proof strip.

### Product Chapters

Yachdee and Court Series each receive an editorial chapter grounded in their real workflows. Each chapter pairs product context with a compact architecture ledger covering entry, execution, data placement, and private connectivity. Court Series uses its real court photography rather than a generic sports asset.

### Shared Architecture

The existing live Three.js Ziac topology is reused in a full-width canvas band. A five-step route explains client entry, global load balancing, nearest healthy Cloud Run execution, regional CockroachDB access, and causal verification.

### Precision and Cost

The closing sections explain how App.Env and infrastructure bindings compile together, how provider and regional availability are validated, and why a saved plan plus causal evidence creates a human verification boundary. Cost language remains precise: Cloud Run may scale to zero by default, minimum instances trade idle cost for readiness, and database spend depends on regions, survival goals, storage, and traffic.

## Visual Direction

- Continue the existing Ziac white, cobalt, amber, mint, and coral system.
- Use real product photography as broad editorial bands.
- Use borders and full-width bands instead of decorative card grids.
- Keep radii at 8px or less.
- Use Lucide icons for architecture and process labels.
- Preserve generous editorial hierarchy while keeping data rows compact.
- No gradients, decorative blobs, fake diagrams, or fabricated customer logos.

## Accessibility and Responsive Behaviour

- Semantic headings and section landmarks.
- Descriptive image alt text.
- Visible keyboard focus inherited from the shared design system.
- Two-column layouts collapse to one column below tablet width.
- Hero and canvas maintain stable heights at desktop and mobile sizes.
- Motion respects `prefers-reduced-motion` through the existing topology and reveal patterns.

## Acceptance Criteria

- Route: `/case-studies/yachdee-court-series`.
- Dedicated title, description, canonical URL, Open Graph image, and TechArticle JSON-LD.
- Linked from desktop and mobile navigation.
- Included in static prerender and sitemap.
- Uses the real Yachdee and Court Series image assets.
- Includes the live `HeroTopology` canvas.
- Explains global HTTPS, regional Cloud Run, CockroachDB locality, Direct VPC, and Private Service Connect.
- Explains compile-time app/infrastructure validation and causal verification.
- Clearly states that this is an active build story, not a retrospective benchmark.
- Includes primary documentation links for Cloud Run scaling, global load balancing, and CockroachDB multi-region behaviour.
- Passes site tests, typecheck, production build, and visual QA at desktop and mobile viewports.
