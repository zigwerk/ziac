import Activity from "lucide-solid/icons/activity";
import ArrowRight from "lucide-solid/icons/arrow-right";
import Braces from "lucide-solid/icons/braces";
import Check from "lucide-solid/icons/check";
import Cloud from "lucide-solid/icons/cloud";
import Database from "lucide-solid/icons/database";
import Globe2 from "lucide-solid/icons/earth";
import MapPin from "lucide-solid/icons/map-pin";
import Network from "lucide-solid/icons/network";
import Route from "lucide-solid/icons/route";
import Server from "lucide-solid/icons/server";
import ShieldCheck from "lucide-solid/icons/shield-check";
import { onCleanup, onMount } from "solid-js";
import { HeroTopology } from "./HeroTopology";
import { MarketingFooter, MarketingHeader } from "./MarketingChrome";

const yachdeeArchitecture = [
  ["Global entry", "Premium global HTTPS load balancing"],
  ["Regional API", "Zig services on Cloud Run near operating hubs"],
  ["Operational data", "Vessel and account rows placed near primary use"],
  ["Shared reads", "Portable metadata available across regions"],
  ["Private path", "Regional Direct VPC with CockroachDB Private Service Connect"],
] as const;

const courtSeriesArchitecture = [
  ["Global entry", "One HTTPS endpoint for players, organisers, and officials"],
  ["Event execution", "Cloud Run API placed with each active event region"],
  ["Live match data", "Check-in, scoring, and dispute rows homed near the event"],
  ["Global reads", "Event discovery and shared competition metadata"],
  ["Evidence", "Video metadata and causal history attached to the match"],
] as const;

const routeSteps = [
  { icon: Globe2, label: "Client", detail: "One public endpoint" },
  { icon: Route, label: "Global edge", detail: "Premium HTTPS routing" },
  { icon: Server, label: "Regional API", detail: "Nearest healthy Cloud Run" },
  { icon: Database, label: "Local data", detail: "CockroachDB locality" },
  { icon: ShieldCheck, label: "Evidence", detail: "Causal verification" },
] as const;

export function CaseStudy() {
  onMount(() => {
    const revealTargets = document.querySelectorAll<HTMLElement>("[data-reveal]");
    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) {
            entry.target.classList.add("is-visible");
            observer.unobserve(entry.target);
          }
        }
      },
      { threshold: 0.12, rootMargin: "0px 0px -5%" },
    );
    revealTargets.forEach((target) => observer.observe(target));
    onCleanup(() => observer.disconnect());
  });

  return (
    <div class="site-shell case-study-page">
      <MarketingHeader current="case-study" />

      <main>
        <section class="case-study-hero" aria-labelledby="case-study-title">
          <img src="/case-studies/yachdee-hero.webp" alt="A motor yacht crossing clear blue water viewed from above" />
          <div class="case-study-hero-scrim" aria-hidden="true" />
          <div class="case-study-hero-copy">
            <p class="eyebrow">Yachdee × Court Series · Building with Ziac</p>
            <h1 id="case-study-title">Two products. One global infrastructure model.</h1>
            <p>Yachdee and Court Series need fast, precise systems wherever their users happen to be. Ziac compiles regional Zig APIs, global routing, and data locality into one architecture their agents can build and humans can verify.</p>
            <div class="hero-actions">
              <a class="button button-primary" href="#architecture"><Network size={18} /> Follow the architecture</a>
              <a class="button case-study-ghost-button" href="/#operations">Open the live canvas <ArrowRight size={18} /></a>
            </div>
            <p class="case-study-status"><Activity size={16} /> Architecture in delivery. Production metrics will follow the rollout.</p>
          </div>
        </section>

        <div class="case-study-proof" aria-label="Shared infrastructure model">
          <span><strong>02</strong><small>product workloads</small></span>
          <span><strong>Regional</strong><small>Zig APIs</small></span>
          <span><strong>01</strong><small>global HTTPS entry</small></span>
          <span><strong>Explicit</strong><small>database locality</small></span>
        </div>

        <section class="case-study-intro" aria-labelledby="global-is-not-one-thing">
          <div data-reveal>
            <p class="eyebrow">The shared problem</p>
            <h2 id="global-is-not-one-thing">Global is not one thing.</h2>
          </div>
          <div class="case-study-intro-copy" data-reveal style={{ "--reveal-delay": "70ms" }}>
            <p>For Yachdee, vessel records, documents, routes, deliveries, payment state, owners, captains, and crew move across countries. The product should travel with the yacht without making every operation feel remote.</p>
            <p>For Court Series, discovery can be broad while a check-in, live score, dual score sign-off, dispute, or payout belongs to a specific event happening now. The architecture needs a global view and local immediacy at the same time.</p>
          </div>
        </section>

        <figure class="case-study-photo" data-reveal>
          <img src="/case-studies/yachdee-delivery.webp" alt="A superyacht underway at sea during a delivery" />
          <figcaption>Yachdee · vessel operations that move between people, ports, and jurisdictions</figcaption>
        </figure>

        <section class="case-study-chapter" aria-labelledby="yachdee-chapter-title">
          <div class="case-study-chapter-copy" data-reveal>
            <p class="eyebrow">01 · Yachdee</p>
            <h2 id="yachdee-chapter-title">A vessel record should travel without feeling far away.</h2>
            <p>Yachdee is building a vessel vault, yacht passport, and delivery workspace for owners, captains, crew, and managers. Documents and operational state need to remain trustworthy as responsibility moves from shore team to crew, from seller to owner, or from one delivery leg to the next.</p>
            <p>Ziac turns that product intent into a regional deployment model: one reviewed Zig service, repeated as Cloud Run revisions near the work, with a global front door and an explicit home for each class of data.</p>
          </div>
          <div class="case-study-ledger" data-reveal style={{ "--reveal-delay": "80ms" }} role="table" aria-label="Yachdee infrastructure model">
            {yachdeeArchitecture.map(([label, value]) => (
              <div role="row"><strong role="rowheader">{label}</strong><span role="cell">{value}</span></div>
            ))}
          </div>
        </section>

        <figure class="case-study-photo case-study-photo-court" data-reveal>
          <img src="/case-studies/court-series-court.webp" alt="Tennis players competing on an outdoor hard court with match cameras beside the court" />
          <figcaption>Court Series · local competition with a product model ready to travel</figcaption>
        </figure>

        <section class="case-study-chapter" aria-labelledby="court-series-chapter-title">
          <div class="case-study-chapter-copy" data-reveal>
            <p class="eyebrow">02 · Court Series</p>
            <h2 id="court-series-chapter-title">A live match cannot wait for a distant backend.</h2>
            <p>Court Series is building the operating system for paid local tennis events: nearby discovery, entry, check-in, match start, dual score sign-off, disputes, refunds, payouts, and video evidence. Its current pilot starts locally, but its event model is designed to repeat across clubs and regions.</p>
            <p>Ziac lets the same service contract move with the competition. Active match state can stay near the court while event discovery and shared competition data remain globally readable.</p>
          </div>
          <div class="case-study-ledger" data-reveal style={{ "--reveal-delay": "80ms" }} role="table" aria-label="Court Series infrastructure model">
            {courtSeriesArchitecture.map(([label, value]) => (
              <div role="row"><strong role="rowheader">{label}</strong><span role="cell">{value}</span></div>
            ))}
          </div>
        </section>

        <section class="case-study-architecture" id="architecture" aria-labelledby="architecture-title">
          <div class="case-study-section-heading" data-reveal>
            <p class="eyebrow">The Ziac model</p>
            <h2 id="architecture-title">One global entry. Regional execution. Data with a home.</h2>
            <p>The same compiled graph can express different placement policy for each workload without giving every product team a different platform.</p>
          </div>
          <div class="case-study-canvas" data-reveal style={{ "--reveal-delay": "70ms" }}>
            <HeroTopology />
          </div>
          <div class="case-study-route" data-reveal aria-label="Request path">
            {routeSteps.map((step, index) => {
              const Icon = step.icon;
              return (
                <>
                  <span><Icon size={20} /><small>{step.label}</small><strong>{step.detail}</strong></span>
                  {index < routeSteps.length - 1 && <ArrowRight size={16} aria-hidden="true" />}
                </>
              );
            })}
          </div>
        </section>

        <section class="case-study-precision" aria-labelledby="precision-title">
          <div data-reveal>
            <p class="eyebrow">Agent speed with a hard boundary</p>
            <h2 id="precision-title">Fast because feedback is local. Precise because the boundary is compiled.</h2>
            <p>Specialist agents can assemble the regional graph quickly because Ziac and ZigEffect make the next valid move inspectable. The compiler and causal runtime keep speed from becoming guesswork.</p>
          </div>
          <div class="case-study-checks" data-reveal style={{ "--reveal-delay": "80ms" }}>
            <span><Braces size={19} /><strong>Application contract</strong><small>App.Env requirements must match bindings, secrecy, type, and scope.</small></span>
            <span><MapPin size={19} /><strong>Placement contract</strong><small>Regions, providers, outputs, and database locality must be available together.</small></span>
            <span><Cloud size={19} /><strong>Mutation contract</strong><small>Agents propose a saved plan before infrastructure changes.</small></span>
            <span><ShieldCheck size={19} /><strong>Operational contract</strong><small>Health, rollout decisions, and repairs retain causal verification.</small></span>
          </div>
        </section>

        <section class="case-study-economics" aria-labelledby="economics-title">
          <div data-reveal>
            <p class="eyebrow">Cost-conscious by design</p>
            <h2 id="economics-title">Low idle compute, deliberate database spend.</h2>
            <p>Cloud Run services can scale to zero by default when they receive no traffic. Teams can add minimum instances where readiness matters enough to justify idle compute. Ziac should expose that trade-off in the plan instead of hiding it behind a generic service preset.</p>
            <p>CockroachDB cost and latency depend on region count, survival goals, storage, traffic, and table locality. Yachdee and Court Series can give globally shared data and region-owned data different homes rather than paying for one universal replication strategy.</p>
          </div>
          <aside class="case-study-sources" data-reveal style={{ "--reveal-delay": "80ms" }} aria-label="Architecture sources">
            <p>Architecture sources</p>
            <a href="https://docs.cloud.google.com/run/docs/about-instance-autoscaling" target="_blank" rel="noreferrer"><Server size={17} /><span><strong>Cloud Run autoscaling</strong><small>Scale to zero and minimum instances</small></span><ArrowRight size={15} /></a>
            <a href="https://docs.cloud.google.com/load-balancing/docs/https" target="_blank" rel="noreferrer"><Route size={17} /><span><strong>Global external Application Load Balancer</strong><small>Global entry and serverless backends</small></span><ArrowRight size={15} /></a>
            <a href="https://www.cockroachlabs.com/docs/stable/multiregion-overview" target="_blank" rel="noreferrer"><Database size={17} /><span><strong>CockroachDB multi-region</strong><small>Survival goals and data locality</small></span><ArrowRight size={15} /></a>
          </aside>
        </section>

        <section class="case-study-honesty" aria-labelledby="honesty-title">
          <div data-reveal>
            <p class="eyebrow">Build status</p>
            <h2 id="honesty-title">This is a build story, not a retrospective benchmark.</h2>
          </div>
          <div data-reveal style={{ "--reveal-delay": "70ms" }}>
            <p>Yachdee, Court Series, and the Ziac architecture are under active development. The model on this page reflects the product requirements and provider contracts being assembled now. Measured production latency, availability, and cost results will be published only after the regional rollout has produced durable evidence.</p>
            <span><Check size={16} /> Product workflows grounded</span>
            <span><Check size={16} /> Provider contracts modelled</span>
            <span><Activity size={16} /> Regional rollout in delivery</span>
          </div>
        </section>

        <section class="case-study-cta" aria-labelledby="case-study-cta-title">
          <div data-reveal><p class="eyebrow">Build from intent</p><h2 id="case-study-cta-title">Compile the next global Zig backend.</h2></div>
          <a class="button button-primary" href="/how-it-works" data-reveal style={{ "--reveal-delay": "80ms" }}>See how Ziac works <ArrowRight size={18} /></a>
        </section>
      </main>

      <MarketingFooter message="Two products. One explicit global infrastructure model." />
    </div>
  );
}
