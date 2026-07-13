import Activity from "lucide-solid/icons/activity";
import ArrowRight from "lucide-solid/icons/arrow-right";
import Bot from "lucide-solid/icons/bot";
import BookOpen from "lucide-solid/icons/book-open";
import Boxes from "lucide-solid/icons/boxes";
import Braces from "lucide-solid/icons/braces";
import Check from "lucide-solid/icons/check";
import Cloud from "lucide-solid/icons/cloud";
import Database from "lucide-solid/icons/database";
import Eye from "lucide-solid/icons/eye";
import FileCode2 from "lucide-solid/icons/file-code-2";
import GitBranch from "lucide-solid/icons/git-branch";
import Globe2 from "lucide-solid/icons/earth";
import LockKeyhole from "lucide-solid/icons/lock-keyhole";
import Network from "lucide-solid/icons/network";
import Rocket from "lucide-solid/icons/rocket";
import Search from "lucide-solid/icons/search";
import ShieldCheck from "lucide-solid/icons/shield-check";
import SquareTerminal from "lucide-solid/icons/square-terminal";
import { createSignal, onCleanup, onMount, Show } from "solid-js";
import { HeroTopology } from "./HeroTopology";
import { MarketingFooter, MarketingHeader } from "./MarketingChrome";

type HarnessId = "codex" | "claude" | "gemini";

interface Harness {
  readonly id: HarnessId;
  readonly name: string;
  readonly command: string;
  readonly adapter: string;
  readonly summary: string;
  readonly transcript: readonly string[];
}

const harnesses: readonly Harness[] = [
  {
    id: "codex",
    name: "Codex",
    command: "codex",
    adapter: ".agents/skills/ziac/SKILL.md",
    summary: "Codex reads the project contract, invokes bounded Ziac tools, and returns evidence-backed code and plans.",
    transcript: [
      "Read ziac.project.json and App.Env",
      "Select gcp-global architecture skill",
      "Compile graph and query missing IAM",
      "Propose saved plan for human review",
    ],
  },
  {
    id: "claude",
    name: "Claude Code",
    command: "claude",
    adapter: ".claude/skills/ziac/SKILL.md",
    summary: "Claude Code receives the same skills, graph vocabulary, safety limits, and exact saved-plan workflow.",
    transcript: [
      "Load Ziac and Zig project guidance",
      "Inspect observed GCP dependencies",
      "Generate global Cloud Run declaration",
      "Verify compile and scenario evidence",
    ],
  },
  {
    id: "gemini",
    name: "Gemini CLI",
    command: "gemini",
    adapter: ".gemini/skills/ziac/SKILL.md",
    summary: "Gemini CLI drives the same MCP kernel and dashboard model without receiving broader infrastructure authority.",
    transcript: [
      "Orient against the current estate",
      "Compare regional topology options",
      "Simulate rollout and failover",
      "Hand off a redacted causal receipt",
    ],
  },
] as const;

const controlLoop = [
  ["01", "Intent", "Describe the backend, users, locality, data, and constraints."],
  ["02", "Compile", "Prove App.Env, bindings, scope, provider support, and graph shape."],
  ["03", "Preflight", "Check APIs, IAM, quotas, billing, policy, regions, and VPC boundaries."],
  ["04", "Simulate", "Run deterministic rollout, failure, cost, and recovery scenarios."],
  ["05", "Approve", "Bind an exact plan digest to a capability and human decision."],
  ["06", "Deploy", "Build immutable Zig images and assemble global infrastructure."],
  ["07", "Observe", "Stream operations, health, traffic, cost, and causal evidence."],
  ["08", "Diagnose", "Correlate revisions, IAM, secrets, network paths, and database locality."],
  ["09", "Verify", "Close only when requirements and runtime evidence agree."],
] as const;

const generatedFiles = [
  ["ziac.project.json", "Requirements, environments, budgets, authority, and scenarios"],
  ["build.zig.zon", "A relocatable dependency on the installed Ziac package"],
  ["src/main.zig", "A production-ready Zig HTTP service and typed App.Env"],
  ["ziac.stack.zig", "Global Cloud Run, load balancing, IAM, DNS, and data wiring"],
  [".agents/ · .claude/ · .gemini/", "Project-aware skills and GCP research agents for every harness"],
  [".mcp.json", "Bounded Ziac tools with explicit read, plan, verify, and apply authority"],
] as const;

export function HowItWorks() {
  const [activeHarnessId, setActiveHarnessId] = createSignal<HarnessId>("codex");
  const activeHarness = () => harnesses.find((harness) => harness.id === activeHarnessId())!;

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
    <div class="site-shell how-page">
      <MarketingHeader current="how-it-works" primaryHref="#scaffold" />

      <main>
        <section class="how-hero" aria-labelledby="how-hero-title">
          <div class="how-hero-visual"><HeroTopology /></div>
          <div class="how-hero-copy">
            <p class="eyebrow">How Ziac works</p>
            <h1 id="how-hero-title">Agents build. Humans verify. <span>Zig ships globally.</span></h1>
            <p>Ziac turns a Zig backend, a GCP estate, and a deployment intent into one compiled graph that any agent harness can understand, operate, and explain.</p>
            <div class="hero-actions">
              <a class="button button-primary" href="#scaffold"><SquareTerminal size={18} /> Start with the CLI</a>
              <a class="button button-secondary" href="#control-loop">Follow the control loop <ArrowRight size={18} /></a>
            </div>
          </div>
        </section>

        <div class="how-proof-strip" aria-label="Ziac operating model">
          <span><Braces size={17} /><strong>One typed graph</strong></span>
          <span><Bot size={17} /><strong>Any agent harness</strong></span>
          <span><Eye size={17} /><strong>One visual truth</strong></span>
          <span><Globe2 size={17} /><strong>Global by default</strong></span>
        </div>

        <section class="how-section scaffold-section" id="scaffold" aria-labelledby="scaffold-title">
          <div class="how-section-heading" data-reveal>
            <p class="eyebrow">01 / Scaffold</p>
            <h2 id="scaffold-title">A project that teaches every agent how to build it.</h2>
            <p><code>ziac init</code> creates more than source files. It packages infrastructure intent, local documentation, harness-native skills, bounded MCP tools, and the dashboard contract beside the application. Everything resolves through the installed package, so the project remains portable without a Ziac source checkout.</p>
          </div>

          <div class="scaffold-layout">
            <div class="cli-window" data-reveal style={{ "--reveal-delay": "60ms" }}>
              <div class="tool-window-header">
                <span><SquareTerminal size={15} /> Private beta CLI flow</span>
                <span>global-api</span>
              </div>
              <pre><code>
                <span class="cli-line"><span class="prompt">$</span> mkdir global-api && cd global-api</span>
                <span class="cli-line"><span class="prompt">$</span> git init</span>
                <span class="cli-line"><span class="prompt">$</span> ziac init --yes</span>
                <span class="cli-line cli-line-spacer" aria-hidden="true"> </span>
                <span class="cli-line"><span class="success">created</span> Zig HTTP service + typed App.Env</span>
                <span class="cli-line"><span class="success">created</span> global Cloud Run architecture</span>
                <span class="cli-line"><span class="success">created</span> Codex, Claude Code, and Gemini skills</span>
                <span class="cli-line"><span class="success">created</span> GCP Developer Researcher + docs</span>
                <span class="cli-line"><span class="success">created</span> local Ziac MCP + dashboard contract</span>
                <span class="cli-line cli-line-spacer" aria-hidden="true"> </span>
                <span class="cli-line"><span class="prompt">$</span> export DEVELOPERKNOWLEDGE_API_KEY=...</span>
                <span class="cli-line"><span class="prompt">$</span> zig build test</span>
                <span class="cli-line"><span class="prompt">$</span> ziac dashboard</span>
                <span class="cli-line"><span class="prompt">$</span> ziac dev --watch</span>
              </code></pre>
            </div>

            <div class="generated-manifest" data-reveal style={{ "--reveal-delay": "110ms" }}>
              <div class="manifest-heading"><span>Generated project contract</span><strong>6 boundaries</strong></div>
              {generatedFiles.map(([path, purpose]) => (
                <div class="manifest-row">
                  <span><FileCode2 size={16} /><code>{path}</code></span>
                  <p>{purpose}</p>
                </div>
              ))}
            </div>
          </div>

          <div class="kit-boundary" data-reveal aria-label="Installed and user-provided development boundaries">
            <div><span>Bundled by Ziac</span><p>Compiler and CLI, package sources, local docs, dashboard assets, Ziac MCP server, skills, and researcher agents.</p></div>
            <div><span>You provide</span><p>The Zig compiler, your preferred agent harness, Google application credentials, and <code>DEVELOPERKNOWLEDGE_API_KEY</code> for current documentation research.</p></div>
          </div>
        </section>

        <section class="harness-band" aria-labelledby="harness-title">
          <div class="harness-inner">
            <div class="how-section-heading" data-reveal>
              <p class="eyebrow">02 / Choose your harness</p>
              <h2 id="harness-title">One kernel. Any harness.</h2>
              <p>Use the agent environment your team already trusts. Ziac supplies the domain depth and keeps infrastructure authority in its own governed kernel.</p>
            </div>

            <div class="harness-workspace" data-reveal style={{ "--reveal-delay": "70ms" }}>
              <div class="harness-tabs" role="tablist" aria-label="Supported agent harnesses">
                {harnesses.map((harness) => (
                  <button
                    id={`harness-tab-${harness.id}`}
                    type="button"
                    role="tab"
                    aria-selected={activeHarnessId() === harness.id}
                    aria-controls={`harness-panel-${harness.id}`}
                    onClick={() => setActiveHarnessId(harness.id)}
                  >
                    {harness.name}
                  </button>
                ))}
              </div>

              <Show when={activeHarness()} keyed>
                {(harness) => (
                  <div class="harness-panel" id={`harness-panel-${harness.id}`} role="tabpanel" aria-labelledby={`harness-tab-${harness.id}`}>
                    <div class="harness-command">
                      <span>Launch</span><code>$ {harness.command}</code>
                      <span>Adapter</span><code>{harness.adapter}</code>
                    </div>
                    <div class="harness-summary"><Bot size={24} /><p>{harness.summary}</p></div>
                    <ol class="harness-transcript">
                      {harness.transcript.map((line, index) => <li><span>{index + 1}</span><p>{line}</p><Check size={14} /></li>)}
                    </ol>
                  </div>
                )}
              </Show>
            </div>

            <div class="skill-strip" aria-label="Bundled specialist skills">
              <article><Cloud size={21} /><div><strong>GCP architect</strong><p>Cloud Run, global load balancing, IAM, APIs, quotas, VPC, DNS, billing, and Google RPC semantics.</p></div></article>
              <article><Braces size={21} /><div><strong>Ziac operator</strong><p>Typed graphs, saved plans, capabilities, scenarios, causal evidence, state, rollout, and recovery.</p></div></article>
              <article><Rocket size={21} /><div><strong>Zig runtime engineer</strong><p>App.Env, builds, immutable OCI images, performance, health checks, tests, and production diagnostics.</p></div></article>
              <article><BookOpen size={21} /><div><strong>GCP Developer Researcher</strong><p>Searches current official Google documentation, compares it with the shipped Ziac baseline, and returns source-backed findings without mutation authority.</p></div></article>
            </div>
          </div>
        </section>

        <section class="how-section control-section" id="control-loop" aria-labelledby="control-title">
          <div class="how-section-heading" data-reveal>
            <p class="eyebrow">03 / Govern the work</p>
            <h2 id="control-title">Autonomy with a hard edge.</h2>
            <p>Agents can inspect, plan, simulate, diagnose, propose, and verify. Mutation requires an explicit capability; deployment accepts only the exact approved saved-plan digest.</p>
          </div>
          <ol class="control-loop" data-reveal style={{ "--reveal-delay": "70ms" }}>
            {controlLoop.map(([number, title, description]) => (
              <li><span>{number}</span><strong>{title}</strong><p>{description}</p></li>
            ))}
          </ol>
          <div class="authority-line" data-reveal>
            <span><Search size={17} /> read</span>
            <span><GitBranch size={17} /> plan</span>
            <span><ShieldCheck size={17} /> verify</span>
            <span class="authority-apply"><LockKeyhole size={17} /> apply exact digest</span>
          </div>
        </section>

        <section class="dashboard-band" aria-labelledby="dashboard-title">
          <div class="dashboard-inner">
            <div class="dashboard-copy" data-reveal>
              <p class="eyebrow">04 / Watch it think</p>
              <h2 id="dashboard-title">The agent drives. You see everything.</h2>
              <p>The harness and dashboard consume the same graph and causal evidence. Watch infrastructure assemble, inspect each decision, follow rollout health, and see automatic diagnosis attach itself to the resource and edge that failed.</p>
              <ul>
                <li><Activity size={17} /><span>Live build, plan, revision, traffic, and verification events</span></li>
                <li><Eye size={17} /><span>Human-readable reasons behind every generated resource</span></li>
                <li><Network size={17} /><span>Graph-aware automatic diagnosis across IAM, secrets, networking, and data</span></li>
                <li><ShieldCheck size={17} /><span>Humans monitor, approve, and verify rather than reconstructing terminal history</span></li>
              </ul>
            </div>
            <figure class="operations-frame dashboard-proof" data-reveal style={{ "--reveal-delay": "90ms" }}>
              <div class="capture-bar" aria-hidden="true"><Activity size={16} /><span>Agent operations</span><span class="capture-live"><i /> Live</span></div>
              <img src="/ziac-operations.png" alt="Ziac dashboard showing an agent session, causal infrastructure events, deployment progress, and resource evidence." loading="lazy" />
            </figure>
          </div>
        </section>

        <section class="how-section global-section" aria-labelledby="global-title">
          <div class="how-section-heading" data-reveal>
            <p class="eyebrow">05 / Provision globally</p>
            <h2 id="global-title">Global is a component, not a six-month platform project.</h2>
            <p>Ziac compiles one Zig service into immutable build infrastructure, regional Cloud Run capacity, a Premium global load balancer, nearest healthy region routing, TLS, DNS, IAM, and CockroachDB locality.</p>
          </div>
          <div class="global-canvas" data-reveal style={{ "--reveal-delay": "80ms" }}><HeroTopology /></div>
          <div class="global-sequence" aria-label="Global provisioning sequence">
            <span><Braces size={18} /><strong>Zig source</strong></span><ArrowRight size={16} />
            <span><Boxes size={18} /><strong>Artifact Registry</strong></span><ArrowRight size={16} />
            <span><Cloud size={18} /><strong>Cloud Run regions</strong></span><ArrowRight size={16} />
            <span><Globe2 size={18} /><strong>Global HTTPS</strong></span><ArrowRight size={16} />
            <span><Database size={18} /><strong>Local data path</strong></span>
          </div>
        </section>

        <section class="estate-band" aria-labelledby="estate-title">
          <div class="estate-inner">
            <div class="how-section-heading" data-reveal>
              <p class="eyebrow">06 / See the whole estate</p>
              <h2 id="estate-title">Existing and new infrastructure share a canvas, not ownership.</h2>
              <p>Ziac can explain the complete system without pretending it owns everything. Cross-boundary dependencies stay visible, while lifecycle and adoption remain explicit.</p>
            </div>
            <div class="ownership-table" data-reveal style={{ "--reveal-delay": "70ms" }}>
              <article><span class="ownership-mark observed"><Search size={19} /></span><div><strong>Observed GCP</strong><p>Read-only resources discovered from the connected project, with source and observation provenance.</p><small>Never mutated by a Ziac deploy</small></div></article>
              <article><span class="ownership-mark managed"><Boxes size={19} /></span><div><strong>Managed by Ziac</strong><p>Resources compiled from Zig declarations, fully planned, deployed, refreshed, and protected by lifecycle policy.</p><small>Desired state and ownership are explicit</small></div></article>
              <article><span class="ownership-mark referenced"><GitBranch size={19} /></span><div><strong>Referenced, not owned</strong><p>Shared buckets, networks, secrets, or services used by the app without silently importing them into state.</p><small>Edges cross the boundary safely</small></div></article>
              <article><span class="ownership-mark third-party"><Database size={19} /></span><div><strong>Third-party account groups</strong><p>CockroachDB and future providers render outside the GCP account moat with their own regions and locality.</p><small>One topology, honest provider boundaries</small></div></article>
            </div>
          </div>
        </section>

        <section class="agent-manifesto" aria-labelledby="manifesto-title">
          <div data-reveal>
            <p class="eyebrow">The operating model changed</p>
            <h2 id="manifesto-title">SaaS isn't dead. It evolved.</h2>
            <p>Agents build first. Humans monitor, approve, and verify. As models become more capable, the software beneath them should become faster, more explicit, and easier to prove. That is why Ziac uses Zig, specializes in Google Cloud, and makes the causal graph the product.</p>
          </div>
          <a class="button button-primary" href="#scaffold" data-reveal style={{ "--reveal-delay": "80ms" }}>Build the first global service <ArrowRight size={18} /></a>
        </section>
      </main>

      <MarketingFooter message="Agent-built. Human-verified. Globally deployed." />
    </div>
  );
}
