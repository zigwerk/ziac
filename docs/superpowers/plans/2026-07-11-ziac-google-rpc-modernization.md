# Ziac Google RPC Modernization Plan

Date: 2026-07-11

## M9.1: RPC Contract Kernel

Status: implemented on 2026-07-11.

- Add failing tests for pinned Cloud Run RPC descriptors, transport selection,
  resource-name validation, and REST path expansion.
- Implement `gcp/rpc.zig` and export it from the GCP facade.
- Migrate Cloud Run CRUD path construction to the descriptor kernel.
- Preserve existing scripted provider requests and release-gate behavior.

Evidence:

- `gcp.rpc` pins `googleapis/googleapis` revision
  `95de37fafded89761dd958268242904a6d893eae` and describes Cloud Run v2 CRUD,
  REST bindings, routing fields, query names, LRO types, supported transports,
  and AIP-relevant semantics.
- Resource-template expansion rejects malformed or mismatched Google resource
  names and constructs canonical REST paths and query fields.
- Transport selection prefers gRPC only with declared HTTP/2 capability, uses
  REST transcoding otherwise, and cannot select experimental protobuf fallback
  for Cloud Run even when an operator allows experimental transports.
- Cloud Run read/create/update/delete request paths and methods now come from
  the descriptor kernel. Existing scripted lifecycle assertions pass unchanged.
- The release gate passes 54/54 steps with 354/355 tests; the only skip remains
  authenticated Cockroach Cloud SQL acceptance. The native distroless
  ZigService container and release secret checks pass.

## M9.2: Proto Lock And Generator

Status: implemented on 2026-07-11.

- Vendor a small lock manifest containing upstream commit and selected proto
  file hashes, not the complete googleapis repository.
- Build a deterministic `protoc` descriptor-set ingestion step.
- Generate Zig message metadata, HTTP bindings, field behaviors, resources,
  routing headers, LRO types, and semantic contract snapshots.
- Add a human-readable proto upgrade diff and compatibility gate.

## M9.3: AIP-Aware Planning

Status: implemented for Cloud Run and exported as a provider kernel on
2026-07-11.

- Generate update masks from changed client-owned fields.
- Classify immutable changes and suppress output-only/default drift.
- Carry etags and request IDs through state and mutation requests.
- Add validate-only provider preflight and partial-list/unreachable safeguards.
- Map `google.rpc.Status` details into typed zigeffect causes.

## M9.4: Audited gRPC Transport

Status: qualification boundary implemented on 2026-07-11; production gRPC
remains deliberately disabled until a network adapter passes every capability
and REST-parity gate. REST transcoding remains the qualified production path.

- Add bounded HTTP/2, unary framing, trailers, cancellation, deadlines,
  multiplexing, connection reuse, and flow control to zigeffect-std.
- Add protobuf wire encoding/decoding from pinned descriptors.
- Prove parity between gRPC and transcoded REST against scripted and live
  fixtures before enabling service-by-service preference.
- Keep experimental `$rpc` fallback opt-in and outside release qualification.

## M9.5: Native Multi-Region Cloud Run

Status: implemented on 2026-07-11.

- Add the global Cloud Run v2 service shape and multi-region settings.
- Add `automatic`, `native_multi_region`, and `controlled_regional_fleet`
  realization policies to `ContainerService` and `ZigService`.
- Reject native mode for regional Direct VPC, PSC, regional bindings, or
  controlled canary requirements.
- Integrate regional NEGs, global load balancing, service health, readiness,
  failover, and migration from existing fleet state.

## M9.6: GCP Intelligence

Status: deterministic graph synthesis, preflight evaluation, topology advice,
asset drift classification, and SLO rollout gates implemented on 2026-07-11.

- Synthesize least-privilege deploy/build/runtime IAM from the graph's RPCs.
- Add org-policy, VPC Service Controls, quota, API enablement, billing, and
  region capability preflight.
- Add cost, latency, residency, Cockroach locality, and carbon-aware topology
  advice without silently changing declared policy.
- Integrate Cloud Asset Inventory drift and Cloud Monitoring/SLO rollout gates.

## Verification

- Package tests, examples, compile-fail contracts, release gate, zigeffect-std,
  Postgres, tool hygiene, and clean-checkout verification remain mandatory.
- Live parity uses a disposable project to compare REST and gRPC observations,
  operation handles, final state, request diagnostics, and no-op plans.

## Completion Evidence

- The pinned 294 KiB descriptor set contains 25 transitive files and is locked
  by SHA-256 together with four critical source hashes.
- `zig build proto-snapshot` deterministically reproduces
  `proto/cloud-run-v2.contract.json`; the package tests verify both hashes.
- Cloud Run updates derive field masks from semantic input changes, preserve
  etags, ignore output-only fields, and use generation/reconciliation readiness.
- Automatic topology emits one `locations/global` service for a uniform
  workload. Direct VPC or independent canaries select a regional fleet; forcing
  an incompatible native topology fails before provider access.
- Unary gRPC framing, message bounds, trailer status, transport capability
  audit, and REST/gRPC parity contracts are implemented. An incomplete adapter
  cannot advertise `grpc_http2`, and the experimental `$rpc` protocol remains
  impossible to select implicitly.
- `zig build examples --summary all` passes 370/371 checks; the sole skip is the
  existing credentialed Cockroach Cloud acceptance test.
