# GCP Network Delivery

M69 completes explicit VPC policy and regional internal load balancing for
Compute workloads. It follows Ziac's three provider layers: typed primitives,
hardened lifecycle adapters and opinionated components.

## Managed Resources

`Firewall` uses tagged ingress or egress direction and an allow-or-deny action.
Source ranges, destination ranges, tags and service accounts remain separate,
and mutable policy uses the current Google fingerprint. `Route` accepts one
typed next hop and replaces conservatively when destination or route policy
changes.

Global and regional health checks support HTTP, HTTPS, HTTP2, TCP, SSL and
gRPC. `InternalAddress`, `RegionBackendService`, `RegionUrlMap`,
`RegionTargetHttpProxy` and `ForwardingRule` cover both regional internal
passthrough and internal managed application load balancers. Regional
frontends are immutable ownership boundaries; backend, health, map and proxy
policy can update with compare-and-swap state.

## Components

- `NetworkPolicy` composes explicit firewalls and routes without inventing
  broad ingress or a default internet path.
- `InternalPassthroughLoadBalancer` creates a retained private VIP, regional
  health check, `INTERNAL` backend and TCP, UDP or L3 forwarding rule.
- `RegionalInternalApplicationLoadBalancer` creates an `INTERNAL_MANAGED`
  HTTP path through a regional proxy and URL map. It requires an explicit
  proxy-only subnet resource dependency and performs no hidden VPC mutation.

`examples/network_delivery.zig` shows an internal HTTP API backed by a regional
instance group, with health-source firewall policy and a proxy-only subnet.

## GCP Intelligence

Graph synthesis derives `compute.googleapis.com` and exact CRUD, network use,
subnetwork use, address use, health-check use, backend use, URL-map use and
proxy use permissions. It does not substitute a broad Compute administrator
role.

Cloud Asset discovery maps firewall, route, health-check, backend, URL-map and
proxy identities from canonical resource names. Addresses and forwarding rules
are adopted into the internal-delivery types only when Cloud Asset properties
prove an internal load-balancing scheme. Ambiguous regional forwarding rules
remain generic observed resources.

Canvas artifacts expose policy action, direction, priority, protocol, health
path, private frontend mode, ports, backend count and global-access state.
Dependencies through the regional proxy path are marked as private traffic;
backend-to-health-check edges are marked as health probes.

Configuration estimates accept explicit Catalog SKU IDs and quantities for
forwarding-rule hours, processed GiB and health probes. They are never labelled
as actual billed cost.

## Qualification

The deterministic product gate applies both internal load-balancer modes,
imports the resources into empty state, refreshes to no-op, cleans up and emits
`ziac.gcp.network-delivery-qualification.v1` evidence.

`scripts/qualify-network-delivery.sh` is the separate authenticated boundary.
It requires ADC, a project ending in `-ziac-disposable`, named backend services,
both forwarding rules and a probe VM. A passing receipt proves healthy L4 and
L7 backends, successful private TCP and HTTP probes, second-state no-op import
and destructive cleanup. Missing credentials or configuration produce a
structured exit-77 skip.

## Google Contracts

- [Compute Engine v1 REST](https://cloud.google.com/compute/docs/reference/rest/v1)
- [VPC firewall rules](https://cloud.google.com/firewall/docs/firewalls)
- [Routes](https://cloud.google.com/vpc/docs/routes)
- [Internal passthrough Network Load Balancer](https://cloud.google.com/load-balancing/docs/internal)
- [Regional internal Application Load Balancer](https://cloud.google.com/load-balancing/docs/l7-internal)
- [Cloud Asset supported types](https://cloud.google.com/asset-inventory/docs/asset-types)
- [Cloud Load Balancing pricing](https://cloud.google.com/vpc/network-pricing#lb)
