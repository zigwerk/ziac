const configuredSiteUrl = import.meta.env.PUBLIC_SITE_URL?.trim();

export const SITE_URL = (configuredSiteUrl || "https://ziac.dev").replace(/\/$/, "");
export const SITE_TITLE = "Ziac - Google Cloud infrastructure, compiled";
export const SITE_DESCRIPTION =
  "Observe existing Google Cloud infrastructure, compile safe GCP plans with specialist agents, and deploy Zig services globally on Cloud Run.";
export const SOCIAL_IMAGE_URL = `${SITE_URL}/ziac-operations.png`;

export const SOFTWARE_APPLICATION_SCHEMA = JSON.stringify({
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  name: "Ziac",
  applicationCategory: "DeveloperApplication",
  operatingSystem: "Cloud",
  url: `${SITE_URL}/`,
  description: SITE_DESCRIPTION,
  offers: {
    "@type": "Offer",
    availability: "https://schema.org/PreOrder",
    price: "0",
    priceCurrency: "USD",
  },
  featureList: [
    "Google Cloud infrastructure visualisation",
    "Compile-time application and resource binding validation",
    "Global Cloud Run deployment planning",
    "Causal infrastructure debugging",
    "Observed and managed infrastructure separation",
  ],
});
