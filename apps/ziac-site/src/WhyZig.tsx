import ArrowRight from "lucide-solid/icons/arrow-right";
import Binary from "lucide-solid/icons/binary";
import Braces from "lucide-solid/icons/braces";
import Check from "lucide-solid/icons/check";
import CircleGauge from "lucide-solid/icons/circle-gauge";
import Container from "lucide-solid/icons/container";
import Cpu from "lucide-solid/icons/cpu";
import Globe2 from "lucide-solid/icons/earth";
import MemoryStick from "lucide-solid/icons/memory-stick";
import PackageCheck from "lucide-solid/icons/package-check";
import Route from "lucide-solid/icons/route";
import ScanLine from "lucide-solid/icons/scan-line";
import { onCleanup, onMount } from "solid-js";
import { HeroTopology } from "./HeroTopology";
import { MarketingFooter, MarketingHeader } from "./MarketingChrome";

const principles = [
  {
    icon: MemoryStick,
    title: "Explicit allocation",
    copy: "Allocators and ownership are visible inputs to the program. Generated code has fewer invisible runtime decisions for an agent or reviewer to reconstruct.",
  },
  {
    icon: ScanLine,
    title: "Inspectable control flow",
    copy: "Errors, cleanup, async boundaries, and resource lifetimes stay close to ordinary Zig. The code an agent writes resembles the code that actually runs.",
  },
  {
    icon: Braces,
    title: "Comptime as a product primitive",
    copy: "Ziac uses comptime to compare App.Env, resource bindings, provider availability, output scope, secrecy, and topology before a cloud mutation exists.",
  },
  {
    icon: PackageCheck,
    title: "Cross-compilation by design",
    copy: "One build system can target container platforms and architectures without making a language runtime part of the production image contract.",
  },
] as const;

export function WhyZig() {
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
    <div class="site-shell deep-page zig-page">
      <MarketingHeader current="why-zig" />

      <main>
        <section class="deep-hero zig-deep-hero" aria-labelledby="zig-hero-title">
          <div class="deep-hero-visual"><HeroTopology /></div>
          <div class="deep-hero-copy">
            <p class="eyebrow">Why Zig</p>
            <h1 id="zig-hero-title">Agents can write more software. <span>The runtime should waste less.</span></h1>
            <p>Generation makes source code cheaper. Production compute, memory, deployment time, and operational complexity still compound every day the service exists, from one local binary to a global Cloud Run service.</p>
            <div class="hero-actions">
              <a class="button button-primary" href="#zig-case"><Cpu size={18} /> See the engineering case</a>
              <a class="button button-secondary" href="/why-zigeffect">Why ZigEffect <ArrowRight size={18} /></a>
            </div>
          </div>
        </section>

        <div class="deep-proof-strip" aria-label="Zig advantages for agent-authored cloud software">
          <span><MemoryStick size={17} /><strong>Explicit resources</strong></span>
          <span><Braces size={17} /><strong>Compile-time contracts</strong></span>
          <span><Binary size={17} /><strong>Lean binaries</strong></span>
          <span><Globe2 size={17} /><strong>Global containers</strong></span>
        </div>

        <section class="deep-section" id="zig-case" aria-labelledby="zig-case-title">
          <div class="deep-editorial-heading" data-reveal>
            <p class="eyebrow">The economics changed</p>
            <h2 id="zig-case-title">Optimise the software that runs, not the effort required to type it.</h2>
            <p>When an agent can produce and revise implementation quickly, choosing a language mainly because it is easy to type becomes less compelling. The durable question is what kind of system the generated code leaves behind.</p>
          </div>

          <div class="principle-grid" data-reveal style={{ "--reveal-delay": "70ms" }}>
            {principles.map((principle) => {
              const Icon = principle.icon;
              return <article><Icon size={22} /><strong>{principle.title}</strong><p>{principle.copy}</p></article>;
            })}
          </div>
        </section>

        <section class="zig-contract-band" aria-labelledby="zig-contract-title">
          <div class="zig-contract-inner">
            <div class="zig-contract-copy" data-reveal>
              <p class="eyebrow">Where Zig becomes Ziac</p>
              <h2 id="zig-contract-title">The application and the cloud meet in the compiler.</h2>
              <p>Most infrastructure tools can validate a resource graph. Ziac also asks whether the Zig application can boot with the exact environment, secrecy, scope, and provider outputs that graph produces.</p>
              <ul>
                <li><Check size={15} /> Missing or extra App.Env bindings</li>
                <li><Check size={15} /> Public values wired into secret fields</li>
                <li><Check size={15} /> Regional outputs escaping their declared scope</li>
                <li><Check size={15} /> Unsupported provider capabilities</li>
              </ul>
            </div>
            <div class="deep-code-window" data-reveal style={{ "--reveal-delay": "90ms" }}>
              <div class="tool-window-header"><span><Braces size={15} /> app.zig</span><span>zig build</span></div>
              <pre><code>{`const App = struct {
    pub const Env = struct {
        database_url: ziac.binding.Secret([]const u8),
    };
};

const Bindings = struct {};
const Service = ziac.gcp.global.ZigService(
    App, Bindings, Providers,
);

error: ZIAC100 missing app binding: database_url`}</code></pre>
            </div>
          </div>
        </section>

        <section class="deep-section" aria-labelledby="delivery-title">
          <div class="deep-editorial-heading" data-reveal>
            <p class="eyebrow">Built once. Placed globally.</p>
            <h2 id="delivery-title">A small deployment unit is infrastructure leverage.</h2>
            <p>Zig gives Ziac a direct path from reviewed source to immutable OCI images and regional Cloud Run revisions. Ziac then assembles identity, routing, health, TLS, DNS, and data locality around that artifact.</p>
          </div>
          <div class="delivery-line" data-reveal style={{ "--reveal-delay": "70ms" }}>
            <span><Braces size={20} /><small>Source</small><strong>Typed Zig service</strong></span>
            <ArrowRight size={17} />
            <span><Container size={20} /><small>Artifact</small><strong>Immutable image</strong></span>
            <ArrowRight size={17} />
            <span><Route size={20} /><small>Placement</small><strong>Cloud Run regions</strong></span>
            <ArrowRight size={17} />
            <span><Globe2 size={20} /><small>Traffic</small><strong>Global HTTPS</strong></span>
          </div>
        </section>

        <section class="runtime-balance" aria-labelledby="runtime-title">
          <div data-reveal>
            <p class="eyebrow">No benchmark theatre</p>
            <h2 id="runtime-title">Performance is a budget you keep.</h2>
            <p>Ziac does not need an invented percentage to make the case. Lower runtime overhead, explicit resource use, and portable artifacts create more room for regional redundancy, faster iteration, and predictable cloud economics.</p>
          </div>
          <div class="runtime-measures" data-reveal style={{ "--reveal-delay": "80ms" }}>
            <span><CircleGauge size={19} /><strong>CPU</strong><small>Pay for useful work</small></span>
            <span><MemoryStick size={19} /><strong>Memory</strong><small>Make ownership visible</small></span>
            <span><Container size={19} /><strong>Artifact</strong><small>Ship the program you built</small></span>
          </div>
        </section>

        <section class="deep-cta" aria-labelledby="zig-cta-title">
          <div data-reveal><p class="eyebrow">The language is the foundation</p><h2 id="zig-cta-title">Now give it an agent-observable runtime.</h2></div>
          <a class="button button-primary" href="/why-zigeffect" data-reveal style={{ "--reveal-delay": "80ms" }}>Explore ZigEffect <ArrowRight size={18} /></a>
        </section>
      </main>

      <MarketingFooter message="Fast binaries. Explicit systems. Global infrastructure." />
    </div>
  );
}
