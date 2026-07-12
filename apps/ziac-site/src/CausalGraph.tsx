import Activity from "lucide-solid/icons/activity";
import ArrowRight from "lucide-solid/icons/arrow-right";
import Bot from "lucide-solid/icons/bot";
import Braces from "lucide-solid/icons/braces";
import Check from "lucide-solid/icons/check";
import Cloud from "lucide-solid/icons/cloud";
import GitBranch from "lucide-solid/icons/git-branch";
import Network from "lucide-solid/icons/network";
import Search from "lucide-solid/icons/search";
import ShieldCheck from "lucide-solid/icons/shield-check";
import TimerReset from "lucide-solid/icons/timer-reset";
import Workflow from "lucide-solid/icons/workflow";
import { onCleanup, onMount } from "solid-js";
import { MarketingFooter, MarketingHeader } from "./MarketingChrome";

const lineage = [
  ["01", "Objective", "Ship a low-latency global API"],
  ["02", "Requirement", "Nearest healthy region with EU write locality"],
  ["03", "Agent proposal", "Six Cloud Run regions and one global entry"],
  ["04", "Comptime proof", "Env, bindings, scope, providers, and outputs valid"],
  ["05", "Saved plan", "Exact resource actions sealed by plan digest"],
  ["06", "Provider RPC", "Google request IDs and long-running operations linked"],
  ["07", "Cloud Run revision", "New images become ready with zero traffic"],
  ["08", "Traffic and health", "Guarded shift reaches every healthy region"],
  ["09", "Verified handoff", "Acceptance evidence and exact replay are redacted"],
] as const;

const agentMoves = [
  {
    icon: Search,
    label: "Orient",
    command: "graph findings --requirement req-global",
    body: "Start from the requirement, not a wall of terminal output. Find the events, resources, assertions, and unresolved findings attached to it.",
  },
  {
    icon: GitBranch,
    label: "Trace",
    command: "graph cause event-42",
    body: "Walk backwards to the decision, provider call, effect, or binding that caused a failure, then use graph children to inspect every consequence.",
  },
  {
    icon: Workflow,
    label: "Propose",
    command: "semantic diff plan-global-api",
    body: "Compare meaning rather than noisy provider JSON, test a bounded counterfactual, and propose the smallest repair against the saved plan.",
  },
  {
    icon: ShieldCheck,
    label: "Verify",
    command: "ziac handoff --redacted",
    body: "Run requirement-linked assertions, preserve the exact replay command, and return a bounded handoff that a human or another harness can verify.",
  },
] as const;

const proofRows = [
  ["Intent", "Objective and requirement IDs", "What the user asked the agent to preserve"],
  ["Decision", "Agent proposal and parent causal IDs", "Why this topology and repair were selected"],
  ["Program", "Source references and comptime diagnostics", "Which application contract was compiled"],
  ["Infrastructure", "Saved plan digest and ownership graph", "The exact actions the human authorised"],
  ["Provider", "RPC request IDs, LROs, revisions, and conditions", "What Google Cloud accepted and reconciled"],
  ["Acceptance", "Assertions, health facts, and replay command", "Why the outcome satisfies the requirement"],
] as const;

export function CausalGraph() {
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
    <div class="site-shell deep-page causal-graph-page">
      <MarketingHeader current="causal-graph" />

      <main>
        <section class="deep-hero causal-graph-hero" aria-labelledby="causal-hero-title">
          <img class="effect-hero-image causal-hero-image" src="/ziac-operations.png" alt="Ziac Operations tracing an agent diagnosis and global Cloud Run rollout through causal deployment events." />
          <div class="deep-hero-copy">
            <p class="eyebrow">The verification layer for agent-built infrastructure</p>
            <h1 id="causal-hero-title">Causal proof, not agent confidence.</h1>
            <p>Ziac and ZigEffect connect intent, agent decisions, application effects, infrastructure plans, Google provider operations, rollout health, and human acceptance in one queryable lineage.</p>
            <div class="hero-actions">
              <a class="button button-primary" href="#deployment-lineage"><GitBranch size={18} /> Follow one deployment</a>
              <a class="button button-secondary" href="/how-it-works">See the agent workflow <ArrowRight size={18} /></a>
            </div>
          </div>
        </section>

        <div class="deep-proof-strip" aria-label="Causal proof stages">
          <span><Bot size={17} /><strong>Intent and decision</strong></span>
          <span><Braces size={17} /><strong>Comptime contract</strong></span>
          <span><Cloud size={17} /><strong>Provider reality</strong></span>
          <span><ShieldCheck size={17} /><strong>Verified outcome</strong></span>
        </div>

        <section class="deep-section" aria-labelledby="two-graphs-title">
          <div class="deep-editorial-heading" data-reveal>
            <p class="eyebrow">Runtime truth meets cloud truth</p>
            <h2 id="two-graphs-title">Two graphs. One lineage.</h2>
            <p>ZigEffect makes program execution causally observable. Ziac applies the same semantic vocabulary to infrastructure ownership, planning, provider reconciliation, and deployment acceptance.</p>
          </div>

          <div class="causal-dual" data-reveal style={{ "--reveal-delay": "70ms" }}>
            <article>
              <div class="causal-dual-heading"><Activity size={22} /><span><small>Application execution</small><strong>ZigEffect runtime graph</strong></span></div>
              <p>Typed effects, services, scopes, fibers, retries, resources, structured failures, findings, and assertions retain cause and consequence.</p>
              <div class="causal-fact-list"><span>effect.started</span><span>service.acquired</span><span>retry.scheduled</span><span>assertion.recorded</span></div>
            </article>
            <div class="causal-shared-spine" aria-label="Shared stable causal identifiers">
              <GitBranch size={19} /><strong>Stable causal IDs</strong><small>Parent relationships connect application behavior to infrastructure evidence.</small>
            </div>
            <article>
              <div class="causal-dual-heading"><Network size={22} /><span><small>Cloud reconciliation</small><strong>Ziac infrastructure graph</strong></span></div>
              <p>Resources, bindings, ownership, plan identity, Google RPCs, long-running operations, revisions, traffic, conditions, and health remain queryable.</p>
              <div class="causal-fact-list"><span>plan.saved</span><span>rpc.started</span><span>revision.ready</span><span>traffic.verified</span></div>
            </article>
          </div>
        </section>

        <section class="lineage-band" id="deployment-lineage" aria-labelledby="lineage-title">
          <div class="lineage-inner">
            <div class="deep-editorial-heading" data-reveal>
              <p class="eyebrow">A global deployment is one connected argument</p>
              <h2 id="lineage-title">From “ship it” to evidence it is safe.</h2>
              <p>Each stage adds typed facts to the lineage. The agent can move quickly because it does not have to rediscover which decision produced which provider action or runtime result.</p>
            </div>
            <ol class="causal-lineage" data-reveal style={{ "--reveal-delay": "70ms" }}>
              {lineage.map(([index, title, body]) => (
                <li>
                  <span>{index}</span>
                  <div><strong>{title}</strong><p>{body}</p></div>
                </li>
              ))}
            </ol>
          </div>
        </section>

        <section class="agent-proof-section" aria-labelledby="agent-proof-title">
          <div class="agent-proof-inner">
            <div class="deep-editorial-heading" data-reveal>
              <p class="eyebrow">How specialist agents use it</p>
              <h2 id="agent-proof-title">Query, repair, replay, verify.</h2>
              <p>The causal graph is an operating interface for any harness, not a transcript tied to one model vendor. Codex, Claude Code, Gemini, CI, and a human reviewer can all pick up the same evidence.</p>
            </div>

            <div class="agent-query-grid" data-reveal style={{ "--reveal-delay": "70ms" }}>
              {agentMoves.map((move) => (
                <article>
                  <div><move.icon size={20} /><strong>{move.label}</strong></div>
                  <code>{move.command}</code>
                  <p>{move.body}</p>
                </article>
              ))}
            </div>

            <figure class="operations-frame causal-operations-frame" data-reveal style={{ "--reveal-delay": "90ms" }}>
              <div class="capture-bar" aria-hidden="true"><GitBranch size={16} /><span>Requirement req-global-api</span><span class="capture-live"><i /> Queryable</span></div>
              <img src="/ziac-operations.png" alt="Ziac Operations showing the agent session, causal timeline, provider events, rollout stages, and selected infrastructure resource." loading="lazy" />
            </figure>
          </div>
        </section>

        <section class="deep-section" aria-labelledby="proof-contract-title">
          <div class="deep-editorial-heading" data-reveal>
            <p class="eyebrow">What makes it proof</p>
            <h2 id="proof-contract-title">A claim must point to the facts that support it.</h2>
            <p>“Deployment succeeded” is only useful when it resolves to the authorised plan, provider result, health conditions, requirement-linked assertions, and the bounds under which those facts were collected.</p>
          </div>
          <div class="proof-contract-table" role="table" aria-label="Causal proof contract" data-reveal style={{ "--reveal-delay": "70ms" }}>
            <div class="proof-contract-row proof-contract-head" role="row"><span role="columnheader">Layer</span><span role="columnheader">Attached evidence</span><span role="columnheader">Question answered</span></div>
            {proofRows.map(([layer, evidence, question]) => (
              <div class="proof-contract-row" role="row"><strong role="rowheader">{layer}</strong><code role="cell">{evidence}</code><span role="cell">{question}</span></div>
            ))}
          </div>
        </section>

        <section class="evidence-honesty causal-honesty" aria-labelledby="causal-honesty-title">
          <div data-reveal>
            <p class="eyebrow">Proof includes its limits</p>
            <h2 id="causal-honesty-title">Missing evidence stays visible.</h2>
            <p>If events were dropped, sampled, or truncated, the receipt says so. Unsupported cases and exhausted exploration bounds cannot become a pass, and redacted handoffs disclose their evidence and capability maturity.</p>
          </div>
          <ul data-reveal style={{ "--reveal-delay": "80ms" }}>
            <li><Check size={15} /> Stable IDs preserve lineage across tools</li>
            <li><Check size={15} /> The plan digest fixes the authorised actions</li>
            <li><Check size={15} /> Exact replay preserves seed and bounds</li>
            <li><Check size={15} /> Humans retain deployment authority</li>
          </ul>
        </section>

        <section class="deep-cta" aria-labelledby="causal-cta-title">
          <div data-reveal><p class="eyebrow">Agents build. Humans verify.</p><h2 id="causal-cta-title">See the full development loop.</h2></div>
          <a class="button button-primary" href="/how-it-works" data-reveal style={{ "--reveal-delay": "80ms" }}>How Ziac works <ArrowRight size={18} /></a>
        </section>
      </main>

      <MarketingFooter message="Every decision connected to the evidence that proves it." />
    </div>
  );
}
