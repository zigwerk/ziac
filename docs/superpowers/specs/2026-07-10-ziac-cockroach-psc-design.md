# Ziac CockroachDB GCP Private Service Connect Design

**Date:** 2026-07-10
**Status:** Validated for implementation
**Roadmap:** Ziac E2E Task 6.6

## Purpose

Ziac must make a private, multi-region Cloud Run to CockroachDB data path a
single typed infrastructure composition. The composition must provision the GCP
consumer network, create a Private Service Connect endpoint in every CockroachDB
region, submit each GCP connection ID to Cockroach Cloud, wait for acceptance,
and publish Cockroach's private regional DNS names inside that VPC.

The design preserves Ziac's differentiator: every cross-provider handoff is a
typed output reference. Users do not copy service attachments, endpoint IDs,
addresses, or DNS names between resources.

## Supported Topology

The initial component supports CockroachDB Standard and Advanced clusters on
GCP. Basic is intentionally absent from the public eligible-plan type.

For each declared region, the component creates:

1. a GCP subnet in a component-owned global-routing VPC;
2. a Cockroach private endpoint service projection;
3. a regional Cockroach cluster projection with private DNS output after the
   service exists;
4. a GCP internal address and PSC forwarding rule;
5. a Cockroach private endpoint connection using the forwarding rule's
   `pscConnectionId`;
6. a private Cloud DNS managed zone bound to the VPC; and
7. an apex A record using the Cockroach private hostname and GCP endpoint IP.

The component also enables `compute.googleapis.com`, `dns.googleapis.com`, and
`servicedirectory.googleapis.com`, and returns per-region Direct VPC settings
for Cloud Run with `PRIVATE_RANGES_ONLY` egress.

## Public API

The high-level resource is
`cockroach.private_service_connect.PrivateServiceConnect`:

```zig
const private = try ziac.cockroach.private_service_connect.PrivateServiceConnect.build(
    allocator,
    google,
    cockroach,
    .{
        .name = "api-db",
        .cluster_resource = cluster.node,
        .cluster_id = cluster.cluster_id,
        .plan = .standard,
        .regions = &.{
            .{ .region = "europe-west1", .subnet_cidr = "10.42.0.0/24" },
            .{ .region = "us-central1", .subnet_cidr = "10.42.1.0/24" },
        },
    },
);
```

`EligiblePlan` contains only `standard` and `advanced`. The cluster ID accepts a
public string output, allowing either a managed `cockroach.Cluster` or an
`ExistingCluster` to feed the component without losing dependency information.
When that ID is a resource reference, `cluster_resource` carries the matching
producer node into the returned self-contained graph. A known literal ID omits
the node.

The result exposes:

- a resource graph;
- the VPC self-link;
- one `RegionalVpc` per declared region for Cloud Run;
- one typed private hostname, endpoint address, endpoint connection ID, and
  accepted Cockroach connection status per region.

## Low-Level Resources

### Cockroach Cluster Region

`cockroach.ClusterRegion` is a read-only regional projection over `GET
/v1/clusters/{cluster_id}`. Its physical ID is `{cluster_id}:{region}` and its
outputs include SQL, internal, private endpoint, and Console DNS names.

The provider verifies that the cluster is on GCP and that the declared region
exists. It preserves a cluster ID output reference in observed inputs when the
resolved value matches remote state.

### Cockroach Private Endpoint Service

`cockroach.PrivateEndpointService` produces the regional GCP service attachment.
For Advanced clusters, create idempotently calls `POST
/v1/clusters/{id}/networking/private-endpoint-services`. For Standard clusters,
Cockroach creates endpoint services automatically, so create proceeds directly
to listing and polling.

The provider polls the regional service until `AVAILABLE`. `CREATING` is
retryable; failed or unknown terminal states fail the operation. Cockroach does
not expose deletion for an established service, so this resource is retained on
delete and its provider delete operation is a verified detach/no-op.

### GCP PSC Address And Endpoint

`gcp.compute.PscAddress` reserves an internal IPv4 address in the regional
subnet. `gcp.compute.PscEndpoint` creates a regional forwarding rule with:

- an empty load balancing scheme;
- the Cockroach service attachment as target;
- the component VPC and reserved address;
- global PSC access enabled; and
- automated DNS disabled because the component owns Cockroach-specific DNS.

The endpoint outputs its internal address, self-link, PSC connection ID, and PSC
connection status. Compute operation completion is the endpoint readiness gate;
the endpoint must not wait for `ACCEPTED`, because Cockroach cannot accept it
until the next resource receives its connection ID.

### Cockroach Private Endpoint Connection

`cockroach.PrivateEndpointConnection` submits the GCP connection ID to `POST
/v1/clusters/{id}/networking/private-endpoint-connections`, then polls the list
endpoint until `STATUS_AVAILABLE`.

`STATUS_PENDING`, `STATUS_PENDING_ACCEPTANCE`, and `STATUS_REJECTED` are
retryable because Cockroach's official provider treats them as convergence
states. Deleting calls the endpoint-specific DELETE route and treats missing or
already deleted connections as success. Its physical ID is
`{cluster_id}:{endpoint_id}`.

### Private DNS

`gcp.dns.ManagedZone` creates a private zone bound to the component VPC. Both
managed-zone DNS names and record-set names accept typed output references and
normalize a trailing dot at provider time. `gcp.dns.RecordSet` retains its
literal-name API for compatibility and gains an optional name output.

Each zone is scoped to one Cockroach regional private hostname. Its apex A
record points to that region's PSC address and depends on the accepted
Cockroach connection, so the graph does not advertise an endpoint before the
cross-provider handshake is ready.

## Dependency And Readiness Order

The graph order is:

```text
project APIs + VPC
  -> subnet + endpoint service
  -> cluster region
  -> internal address
  -> GCP PSC endpoint
  -> Cockroach endpoint connection (waits for STATUS_AVAILABLE)
  -> private DNS zone and record
```

Output references create most edges automatically. Explicit edges enforce API
enablement, ensure the cluster projection waits for Cockroach to publish the
private endpoint hostname, and ensure DNS records wait for connection
acceptance. Destruction runs in reverse, removing DNS and accepted connections
before forwarding rules, addresses, subnets, and the VPC.

`gcp.global.ContainerService` accepts this graph through `base_graph` and maps
the returned bindings through `regional_direct_vpc`. The resulting graph keeps
the protected cluster, private connectivity, regional Cloud Run services, and
global load balancer in one dependency-complete DAG.

## Validation

Build-time validation rejects empty regions, duplicate regions, invalid subnet
CIDRs, region sets that differ from configured GCP service regions, and
non-Premium GCP configuration. Owning the network ensures every consumer
resource uses the configured GCP project.

Provider-time validation rejects:

- a Cockroach cluster whose cloud provider is not GCP;
- a missing or mismatched Cockroach region;
- a service attachment whose regional path differs from the declared region;
- a GCP network, subnet, or address outside the configured project/region;
- a PSC connection associated with the wrong regional endpoint service; and
- malformed private DNS names or endpoint IDs.

No `cockroach.AuthorizedNetwork` node is constructed by this component. Public
static egress and PSC remain deliberately separate networking modes.

## Drift, Import, And Replacement

Identity fields are immutable. Changes to project, region, network, subnet,
service attachment, address, endpoint ID, cluster ID, or private DNS identity
plan replacement. Polling status and server-generated output differences do not
create drift.

All low-level resources implement import. Read-only cluster region and private
endpoint service resources import by their composite identities. Managed zones,
addresses, forwarding rules, and endpoint connections import by the provider's
physical ID after validating the desired identity.

## Failure Semantics

Polling uses `OperationContext`, including cancellation, fake clocks, and
deadlines. Transient HTTP and rate-limit failures use the existing clients'
retry behavior. Unexpected provider state is `ProviderBug`; identity and
topology mismatches are `InvalidConfiguration`; deadlines are
`ProviderTimeout`.

No secret material is introduced by PSC. Cluster IDs, service attachments,
connection IDs, IPs, and DNS names are public infrastructure outputs.

## Alternatives Rejected

- **Wait for GCP `ACCEPTED` during forwarding-rule creation:** this deadlocks
  before Cockroach receives the connection ID.
- **Use only Service Directory automatic DNS:** it does not make the typed
  Cockroach regional hostname the application contract.
- **Require users to provide an arbitrary VPC and subnets:** the component could
  not prove project and regional alignment from output references alone.
- **Represent all regions as one dynamic map output:** Ziac would lose static
  output descriptors and per-region dependency edges.
- **Create public allowlists as a fallback:** that silently weakens the selected
  private-network contract.

## Verification Boundary

Task 6.6 is complete when unit and scripted provider tests prove exact API
payloads, polling, identity normalization, imports, deletes, graph ordering,
typed outputs, eligibility, region matching, private DNS, and the absence of
public allowlists. Authenticated GCP and Cockroach data-path verification remains
the explicit Task 6.7 live gate.
