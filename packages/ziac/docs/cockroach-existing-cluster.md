# Existing CockroachDB Clusters

`cockroach.existing_cluster.ExistingCluster` adopts an existing CockroachDB
Cloud cluster as a retained, read-only Ziac resource. It is the first data slice
for global Cloud Run stacks and establishes the topology and endpoint outputs
used by SQL users and Secret Manager bindings.

## Provider Configuration

The provider API key is represented by a `value.SecretReference`, never a
literal string:

```zig
const provider = ziac.cockroach.config.ProviderConfig{
    .api_key = ziac.cockroach.config.environmentApiKey("COCKROACH_API_KEY"),
};
```

Only environment-backed references are accepted in this slice. The default
reference is `COCKROACH_API_KEY`. `loadApiKeyAlloc` resolves and owns the value
at provider startup; the key is securely zeroed on release. Resource inputs,
state, plans, outputs, and diagnostics contain the reference only.

## Topology Contract

An existing cluster declaration includes a stable logical name, Cockroach Cloud
cluster ID, plan, and exact GCP region set:

```zig
var database = try ziac.cockroach.existing_cluster.ExistingCluster.build(
    allocator,
    provider,
    .{
        .name = "production",
        .cluster_id = "cluster-1",
        .plan = .standard,
        .regions = &.{ "europe-west1", "us-central1" },
    },
);
```

Regions are sorted before hashing, so declaration order does not cause a diff.
Empty or duplicate regions fail during graph construction. Cluster IDs allow
only ASCII letters, digits, and hyphens before they can enter a Cloud API path.
The cloud provider is fixed to GCP for the initial Ziac product.

The client decodes both the cluster-level SQL DNS name and each region's public
SQL, internal, Private Service Connect, and Console DNS names, node count, and
primary marker from the pinned `Cc-Version: 2024-09-16` response.

## Outputs

The resource exposes typed public outputs for:

- `cluster_id`, `name`, `cloud_provider`, and `plan`;
- cluster-level `sql_dns`;
- sorted `regions`;
- `primary_region`, `primary_sql_dns`, `primary_internal_dns`, and
  `primary_private_endpoint_dns`.

The regional metadata remains provider-owned public connection metadata. SQL
passwords and complete connection URIs belong to the secret boundary introduced
by `cockroach.ConnectionSecret`.

## Lifecycle And Drift

Create and import read the declared cluster and adopt it only when cloud, plan,
and regions match exactly. Refresh records remote endpoint and topology changes.
A missing remote cluster taints the state record. Region diagnostics sort both
missing and unexpected regions for stable plans and tests.

Topology drift produces an update diff, but the provider does not mutate an
existing-cluster reference. Deploy fails closed until the declaration is
updated to the intended remote topology or the cluster is corrected outside
Ziac. Destroy and replacement deletion validate the physical ID and detach
state without issuing a Cockroach Cloud delete request. The resource also sets
`retain_on_delete` in state as a second ownership guard.
