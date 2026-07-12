// Ziac dashboard-owned resource icon catalogue.
import type { ZiacVisualResource } from "./ziacVisualArtifact";

export type ZiacResourceVisualIdentity = {
  family: string;
  label: string;
  iconPath: string | null;
  official: boolean;
};

const gcpIconRoot = "/provider-icons/gcp";

export function resourceVisualIdentity(resource: Pick<ZiacVisualResource, "provider" | "type">): ZiacResourceVisualIdentity {
  if (resource.provider === "cockroach") {
    return { family: "cockroach.database", label: "CockroachDB", iconPath: null, official: false };
  }
  if (resource.provider !== "gcp") {
    return { family: `${resource.provider}.resource`, label: "Local resource", iconPath: null, official: false };
  }
  if (resource.type === "gcp.run.Service") {
    return { family: "gcp.run", label: "Cloud Run", iconPath: `${gcpIconRoot}/cloud-run.png`, official: true };
  }
  if (resource.type.startsWith("gcp.storage.")) {
    return { family: "gcp.storage", label: "Cloud Storage", iconPath: `${gcpIconRoot}/cloud-storage.png`, official: true };
  }
  if (isNetworkingType(resource.type)) {
    return { family: "gcp.networking", label: "Networking", iconPath: `${gcpIconRoot}/networking.png`, official: true };
  }
  if (resource.type.startsWith("gcp.iam.") || resource.type.startsWith("gcp.secret.")) {
    return { family: "gcp.security", label: "Security & identity", iconPath: `${gcpIconRoot}/security-identity.png`, official: true };
  }
  if (resource.type.startsWith("gcp.sql.") || resource.type.startsWith("gcp.spanner.") || resource.type.startsWith("gcp.firestore.")) {
    return { family: "gcp.databases", label: "Databases", iconPath: `${gcpIconRoot}/databases.png`, official: true };
  }
  if (resource.type.startsWith("gcp.functions.") || resource.type.startsWith("gcp.scheduler.") || resource.type.startsWith("gcp.tasks.")) {
    return { family: "gcp.serverless", label: "Serverless", iconPath: `${gcpIconRoot}/serverless.png`, official: true };
  }
  return { family: "gcp.compute", label: "Google Cloud", iconPath: `${gcpIconRoot}/compute.png`, official: true };
}

function isNetworkingType(type: string) {
  return type.startsWith("gcp.compute.") || type.startsWith("gcp.dns.") || type.startsWith("gcp.networking.");
}
