import { Link, Meta, Title, useHead } from "@solidjs/meta";
import { WhyZigEffect } from "../WhyZigEffect";
import { SITE_URL, SOCIAL_IMAGE_URL } from "../seo";

const title = "Why ZigEffect for agent-authored systems - Ziac";
const description = "How ZigEffect gives software agents typed effects, scoped resources, causal evidence, statecharts, deterministic fault testing, and governed handoffs.";
const canonical = `${SITE_URL}/why-zigeffect`;

const articleSchema = JSON.stringify({
  "@context": "https://schema.org",
  "@type": "TechArticle",
  headline: "Why ZigEffect for agent-authored systems",
  description,
  url: canonical,
  author: { "@type": "Organization", name: "Ziac" },
  publisher: { "@type": "Organization", name: "Ziac" },
  about: ["ZigEffect", "Causal debugging", "Deterministic testing", "Agentic software development"],
});

export default function WhyZigEffectRoute() {
  useHead({
    tag: "script",
    id: "ziac-why-zigeffect-schema",
    props: { type: "application/ld+json", children: articleSchema },
    setting: { close: true },
  });

  return (
    <>
      <Title>{title}</Title>
      <Meta name="description" content={description} />
      <Meta name="robots" content="index, follow, max-image-preview:large, max-snippet:-1" />
      <Link rel="canonical" href={canonical} />
      <Meta property="og:type" content="article" />
      <Meta property="og:site_name" content="Ziac" />
      <Meta property="og:title" content={title} />
      <Meta property="og:description" content={description} />
      <Meta property="og:url" content={canonical} />
      <Meta property="og:image" content={SOCIAL_IMAGE_URL} />
      <Meta name="twitter:card" content="summary_large_image" />
      <Meta name="twitter:title" content={title} />
      <Meta name="twitter:description" content={description} />
      <Meta name="twitter:image" content={SOCIAL_IMAGE_URL} />
      <WhyZigEffect />
    </>
  );
}
