# Ziac M71 Connectivity Provider Design

Date: 2026-07-14
Status: accepted for implementation

## Objective

Make hybrid, cross-VPC and service-producer connectivity a first-class Ziac
surface. M71 provides a modern HA VPN path, explicit BGP ownership, safe VPC
peering, Network Connectivity Center (NCC) hub-and-spoke topology and Private
Service Connect policy while retaining the existing Service Networking private
service-access resources.

Classic VPN dynamic routing is intentionally excluded. Google deprecated that
path on 2025-08-01 and recommends HA VPN for production dynamic routing. Ziac
will not make a deprecated architecture the easy path; existing Classic VPN
resources remain observable through Cloud Asset Inventory.

## Resource Surface

M71 adds nine managed resource types:

1. `gcp.compute.HaVpnGateway`
2. `gcp.compute.ExternalVpnGateway`
3. `gcp.compute.VpnTunnel`
4. `gcp.compute.RouterInterface`
5. `gcp.compute.RouterBgpPeer`
6. `gcp.compute.NetworkPeering`
7. `gcp.networkconnectivity.Hub`
8. `gcp.networkconnectivity.Spoke`
9. `gcp.networkconnectivity.ServiceConnectionPolicy`

The existing `gcp.compute.Router`, `gcp.compute.PrivateServiceRange`,
`gcp.servicenetworking.Connection` and `ziac.gcp.PrivateServiceAccess` remain
the service-networking foundation and are integrated rather than duplicated.

Compute resources use the pinned Compute v1 Discovery contract. NCC and PSC
policy resources use the Network Connectivity v1 AIP contracts and generic
Google long-running operations.

## Typed Declarations

`Router` gains optional BGP configuration without breaking existing callers.
The local ASN must be in the private 16-bit or 32-bit ASN ranges accepted by
Cloud Router. Router identity remains immutable while BGP advertisement policy
is mutable through a fingerprint-safe update.

An HA VPN gateway references a typed network output and is regional. An
external VPN gateway declares one, two or four numbered interfaces with public
IPv4 addresses. A VPN tunnel selects one local and one peer interface, a Cloud
Router, IKE version 2 and a secret output reference. The pre-shared key is
resolved only while serializing the create request, is never persisted in
desired or observed state, and is overwritten with a redacted body after use.
The provider exposes only Google’s shared-secret hash and operational status.

Router interfaces and BGP peers are synthetic children of a Cloud Router.
Their physical IDs name the containing router and child name. Each adapter
reads the current router, preserves unrelated child arrays, submits the current
fingerprint and retries a bounded 409 or 412 conflict. A router interface owns
one VPN tunnel attachment and link-local address range. A peer owns its
interface, peer ASN, local/peer addresses, route priority, advertisement policy
and optional BFD policy.

VPC peering is a synthetic child of the local network. It owns one named entry
in `Network.peerings` and uses `addPeering`, `updatePeering` and
`removePeering`, not a whole-network replacement. Route import/export,
public-IP route behavior, IP stack and update strategy are explicit. A
one-sided peering is legal at the primitive layer but the component layer
creates and validates both sides.

NCC Hub is global and owns description, labels, policy mode, preset topology
and PSC export behavior. Spoke is location scoped and uses a tagged link union:
exactly one VPC network, VPN tunnel set, Interconnect attachment set or router
appliance set. Hub, location and link kind are immutable. Service Connection
Policy owns its network, service class, consumer subnetworks, producer location
policy and allowed hierarchy levels. Mutable NCC resources use etags and exact
field masks; delete also carries the current etag.

## Hardened Lifecycle

Compute operations checkpoint by global or regional scope and resume through
the shared operation engine. Gateway, tunnel and external-peer identity changes
replace conservatively. Reads normalize self links to canonical resource names
while preserving typed output references when their resolved values match.

Router-child and peering mutations are compare-and-swap operations over a
shared parent. The adapter never owns or drops a sibling created by another
Ziac project or another tool. Import requires the complete canonical synthetic
physical ID so ownership cannot be inferred from a short name.

NCC resources create, patch and delete through resumable generic LROs. Reads
strip output-only timestamps, states, route tables and summaries from desired
inputs but expose health state and reasons as outputs. Failed reconciliation
is reported as a provider diagnostic rather than being normalized into
readiness.

## Opinionated Components

`HaVpnConnection` composes a BGP-capable router, HA VPN gateway, external peer
gateway, two tunnels, two router interfaces and two BGP peers. It requires two
independent local/peer paths, unique link-local BGP pairs and two typed secret
references. It is the default production hybrid-connectivity abstraction.

`BidirectionalVpcPeering` creates matching peering entries on two networks,
with symmetric stack and update strategy. Each side’s import setting is derived
from the opposite side’s export setting and validation rejects a route policy
that cannot become effective.

`VpcConnectivityMesh` creates one NCC hub and one global VPC spoke per network
with deterministic names. `PrivateServiceConnectivityPolicy` wraps a service
connection policy and exposes its PSC connection-limit output. Service
Networking’s `PrivateServiceAccess` remains the higher-level abstraction for
legacy producer services such as Cloud SQL private IP.

## Product Integration

Permission synthesis includes exact Compute VPN, Router and Network peering
methods, Network Connectivity CRUD, `networkconnectivity.groups.use` where
needed and operation polling. Cloud Asset mapping adopts VPN gateways, external
gateways, tunnels, NCC hubs, spokes and service-connection policies. Router
children and peerings are reconstructed from parent properties and remain
synthetic ownership candidates.

Canvas metadata exposes account/VPC containment, VPN paths, tunnel status,
interface numbers, ASNs, BGP status, route policy, hub topology, spoke kind and
PSC consumer subnetworks. Connectivity edges are flat topology edges and are
distinguished as encrypted tunnel, BGP session, peering, hub membership or
service producer access.

Configuration estimates use explicit quantities and unit rates. The default
catalog assumptions track tunnel hours, VPN egress GiB, VPC/hybrid spoke hours,
NCC advanced-data GiB and site-to-site transfer GiB. They are labelled
configuration estimates, not billing data. Cloud Router, hub and peering base
resources carry zero base price where Google does not charge for them.

## Qualification

The local receipt applies an HA VPN topology, bidirectional peering, NCC mesh
and service policy through deterministic transports, imports them into empty
state, refreshes to a no-op plan and performs explicit cleanup while proving
unrelated parent children survive.

The authenticated runner requires ADC and a disposable billing-enabled project
plus a separately controlled VPN peer. It must observe both tunnels established,
both BGP sessions up, routes exchanged in both directions, active peering/NCC
spokes, a usable service connection policy and complete cleanup. Missing
authority exits with structured status 77 and is never represented as a pass.

## Definition Of Done

M71 is locally complete when declarations, lifecycle adapters, components,
intelligence, estate, visual, cost, documentation, examples and qualification
boundaries pass the release gate. Establishing an external peer and exchanging
real traffic remain separate authenticated evidence.

## Primary Google Contracts

- Compute v1 VpnGateways, ExternalVpnGateways, VpnTunnels, Routers and Networks.
- Network Connectivity v1 Hubs, Spokes and ServiceConnectionPolicies.
- Service Networking v1 Services.Connections.
- Cloud VPN and Network Connectivity Center pricing contracts.
