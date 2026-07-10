# Ziac CockroachDB GCP PSC Implementation Plan

**Date:** 2026-07-10
**Design:** `docs/superpowers/specs/2026-07-10-ziac-cockroach-psc-design.md`
**Roadmap:** Ziac E2E Task 6.6

Each implementation task starts with a failing focused test and ends with that
test passing. Runtime changes stay under `packages/ziac/src`; no zigeffect tool
is added.

## Task 1: Cockroach Private Networking Client

Files:

- Modify `packages/ziac/src/cockroach/client.zig`.
- Modify `packages/ziac/test/cockroach_client_test.zig`.

Steps:

1. Add failing decode tests for endpoint service and connection list responses.
2. Add exact request tests for enabling services and creating/deleting
   connections.
3. Implement owned service/connection models, status enums, list helpers, and
   mutation methods against Cockroach Cloud API `2024-09-16`.
4. Prove pagination, malformed responses, API version headers, and idempotent
   delete behavior.

## Task 2: Typed Cockroach PSC Resources

Files:

- Create `packages/ziac/src/cockroach/private_endpoint.zig`.
- Modify `packages/ziac/src/cockroach/root.zig`.
- Create `packages/ziac/test/cockroach_private_endpoint_test.zig`.
- Modify `packages/ziac/test/all_test.zig`.

Steps:

1. Add failing builder tests for `ClusterRegion`,
   `PrivateEndpointService`, and `PrivateEndpointConnection`.
2. Implement typed cluster ID, service attachment, endpoint ID, status, and DNS
   outputs.
3. Validate names, regions, plans, and output-reference fields.
4. Prove lifecycle retention and stable composite physical identities.

## Task 3: Cockroach PSC Provider Lifecycle

Files:

- Modify `packages/ziac/src/cockroach/live_provider.zig`.
- Create `packages/ziac/test/cockroach_private_endpoint_live_provider_test.zig`.

Steps:

1. Add failing tests for regional cluster projection and GCP provider/region
   mismatch.
2. Add failing Standard and Advanced endpoint-service lifecycle tests, including
   the Advanced enable POST and Standard no-POST path.
3. Add failing endpoint-connection create/read/import/delete and acceptance
   polling tests.
4. Implement output resolution and normalization that preserves references.
5. Implement deadline, retryable status, terminal status, wrong-service, and
   idempotency behavior.

## Task 4: GCP PSC Compute Resources

Files:

- Create `packages/ziac/src/gcp/psc.zig`.
- Modify `packages/ziac/src/gcp/root.zig`.
- Modify `packages/ziac/src/gcp/compute_provider.zig`.
- Create `packages/ziac/test/gcp_psc_test.zig`.
- Create `packages/ziac/test/gcp_psc_live_provider_test.zig`.

Steps:

1. Add failing builder tests for the regional internal address and forwarding
   rule, including typed subnet, network, address, and target inputs.
2. Add failing provider tests for exact Compute API bodies, regional operation
   polling, read normalization, output extraction, import, and delete.
3. Implement `PscAddress` and `PscEndpoint` builders.
4. Extend the Compute provider with regional kinds and PSC outputs.
5. Prove global access is enabled and automated DNS is disabled.

## Task 5: Private Cloud DNS

Files:

- Modify `packages/ziac/src/gcp/dns.zig`.
- Modify `packages/ziac/src/gcp/dns_provider.zig`.
- Create `packages/ziac/test/gcp_private_dns_test.zig`.
- Modify `packages/ziac/test/gcp_dns_live_provider_test.zig`.

Steps:

1. Add failing builder/provider tests for a VPC-bound private managed zone.
2. Add failing tests for output-backed managed-zone and record-set names.
3. Implement managed-zone create/read/diff/import/delete.
4. Extend record sets without breaking existing literal-name callers.
5. Prove trailing-dot normalization preserves output references and does not
   create drift.

## Task 6: High-Level Private Service Connect Component

Files:

- Create `packages/ziac/src/cockroach/private_service_connect.zig`.
- Modify `packages/ziac/src/cockroach/root.zig`.
- Create `packages/ziac/test/cockroach_private_service_connect_test.zig`.
- Add `packages/ziac/test/compile_fail/cockroach_psc_basic.zig` and expectation.

Steps:

1. Add failing topology tests for two regions and all typed dependency edges.
2. Add failing validation tests for duplicate/missing/mismatched regions,
   invalid CIDRs, and GCP network policy.
3. Add a compile-fail contract proving Basic cannot be selected.
4. Implement API enablement, VPC, subnets, Cockroach projections, endpoints,
   accepted connections, private zones, and A records.
5. Return per-region Direct VPC and private connection outputs.
6. Prove the graph contains no `cockroach.AuthorizedNetwork` resource.

## Task 7: Example And Documentation

Files:

- Create `packages/ziac/examples/cockroach_private_service_connect.zig`.
- Modify `packages/ziac/build.zig`.
- Create `packages/ziac/docs/private-service-connect.md`.
- Modify `packages/ziac/docs/roadmap.md`.
- Modify `docs/superpowers/plans/2026-07-10-ziac-e2e-delivery.md`.

Steps:

1. Add a compiling managed-cluster plus PSC plus Cloud Run wiring example.
2. Document topology, cost and plan constraints, lifecycle, DNS, imports,
   troubleshooting, and the Task 6.7 live gate.
3. Mark Task 6.6 implementation evidence in the delivery roadmap.

## Task 8: Full Verification And Commit

Run:

```sh
bun run ziac:test
bun run ziac:examples
(cd packages/ziac && zig build)
bun run zigeffect:std:test
bun run zigeffect:postgres:test
bun run zigeffect:postgres:cockroach-live-test
bash packages/zigeffect/tools/check_tool_hygiene.sh
git diff --check
```

Inspect `git status` and the final diff. Commit only the PSC slice as:

```text
Add CockroachDB GCP private connectivity
```

## Implementation Evidence

Tasks 1 through 7 were implemented on 2026-07-10 with test-first resource,
provider, graph, compile-fail, and example coverage. The final composition uses
`cluster_resource` to retain unresolved cluster dependencies and
`ContainerService.base_graph` plus `regional_direct_vpc` to produce one strict
multi-provider DAG. Provider recovery lists remote Cockroach services and
connections before mutation, and resolved GCP/DNS outputs are checked against
their declared project and region at the request boundary. Task 8 passed every
listed command on 2026-07-10, including 263 Ziac tests, examples, package builds,
the local verified-TLS CockroachDB integration, tool hygiene, and diff checks.
