# Global GCP ContainerService

`gcp.global.ContainerService` is Ziac's first high-level GCP component. It turns
one container image and domain into a deterministic graph for a global external
Application Load Balancer backed by regional Cloud Run services.

```zig
const regions = [_][]const u8{ "europe-west1", "us-central1" };

var service = try ziac.gcp.global.ContainerService.build(allocator, gcp, .{
    .name = "api",
    .image = "europe-west1-docker.pkg.dev/project/apps/api@sha256:...",
    .regions = &regions,
    .domain = "api.example.com",
    .dns_zone = "example-com",
});
defer service.deinit();
```

For two regions with DNS and HTTP redirect enabled, the component creates:

- two Cloud Run v2 services and two regional serverless NEGs;
- one Premium global address, backend service, HTTPS URL map, managed
  certificate, target HTTPS proxy, and port-443 forwarding rule;
- one HTTPS-redirect URL map, target HTTP proxy, and port-80 forwarding rule;
- one A record in the referenced existing Cloud DNS zone.

Adding regions adds exactly one Cloud Run service and one NEG per region. The
remaining resources stay global singletons.

## Wiring And Ordering

The component binds every consumer to typed producer outputs. The DNS record
and forwarding rules carry the global address's typed `address` output as a
canonical desired input. Ziac derives the dependency edge, waits for address
state, and resolves the allocated IP only while building the provider request.
The desired hash continues to contain the output identity, so refresh is stable
without predicting or persisting a builder-side IP.

The graph validates acyclic before the component is returned. Apply follows its
dependency order; destroy automatically reverses it so forwarding rules and
proxies are removed before the address, certificate, backends, NEGs, and
regional services.

## Traffic Policy

Regional services use
`INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER`. The component disables the Cloud Run
invoker IAM check so public requests arriving through the external load
balancer can reach the container. Direct internet requests to the service's
`run.app` URL remain blocked by ingress. Setting invoker access and ingress are
separate controls; changing one does not substitute for the other.

The component requires at least two unique regions and Premium network tier.
`health_mode = .production` additionally requires at least one warm instance per
region plus startup and liveness probes. Cloud Run validates all probe, scaling,
resource, environment, secret-volume, and Direct VPC settings before graph
construction completes.

## TLS And DNS

Managed certificate creation ends when the Compute operation completes, not
when issuance is `ACTIVE`. Use the explicit certificate readiness helper at a
release gate. `dns_zone` is optional and always references an existing zone;
the component never owns or destroys that zone. HTTP-to-HTTPS redirect is on by
default and can be disabled with `http_redirect = false`.

The component exposes a known typed `url`, the allocated `ip_address` output,
and the managed `certificate_status` output. The authenticated two-region
deployment, health probe, failover, failback, and teardown sequence remains the
M5 live acceptance gate.

The compiled CLI exposes this graph as `--stack global-container`. Configure it
with `ZIAC_LIVE_REGIONS`, `ZIAC_LIVE_IMAGE`, `ZIAC_LIVE_DOMAIN`, and optional
`ZIAC_LIVE_DNS_ZONE`; live commands still require `--provider gcp --allow-live`,
and credential-gated acceptance also requires `--live-test` plus a disposable
project suffix.
