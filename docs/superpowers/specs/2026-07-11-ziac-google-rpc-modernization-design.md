# Ziac Google RPC And GCP Specialization Design

Date: 2026-07-11
Status: deterministic implementation delivered; authenticated external acceptance pending configured infrastructure

## Objective

Make Google Cloud the deeply understood primary provider for Ziac. Provider
behavior should derive from Google's protobuf and API Improvement Proposal
contracts instead of hand-maintained URL knowledge, while preserving a
production-safe transport for every GCP service.

## Source Contract

The initial contract lock is `googleapis/googleapis` commit
`95de37fafded89761dd958268242904a6d893eae`. Generated Ziac metadata records:

- protobuf package, service, method, default host, and OAuth scopes;
- resource type and canonical resource-name patterns;
- HTTP transcoding bindings and request routing fields;
- field behavior such as required, identifier, immutable, and output-only;
- field masks, etags, request IDs, validate-only support, pagination, and
  unreachable regions;
- long-running operation response and metadata types;
- reconciliation, generation, conditions, and state fields.

The lock is upgraded deliberately with a semantic contract diff. CI must show
added, removed, or behavior-changing methods and fields before generated code
changes.

## Transport Decision

Ziac uses one method descriptor with multiple transports:

1. `grpc` is preferred when the service exposes it and zigeffect has an audited
   HTTP/2 transport with cancellation, deadlines, trailers, flow control,
   bounded messages, and redacted diagnostics.
2. `rest_transcoding` uses the proto's `google.api.http` binding and canonical
   protobuf JSON. This is the initial production transport and matches Ziac's
   existing HTTP runtime.
3. `rest_discovery` covers GCP surfaces whose supported contract is still a
   Discovery/REST API, notably parts of Compute and Storage.
4. `protobuf_http_fallback` refers to the `$rpc` protocol described by
   HowToRPC. Google labels it experimental, so Ziac must never select it unless
   an operator explicitly enables an experimental feature for a method whose
   contract declares support.

Resource code depends on RPC descriptors and typed messages, never directly on
a transport. The planner and state format are transport-independent.

## Cloud Run Architecture Compiler

Cloud Run v2 now exposes a declarative-friendly service at location `global`
with `multi_region_settings.regions`. Ziac adds two deployment realizations:

- `native_multi_region`: one global Cloud Run service, read-only regional
  replicas, one NEG per selected region, and the global load balancer. This is
  the simplest path for uniform stateless services.
- `controlled_regional_fleet`: one mutable service per region. Ziac selects
  this when an app requires regional Direct VPC subnets, Cockroach PSC locality,
  region-scoped bindings, independent canary progression, or per-region
  configuration.

`automatic` chooses the least complex valid realization at comptime and emits
the reason into the plan. An explicit incompatible choice fails before cloud
access.

## AIP-Aware IaC Semantics

Ziac treats Google API annotations as planning rules:

- output-only fields never create drift;
- immutable field changes become replacements;
- client-owned defaults remain distinct from server effective values;
- update masks are generated from the typed semantic diff;
- etags/fingerprints become mandatory compare-and-swap preconditions when
  available;
- validate-only methods provide mutation-free provider preflight;
- request IDs derive deterministically from plan and operation identity;
- LRO types drive checkpoint, polling, cancellation, and typed response unpack;
- reconciling, generation, conditions, and states drive readiness;
- pagination and unreachable-region fields prevent partial discovery from being
  mistaken for a complete read.

## GCP-Native Advantages

This specialization enables capabilities generic IaC engines struggle to make
coherent:

1. **Proto contract drift:** detect GCP API evolution before runtime and explain
   whether a provider upgrade adds capability, changes replacement behavior, or
   affects state.
2. **Architecture synthesis:** choose native multi-region Cloud Run or a
   controlled fleet from app bindings, networking, rollout, and database
   locality requirements.
3. **Permission synthesis:** derive the deployer, builder, and runtime IAM
   permissions from the exact RPC methods and resources in the graph.
4. **Mutation-free preview:** combine local diff with API validate-only,
   TestIamPermissions, quota, org-policy, region availability, and Service Usage
   checks.
5. **Google-semantic drift:** distinguish user fields, server defaults,
   effective values, output state, and active reconciliation instead of diffing
   arbitrary JSON.
6. **Topology intelligence:** co-plan Cloud Run regions, global load balancing,
   service health, Direct VPC, Cockroach gateways, latency, residency, and
   failover policy.
7. **Operational plans:** surface request IDs, quota subjects, LRO phase,
   condition failures, health state, and safe repair commands as typed causal
   evidence.

## Rejected Approaches

- Switching all calls to experimental protobuf-over-HTTP would reduce safety
  and API coverage.
- Waiting for full gRPC before using protobuf contracts would postpone the most
  valuable schema and AIP improvements.
- Generating opaque CRUD wrappers directly from protos would reproduce generic
  providers without Ziac's higher-level topology and comptime contracts.
- Replacing every regional fleet with native multi-region Cloud Run would break
  regional networking, PSC locality, and controlled canary requirements.

## Initial Acceptance

- A pinned RPC descriptor module models Cloud Run v2 CRUD, HTTP bindings,
  routing, LROs, field masks, etags, validate-only, and reconciliation.
- A structured path expander validates resource-name templates and produces the
  existing REST paths without ad hoc provider concatenation.
- Transport selection prefers gRPC only when audited HTTP/2 is available and
  never selects experimental fallback implicitly.
- Cloud Run provider contract tests pass through the descriptor layer with no
  state or behavior regression.
