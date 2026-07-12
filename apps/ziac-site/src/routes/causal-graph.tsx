import { Link, Meta, Title, useHead } from "@solidjs/meta";
import { CausalGraph } from "../CausalGraph";
import { SITE_URL, SOCIAL_IMAGE_URL } from "../seo";

const title = "Causal graph and agent verification - Ziac";
const description = "How Ziac and ZigEffect connect agent decisions, infrastructure plans, Google provider operations, Cloud Run health, and human verification through causal proof.";
const canonical = `${SITE_URL}/causal-graph`;

const articleSchema = JSON.stringify({
  "@context": "https://schema.org",
  "@type": "TechArticle",
  headline: "Causal proof for agent-built Google Cloud infrastructure",
  description,
  url: canonical,
  author: { "@type": "Organization", name: "Ziac" },
  publisher: { "@type": "Organization", name: "Ziac" },
  about: ["Causal graphs", "Agent verification", "ZigEffect", "Google Cloud infrastructure"],
});

export default function CausalGraphRoute() {
  useHead({
    tag: "script",
    id: "ziac-causal-graph-schema",
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
      <CausalGraph />
    </>
  );
}
