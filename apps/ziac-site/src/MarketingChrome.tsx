import ArrowRight from "lucide-solid/icons/arrow-right";
import Menu from "lucide-solid/icons/menu";
import X from "lucide-solid/icons/x";
import { createSignal, Show } from "solid-js";
import { ZiacMark } from "./ZiacMark";

export type MarketingRoute = "product" | "how-it-works" | "why-zig" | "why-zigeffect" | "causal-graph" | "case-study";

interface MarketingHeaderProps {
  readonly current: MarketingRoute;
  readonly onPrimaryAction?: () => void;
  readonly onSignIn?: () => void;
  readonly primaryLabel?: string;
  readonly primaryHref?: string;
}

const navItems: readonly { label: string; href: string; route?: MarketingRoute }[] = [
  { label: "Product", href: "/", route: "product" },
  { label: "How it works", href: "/how-it-works", route: "how-it-works" },
  { label: "Why Zig", href: "/why-zig", route: "why-zig" },
  { label: "ZigEffect", href: "/why-zigeffect", route: "why-zigeffect" },
  { label: "Case study", href: "/case-studies/yachdee-court-series", route: "case-study" },
  { label: "Dashboard", href: "/#operations" },
] as const;

export function MarketingHeader(props: MarketingHeaderProps) {
  const [menuOpen, setMenuOpen] = createSignal(false);
  const primaryLabel = () => props.primaryLabel ?? "Start with the CLI";
  const primaryHref = () => props.primaryHref ?? "/how-it-works#scaffold";

  const runPrimaryAction = () => {
    setMenuOpen(false);
    props.onPrimaryAction?.();
  };

  const runSignIn = () => {
    setMenuOpen(false);
    props.onSignIn?.();
  };

  return (
    <>
      <header class="site-header">
        <a class="brand" href="/" aria-label="Ziac home">
          <span class="brand-mark"><ZiacMark /></span>
          <span>Ziac</span>
        </a>

        <nav class="desktop-nav" aria-label="Primary navigation">
          {navItems.map((item) => (
            <a href={item.href} aria-current={item.route === props.current ? "page" : undefined}>{item.label}</a>
          ))}
        </nav>

        <div class="header-actions">
          <Show when={props.onSignIn} fallback={<a class="text-button" href="/#beta">Sign in</a>}>
            <button class="text-button" type="button" onClick={runSignIn}>Sign in</button>
          </Show>
          <Show
            when={props.onPrimaryAction}
            fallback={<a class="button button-primary button-small" href={primaryHref()}>{primaryLabel()} <ArrowRight size={16} /></a>}
          >
            <button class="button button-primary button-small" type="button" onClick={runPrimaryAction}>{primaryLabel()} <ArrowRight size={16} /></button>
          </Show>
          <button
            class="icon-button mobile-menu-button"
            type="button"
            aria-label={menuOpen() ? "Close navigation" : "Open navigation"}
            aria-expanded={menuOpen()}
            onClick={() => setMenuOpen(!menuOpen())}
          >
            {menuOpen() ? <X size={20} /> : <Menu size={20} />}
          </button>
        </div>
      </header>

      <Show when={menuOpen()}>
        <nav class="mobile-nav" aria-label="Mobile navigation">
          {navItems.map((item) => (
            <a href={item.href} aria-current={item.route === props.current ? "page" : undefined} onClick={() => setMenuOpen(false)}>{item.label}</a>
          ))}
          <Show when={props.onPrimaryAction}>
            <button type="button" onClick={runPrimaryAction}>{primaryLabel()}</button>
          </Show>
        </nav>
      </Show>
    </>
  );
}

interface MarketingFooterProps {
  readonly message?: string;
}

export function MarketingFooter(props: MarketingFooterProps) {
  return (
    <footer id="about">
      <a class="brand" href="/"><span class="brand-mark"><ZiacMark /></span><span>Ziac</span></a>
      <p>{props.message ?? "Infrastructure as compiled intent."}</p>
      <p>Built with Zig and ZigEffect.</p>
    </footer>
  );
}
