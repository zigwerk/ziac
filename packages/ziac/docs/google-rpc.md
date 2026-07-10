# Google RPC Contracts

## Why Proto-First

Most modern Google APIs are defined as protobuf RPC services and expose
REST/JSON through `google.api.http` transcoding. Ziac uses the protobuf contract
as its source of API meaning even when the selected wire transport is REST.
This avoids maintaining separate assumptions about RPC names, resource paths,
query names, request routing, long-running operations, and field behavior.

The first source lock is `googleapis/googleapis` commit
`95de37fafded89761dd958268242904a6d893eae`. `gcp.rpc.cloud_run_v2` describes
Cloud Run `CreateService`, `GetService`, `UpdateService`, and `DeleteService`.
The Cloud Run provider builds its existing REST requests through these
descriptors and validates resource names against the proto path templates.

## Transport Matrix

| Transport | Policy | Initial use |
| --- | --- | --- |
| gRPC over HTTP/2 | Preferred when audited and supported | Planned per-service rollout |
| REST/JSON transcoding | Production default | Cloud Run and modern proto APIs |
| Discovery REST | Supported where authoritative | Compute, Storage, legacy surfaces |
| `$rpc` protobuf-over-HTTP fallback | Experimental opt-in only | Excluded from release qualification |

The fallback described by Google's HowToRPC page is not a shortcut around a
real gRPC transport. Ziac will only enable gRPC after zigeffect-std provides
bounded HTTP/2 framing, trailers, deadlines, cancellation, multiplexing, flow
control, and redacted diagnostics.

## AIP Semantics

RPC descriptors carry infrastructure-relevant Google API semantics:

- required, identifier, immutable, and output-only field behavior;
- canonical resource names and request-routing fields;
- update masks, etags, validate-only, and request IDs;
- LRO response and metadata types;
- reconciling, generation, condition, and state fields;
- pagination and unreachable-resource reporting.

The target is for these annotations to drive replacement classification, drift
normalization, compare-and-swap updates, mutation-free preflight, deterministic
idempotency, checkpointed LROs, and readiness without resource-specific string
logic.

## Cloud Run Multi-Region

Cloud Run v2 now supports a declarative-friendly global service with
`multi_region_settings.regions`. Ziac will expose three realization policies:

- `automatic` selects the least complex topology that satisfies the app;
- `native_multi_region` uses one global Cloud Run service and regional NEGs;
- `controlled_regional_fleet` preserves independent regional services.

Native mode is appropriate for uniform stateless workloads. The controlled
fleet remains required for regional Direct VPC subnets, CockroachDB PSC
locality, region-scoped bindings, per-region configuration, or independent
canary progression. The selected realization and reason are part of the plan.

## Provider Intelligence

The proto layer is the base for GCP-specific features rather than an end in
itself: semantic API upgrade diffs, IAM synthesis from actual RPCs,
validate-only and permission preflight, quota and org-policy checks, region and
database-locality planning, service-health failover, and SLO-gated rollouts.
