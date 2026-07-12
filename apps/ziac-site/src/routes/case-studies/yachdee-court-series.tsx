import { Link, Meta, Title, useHead } from "@solidjs/meta";
import { CaseStudy } from "../../CaseStudy";
import { SITE_URL } from "../../seo";

const title = "Yachdee and Court Series build globally with Ziac - Case study";
const description = "How Yachdee and Court Series are building with Ziac, Zig, Google Cloud Run, global load balancing, and CockroachDB locality for precise global products.";
const canonical = `${SITE_URL}/case-studies/yachdee-court-series`;
const socialImage = `${SITE_URL}/case-studies/yachdee-hero.webp`;

const articleSchema = JSON.stringify({
  "@context": "https://schema.org",
  "@type": "TechArticle",
  headline: "Two products. One global infrastructure model.",
  description,
  url: canonical,
  image: socialImage,
  author: { "@type": "Organization", name: "Ziac" },
  publisher: { "@type": "Organization", name: "Ziac" },
  about: ["Yachdee", "Court Series", "Zig", "Google Cloud Run", "CockroachDB", "Global infrastructure"],
});

export default function CaseStudyRoute() {
  useHead({
    tag: "script",
    id: "ziac-yachdee-court-series-schema",
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
      <Meta property="og:image" content={socialImage} />
      <Meta name="twitter:card" content="summary_large_image" />
      <Meta name="twitter:title" content={title} />
      <Meta name="twitter:description" content={description} />
      <Meta name="twitter:image" content={socialImage} />
      <CaseStudy />
    </>
  );
}
