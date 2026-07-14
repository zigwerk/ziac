# Ziac M69 Network Delivery Provider Design

Date: 2026-07-14
Status: accepted for implementation

## Objective

Complete the ordinary VPC policy and regional internal-delivery path needed by
platform teams running Compute Engine workloads. M69 adds firewalls, routes,
health checks, regional backend services and both passthrough and proxy-based
internal load balancing without weakening Ziac's ownership or drift semantics.

## Resource Surface

M69 manages nine resource types:

1. `gcp.compute.Firewall`
2. `gcp.compute.Route`
3. `gcp.compute.HealthCheck`
4. `gcp.compute.RegionHealthCheck`
5. `gcp.compute.InternalAddress`
6. `gcp.compute.RegionBackendService`
7. `gcp.compute.RegionUrlMap`
8. `gcp.compute.RegionTargetHttpProxy`
9. `gcp.compute.ForwardingRule`

The resources use Compute v1 Discovery contracts. Firewall, route and global
health-check identity is global; the remaining resources are regional.
Existing `RegionalAddress` remains the external-address declaration so changing
an address purpose cannot silently repurpose an existing frontend.

## Policy And Lifecycle

Firewall declarations use an explicit direction and action union. An allow rule
cannot carry deny entries and vice versa. Source ranges, destination ranges,
source tags, target tags and target service accounts remain distinct. Priority,
logging and disabled state are updateable with current fingerprints. Network
identity and direction changes replace.

Routes declare one typed next hop: gateway, instance, IP, VPN tunnel or internal
load-balancer forwarding rule. Destination and next-hop identity are immutable;
priority and tags are visible but conservative replacement fields because the
Compute route API exposes insert/delete rather than patch.

Health checks share one typed contract for HTTP, HTTPS, HTTP2, TCP, SSL and
gRPC. Scope is encoded by the resource type. Check/timeout thresholds and log
configuration update in place with fingerprint-aware PUT. Protocol changes
replace to avoid ambiguous transport migration.

Regional backend services are tagged by load-balancer mode:

- `internal_passthrough` uses `INTERNAL` with TCP, UDP or `UNSPECIFIED` and one
  regional/global health check.
- `internal_application` uses `INTERNAL_MANAGED` with HTTP, HTTPS, HTTP2, H2C
  or gRPC and a regional health check.

Backends are explicit instance-group or NEG outputs with balancing, capacity,
failover and connection-draining policy. Updates fetch the current fingerprint,
preserve output-only fields and retry bounded 412 conflicts.

Regional URL maps and HTTP proxies are mutable by current fingerprint. HTTPS
frontends remain M70 because Certificate Manager and certificate maps must be
designed together. Regional forwarding rules are immutable frontends: mode,
network, subnet, address, protocol, ports and target/backend service changes
replace.

## Opinionated Components

`NetworkPolicy` composes explicit firewall and route declarations onto an
existing network. It never invents ingress sources or default internet routes.

`InternalPassthroughLoadBalancer` composes a regional internal address, health
check, backend service and forwarding rule around an M68 managed group or
another typed backend. It supports TCP, UDP and all-port L3 policy with
validation matching Google's frontend limits.

`RegionalInternalApplicationLoadBalancer` composes an internal address,
regional health check, `INTERNAL_MANAGED` backend, URL map, HTTP proxy and
forwarding rule. The caller supplies an existing regular subnet and an explicit
proxy-only-subnet dependency. Ziac validates both but does not create hidden
network mutations.

## Product Integration

Permission synthesis derives exact firewall, route, health-check, address,
backend, URL-map, proxy and forwarding-rule methods plus network/subnetwork use.
Cloud Asset mapping adopts official Firewall, Route, HealthCheck,
BackendService, UrlMap, TargetHttpProxy, Address and ForwardingRule identities
where scope can be proven from the asset name and properties.

The canvas renders firewall boundaries, route edges, health probes, L4/L7
backend membership and private frontend traffic. Inspector metadata includes
scheme, protocol, ports, priority, action, health path and global-access state.
Cost estimates keep forwarding-rule hours, processed bytes and health-check
probe assumptions explicit and configuration-based.

## Qualification

The local qualification composes both internal load-balancer modes, applies the
graph, imports into empty state, refreshes to no-op and performs
retention-aware cleanup. The remote runner requires ADC, a disposable project,
an existing VPC, backend instance group and proxy-only subnet. A passing receipt
must observe healthy backend status and successful private probes from a test
VM; local tests never claim that evidence.

## Definition Of Done

M69 is locally complete when all nine declarations, lifecycle adapters,
components, intelligence, estate, visual, cost, documentation, examples and
qualification boundaries pass the full release gate. Authenticated health and
private-connectivity proof remains a separate disposable-project status.

## Primary Google Contracts

- Compute v1 Firewalls and Routes REST resources.
- Compute v1 global and regional HealthChecks resources.
- Compute v1 regionBackendServices, regionUrlMaps,
  regionTargetHttpProxies and forwardingRules resources.
- Internal passthrough Network Load Balancer architecture.
- Regional internal Application Load Balancer architecture.
