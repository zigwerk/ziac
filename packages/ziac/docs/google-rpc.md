# Google RPC Contracts

## Why Proto-First

Most modern Google APIs are defined as protobuf RPC services and expose
REST/JSON through `google.api.http` transcoding. Ziac uses the protobuf contract
as its source of API meaning even when the selected wire transport is REST.
This avoids maintaining separate assumptions about RPC names, resource paths,
query names, request routing, long-running operations, and field behavior.

The source lock is `googleapis/googleapis` commit
`95de37fafded89761dd958268242904a6d893eae`. `gcp.rpc.cloud_run_v2` describes
Cloud Run `CreateService`, `GetService`, `UpdateService`, and `DeleteService`.
The Cloud Run provider builds its existing REST requests through these
descriptors and validates resource names against the proto path templates.

The lock includes a real descriptor set generated with imports and source
information. `gcp.proto_contract` verifies its SHA-256, ingests protobuf
descriptors directly, extracts methods and field behaviors, and emits
`proto/cloud-run-v2.contract.json` deterministically. Semantic upgrade diffs
identify additions, removals, and behavior changes.

## Transport Matrix

| Transport | Policy | Initial use |
| --- | --- | --- |
| gRPC over HTTP/2 | Preferred when audited and supported | Capability and parity gated |
| REST/JSON transcoding | Production default | Cloud Run and modern proto APIs |
| Discovery REST | Supported where authoritative | Compute, Storage, legacy surfaces |
| `$rpc` protobuf-over-HTTP fallback | Experimental opt-in only | Excluded from release qualification |

The fallback described by Google's HowToRPC page is not a shortcut around a
real gRPC transport. `gcp.grpc` implements bounded unary framing, trailer
status, and a complete capability audit. A transport cannot advertise gRPC
unless it also proves TLS, HTTP/2, deadlines, cancellation, multiplexing,
connection reuse, flow control, and redacted diagnostics.

## AIP Semantics

RPC descriptors carry infrastructure-relevant Google API semantics:

- required, identifier, immutable, and output-only field behavior;
- canonical resource names and request-routing fields;
- update masks, etags, validate-only, and request IDs;
- LRO response and metadata types;
- reconciling, generation, condition, and state fields;
- pagination and unreachable-resource reporting.

These annotations now drive the reusable AIP planner. Cloud Run consumes
semantic update masks, etag compare-and-swap, generation/reconciliation
readiness, and output-only normalization. Partial-list and typed
`google.rpc.Status` contracts are exported for subsequent services.

## Cloud Run Multi-Region

Cloud Run v2 now supports a declarative-friendly global service with
`multi_region_settings.regions`. Ziac exposes three realization policies:

- `automatic` selects the least complex topology that satisfies the app;
- `native_multi_region` uses one global Cloud Run service and regional NEGs;
- `controlled_regional_fleet` preserves independent regional services.

Native mode is appropriate for uniform stateless workloads. The controlled
fleet remains required for regional Direct VPC subnets, CockroachDB PSC
locality, region-scoped bindings, per-region configuration, or independent
canary progression. The selected realization and reason are part of the plan.

Automatic and forced modes are implemented in `ContainerService` and
`ZigService`. Forced native mode fails before provider access when a regional
constraint is present.

## Provider Intelligence

The proto layer is the base for GCP-specific features rather than an end in
itself. Graph-derived API/RPC/IAM synthesis, preflight evidence, topology
advice, Cloud Asset drift disposition, and SLO rollout gates are implemented in
`gcp.intelligence`. See `gcp-specialization.md` for the complete boundary.
