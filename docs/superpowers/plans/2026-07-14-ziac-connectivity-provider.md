# Ziac M71 Connectivity Provider Plan

Date: 2026-07-14
Design: `docs/superpowers/specs/2026-07-14-ziac-connectivity-provider-design.md`
Status: locally complete; authenticated disposable-project qualification pending

## Contract And Tests

- [x] Add failing declaration and validation tests for all nine resources.
- [x] Add failing secret-redaction, replacement and canonical import tests.
- [x] Add failing router-child conflict and sibling-preservation tests.
- [x] Add failing peering method and Compute operation-resume tests.
- [x] Add failing NCC etag, field-mask and generic LRO tests.

## Typed Primitives

- [x] Extend Router with optional BGP configuration.
- [x] Implement HA and external VPN gateway plus VPN tunnel declarations.
- [x] Implement router-interface, BGP-peer and network-peering declarations.
- [x] Implement NCC hub, spoke and service-connection-policy declarations.
- [x] Register Network Connectivity endpoint, catalog, exports and provenance.

## Hardened Provider

- [x] Add Compute VPN CRUD/import and scoped operation resume.
- [x] Add fingerprint-safe router child mutation with bounded conflict retry.
- [x] Add native VPC peering add/update/remove lifecycle.
- [x] Add NCC CRUD/import, LRO checkpoint/resume, etags and field masks.
- [x] Normalize output-only defaults and preserve typed output wiring.
- [x] Wire all resources through the shared live provider.

## Components And Product Surface

- [x] Add `HaVpnConnection` and `BidirectionalVpcPeering`.
- [x] Add `VpcConnectivityMesh` and `PrivateServiceConnectivityPolicy`.
- [x] Add exact API and permission synthesis.
- [x] Add Cloud Asset ownership reconciliation.
- [x] Add VPN, BGP, peering, NCC and PSC canvas metadata and edges.
- [x] Add explicit configuration-estimate connectivity costs.

## Distribution And Qualification

- [x] Add public example and installed documentation.
- [x] Add local apply/import/refresh/no-op/cleanup receipt.
- [x] Add fail-closed authenticated qualification runner.
- [x] Run Testing v2, examples, migration, typecheck and release gates.
- [x] Record evidence, update roadmaps and commit M71.

## Evidence

The Testing v2 package gate is complete with 737 discovered and executed tests,
736 passed, one credential-gated skip, and zero failures, pending tests, leaks
or logged errors. The catalog contains 149 managed resource types. The live
qualification runner fails closed and reports a structured exit-77 skip when
ADC or disposable-project configuration is absent. Broader release evidence is
complete for public examples, the Testing v2 migration guard, root TypeScript,
formatting and static secret checks. The aggregate release gate reached its
container lane but could not complete because the local Docker daemon returned
empty engine metadata and wedged `docker info`; no container result is claimed.
