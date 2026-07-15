# Ziac Hermes Compute Compatibility Implementation Plan

**Goal:** Deliver M84C's first third-party compatibility application as a
secure, low-cost Hermes Agent deployment on Compute Engine.

**Design:**
[`2026-07-15-ziac-hermes-compute-compatibility-design.md`](../specs/2026-07-15-ziac-hermes-compute-compatibility-design.md)

**Status:** Remote-desktop amendment shipped deterministically. Authenticated
execution still requires a billed
`*-ziac-disposable` project, a non-production Hermes secret, a test hostname,
and a registered Nous dashboard OAuth client.

## Task 1: Freeze The Component Contract

- [x] Add a test that builds the default Hermes graph and asserts its resource
  inventory, defaults, lifecycle flags, IAM scope, metadata, tags, and outputs.
- [x] Assert explicit dependency edges from secret version and IAM to the VM.
- [x] Assert IAP-only SSH, public TLS-only ingress, and that Hermes ports never
  enter a firewall.
- [x] Add negative tests for unpinned images, undersized machines/disks, region
  mismatch, malformed secret references, and invalid startup digests.
- [x] Run the focused test and retain the expected compile failure before the
  component exists.

## Task 2: Implement `gcp.HermesCompute`

- [x] Add the high-level component under `packages/ziac/src/gcp/` using existing
  Network, Subnetwork, Firewall, ServiceAccount, Secret, SecretVersion,
  SecretIamMember, and VirtualMachine resources.
- [x] Keep all secret payloads represented as secret references.
- [x] Add stable public outputs and export the component through the GCP facade.
- [x] Add explicit graph dependencies where values alone cannot encode order.
- [x] Pass the focused deterministic tests.

## Task 3: Add The Reviewed Guest Bootstrap

- [x] Add an idempotent Debian 12 startup script with bounded package retries,
  metadata-token retrieval, Secret Manager access, strict file permissions,
  pinned-image enforcement, localhost-only port publication, and Docker restart.
- [x] Emit useful non-secret bootstrap status to serial logs.
- [x] Add shell static checks and a contract test for sensitive invariants.
- [x] Document digest generation and secret rotation behavior.

## Task 4: External-Project Example And Qualification

- [x] Add a complete `examples/hermes_compute.zig` stack using only public Ziac
  APIs and operator-provided secret references.
- [x] Register the example with the package build where local conventions require
  it and run the Testing v2 migration guard after any build-file change.
- [x] Add a fail-closed live runner for a billed disposable project.
- [ ] Verify apply, VM readiness, container image, localhost listeners, IAP
  access, persistence across restart, no-op plan, destroy, and empty inventory.
- [x] Make authenticated execution skippable only through the existing explicit
  qualification contract, never as a passing cloud claim.

## Task 5: Product Documentation And Evidence

- [x] Publish operator documentation covering cost posture, prerequisites,
  deploy, OAuth desktop access, IAP recovery, updates, backups, resizing, and
  cleanup.
- [x] Add M84C to the current roadmap and mark deterministic implementation
  separately from authenticated qualification.
- [x] Link the guide from the Ziac README.
- [x] Run focused tests, package `zig build test`, inspect the complete Testing v2
  receipt, run shell/build hygiene gates, and report any credential-bound lane.

## Task 6: Make Hermes Desktop The Consumer

- [x] Add a failing contract proving a durable regional IP, public 80/443-only
  edge, optional Cloud DNS record, OAuth metadata, and typed desktop URL.
- [x] Add a public-output field to Compute network interfaces so a reserved
  regional address can be attached to a VM without flattening the value.
- [x] Keep 8642 and 9119 on host loopback while enabling Hermes' supervised
  desktop backend on non-loopback inside its container so the auth gate engages.
- [x] Run a pinned Caddy container as the TLS edge and proxy `/api/ws` and the
  supporting REST surface without special WebSocket configuration.
- [x] Require a valid desktop hostname and Nous OAuth client ID and set the
  canonical public callback URL.
- [x] Return `desktop_url` and `public_ip` outputs suitable for dashboard wiring.

## Task 7: Qualify The Remote Contract

- [x] Update the live runner to require a test domain, DNS zone, and OAuth client
  ID, and to fail closed when any are absent.
- [ ] Verify valid public TLS, OAuth provider advertisement, denied
  unauthenticated REST/WebSocket access, stable URL after restart, no-op plan,
  destroy, and empty inventory.
- [x] Update the external-project example, operator guide, roadmap, release
  checks, and evidence labels to describe Hermes Desktop rather than an IAP
  tunnel as the product path.
- [x] Run the focused test first, then the package suite, complete Testing v2
  receipt inspection, examples, shell/static checks, and release gates.
