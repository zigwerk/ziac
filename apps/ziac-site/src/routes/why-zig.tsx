import { Link, Meta, Title, useHead } from "@solidjs/meta";
import { WhyZig } from "../WhyZig";
import { SITE_URL, SOCIAL_IMAGE_URL } from "../seo";

const title = "Why Zig for agent-built cloud software - Ziac";
const description = "Why Ziac uses Zig for explicit resource ownership, compile-time application and infrastructure contracts, portable containers, and global Cloud Run services.";
const canonical = `${SITE_URL}/why-zig`;

const articleSchema = JSON.stringify({
  "@context": "https://schema.org",
  "@type": "TechArticle",
  headline: "Why Zig for agent-built cloud software",
  description,
  url: canonical,
  author: { "@type": "Organization", name: "Ziac" },
  publisher: { "@type": "Organization", name: "Ziac" },
  about: ["Zig programming language", "Google Cloud Run", "Agentic software development"],
});

export default function WhyZigRoute() {
  useHead({
    tag: "script",
    id: "ziac-why-zig-schema",
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
      <WhyZig />
    </>
  );
}
