export type Point3 = readonly [number, number, number];

export interface HeroSlab {
  readonly id: string;
  readonly label: string;
  readonly detail: string;
  readonly position: Point3;
  readonly size: readonly [number, number];
  readonly tone: "account" | "region" | "external";
}

export interface HeroResource {
  readonly id: string;
  readonly name: string;
  readonly type: string;
  readonly slabId: string;
  readonly position: Point3;
  readonly tone: "run" | "data" | "edge" | "external";
  readonly status: string;
}

export interface HeroRoute {
  readonly id: string;
  readonly from: string;
  readonly to: string;
  readonly label: string;
  readonly tone: "request" | "data" | "binding";
  readonly points: readonly Point3[];
}

export const heroSlabs: readonly HeroSlab[] = [
  {
    id: "prod-account",
    label: "prod-account",
    detail: "GCP account",
    position: [-3.7, 0, -2.8],
    size: [4.5, 3.2],
    tone: "account",
  },
  {
    id: "us-central1",
    label: "us-central1",
    detail: "VPC global-api",
    position: [1.5, 0, -2.4],
    size: [4.4, 3.2],
    tone: "region",
  },
  {
    id: "europe-west1",
    label: "europe-west1",
    detail: "VPC global-api",
    position: [-3.1, 0, 1.5],
    size: [4.4, 3.1],
    tone: "region",
  },
  {
    id: "asia-northeast1",
    label: "asia-northeast1",
    detail: "VPC global-api",
    position: [2.4, 0, 1.8],
    size: [4.6, 3.1],
    tone: "region",
  },
  {
    id: "external-services",
    label: "external-services",
    detail: "CockroachDB Cloud",
    position: [1.4, 0, 5.5],
    size: [4.7, 2.5],
    tone: "external",
  },
] as const;

export const heroResources: readonly HeroResource[] = [
  {
    id: "api-https",
    name: "api-https",
    type: "Global LB",
    slabId: "prod-account",
    position: [-3.7, 0.58, -2.8],
    tone: "edge",
    status: "Healthy - 100% global traffic",
  },
  {
    id: "run-us",
    name: "api-us",
    type: "Cloud Run",
    slabId: "us-central1",
    position: [0.6, 0.58, -2.4],
    tone: "run",
    status: "3 revisions - 99.99% uptime",
  },
  {
    id: "cache-us",
    name: "session-cache",
    type: "Memorystore",
    slabId: "us-central1",
    position: [2.5, 0.58, -2.4],
    tone: "data",
    status: "Healthy - 1.8 ms p95",
  },
  {
    id: "run-eu",
    name: "api-eu",
    type: "Cloud Run",
    slabId: "europe-west1",
    position: [-3.1, 0.58, 1.5],
    tone: "run",
    status: "2 revisions - 100% ready",
  },
  {
    id: "run-asia",
    name: "api-asia",
    type: "Cloud Run",
    slabId: "asia-northeast1",
    position: [1.4, 0.58, 1.8],
    tone: "run",
    status: "2 revisions - 100% ready",
  },
  {
    id: "bucket-asia",
    name: "media-assets",
    type: "Cloud Storage",
    slabId: "asia-northeast1",
    position: [3.4, 0.58, 1.8],
    tone: "data",
    status: "Standard - multi-region",
  },
  {
    id: "cockroach",
    name: "global-primary",
    type: "CockroachDB",
    slabId: "external-services",
    position: [1.4, 0.58, 5.5],
    tone: "external",
    status: "3 regions - survivable",
  },
] as const;

export const heroRoutes: readonly HeroRoute[] = [
  {
    id: "route-us",
    from: "api-https",
    to: "run-us",
    label: "nearest request",
    tone: "request",
    points: [
      [-3.7, 0.43, -2.8],
      [-1.7, 0.43, -2.8],
      [-1.7, 0.43, -2.4],
      [0.6, 0.43, -2.4],
    ],
  },
  {
    id: "route-eu",
    from: "api-https",
    to: "run-eu",
    label: "nearest request",
    tone: "request",
    points: [
      [-3.7, 0.43, -2.8],
      [-4.7, 0.43, -1.1],
      [-4.7, 0.43, 1.5],
      [-3.1, 0.43, 1.5],
    ],
  },
  {
    id: "route-asia",
    from: "api-https",
    to: "run-asia",
    label: "nearest request",
    tone: "request",
    points: [
      [-3.7, 0.43, -2.8],
      [-0.8, 0.43, -1.1],
      [-0.8, 0.43, 1.8],
      [1.4, 0.43, 1.8],
    ],
  },
  {
    id: "binding-cache",
    from: "run-us",
    to: "cache-us",
    label: "private read/write",
    tone: "binding",
    points: [
      [0.6, 0.44, -2.4],
      [1.55, 0.44, -2.4],
      [2.5, 0.44, -2.4],
    ],
  },
  {
    id: "binding-storage",
    from: "run-asia",
    to: "bucket-asia",
    label: "object read",
    tone: "binding",
    points: [
      [1.4, 0.44, 1.8],
      [2.4, 0.44, 1.8],
      [3.4, 0.44, 1.8],
    ],
  },
  {
    id: "data-global",
    from: "run-eu",
    to: "cockroach",
    label: "SQL/TLS",
    tone: "data",
    points: [
      [-3.1, 0.43, 1.5],
      [-1.5, 0.43, 3.2],
      [1.4, 0.43, 3.2],
      [1.4, 0.43, 5.5],
    ],
  },
] as const;
