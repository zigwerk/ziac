# CockroachDB GCP Private Service Connect

`cockroach.private_service_connect.PrivateServiceConnect` builds a private,
multi-region path from Cloud Run to a GCP-hosted CockroachDB Standard or
Advanced cluster. It owns the consumer VPC, one endpoint per region, the
Cockroach endpoint-acceptance handshake, and private DNS. No public Cockroach
allowlist is created.

## Requirements

- The Cockroach cluster must run on GCP and use the Standard or Advanced plan.
  Basic is rejected at comptime by the component's `EligiblePlan` type.
- The GCP provider must use Premium network tier.
- Region policies must exactly match `ProviderConfig.service_regions`, with one
  unique subnet CIDR per region.
- A managed cluster should remain protected. An adopted cluster should use the
  retained `ExistingCluster` resource.
- Live operations require Google ADC, a Cockroach Cloud service-account API
  key, sufficient GCP/Cockroach permissions, and available regional PSC,
  internal-address, forwarding-rule, VPC, subnet, and Cloud DNS quotas.

The component enables `compute.googleapis.com`, `dns.googleapis.com`, and
`servicedirectory.googleapis.com`. Organization policy can still prohibit the
resources after API enablement, so validate policy and quota before a live
production rollout.

## Topology

The component creates one custom-mode VPC with global dynamic routing. For each
declared region it creates:

1. a regional subnet with Private Google Access;
2. a Cockroach private endpoint service projection;
3. a regional Cockroach projection that exposes the private SQL hostname;
4. an internal GCP address and PSC forwarding rule;
5. a Cockroach private endpoint connection using GCP's generated PSC connection
   ID;
6. a VPC-bound private Cloud DNS managed zone; and
7. an apex A record from the Cockroach private hostname to the endpoint IP.

GCP forwarding-rule creation completes before Cockroach accepts the endpoint.
Ziac then submits the generated connection ID to Cockroach and polls until the
connection is available. The DNS record depends on that accepted connection,
so the graph does not advertise an endpoint before the cross-provider handshake
is ready.

## Managed Cluster

Pass the managed cluster node alongside its typed cluster-ID output. The node is
required because `PrivateServiceConnect` returns a self-contained graph and must
include the resource referenced by that output.

```zig
var cluster = try ziac.cockroach.cluster.Cluster.build(allocator, .{}, .{
    .name = "ziac-prod",
    .plan = .{ .standard = .{
        .regions = &.{
            .{ .name = "europe-west1", .primary = true },
            .{ .name = "us-central1" },
        },
        .provisioned_virtual_cpus = 4,
    } },
});
defer cluster.deinit(allocator);

const policies = [_]ziac.cockroach.private_service_connect.RegionPolicy{
    .{ .region = "europe-west1", .subnet_cidr = "10.42.0.0/24" },
    .{ .region = "us-central1", .subnet_cidr = "10.42.1.0/24" },
};

var private = try ziac.cockroach.private_service_connect.PrivateServiceConnect.build(
    allocator,
    google,
    .{},
    .{
        .name = "api-db",
        .cluster_resource = cluster.node,
        .cluster_id = cluster.cluster_id,
        .plan = .standard,
        .regions = &policies,
    },
);
defer private.deinit();
```

Destroying this graph cannot delete the protected cluster. Cluster deletion
still requires the separate unprotect deploy and confirmed destroy documented
in `docs/cockroach-cluster.md`.

## Existing Cluster

An `ExistingCluster` output is wired in the same way: pass its node and
`cluster_id` output. For a literal known cluster ID, omit `cluster_resource`.
Ziac validates the actual cloud, plan, and regional topology during provider
reads instead of trusting the declaration.

```zig
.cluster_resource = existing.node,
.cluster_id = existing.cluster_id,
.plan = .advanced,
```

The cluster resource is retained. PSC endpoint services are also retained
because Cockroach Cloud does not expose deletion for an established endpoint
service. Endpoint connections, GCP forwarding rules, addresses, private zones,
subnets, and the VPC remain managed and are removed in reverse dependency
order.

## Cloud Run Composition

Convert the returned regional bindings to `RegionalDirectVpc`, append the PSC
graph through `base_graph`, and give the matching subnet to each Cloud Run
region:

```zig
var regional_vpc: [2]ziac.gcp.global.RegionalDirectVpc = undefined;
for (private.regions, 0..) |binding, index| regional_vpc[index] = .{
    .region = binding.region,
    .config = binding.direct_vpc,
};

var application = try ziac.gcp.global.ContainerService.build(allocator, google, .{
    .base_graph = &private.graph,
    .name = "api",
    .image = image,
    .regions = &.{ "europe-west1", "us-central1" },
    .domain = "api.example.com",
    .regional_direct_vpc = &regional_vpc,
});
defer application.deinit();
```

`base_graph` clones the existing resources into the resulting application DAG.
`regional_direct_vpc` must contain exactly one unique entry for every service
region and cannot be combined with the single shared `direct_vpc` option. PSC
bindings use `PRIVATE_RANGES_ONLY`, keeping ordinary public egress outside the
private path.

The complete managed-cluster example is
`examples/cockroach_private_service_connect.zig`. Its two-region graph contains
the protected cluster, private connectivity, regional Cloud Run services, and
the global HTTPS load balancer without an `AuthorizedNetwork` resource.

## Outputs And DNS

The component returns the VPC self-link plus one ordered `RegionalBinding` per
policy. Each binding contains:

- the region and typed Direct VPC configuration;
- the Cockroach private SQL hostname;
- the internal PSC endpoint address;
- GCP's PSC connection ID; and
- the accepted Cockroach connection status.

Cloud DNS names are canonicalized with a trailing dot by the provider. Callers
can pass output-backed names without one. Each managed zone is private and
visible only from the component VPC. Automated PSC DNS is disabled on the
forwarding rule so the typed Cockroach hostname remains the application
contract.

## Drift, Import, And Replacement

All low-level resources implement refresh and import. Composite Cockroach
identities use `cluster:region` for projections and `cluster:endpoint` for
connections. GCP resources use their provider physical IDs. Import validates
the declared project, region, network, service attachment, cluster, and endpoint
identity before adopting state.

Output-backed Compute and Cloud DNS inputs are validated again after resolution.
A subnet, address, network, service attachment, or private zone value from the
wrong project or region, an invalid IP address, or an invalid DNS name fails
before any provider mutation is attempted.

Identity changes replace PSC resources. This includes project, region, network,
subnet, address, service attachment, cluster ID, endpoint ID, and DNS identity.
Mutable provider status and server-generated outputs do not create drift.

Import resources individually with the standard CLI form:

```sh
ziac import --stack <stack> --stage <stage> \
  --resource <typed-resource-id> --id <provider-physical-id> \
  --provider gcp --allow-live
```

Import the producer before consumers, then run `refresh` and `plan`. Never
manually edit state to copy a service attachment or PSC connection ID.

## Operations And Cost

PSC forwarding rules, reserved internal addresses, VPC networking, Cloud DNS
managed zones and queries, Cockroach plan capacity, and cross-region traffic can
all incur charges. Each additional region adds a subnet, address, forwarding
rule, endpoint connection, private zone, and Cloud Run path. Review current GCP
and Cockroach pricing and regional quotas before adding regions.

Use a staged rollout:

1. create or adopt the protected cluster;
2. deploy PSC and wait for every connection status to become available;
3. verify private DNS from a workload attached to each regional subnet;
4. deploy Cloud Run with the returned regional VPC bindings; and
5. exercise SQL over verified TLS before directing production traffic.

During destroy, application and DNS consumers disappear first, followed by
Cockroach endpoint connections and GCP endpoints. Retained endpoint services
and protected/adopted clusters remain. This asymmetry is intentional and should
be included in cost and recovery reviews.

Create operations list Cockroach endpoint services and connections before
mutating them. A deployment interrupted after the remote object was accepted
therefore resumes polling the existing object instead of issuing a duplicate
enablement or registration request.

## Troubleshooting

- `MissingClusterResource` means a resource-backed cluster ID was supplied
  without its producer node. Pass `.cluster_resource = cluster.node`.
- `ClusterResourceMismatch` means the node does not produce the cluster-ID
  reference. Keep the node and output from the same builder result.
- Region-policy errors mean PSC policies and GCP service regions are missing,
  duplicated, or ordered differently. Declare exactly one policy per region.
- A provider cloud, plan, or region mismatch means the live Cockroach cluster
  does not match the component declaration. Correct the declaration; do not
  force state adoption.
- `STATUS_PENDING` and `STATUS_PENDING_ACCEPTANCE` are convergence states.
  `STATUS_REJECTED` is retried because Cockroach can still accept a newly
  registered GCP endpoint. Other terminal states fail immediately.
- A GCP endpoint can finish its Compute operation while its PSC status is still
  pending. This is expected; the following Cockroach connection resource owns
  acceptance polling.
- Missing DNS usually means the endpoint service has not populated the regional
  private hostname, the connection is not accepted, or the workload is not
  attached to the component VPC and matching regional subnet.
- Timeouts honor operation deadlines and cancellation. Inspect redacted request
  IDs and typed provider categories; API keys and SQL secrets are never included
  in diagnostics.

## Verification Boundary

Scripted tests cover exact GCP and Cockroach API requests, Standard and Advanced
service behavior, interrupted-operation resume, endpoint polling, imports,
deletes, provider-time validation of resolved outputs, typed output
normalization, private DNS, graph ordering, Cloud Run composition, and the
absence of public allowlists. The example and all compile-fail contracts build
under `zig build test` and `zig build examples`.

Authenticated deployment, regional DNS and SQL probes, verified-TLS reads and
writes, password rotation, and protected teardown are the separate Task 6.7
live data-path gate. They require disposable GCP and Cockroach Cloud credentials
and are not simulated by the scripted provider suite.

The Task 6.6 milestone verification passed on 2026-07-10: 263 Ziac tests (262
passed and one credential-gated test skipped), all Ziac examples and package
builds, zigeffect standard-library and PostgreSQL tests/examples, the local
CockroachDB verified-TLS integration, the 46-file tool-hygiene policy, and
`git diff --check`.
