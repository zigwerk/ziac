// Standalone Ziac dashboard icon coverage.
import { expect, test } from "bun:test";
import { resourceVisualIdentity } from "./ziacResourceIconCatalog";
import type { ZiacVisualResource } from "./ziacVisualArtifact";

test("provider icon catalogue uses official GCP core-product artwork", () => {
  expect(resourceVisualIdentity(resource("gcp.run.Service"))).toMatchObject({
    family: "gcp.run",
    label: "Cloud Run",
    iconPath: "/provider-icons/gcp/cloud-run.png",
    official: true,
  });
  expect(resourceVisualIdentity(resource("gcp.storage.Bucket"))).toMatchObject({
    family: "gcp.storage",
    label: "Cloud Storage",
    iconPath: "/provider-icons/gcp/cloud-storage.png",
    official: true,
  });
  expect(resourceVisualIdentity(resource("gcp.pubsub.Topic"))).toMatchObject({
    family: "gcp.pubsub",
    label: "Pub/Sub",
    iconPath: "/provider-icons/gcp/pubsub.png",
    official: true,
  });
});

test("provider icon catalogue groups GCP primitives into stable product families", () => {
  expect(resourceVisualIdentity(resource("gcp.compute.GlobalForwardingRule")).family).toBe("gcp.networking");
  expect(resourceVisualIdentity(resource("gcp.compute.RegionServerlessNeg")).family).toBe("gcp.networking");
  expect(resourceVisualIdentity(resource("gcp.iam.ProjectMember"))).toMatchObject({ family: "gcp.security", label: "Security & identity" });
  expect(resourceVisualIdentity(resource("gcp.secret.Secret"))).toMatchObject({ family: "gcp.security", label: "Security & identity" });
  expect(resourceVisualIdentity(resource("gcp.unknown.Widget"))).toMatchObject({
    family: "gcp.compute",
    iconPath: "/provider-icons/gcp/compute.png",
    official: true,
  });
});

test("non-GCP resources are never assigned a Google product icon", () => {
  const cockroach = resourceVisualIdentity(resource("cockroach.Cluster", "cockroach"));
  expect(cockroach).toMatchObject({ family: "cockroach.database", label: "CockroachDB", iconPath: null, official: false });
});

function resource(type: string, provider: ZiacVisualResource["provider"] = "gcp"): ZiacVisualResource {
  return {
    id: `${type}.demo`,
    provider,
    type,
    logical_id: "demo",
    scope: "project",
    regions: [],
    operation: "create",
    health: "unknown",
    ownership: "managed",
    inputs: {},
    lifecycle: { protect: false, retain_on_delete: false, replace_before_delete: false },
    reasons: [],
  };
}
