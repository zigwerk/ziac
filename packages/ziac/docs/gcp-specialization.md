# GCP Specialization

Ziac treats Google Cloud as an architecture it understands, not a bag of CRUD
resources. The provider compiles application constraints into one of two Cloud
Run realizations, derives Google API and IAM requirements from the resulting
graph, and preserves Google API semantics through planning, mutation, state,
readiness, and visual evidence.

Cloudflare is outside this provider boundary. The supported application path is
Zig source to Artifact Registry, Cloud Run, the Premium global external
Application Load Balancer, and CockroachDB.

## Contract Supply Chain

The source lock is `proto/googleapis.lock.json`. It records:

- `googleapis/googleapis` revision
  `95de37fafded89761dd958268242904a6d893eae`;
- `protoc` 30.2 and hashes for critical Cloud Run and annotation sources;
- a 25-file transitive descriptor set with imports and source information;
- the deterministic semantic snapshot hash.

`gcp.proto_contract` reads `FileDescriptorSet` directly from protobuf wire
format. It discovers services, methods, service hosts, message fields, nested
messages, and `google.api.field_behavior` extensions. It does not scrape source
text or require `protoc` at runtime.

```sh
zig build proto-snapshot > proto/cloud-run-v2.contract.json
```

The release gate verifies both locked artifacts. `diffFacts` classifies added,
removed, and behavior-changing fields and marks removals plus new required or
immutable behavior as breaking. Provider upgrades therefore expose semantic
consequences before generated metadata changes.

## AIP-Aware Planning

`gcp.aip` turns Google API annotations into IaC decisions:

- output-only changes are evidence, never desired-state drift;
- identifier and immutable changes require replacement;
- mutable paths form a stable, sorted field mask;
- deterministic operation identities are UUID-shaped and stable per
  stack/resource/operation;
- pagination tokens and unreachable regions make discovery incomplete;
- generation, observed generation, reconciliation, terminal conditions, and
  revision convergence determine readiness;
- `google.rpc.Status` codes and detail types become typed causes, including
  quota and precondition failures.

The Cloud Run provider consumes these rules. Its update mask is derived from
changed API groups instead of a constant, observed etags are sent as
compare-and-swap preconditions, and readiness cannot pass while the service is
reconciling or its observed generation/revision is stale.

Cloud Run supports `validate_only` on create, update, and delete. The RPC
descriptors expose those query fields so a live preflight adapter can invoke the
same request contract without mutation.

## Architecture Compiler

`ContainerService` and `ZigService` expose:

```zig
.realization = .automatic
.realization = .native_multi_region
.realization = .controlled_regional_fleet
```

Automatic mode chooses `native_multi_region` for a uniform stateless service.
The graph contains one mutable Cloud Run v2 service at `locations/global`, its
`multiRegionSettings.regions`, one serverless NEG per region, and the shared
global load-balancing chain.

Automatic mode chooses `controlled_regional_fleet` when the declaration needs:

- regional or shared Direct VPC configuration;
- CockroachDB Private Service Connect locality;
- independently mutable regional bindings or configuration;
- a canary region that must converge before the remaining fleet.

Forcing native mode with a fleet-only requirement returns
`NativeMultiRegionIncompatible` before graph execution or cloud access. The
selected realization and human-readable reason are retained on the component.

Native regional replicas are provider-managed and read-only. Ziac mutates the
global service and continues to create regional serverless NEGs for nearest
healthy routing through the Premium global load balancer.

## Permission And Preflight Compiler

`gcp.intelligence.synthesizeGraph` inspects resource types and emits sorted,
deduplicated API services, RPC methods, and IAM permissions. This is narrower
than assigning a static provider role because requirements follow the compiled
topology.

`evaluatePreflight` compares those requirements with an evidence snapshot for:

- Service Usage enablement;
- `TestIamPermissions` results;
- billing state;
- requested and available regions;
- quota sufficiency;
- Organization Policy;
- VPC Service Controls.

Any missing evidence is a typed finding and `ready` remains false. The planner
does not silently grant roles, enable services, move regions, or relax policy.

Topology advice compares Cloud Run regions, CockroachDB regions, residency
allowlists, private connectivity, and rollout independence. It returns findings
and a recommended realization while preserving the exact declared regions.
Cloud Asset drift classification distinguishes active reconciliation, missing
managed assets, and unexpected assets. Monitoring/SLO signals gate rollout by
availability, p95 latency, and remaining error budget.

## RPC Transport Boundary

The production path remains protobuf-defined REST/JSON transcoding. Ziac can
advertise gRPC only through a transport that proves all of these capabilities:

- HTTP/2 with TLS and trailers;
- deadlines and cooperative cancellation;
- multiplexing, connection reuse, and flow control;
- bounded message framing;
- redacted diagnostics.

`gcp.grpc` supplies bounded unary framing, trailer status parsing, the qualified
transport interface, and canonical REST/gRPC parity checks. One missing
capability makes `grpc_http2` false, so transport selection falls back to REST.
Google's experimental `$rpc` protocol remains a separate explicit capability
and is unsupported by Cloud Run's descriptor.

This boundary is intentional. Zig 0.16's standard HTTP client is not treated as
an audited HTTP/2 implementation, and Ziac does not infer production safety
from an adapter name. A future nghttp2/libcurl or native adapter can be enabled
without changing resources or state after deterministic and live parity gates.

## Evidence

```sh
zig build test --summary all
zig build examples --summary all
zig build proto-snapshot
zig build release-gate --summary all
```

`examples/gcp_specialization.zig` demonstrates native topology compilation,
graph-derived RPC/IAM synthesis, and a passing mutation-free preflight snapshot.
Credential-free tests prove deterministic semantics and fail-closed transport
selection. Authenticated org, quota, Cloud Asset, Monitoring, failover, and
Cockroach data-path acceptance remains separately identified by the live-test
manifest; local tests never claim that evidence.
