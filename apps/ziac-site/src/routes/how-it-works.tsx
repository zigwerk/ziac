import { Link, Meta, Title, useHead } from "@solidjs/meta";
import { HowItWorks } from "../HowItWorks";
import { SITE_URL } from "../seo";

const title = "How Ziac works - Agentic global infrastructure for Zig";
const description = "Scaffold a Ziac project, bring Codex, Claude Code, or Gemini CLI, and watch specialist agents compile, deploy, diagnose, and verify global Google Cloud infrastructure.";
const canonical = `${SITE_URL}/how-it-works`;

const howToSchema = JSON.stringify({
  "@context": "https://schema.org",
  "@type": "HowTo",
  name: "How Ziac works",
  description,
  totalTime: "PT15M",
  step: [
    { "@type": "HowToStep", name: "Scaffold the project", text: "Create a Zig service, Ziac project contract, global GCP stack, specialist skills, and agent adapters." },
    { "@type": "HowToStep", name: "Choose an agent harness", text: "Use Codex, Claude Code, or Gemini CLI against the same governed Ziac kernel." },
    { "@type": "HowToStep", name: "Compile and verify", text: "Compile application bindings and infrastructure, preflight GCP, and run deterministic scenarios." },
    { "@type": "HowToStep", name: "Deploy globally", text: "Build an immutable Zig image and provision regional Cloud Run behind global HTTPS routing." },
    { "@type": "HowToStep", name: "Observe and diagnose", text: "Monitor the visual graph, causal events, rollout health, and evidence-backed repair proposals." },
  ],
});

export default function HowItWorksRoute() {
  useHead({
    tag: "script",
    id: "ziac-how-it-works-schema",
    props: { type: "application/ld+json", children: howToSchema },
    setting: { close: true },
  });

  return (
    <>
      <Title>{title}</Title>
      <Meta name="description" content={description} />
      <Meta name="robots" content="index, follow, max-image-preview:large, max-snippet:-1" />
      <Link rel="canonical" href={canonical} />
      <Meta property="og:type" content="website" />
      <Meta property="og:site_name" content="Ziac" />
      <Meta property="og:title" content={title} />
      <Meta property="og:description" content={description} />
      <Meta property="og:url" content={canonical} />
      <Meta property="og:image" content={`${SITE_URL}/ziac-operations.png`} />
      <Meta name="twitter:card" content="summary_large_image" />
      <Meta name="twitter:title" content={title} />
      <Meta name="twitter:description" content={description} />
      <Meta name="twitter:image" content={`${SITE_URL}/ziac-operations.png`} />
      <HowItWorks />
    </>
  );
}
