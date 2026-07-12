import { Link, Meta, Title, useHead } from "@solidjs/meta";
import { ProductLanding } from "../ProductLanding";
import {
  SITE_DESCRIPTION,
  SITE_TITLE,
  SITE_URL,
  SOCIAL_IMAGE_URL,
  SOFTWARE_APPLICATION_SCHEMA,
} from "../seo";

export default function Home() {
  useHead({
    tag: "script",
    id: "ziac-software-application-schema",
    props: {
      type: "application/ld+json",
      children: SOFTWARE_APPLICATION_SCHEMA,
    },
    setting: { close: true },
  });

  return (
    <>
      <Title>{SITE_TITLE}</Title>
      <Meta name="description" content={SITE_DESCRIPTION} />
      <Meta name="robots" content="index, follow, max-image-preview:large, max-snippet:-1, max-video-preview:-1" />
      <Meta name="keywords" content="Zig infrastructure, Google Cloud IaC, Cloud Run deployment, GCP infrastructure diagram, agentic infrastructure" />
      <Link rel="canonical" href={`${SITE_URL}/`} />

      <Meta property="og:type" content="website" />
      <Meta property="og:site_name" content="Ziac" />
      <Meta property="og:title" content={SITE_TITLE} />
      <Meta property="og:description" content={SITE_DESCRIPTION} />
      <Meta property="og:url" content={`${SITE_URL}/`} />
      <Meta property="og:image" content={SOCIAL_IMAGE_URL} />
      <Meta property="og:image:alt" content="Ziac visualising and operating a global Google Cloud deployment" />

      <Meta name="twitter:card" content="summary_large_image" />
      <Meta name="twitter:title" content={SITE_TITLE} />
      <Meta name="twitter:description" content={SITE_DESCRIPTION} />
      <Meta name="twitter:image" content={SOCIAL_IMAGE_URL} />

      <ProductLanding />
    </>
  );
}
