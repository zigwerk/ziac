# GCP Connectivity

Ziac M71 manages modern hybrid and cross-network connectivity through typed
Compute and Network Connectivity resources. It deliberately makes HA VPN the
default production path and does not scaffold deprecated Classic VPN dynamic
routing.

## Managed Resources

- `gcp.compute.HaVpnGateway`
- `gcp.compute.ExternalVpnGateway`
- `gcp.compute.VpnTunnel`
- `gcp.compute.RouterInterface`
- `gcp.compute.RouterBgpPeer`
- `gcp.compute.NetworkPeering`
- `gcp.networkconnectivity.Hub`
- `gcp.networkconnectivity.Spoke`
- `gcp.networkconnectivity.ServiceConnectionPolicy`

The existing `gcp.compute.Router`, `gcp.compute.PrivateServiceRange` and
`gcp.servicenetworking.Connection` remain part of the same connectivity model.

## Opinionated Components

`ziac.gcp.HaVpnConnection` composes a Cloud Router, HA VPN gateway, external
peer gateway, two tunnels, two router interfaces and two BGP peers. Both
pre-shared keys are secret outputs. Only the mutation request sees plaintext;
desired state, observed state, plans, logs and receipts retain references.

`ziac.gcp.BidirectionalVpcPeering` owns both project-local peering entries. The
primitive permits one-sided ownership for migrations, while the component
makes reciprocity explicit and supports different provider projects.

`ziac.gcp.VpcConnectivityMesh` creates an NCC hub and typed VPC, VPN,
Interconnect or router-appliance spokes. A router-appliance link keeps the VM
URI and peering IP together as one typed value.

`ziac.gcp.PrivateServiceConnectivityPolicy` manages PSC producer policy,
subnetworks and optional producer allowlists. Allowlists use canonical
`projects/...`, `folders/...` or `organizations/...` resource names.

## Lifecycle Safety

VPN resources resume regional or global Compute operations. Gateway and tunnel
identity changes replace conservatively. Router interfaces and BGP peers are
synthetic children: updates read the current router fingerprint, preserve all
unowned siblings and retry bounded `409` or `412` conflicts.

VPC peering uses Google's `addPeering`, `updatePeering` and `removePeering`
actions rather than replacing the Network. NCC resources use canonical AIP
names, generic long-running operation checkpoints, etags and exact update
masks. Imports require complete physical IDs.

## Agent And Canvas Model

Permission synthesis derives separate HA VPN, external gateway, tunnel,
router, peering, NCC hub, spoke and service-policy permissions. The canvas
emits `vpn_attachment`, `bgp_session`, `hub_membership` and `hub_attachment`
edges with typed connectivity inspector metadata.

Cloud Asset Inventory can adopt supported VPN gateways, external gateways,
tunnels, routers, hubs, spokes and service policies. Router children and VPC
peerings are embedded in their parent resources, so Ziac never guesses their
ownership from an observed parent alone.

## Cost Provenance

Configuration estimates keep four assumptions separate: VPN tunnel hours, NCC
hybrid-spoke hours, NCC VPC-spoke hours and NCC data-transfer GiB. These are
catalog estimates, not actual billed cost. Actual cost requires the customer's
Cloud Billing export.

Current list-price assumptions should be refreshed from the official
[Network Connectivity pricing](https://cloud.google.com/network-connectivity/pricing)
page. API behavior is pinned to the Compute v1 and Network Connectivity v1
Discovery documents.

## Qualification

`scripts/qualify-connectivity.sh` is the authenticated boundary. It requires a
billing-enabled disposable project, ADC, explicit resource names and a remote
VPN peer. It must observe established tunnels, learned routes, active NCC
resources, a readable PSC policy, second-state no-op import and complete
cleanup before emitting `authenticated=true`.

Without that environment the script exits `77` with a structured skip. Local
qualification is always marked unauthenticated.
