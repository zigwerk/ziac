import Activity from "lucide-solid/icons/activity";
import ArrowRight from "lucide-solid/icons/arrow-right";
import Bot from "lucide-solid/icons/bot";
import Braces from "lucide-solid/icons/braces";
import Check from "lucide-solid/icons/check";
import GitBranch from "lucide-solid/icons/git-branch";
import Layers from "lucide-solid/icons/layers";
import Orbit from "lucide-solid/icons/orbit";
import Repeat2 from "lucide-solid/icons/repeat-2";
import ShieldCheck from "lucide-solid/icons/shield-check";
import TimerReset from "lucide-solid/icons/timer-reset";
import Workflow from "lucide-solid/icons/workflow";
import { onCleanup, onMount } from "solid-js";
import { MarketingFooter, MarketingHeader } from "./MarketingChrome";

const faultRows = [
  ["Allocation", "Fail every bounded allocation point", "Replay token"],
  ["Schedule", "Explore bounded fiber interleavings", "Shortest trace"],
  ["Network", "Delay, drop, duplicate, reorder, partition", "VirtualWorld"],
  ["Storage", "Stale reads, conflicts, partial writes, recovery", "Semantic receipt"],
  ["Runtime", "Timeout, cancellation, crash, restart", "Causal diff"],
] as const;

export function WhyZigEffect() {
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
    <div class="site-shell deep-page effect-page">
      <MarketingHeader current="why-zigeffect" />

      <main>
        <section class="deep-hero effect-deep-hero" aria-labelledby="effect-hero-title">
          <img class="effect-hero-image" src="/ziac-operations.png" alt="Ziac operations workbench showing causal deployment events, an agent diagnosis, and infrastructure verification." />
          <div class="deep-hero-copy">
            <p class="eyebrow">Why ZigEffect</p>
            <h1 id="effect-hero-title">Software agents need a runtime <span>they can interrogate.</span></h1>
            <p>ZigEffect makes execution typed, scoped, deterministic, and causally observable so agents can ask what happened, prove a repair, and hand evidence back to a human.</p>
            <div class="hero-actions">
              <a class="button button-primary" href="#effect-model"><Orbit size={18} /> Explore the runtime</a>
              <a class="button button-secondary" href="/how-it-works">See Ziac use it <ArrowRight size={18} /></a>
            </div>
          </div>
        </section>

        <div class="deep-proof-strip" aria-label="ZigEffect runtime model">
          <span><Braces size={17} /><strong>Typed effects</strong></span>
          <span><GitBranch size={17} /><strong>Causal evidence</strong></span>
          <span><Workflow size={17} /><strong>Typed statecharts</strong></span>
          <span><Repeat2 size={17} /><strong>Deterministic replay</strong></span>
        </div>

        <section class="deep-section" id="effect-model" aria-labelledby="effect-model-title">
          <div class="deep-editorial-heading" data-reveal>
            <p class="eyebrow">Ordinary Zig. Explicit behavior.</p>
            <h2 id="effect-model-title">The type tells an agent what a program needs and how it can fail.</h2>
            <p>ZigEffect keeps direct-style Zig while making success, typed errors, required services, layers, execution, and scoped resources part of one composable contract.</p>
          </div>
          <div class="effect-signature" data-reveal style={{ "--reveal-delay": "70ms" }}>
            <div><small>Effect</small><code>Effect&lt;Success, Failure, Env&gt;</code></div>
            <span><ArrowRight size={17} /></span>
            <div><small>Context</small><code>ctx.service(Database)</code></div>
            <span><ArrowRight size={17} /></span>
            <div><small>Scope</small><code>acquireRelease(resource)</code></div>
          </div>
          <div class="effect-foundations">
            <article data-reveal><Layers size={22} /><strong>Layers and services</strong><p>Compile-time service requirements, dependency ordering, memoized startup, replacement, and reverse-order teardown.</p></article>
            <article data-reveal style={{ "--reveal-delay": "60ms" }}><ShieldCheck size={22} /><strong>Scoped resources</strong><p>Finalizers run across success, failure, interruption, and cancellation; cleanup failures remain visible in the structured cause.</p></article>
            <article data-reveal style={{ "--reveal-delay": "120ms" }}><Activity size={22} /><strong>Multiple executors</strong><p>The same effect shape can run deterministically for tests, on real coroutines, or on a thread pool with structurally comparable evidence.</p></article>
          </div>
        </section>

        <section class="causal-band" aria-labelledby="causal-title">
          <div class="causal-inner">
            <div class="causal-copy" data-reveal>
              <p class="eyebrow">The debugging interface is a graph</p>
              <h2 id="causal-title">Stop asking agents to reconstruct execution from logs.</h2>
              <p>The causal event graph connects requirements, effects, services, retries, resources, fibers, findings, provider calls, and assertions. An agent can query lineage and consequence directly.</p>
              <div class="causal-queries">
                <code>graph cause event-42</code>
                <code>graph children deploy-7</code>
                <code>graph findings --requirement req-global</code>
              </div>
              <a class="editorial-link" href="/causal-graph">Follow the full Ziac causal lineage <ArrowRight size={16} /></a>
            </div>
            <figure class="operations-frame causal-proof-frame" data-reveal style={{ "--reveal-delay": "90ms" }}>
              <div class="capture-bar" aria-hidden="true"><GitBranch size={16} /><span>Causal operations</span><span class="capture-live"><i /> Queryable</span></div>
              <img src="/ziac-operations.png" alt="Ziac dashboard tracing infrastructure events and an agent diagnosis through the causal graph." loading="lazy" />
            </figure>
          </div>
        </section>

        <section class="deep-section" aria-labelledby="workflow-runtime-title">
          <div class="deep-editorial-heading" data-reveal>
            <p class="eyebrow">Long-running work has shape</p>
            <h2 id="workflow-runtime-title">Typed statecharts make decisions visible before they become incidents.</h2>
            <p>State, events, context, commands, guards, timers, retries, and durable journal transitions are typed. Agents can inspect the machine, explore reachable states, and replay the exact transition path.</p>
          </div>
          <div class="statechart-line" data-reveal style={{ "--reveal-delay": "70ms" }} aria-label="Example deployment statechart">
            <span><small>State 01</small><strong>planned</strong></span><ArrowRight size={17} />
            <span><small>State 02</small><strong>building</strong></span><ArrowRight size={17} />
            <span><small>State 03</small><strong>canary</strong></span><ArrowRight size={17} />
            <span><small>State 04</small><strong>verifying</strong></span><ArrowRight size={17} />
            <span class="statechart-done"><small>State 05</small><strong>promoted</strong></span>
          </div>
        </section>

        <section class="testing-band" aria-labelledby="testing-title">
          <div class="testing-inner">
            <div class="testing-copy" data-reveal>
              <p class="eyebrow">Testing v2</p>
              <h2 id="testing-title">Make failure cheap enough to explore.</h2>
              <p><code>TestContext</code> and <code>AssertionRecorder</code> publish requirement-linked receipts with stable assertions, source references, repair hints, causal identifiers, and exact replay commands.</p>
              <p><code>VirtualWorld</code> exercises distributed failure without touching production.</p>
            </div>
            <div class="fault-table" data-reveal style={{ "--reveal-delay": "80ms" }} role="table" aria-label="Deterministic fault exploration">
              <div class="fault-row fault-head" role="row"><span>Boundary</span><span>Explore</span><span>Evidence</span></div>
              {faultRows.map(([boundary, explore, evidence]) => (
                <div class="fault-row" role="row"><strong>{boundary}</strong><span>{explore}</span><code>{evidence}</code></div>
              ))}
            </div>
          </div>
        </section>

        <section class="deep-section" aria-labelledby="handoff-title">
          <div class="deep-editorial-heading" data-reveal>
            <p class="eyebrow">Harnesses are replaceable</p>
            <h2 id="handoff-title">The evidence survives the agent session.</h2>
            <p>A provider-neutral handoff carries objective, requirements, acceptance state, bounded artifacts, causal IDs, replay commands, capability maturity, and next actions between Codex, Claude Code, Gemini, CI, and humans.</p>
          </div>
          <div class="handoff-contract" data-reveal style={{ "--reveal-delay": "70ms" }}>
            <span><Bot size={20} /><strong>Agent</strong><small>Proposes and verifies</small></span>
            <ArrowRight size={17} />
            <span><GitBranch size={20} /><strong>Receipt</strong><small>Bounded causal evidence</small></span>
            <ArrowRight size={17} />
            <span><TimerReset size={20} /><strong>Replay</strong><small>Same seed and bounds</small></span>
            <ArrowRight size={17} />
            <span><ShieldCheck size={20} /><strong>Human</strong><small>Approves exact authority</small></span>
          </div>
        </section>

        <section class="evidence-honesty" aria-labelledby="honesty-title">
          <div data-reveal>
            <p class="eyebrow">Proof includes its limits</p>
            <h2 id="honesty-title">Incomplete evidence must look incomplete.</h2>
            <p>ZigEffect discloses when events were dropped, sampled, or truncated; when exploration bounds were exhausted; and whether an adapter is a deterministic model, local development tool, production candidate, or production verified.</p>
          </div>
          <ul data-reveal style={{ "--reveal-delay": "80ms" }}>
            <li><Check size={15} /> No unsupported case becomes a pass</li>
            <li><Check size={15} /> No secret enters a handoff receipt</li>
            <li><Check size={15} /> No maturity claim outruns its evidence</li>
          </ul>
        </section>

        <section class="deep-cta" aria-labelledby="effect-cta-title">
          <div data-reveal><p class="eyebrow">ZigEffect is the runtime. Ziac is the cloud system.</p><h2 id="effect-cta-title">Watch agents use both.</h2></div>
          <a class="button button-primary" href="/how-it-works" data-reveal style={{ "--reveal-delay": "80ms" }}>See how Ziac works <ArrowRight size={18} /></a>
        </section>
      </main>

      <MarketingFooter message="Typed execution. Causal evidence. Agent-ready systems." />
    </div>
  );
}
