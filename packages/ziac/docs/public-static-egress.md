# Public Static Egress For CockroachDB

`cockroach.public_egress.PublicStaticEgress` gives each regional Cloud Run
deployment a stable public source address and adds exactly that address to a
CockroachDB Cloud SQL allowlist. It is Ziac's initial production connectivity
path for existing GCP-hosted CockroachDB clusters.

This is a public-network design with narrow source restrictions. It is not a
private-network or Private Service Connect design.

## Topology

The component creates one custom-mode, global-routing VPC. For every configured
service region it creates:

- one regional subnet with Private Google Access;
- one Cloud Router;
- one Premium external regional address;
- one manual Cloud NAT using only that address and subnet;
- one CockroachDB Cloud authorized-network entry for the address as `/32`.

It also returns a typed `cloud_run.DirectVpc` value for each region. The value
uses resource outputs for the network and subnetwork, sets Cloud Run egress to
`ALL_TRAFFIC`, and therefore derives the deployment dependencies automatically.

```zig
const policies = [_]ziac.cockroach.public_egress.RegionPolicy{
    .{ .region = "europe-west1", .subnet_cidr = "10.42.0.0/24" },
    .{ .region = "us-central1", .subnet_cidr = "10.42.1.0/24" },
};

var egress = try ziac.cockroach.public_egress.PublicStaticEgress.build(
    allocator,
    .{
        .project_id = "example-project",
        .primary_region = "europe-west1",
        .service_regions = &.{ "europe-west1", "us-central1" },
        .network_tier = .premium,
    },
    .{},
    .{
        .name = "api",
        .cluster_id = "cockroach-cluster-id",
        .regions = &policies,
    },
);
defer egress.deinit();
```

`egress.regional_vpc` is ordered like `policies`; select the entry with the
same region when building each `gcp.cloud_run.Service`.

## Safety Invariants

The production builder enforces the following policy:

- GCP Premium network tier is required.
- Region policies are unique and must exactly match configured service regions
  when that provider constraint is present.
- Subnets are custom and reject broad or malformed CIDRs.
- Cloud NAT uses `MANUAL_ONLY`, `LIST_OF_SUBNETWORKS`, and
  `ALL_IP_RANGES` for the one managed subnet.
- Endpoint-independent mapping is enabled and the default minimum allocation is
  64 ports per VM.
- Cockroach SQL access is enabled, Cockroach UI access is disabled, and every
  production allowlist entry must be `/32`.
- The Cockroach allowlist receives the allocated address output, not a copied
  configuration string.

The address is public metadata and may be stored as a normal provider output.
Cockroach API credentials and database connection secrets continue to use
secret references and never enter this graph as plaintext.

## Provider Lifecycle

`Network`, `Subnetwork`, `Router`, and `RegionalAddress` use the generic Compute
provider lifecycle and regional/global long-running-operation polling as
appropriate. Identity changes replace these resources.

Cloud NAT is a nested field of a Compute Router. Its provider performs a
read-modify-patch using the router fingerprint, preserves unrelated NATs and
router fields, retries fingerprint conflicts, and removes only the managed NAT
on destroy. Refresh normalizes concrete API self-links back to the typed output
references that produced them.

`cockroach.AuthorizedNetwork` supports read, create, mutable SQL/UI flag update,
idempotent delete, import, and refresh. Its stable physical identity is the
cluster plus resolved IP and mask. Address or cluster changes replace the rule.

## Operations

Cloud Run traffic must use the returned Direct VPC configuration; otherwise its
database connection will not traverse the reserved NAT address. Because all
traffic is routed through Direct VPC, NAT sizing and quotas apply to every
outbound connection from that regional service.

During initial deployment, the dependency graph allocates the address before
writing the Cockroach allowlist and starts Cloud Run only after its network
outputs exist. Cockroach can take time to propagate allowlist changes, so the
application should use bounded connection retries during startup.

During destroy, Cloud Run and the Cockroach allowlist are removed before the NAT
and address dependencies. Retain the Cockroach cluster independently through
`cockroach.existing_cluster.ExistingCluster`; destroying this networking graph
does not delete that cluster.

Use Private Service Connect instead when policy forbids public endpoints or
public egress. The private path is implemented separately and documented in
`docs/private-service-connect.md`; the two modes never create each other's
networking resources.

## Verification

Scripted provider tests prove:

- resource request paths and long-running-operation scope;
- typed output resolution into Direct VPC, NAT, and allowlist requests;
- refresh normalization back to output references;
- router fingerprint and unrelated-NAT preservation;
- exact `/32` SQL-only allowlist writes;
- full create/read/diff/update/delete/import lifecycles;
- deterministic component shape and dependency derivation.

Authenticated GCP and Cockroach Cloud execution remains part of the M6 live
acceptance gate and requires disposable-project credentials.
