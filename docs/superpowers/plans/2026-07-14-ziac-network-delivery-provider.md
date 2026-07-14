# Ziac M69 Network Delivery Provider Plan

Date: 2026-07-14
Design: `docs/superpowers/specs/2026-07-14-ziac-network-delivery-provider-design.md`
Status: locally complete; authenticated qualification pending

## Contract And Tests

- [x] Add failing declaration tests for all nine resources.
- [x] Add failing policy-union, next-hop and load-balancer-mode validation.
- [x] Add failing global/regional operation, fingerprint and import tests.

## Typed Primitives

- [x] Implement Firewall and Route declarations.
- [x] Implement global and regional HealthCheck declarations.
- [x] Implement InternalAddress and RegionBackendService declarations.
- [x] Implement RegionUrlMap, RegionTargetHttpProxy and ForwardingRule.
- [x] Register catalog, exports and pinned Compute v1 provenance.

## Hardened Provider

- [x] Add canonical global/regional CRUD, import and operation resume.
- [x] Add fingerprint-aware mutable firewall, health and backend updates.
- [x] Add immutable route, address and forwarding-rule replacement boundaries.
- [x] Normalize output-only state and preserve output-backed references.
- [x] Wire all resources through the live provider dispatcher.

## Components And Product Surface

- [x] Add `NetworkPolicy`.
- [x] Add `InternalPassthroughLoadBalancer`.
- [x] Add `RegionalInternalApplicationLoadBalancer`.
- [x] Add exact API/permission and runtime traffic synthesis.
- [x] Add Cloud Asset identity and ownership reconciliation.
- [x] Add canvas topology, health and private traffic metadata.
- [x] Add explicit forwarding, data and probe cost estimates.

## Distribution And Qualification

- [x] Add public examples and installed agent documentation.
- [x] Add local receipt and fail-closed authenticated runner.
- [x] Compile examples and run Testing v2 package suite.
- [x] Run formatting, migration guard, root typecheck and release gate.
- [x] Record evidence, update both roadmaps and commit M69.
