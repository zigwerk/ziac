import ArrowRight from "lucide-solid/icons/arrow-right";
import Binary from "lucide-solid/icons/binary";
import Bot from "lucide-solid/icons/bot";
import BookOpen from "lucide-solid/icons/book-open";
import Boxes from "lucide-solid/icons/boxes";
import Braces from "lucide-solid/icons/braces";
import Check from "lucide-solid/icons/check";
import ChevronDown from "lucide-solid/icons/chevron-down";
import Cloud from "lucide-solid/icons/cloud";
import Database from "lucide-solid/icons/database";
import Gauge from "lucide-solid/icons/gauge";
import GitBranch from "lucide-solid/icons/git-branch";
import Globe2 from "lucide-solid/icons/earth";
import LockKeyhole from "lucide-solid/icons/lock-keyhole";
import Network from "lucide-solid/icons/network";
import Rocket from "lucide-solid/icons/rocket";
import Search from "lucide-solid/icons/search";
import ShieldCheck from "lucide-solid/icons/shield-check";
import SquareTerminal from "lucide-solid/icons/square-terminal";
import X from "lucide-solid/icons/x";
import { createEffect, createSignal, onCleanup, onMount, Show } from "solid-js";
import { HeroTopology } from "./HeroTopology";
import { MarketingFooter, MarketingHeader } from "./MarketingChrome";

type ComparisonKind = "contract" | "provider" | "global" | "agents" | "estate" | "evidence";

interface ComparisonRow {
  readonly kind: ComparisonKind;
  readonly title: string;
  readonly ziac: string;
  readonly pulumi: string;
  readonly terraform: string;
}

const comparisonRows: readonly ComparisonRow[] = [
  {
    kind: "contract",
    title: "App + infrastructure",
    ziac: "One comptime contract across App.Env, binding types, secrecy, output scope, and provider availability.",
    pulumi: "Strongly typed SDKs model resources; provider-created Outputs remain asynchronous deployment values.",
    terraform: "HCL, provider schemas, and checks validate configuration during validate, plan, or apply as values become known.",
  },
  {
    kind: "provider",
    title: "Provider-native GCP",
    ziac: "Google RPC and AIP semantics drive field masks, immutability, etags, long-running operations, and readiness.",
    pulumi: "A broad, multi-language SDK designed to provision across all major clouds.",
    terraform: "A broad declarative ecosystem built around HCL and cloud provider plugins.",
  },
  {
    kind: "global",
    title: "Global Cloud Run",
    ziac: "One ZigService component builds source, identity, regional services, NEGs, Premium global load balancing, TLS, and DNS.",
    pulumi: "Compose provider resources and reusable components in a supported general-purpose language.",
    terraform: "Compose provider resources or modules for each region and the global load-balancing graph.",
  },
  {
    kind: "agents",
    title: "Agent-native execution",
    ziac: "Specialist skills are capability-gated and share the same typed graph, causal facts, tests, and deployment evidence.",
    pulumi: "Automation API and Pulumi Cloud automate and operate the general-purpose deployment engine.",
    terraform: "CLI and HCP workflows expose plans and state for automation around the Terraform engine.",
  },
  {
    kind: "estate",
    title: "Observed before managed",
    ziac: "Scan an estate read-only, reference shared resources without ownership, and adopt only after a zero-change proof.",
    pulumi: "Import external resources into stack state and optionally generate matching source code.",
    terraform: "Import binds an existing remote object to a resource address in workspace state.",
  },
  {
    kind: "evidence",
    title: "Causal debugging",
    ziac: "Follow one causal chain from source and agent decision through provider RPC, revision, traffic, health, and rollback.",
    pulumi: "State, checkpoints, and deployment history record infrastructure engine execution.",
    terraform: "Plan, state, provider diagnostics, and cloud logs describe different parts of execution.",
  },
] as const;

type AgentKind = "architecture" | "gcp" | "policy" | "database" | "pricing" | "rollout";

interface AgentScenario {
  readonly id: string;
  readonly label: string;
  readonly intent: string;
  readonly proof: string;
  readonly agents: readonly {
    readonly kind: AgentKind;
    readonly name: string;
    readonly skill: string;
    readonly result: string;
  }[];
  readonly facts: readonly string[];
}

const agentScenarios: readonly AgentScenario[] = [
  {
    id: "global-api",
    label: "Global API",
    intent: "Deploy this Zig API close to every user with one global endpoint.",
    proof: "Global Cloud Run plan ready",
    agents: [
      { kind: "architecture", name: "Topology agent", skill: "Global service architecture", result: "6 regions selected" },
      { kind: "gcp", name: "GCP agent", skill: "Cloud Run, HTTPS LB, IAM", result: "Provider graph valid" },
      { kind: "rollout", name: "Rollout agent", skill: "Build, canary, traffic shift", result: "Guardrails attached" },
    ],
    facts: ["Nearest healthy region routing", "Compile-time Env and binding proof", "Rollback path retained"],
  },
  {
    id: "residency",
    label: "Residency",
    intent: "Keep EU writes in-region while the API remains globally available.",
    proof: "Residency boundaries proved",
    agents: [
      { kind: "policy", name: "Policy agent", skill: "Residency and org policy", result: "EU boundary enforced" },
      { kind: "gcp", name: "IAM agent", skill: "Least-privilege identities", result: "Permissions complete" },
      { kind: "database", name: "Cockroach agent", skill: "Regional tables and failover", result: "Locality aligned" },
    ],
    facts: ["EU write path remains regional", "Cross-region reads declared", "Failover consequences visible"],
  },
  {
    id: "cost-aware",
    label: "Cost-aware rollout",
    intent: "Add global capacity without paying for idle regions we do not need.",
    proof: "Cost-aware rollout ready",
    agents: [
      { kind: "architecture", name: "Discovery agent", skill: "Observed estate and demand", result: "Existing fleet mapped" },
      { kind: "pricing", name: "Pricing agent", skill: "Regional SKU estimates", result: "Options compared" },
      { kind: "rollout", name: "Capacity agent", skill: "Min instances and scaling", result: "Budget guard set" },
    ],
    facts: ["Observed and Ziac-owned cost separated", "Idle capacity avoided", "Plan delta remains reviewable"],
  },
] as const;

function agentIcon(kind: AgentKind) {
  switch (kind) {
    case "architecture": return <Network size={19} />;
    case "gcp": return <Cloud size={19} />;
    case "policy": return <LockKeyhole size={19} />;
    case "database": return <Database size={19} />;
    case "pricing": return <Gauge size={19} />;
    case "rollout": return <Rocket size={19} />;
  }
}

function comparisonIcon(kind: ComparisonKind) {
  switch (kind) {
    case "contract": return <Braces size={19} />;
    case "provider": return <Cloud size={19} />;
    case "global": return <Globe2 size={19} />;
    case "agents": return <Bot size={19} />;
    case "estate": return <Search size={19} />;
    case "evidence": return <GitBranch size={19} />;
  }
}

export function ProductLanding() {
  const [dialogOpen, setDialogOpen] = createSignal(false);
  const [joined, setJoined] = createSignal(false);
  const [activeScenarioId, setActiveScenarioId] = createSignal(agentScenarios[0]!.id);
  const activeScenario = () => agentScenarios.find((scenario) => scenario.id === activeScenarioId())!;
  let dialog!: HTMLDivElement;

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
      { threshold: 0.14, rootMargin: "0px 0px -6%" },
    );
    revealTargets.forEach((target) => observer.observe(target));
    onCleanup(() => observer.disconnect());
  });

  createEffect(() => {
    if (!dialogOpen()) return;
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    queueMicrotask(() => dialog?.querySelector<HTMLInputElement>("input")?.focus());
    const onKeydown = (event: KeyboardEvent) => {
      if (event.key === "Escape") setDialogOpen(false);
    };
    window.addEventListener("keydown", onKeydown);
    onCleanup(() => {
      document.body.style.overflow = previousOverflow;
      window.removeEventListener("keydown", onKeydown);
    });
  });

  const openDialog = () => {
    setJoined(false);
    setDialogOpen(true);
  };

  const submitBeta = (event: SubmitEvent) => {
    event.preventDefault();
    const form = event.currentTarget as HTMLFormElement;
    if (!form.reportValidity()) return;
    setJoined(true);
  };

  return (
    <div class="site-shell product-page">
      <MarketingHeader current="product" onSignIn={openDialog} onPrimaryAction={openDialog} primaryLabel="Get started" />

      <main id="top">
        <section class="hero" aria-labelledby="hero-title">
          <div class="hero-copy">
            <p class="eyebrow hero-eyebrow">Google Cloud first. Agent-native infrastructure at Zig speed.</p>
            <h1 id="hero-title">Your <span class="hero-cloud">Google Cloud</span> estate, <span class="hero-compiled">compiled.</span></h1>
            <p class="hero-summary">See what exists. Then let specialist agents compile complex global infrastructure with <a class="hero-inline-link" href="/causal-graph">causal proof</a>.</p>
            <div class="hero-actions">
              <button class="button button-primary" type="button" onClick={openDialog}>
                <Cloud size={18} /> Connect a GCP project
              </button>
              <a class="button button-secondary" href="#operations">
                Explore the canvas <ArrowRight size={18} />
              </a>
            </div>
            <div class="hero-brand-bridge" aria-label="From Google Cloud infrastructure through Ziac compile-time validation to a Zig service">
              <span class="bridge-cloud"><Cloud size={14} /> GCP graph</span>
              <ArrowRight size={13} />
              <span class="bridge-compiler"><Braces size={14} /> Ziac comptime</span>
              <ArrowRight size={13} />
              <span class="bridge-zig"><Binary size={14} /> Zig service</span>
            </div>
            <p class="hero-note"><Check size={15} /> From local Zig backend to truly global apps. Nothing changes without a proved plan.</p>
          </div>

          <div class="hero-visual" aria-hidden="false"><HeroTopology /></div>

          <a class="scroll-cue" href="#agents" aria-label="See how Ziac agents work">
            <span>See how it works</span>
            <ChevronDown size={17} />
          </a>
        </section>

        <section class="agent-section" id="agents" aria-labelledby="agents-title">
          <div class="agent-intro" data-reveal>
            <p class="eyebrow">Specialist agents. One causal graph.</p>
            <h2 id="agents-title">An infrastructure team that compiles.</h2>
            <p>Ziac gives agents dedicated skills for GCP architecture, IAM, pricing, Cloud Run rollout, and CockroachDB locality. They work in parallel against one typed graph, so speed still produces reviewable infrastructure code.</p>
            <ul class="agent-benefits">
              <li><Braces size={18} /><span>Generate idiomatic Ziac code from application intent</span></li>
              <li><GitBranch size={18} /><span>Attach every decision and output to causal evidence</span></li>
              <li><ShieldCheck size={18} /><span>Prove Env, bindings, permissions, and provider support at compile time</span></li>
            </ul>
          </div>

          <div class="agent-console" data-reveal style={{ "--reveal-delay": "100ms" }}>
            <div class="agent-console-header">
              <div><span><Bot size={15} /> Agent build</span><strong>global-api.ziac</strong></div>
              <span class="agent-live"><i /> specialists online</span>
            </div>

            <div class="agent-tabs" role="tablist" aria-label="Agent infrastructure scenarios">
              {agentScenarios.map((scenario) => (
                <button
                  id={`agent-tab-${scenario.id}`}
                  type="button"
                  role="tab"
                  aria-selected={activeScenarioId() === scenario.id}
                  aria-controls={`agent-panel-${scenario.id}`}
                  onClick={() => setActiveScenarioId(scenario.id)}
                >
                  {scenario.label}
                </button>
              ))}
            </div>

            <Show when={activeScenario()} keyed>
              {(scenario) => (
                <div class="agent-scenario" id={`agent-panel-${scenario.id}`} role="tabpanel" aria-labelledby={`agent-tab-${scenario.id}`}>
                  <div class="agent-intent"><span>Intent</span><p>{scenario.intent}</p></div>
                  <div class="agent-list" aria-label="Specialist agent results">
                    {scenario.agents.map((agent, index) => (
                      <div class="agent-row" style={{ "--agent-delay": `${index * 90}ms` }}>
                        <span class={`agent-icon agent-icon-${agent.kind}`}>{agentIcon(agent.kind)}</span>
                        <span class="agent-identity"><strong>{agent.name}</strong><small>{agent.skill}</small></span>
                        <span class="agent-result"><Check size={14} />{agent.result}</span>
                      </div>
                    ))}
                  </div>
                  <div class="causal-proof">
                    <div class="causal-proof-title"><span><GitBranch size={17} /> Causal proof</span><strong>{scenario.proof}</strong></div>
                    <div class="causal-facts">{scenario.facts.map((fact) => <span><Check size={13} />{fact}</span>)}</div>
                  </div>
                </div>
              )}
            </Show>
          </div>
        </section>

        <section class="agent-kit-section" id="agent-kit" aria-labelledby="agent-kit-title">
          <div class="agent-kit-copy" data-reveal>
            <p class="eyebrow">One install. Every agent equipped.</p>
            <h2 id="agent-kit-title">The development platform arrives with the CLI.</h2>
            <p>Install Ziac once, then scaffold a project with the local compiler, dashboard, Ziac MCP server, reference documentation, and harness-native skills needed to build it. The generated kit resolves through the project dependency, so agents do not need a Ziac source checkout beside your application.</p>
            <div class="agent-kit-principles" aria-label="Installed agent development kit principles">
              <span><Boxes size={18} /><strong>Relocatable by design</strong><small>Package sources, dashboard assets, and docs resolve from <code>build.zig.zon</code>.</small></span>
              <span><Bot size={18} /><strong>Harness-native</strong><small>Codex, Claude Code, and Gemini receive the same project-aware operating model.</small></span>
              <span><BookOpen size={18} /><strong>Current GCP research</strong><small>The GCP Developer Researcher compares the shipped baseline with official documentation.</small></span>
            </div>
            <a class="editorial-link" href="/how-it-works#scaffold">See what <code>ziac init</code> installs <ArrowRight size={16} /></a>
          </div>

          <div class="agent-kit-manifest" data-reveal style={{ "--reveal-delay": "90ms" }}>
            <div class="agent-kit-manifest-header">
              <span><SquareTerminal size={15} /><code>$ ziac init --yes</code></span>
              <strong><i /> local kit ready</strong>
            </div>
            <div class="agent-kit-manifest-row"><span><Braces size={17} /></span><div><code>ziac</code><small>CLI and infrastructure compiler</small></div><strong>bundled</strong></div>
            <div class="agent-kit-manifest-row"><span><GitBranch size={17} /></span><div><code>ziac-mcp</code><small>Ziac MCP server</small></div><strong>bundled</strong></div>
            <div class="agent-kit-manifest-row"><span><Network size={17} /></span><div><code>ziac-dashboard-host</code><small>Local visual control surface</small></div><strong>bundled</strong></div>
            <div class="agent-kit-manifest-row"><span><Bot size={17} /></span><div><code>.agents · .claude · .gemini</code><small>Harness-native skills and researcher agents</small></div><strong>generated</strong></div>
            <div class="agent-kit-manifest-row"><span><BookOpen size={17} /></span><div><code>gcp-developer-researcher</code><small>GCP Developer Researcher</small></div><strong>read only</strong></div>
            <div class="agent-kit-manifest-footer"><span>User-owned credential</span><code>DEVELOPERKNOWLEDGE_API_KEY</code></div>
          </div>
        </section>

        <section class="why-section" id="why-ziac" aria-labelledby="why-title">
          <div class="why-heading" data-reveal>
            <p class="eyebrow">Depth over breadth</p>
            <h2 id="why-title">Pulumi and Terraform are broad. Ziac goes deep.</h2>
            <p>Use general-purpose IaC when you need to describe almost any cloud. Use Ziac when the product is a Zig backend on GCP and you want the application, infrastructure, agents, deployment, and runtime evidence to share one contract.</p>
          </div>

          <div class="gcp-first-band" data-reveal style={{ "--reveal-delay": "60ms" }}>
            <div class="gcp-first-position">
              <p class="eyebrow">Google Cloud first</p>
              <h3>Google Cloud is not our third provider.</h3>
              <p>Too much cloud tooling begins AWS-first, expands to Azure, then asks Google Cloud teams to accept an adapter, delayed integrations, or generic diagrams. Ziac reverses that order.</p>
            </div>
            <div class="gcp-first-points">
              <article class="gcp-semantic"><span><Cloud size={20} /></span><div><strong>Google API semantics first</strong><p>Proto contracts, AIPs, field masks, etags, long-running operations, quotas, IAM, and readiness.</p></div></article>
              <article class="gcp-diagram"><span><Network size={20} /></span><div><strong>GCP-native infrastructure diagrams</strong><p>Projects, global VPC boundaries, regional slabs, Cloud Run, load balancers, IAM edges, cost, and health.</p></div></article>
              <article class="gcp-global"><span><Globe2 size={20} /></span><div><strong>Global Cloud Run primitives first</strong><p>Multi-region services, nearest healthy routing, Cockroach locality, rollout, and causal evidence are product primitives.</p></div></article>
            </div>
          </div>

          <div class="comparison-table" role="table" aria-label="Ziac compared with Pulumi and Terraform" data-reveal style={{ "--reveal-delay": "80ms" }}>
            <div class="comparison-header" role="row">
              <span role="columnheader">What matters</span><span role="columnheader">Ziac</span><span role="columnheader">Pulumi and Terraform</span>
            </div>
            {comparisonRows.map((row, index) => (
              <div class="comparison-row" role="row" style={{ "--comparison-delay": `${index * 45}ms` }}>
                <div class="comparison-topic" role="rowheader"><span>{comparisonIcon(row.kind)}</span><strong>{row.title}</strong></div>
                <div class="comparison-ziac" role="cell"><span>Ziac</span><p>{row.ziac}</p></div>
                <div class="comparison-incumbents" role="cell">
                  <div><strong>Pulumi</strong><p>{row.pulumi}</p></div>
                  <div><strong>Terraform</strong><p>{row.terraform}</p></div>
                </div>
              </div>
            ))}
          </div>

          <p class="comparison-note" data-reveal>
            Compared against documented default models for
            <a href="https://www.pulumi.com/docs/iac/concepts/inputs-outputs/" target="_blank" rel="noreferrer"> Pulumi Inputs and Outputs</a>,
            <a href="https://www.pulumi.com/docs/iac/concepts/automation-api/" target="_blank" rel="noreferrer"> Automation API</a>,
            <a href="https://developer.hashicorp.com/terraform/language/validate" target="_blank" rel="noreferrer"> Terraform validation</a>,
            <a href="https://developer.hashicorp.com/terraform/language/import" target="_blank" rel="noreferrer"> import</a>, and
            <a href="https://docs.cloud.google.com/run/docs/multiple-regions" target="_blank" rel="noreferrer"> Google Cloud multi-region Cloud Run</a>.
          </p>

          <div class="comptime-proof" data-reveal>
            <div class="comptime-code">
              <div class="comptime-code-header"><span><Braces size={15} /> app.zig</span><span>zig build</span></div>
              <pre><code>{`const App = struct {
    pub const Env = struct {
        database_url: ziac.binding.Secret([]const u8),
    };
};

const Bindings = struct {};
const Service = ziac.gcp.global.ZigService(
    App, Bindings, Providers,
);

`}<span class="compile-error">error: ZIAC100 missing app binding: database_url</span></code></pre>
            </div>
            <div class="comptime-explanation">
              <p class="eyebrow">The compiler owns the boundary</p>
              <h3>Compile. Diagnose. Repair. Verify.</h3>
              <p>Ziac and ZigEffect make this a high-speed agent feedback loop. A failure like this becomes typed causal evidence linked to the application and infrastructure contract. The agent repairs the exact boundary, re-runs only the affected graph and deterministic tests, and proves the change before preview or a provider RPC.</p>
              <div class="agent-compile-loop" aria-label="Agent compile feedback loop">
                <span><Bot size={16} /><strong>Agent edit</strong><small>Source + intent</small></span>
                <span><Braces size={16} /><strong>Compile</strong><small>Whole contract</small></span>
                <span><GitBranch size={16} /><strong>Diagnose</strong><small>Causal evidence</small></span>
                <span><Check size={16} /><strong>Targeted repair</strong><small>Exact boundary</small></span>
                <span><ShieldCheck size={16} /><strong>Verify</strong><small>Affected tests</small></span>
              </div>
              <ul>
                <li><Check size={15} /><span>Missing or extra bindings</span></li>
                <li><Check size={15} /><span>Public and secret mismatches</span></li>
                <li><Check size={15} /><span>Regional outputs wired into global scope</span></li>
                <li><Check size={15} /><span>Unavailable providers and unsupported values</span></li>
              </ul>
              <a class="editorial-link comptime-causal-link" href="/causal-graph">See how agents use causal proof <ArrowRight size={16} /></a>
            </div>
          </div>
        </section>

        <section class="operations-section" id="operations" aria-labelledby="operations-title">
          <div class="section-heading" data-reveal>
            <p class="eyebrow">Live architecture, not a static diagram</p>
            <h2 id="operations-title">Watch infrastructure assemble as agents work.</h2>
            <p>The canvas combines existing GCP resources with Ziac-managed infrastructure, then exposes ownership, routing, dependencies, and health while every proposed change is still reviewable.</p>
          </div>
          <figure class="operations-canvas" data-reveal style={{ "--reveal-delay": "90ms" }}>
            <div class="operations-canvas-bar">
              <span><Network size={16} /> Architecture canvas</span>
              <span class="operations-canvas-scope">GCP estate <ArrowRight size={13} /> <strong>Ziac + Existing</strong></span>
              <span class="capture-live"><i /> Live topology</span>
            </div>
            <div class="operations-canvas-view">
              <HeroTopology />
              <div class="canvas-resource-count"><Boxes size={15} /><strong>17 resources</strong><span>20 connections</span></div>
              <div class="canvas-legend" aria-label="Canvas resource ownership legend">
                <span><i class="legend-observed" />Observed</span>
                <span><i class="legend-managed" />Ziac managed</span>
                <span><i class="legend-external" />Third party</span>
              </div>
            </div>
            <figcaption class="operations-canvas-facts">
              <span><small>Ownership</small><strong>Observed + managed</strong></span>
              <span><small>Routing</small><strong>Nearest healthy region</strong></span>
              <span><small>Verification</small><strong>Causal proof attached</strong></span>
            </figcaption>
          </figure>
        </section>

        <section class="workflow-section" id="workflow" aria-labelledby="workflow-title">
          <div class="section-heading centered" data-reveal><p class="eyebrow">From intent to truly global</p><h2 id="workflow-title">Quality infrastructure code at agent speed.</h2></div>
          <div class="workflow-grid">
            <article class="workflow-observe" data-reveal style={{ "--reveal-delay": "0ms" }}><span class="step-number">01</span><span class="step-icon"><Search size={25} /></span><h3>Understand the whole system</h3><p>Combine existing resources, application Env, dependencies, ownership, locality, and cost in one graph.</p></article>
            <article class="workflow-compile" data-reveal style={{ "--reveal-delay": "80ms" }}><span class="step-number">02</span><span class="step-icon"><ShieldCheck size={25} /></span><h3>Specialist agents compile</h3><p>Dedicated skills generate Ziac code and catch missing permissions, invalid bindings, provider gaps, and unsafe wiring.</p></article>
            <article class="workflow-deploy" data-reveal style={{ "--reveal-delay": "160ms" }}><span class="step-number">03</span><span class="step-icon"><Globe2 size={25} /></span><h3>Ship a global backend</h3><p>Roll Zig services across Cloud Run regions behind global routing, with guarded traffic shifts and causal traceability.</p></article>
          </div>
        </section>

        <section class="compatibility-section" id="product" data-reveal>
          <div class="compatibility-lockup"><img src="/zig-mark.svg" alt="Zig" /><h2>backends. Google Cloud, deeply integrated.</h2></div>
          <p>Cloud Run at the edge of every region. CockroachDB where the data belongs. One compiled application and infrastructure contract.</p>
        </section>

        <section class="beta-section" id="beta">
          <div class="beta-inner">
            <div class="beta-main">
              <div class="beta-copy" data-reveal>
                <p class="eyebrow">Private beta · Read-only first scan</p>
                <h2>Bring one GCP project. Ship one <span class="inline-zig-mark"><img src="/zig-mark.svg" alt="Zig" /></span> backend everywhere.</h2>
                <p>Start by mapping the estate you already have. Nothing is changed until you approve a proved plan.</p>
              </div>
              <div class="beta-action" data-reveal style={{ "--reveal-delay": "100ms" }}>
                <button class="button button-primary" type="button" onClick={openDialog}>Connect a GCP project <ArrowRight size={18} /></button>
                <small>Private-beta access. No cloud credentials are requested on this page.</small>
              </div>
            </div>
            <div class="beta-sequence" aria-label="Ziac private beta workflow">
              <span><small>01</small><strong>Observe the estate</strong><em>Read-only inventory and cost context</em></span>
              <span><small>02</small><strong>Compile the change</strong><em>Agents generate a proved Ziac plan</em></span>
              <span><small>03</small><strong>Deploy with proof</strong><em>Human authority and causal verification</em></span>
            </div>
          </div>
        </section>
      </main>

      <MarketingFooter />

      {dialogOpen() && (
        <div class="dialog-backdrop" onMouseDown={(event) => event.target === event.currentTarget && setDialogOpen(false)}>
          <div class="beta-dialog" role="dialog" aria-modal="true" aria-labelledby="beta-dialog-title" ref={dialog}>
            <button class="icon-button dialog-close" type="button" aria-label="Close dialog" onClick={() => setDialogOpen(false)}><X size={20} /></button>
            {joined() ? (
              <div class="dialog-success" aria-live="polite">
                <span><Check size={24} /></span><p class="eyebrow">You're on the list</p><h2 id="beta-dialog-title">We’ll be in touch.</h2>
                <p>Your project stays untouched until you explicitly approve a read-only connection.</p>
                <button class="button button-primary" type="button" onClick={() => setDialogOpen(false)}>Done</button>
              </div>
            ) : (
              <>
                <p class="eyebrow">Private beta</p><h2 id="beta-dialog-title">Connect your first GCP project.</h2>
                <p class="dialog-copy">Join the early access list for read-only estate discovery, specialist infrastructure agents, live cost estimates, and generated Ziac code.</p>
                <form onSubmit={submitBeta}>
                  <label>Work email<input type="email" name="email" autocomplete="email" placeholder="you@company.com" required /></label>
                  <label>GCP project ID<input type="text" name="project" placeholder="my-production-project" required /></label>
                  <button class="button button-primary" type="submit">Request access <ArrowRight size={18} /></button>
                </form>
                <small>No OAuth yet. We’ll ask before requesting read-only Cloud Asset Inventory access.</small>
              </>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
