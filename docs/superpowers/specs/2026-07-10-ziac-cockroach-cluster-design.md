# Ziac Cockroach Cloud Cluster Design

**Status:** Validated for implementation on 2026-07-10

## Objective

Add a production-safe, mutable `cockroach.Cluster` resource for GCP-hosted
CockroachDB Cloud clusters. The resource supports Basic, Standard, and Advanced
plans, converges mutable capacity and topology, waits for long-running cluster
operations, and makes accidental cluster deletion difficult at both the Ziac
and Cockroach Cloud layers.

This is the cluster foundation for the following Private Service Connect work.
It intentionally excludes AWS, Azure, BYOC, backup policy, version upgrades,
labels, folders, and public allowlist creation.

## Public Resource Model

`cockroach.Cluster` accepts a logical `name`, one plan-specific configuration,
and `protect`, which defaults to `true`.

The plan-specific configuration is a closed Zig union:

- `basic`: one or more GCP regions, an explicit primary region when more than
  one region is present, and optional positive request-unit and storage limits.
- `standard`: one or more GCP regions, an explicit primary region when more than
  one region is present, and a positive provisioned-vCPU limit.
- `advanced`: one or more GCP regions with positive node counts, positive vCPUs
  per node, optional storage per node, optional CockroachDB version, and
  optional private network visibility/CIDR creation settings.

Region order is normalized before hashing. Names are validated against the
Cockroach Cloud 6-20 character lowercase/digit/dash contract. Duplicate or
empty regions, invalid primary regions, non-positive explicit limits, and
serverless/Advanced field mixing are rejected before a resource enters the
graph.

The resource exposes the same topology outputs as `ExistingCluster`, plus the
remote state and deletion-protection state. This allows SQL users, connection
secrets, public egress, and private-connectivity components to consume either a
managed or adopted cluster through equivalent typed outputs.

## API Contract

The client remains pinned to Cockroach Cloud API `2024-09-16` and sends:

- `POST /v1/clusters` with `provider: "GCP"` and the plan inside `spec.plan`.
- `PATCH /v1/clusters/{id}` with the generated update-specification shape.
- `GET /v1/clusters/{id}` for refresh and readiness polling.
- `DELETE /v1/clusters/{id}` only after all deletion guards pass.

Basic and Standard use `spec.serverless`. Create requests always set
`with_empty_ip_allowlist: true`, preventing the Cockroach API default that
otherwise creates an unrestricted public allowlist. Usage-limit integers are
encoded as JSON strings, matching the pinned OpenAPI schema.

Advanced uses `spec.dedicated.region_nodes` and
`spec.dedicated.hardware.machine_spec.num_virtual_cpus`. Storage defaults are
left to Cockroach Cloud when omitted. GCP disk IOPS are not exposed because the
provider ignores them.

Client request bodies are produced through structured JSON serialization. No
credentials, connection strings, or secret values enter request diagnostics,
resource inputs, outputs, or state.

## Lifecycle And Drift

The provider reads the complete managed shape from the remote cluster and
returns normalized observed inputs. Drift is classified as follows:

- Name or cloud-provider changes require replacement.
- Transitions between serverless and Advanced require replacement.
- Basic/Standard plan transitions, capacity changes, region additions, primary
  region changes, and protection changes update in place.
- Serverless region removal requires replacement because the pinned API cannot
  remove serverless regions.
- Advanced region/node-count and hardware changes update in place.
- Immutable Advanced networking creation settings require replacement.

Create and update poll `GET /v1/clusters/{id}` until `CREATED`. `CREATING` and
`LOCKED` continue polling; `CREATION_FAILED` and `DELETED` fail immediately.
Polling uses the operation context clock, cancellation, deadline, and bounded
poll interval. The resource timeout defaults to two hours, which covers the
longer Advanced update path.

Import accepts a Cockroach cluster ID, reads the cluster, verifies that its
GCP/plan/topology shape matches the declaration, and adopts it without mutation.

## Deletion Safety

One `protect` argument controls two independent guards:

1. It is included in resource inputs and maps to Cockroach Cloud
   `delete_protection`, so changing `true` to `false` produces a real PATCH.
2. It maps to Ziac lifecycle protection, so replacement or removal cannot be
   planned while protection remains enabled in state.

A cluster can therefore be destroyed only through a two-step workflow:

1. Set `protect = false` and deploy, which disables remote protection and saves
   unprotected state.
2. Run `ziac destroy ... --confirm`, which provides an explicit destructive
   confirmation to provider operation contexts.

The Cockroach provider re-reads the cluster immediately before deletion and
rejects deletion if the declaration is protected, remote protection is still
enabled, the physical ID differs, or destructive confirmation is absent.
`404` is treated as already deleted.

## Test Strategy

Unit and contract tests cover:

- Exact Basic, Standard, and Advanced create/update JSON.
- Name, region, primary-region, sizing, and plan-specific validation.
- Stable input hashing under region reordering.
- Read/create/update/import/delete provider lifecycles.
- Readiness polling, terminal failure, cancellation, and timeout.
- Mutable scaling versus immutable replacement classification.
- Default local and remote protection.
- The required unprotect deploy followed by confirmed destroy.
- CLI parsing and executor propagation of destructive confirmation.
- No unrestricted allowlist in any cluster create request.

Authenticated creation is part of the later disposable live gate. This task
must still be complete and deterministic without external credentials through
recording transports and fake clocks.
