# Ziac Hermes Compute Compatibility Design

**Date:** 2026-07-15
**Milestone:** M84C
**Status:** Accepted for implementation (remote-desktop amendment)

## Objective

Prove that a real third-party application can be described, deployed, operated,
and removed through Ziac without becoming a special-case provider fixture. The
first application is NousResearch Hermes Agent on one Google Compute Engine VM.
The default must be inexpensive enough for an individual developer while
remaining useful as a persistent backend for the Hermes Desktop application.

This lane complements, but does not replace, the purpose-built Ziac global E2E.
Core engine health is qualified by Ziac-owned probes; Hermes demonstrates that
the same public component surface can host software Ziac does not control.

## Deployment Contract

`gcp.HermesCompute` composes existing hardened resources into one graph:

1. a custom-mode VPC and one regional subnet;
2. an ingress firewall allowing TCP 22 only from Google IAP
   `35.235.240.0/20`, targeted to the Hermes VM tag;
3. a second ingress firewall allowing only TCP 80 and 443 from the internet,
   targeted to a separate desktop-edge VM tag;
4. one durable regional external IPv4 address and, when requested, one Cloud
   DNS `A` record for the desktop hostname;
5. a dedicated service account with no project-level role;
6. a Secret Manager secret and version sourced from a secret reference;
7. a secret-scoped `roles/secretmanager.secretAccessor` grant for the VM
   identity;
8. one retained balanced persistent boot disk; and
9. one Shielded VM with OS Login, project SSH keys blocked, pinned Hermes and
   TLS-proxy image contracts, and a secret-sourced startup script.

The VM receives a reserved public IPv4 address for durable outbound and desktop
connectivity. Hermes' OpenAI-compatible API on 8642 and desktop backend on 9119
remain published only on `127.0.0.1` at the host boundary. A pinned Caddy
container terminates HTTPS and proxies the declared hostname to the desktop
backend. Only 80 and 443 are public; 9119 is never admitted by a GCP firewall.
This avoids the fixed cost and extra resources of an external Application Load
Balancer while still presenting the desktop client with a stable HTTPS URL.

The official Hermes container runs `gateway run` with its supervised dashboard
backend enabled. The dashboard binds non-loopback inside the container so its
mandatory auth gate engages, while Docker publishes that port only to host
loopback. The deployment requires a Nous Portal OAuth client ID registered for
`https://<domain>/auth/callback`; the startup script sets both the OAuth client
ID and `HERMES_DASHBOARD_PUBLIC_URL`. The Hermes Desktop application connects to
the returned `https://<domain>` URL and upgrades chat traffic at `/api/ws`.

## Sizing And Persistence

The default machine type is `e2-medium`: two shared-core vCPUs, four GiB of RAM,
and enough capacity for Hermes controlling hosted model APIs. It aligns with
the official Hermes Compose memory budget and is the lowest-cost sensible
default. `e2-standard-2` is the documented upgrade for concurrent tools or
heavier local work.

The default disk is 30 GiB `pd-balanced`. `/opt/data` is mounted into the Hermes
container and resides on that retained boot disk. Instance deletion protection,
Ziac lifecycle protection, and disk retention are enabled by default; live
qualification explicitly disables them so cleanup can be proven.

The default guest is Debian 12. The startup script installs the distribution
Docker package, reads the environment file from Secret Manager with the VM's
metadata identity, and runs the pinned `nousresearch/hermes-agent` and official
Caddy images with restart policies. Both images must use an immutable digest or
explicit version tag; `latest` and untagged references are compile-time graph
validation errors.

## Secret Boundary

Hermes model keys and optional messaging tokens enter the graph as a
`SecretReference`, normally an environment-backed value such as
`HERMES_ENV_FILE`. The payload is written to Secret Manager by the provider and
never embedded in graph JSON, state, metadata, logs, or qualification receipts.

The startup script is also a `SecretOutput` with a required SHA-256 digest. This
preserves Ziac's existing startup-script integrity boundary. The checked-in
script is public source, but the apply path still verifies that the bytes used
by the provider match the reviewed artifact.

## Qualification

The qualification runner is fail-closed. It requires:

- a project ID ending in `-ziac-disposable`;
- authenticated `gcloud` and Ziac binaries;
- an explicit confirmation variable;
- a Hermes environment secret supplied by the operator;
- a Cloud DNS hostname and managed zone;
- a Nous dashboard OAuth client registered for that hostname; and
- cleanup enabled by default.

The runner creates the graph from an external-project-style example, applies
it, waits for the VM and containers, verifies the pinned images and
localhost-only backend listeners over IAP, then probes the public TLS status
endpoint. It proves that Hermes advertises OAuth, that unauthenticated API and
WebSocket access fail closed, that the service survives restart, and that the
desktop URL remains stable. It records redacted evidence, destroys resources,
and checks the relevant inventory is empty. Credentials, OAuth sessions, secret
payloads, access tokens, and environment files never enter the receipt.

## Public API

The component accepts project-specific names, region, zone, subnet CIDR,
machine type, disk size/type, source image, Hermes and proxy images, desktop
domain, optional Cloud DNS zone and TTL, Nous OAuth client ID, environment
secret source, startup-script secret output and digest, labels, and lifecycle
controls. It returns the complete graph plus a known desktop URL and VM,
address, network, subnet, disk, service-account, and secret outputs needed by a
caller or dashboard.

Validation rejects:

- an empty name, region, zone, CIDR, image, domain, OAuth client ID, or secret
  source;
- a zone outside the selected region;
- malformed desktop hostnames or OAuth client IDs;
- `latest` or untagged Hermes or proxy images;
- machine types below the declared four-GiB baseline;
- disks below 20 GiB;
- DNS configuration without a valid managed-zone name;
- direct public ingress to Hermes ports; and
- missing or malformed startup-script digests.

## Acceptance

The deterministic gate passes when tests prove the exact resource inventory,
dependency edges, static addressing, DNS wiring, private backend-port posture,
public TLS-only ingress, least-privilege IAM, OAuth configuration, protected
retained disk, secure VM metadata, default sizing, explicit override behavior,
image pinning, and invalid-input diagnostics. The authenticated gate remains
unqualified until a disposable-project receipt proves create, TLS and OAuth
health, desktop protocol access control, restart persistence, no-op planning,
destroy, and empty cleanup inventory.

## Sources

- Hermes Docker guide: <https://github.com/hermes-agent/hermes-agent/blob/main/website/docs/user-guide/docker.md>
- Hermes Desktop remote backend guide: <https://github.com/hermes-agent/hermes-agent/blob/main/website/docs/user-guide/desktop.md#connecting-to-a-remote-backend>
- Hermes dashboard authentication guide: <https://github.com/hermes-agent/hermes-agent/blob/main/website/docs/user-guide/features/web-dashboard.md#authentication-gated-mode>
- Hermes Compose contract: <https://github.com/NousResearch/hermes-agent/blob/main/docker-compose.yml>
- Google E2 machine types: <https://docs.cloud.google.com/compute/docs/general-purpose-machines>
- IAP TCP forwarding: <https://cloud.google.com/iap/docs/using-tcp-forwarding>
- Caddy automatic HTTPS: <https://caddyserver.com/docs/automatic-https>
