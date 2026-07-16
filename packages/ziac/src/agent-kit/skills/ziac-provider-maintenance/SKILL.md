---
name: ziac-provider-maintenance
description: Maintain released first-party or third-party Ziac providers as upstream APIs evolve. Use for provider upgrades, protobuf or discovery changes, compatibility ranges, state migrations, drift repairs, imports, deprecations, retry policy, long-running operations, security fixes, or provider release preparation.
---

# Ziac Provider Maintenance

Preserve user resource identity and state while moving a provider from one
pinned upstream contract to another. A provider update is a compatibility
change, not a mechanical schema refresh.

## Proof-carrying maintenance loop

Start from `ziac_context` or `zigeffect agent context` when the effect manifest
is present. Freeze its source revision, manifest digest, graph cursor, proof
references, provider digest, and upstream contract. Respect work-packet paths,
dependencies, verification commands, lease, and fencing token.

After regression-first implementation, require fresh stable process receipts
and test proof handoffs for migration, behavior, import, drift, and recovery.
Raw receipts are diagnostic only. Compare causal deltas and exact paths, then
re-query context. The project-mounted graph must resolve every mapped assertion
ID. The release proof handoff records old/new digests, changed
paths, migrations, replay commands, receipt digests, causal IDs, limitations,
and remaining authenticated gates.

## Maintenance Loop

1. Freeze the current package manifest, provider binary identity, source
   contract, state fixtures and last qualification receipt. Work from an
   immutable baseline.
2. For GCP, ask `gcp-developer-researcher` for current official contracts,
   annotations, IAM, release status, quotas and deprecations. Record source URLs
   and distinguish documented facts from inference.
3. Produce a **semantic upgrade report** before implementation. Classify each
   change as additive, default-changing, output-only, updateable, immutable,
   replacement-causing, removed, renamed, permission-changing or behaviorally
   ambiguous.
4. Map the report to resource IDs, desired hashes, output wiring, diff results,
   replacement policy, imports, state schema, retry classes and readiness.
   Require an explicit versioned **state migration** for any persisted shape
   change; prove old state upgrades deterministically and idempotently.
5. Add failing regression fixtures for the old and new contracts. Preserve
   no-op plans for unchanged resources, stable imports, typed errors, redaction,
   interrupted-operation recovery and downgrade diagnostics where supported.
6. Implement the smallest adapter or generated-contract change. Handwritten
   lifecycle policy wins over a blind generated rewrite. Never rewrite state in
   place or silently broaden permissions.
7. Run `ziac package verify .`, `zig build provider-rpc-test` and
   `zig build test --summary failures` or package-owned equivalents. Inspect the
   Testing v2 receipt and compare the compatibility matrix.
8. Create a release handoff containing old/new digests, the semantic report,
   migration evidence, changed permissions, replacement risks, deprecations,
   rollback limits and open cloud gates. Send the immutable candidate to an
   independent qualifier.

## Authority Contract

Do not apply infrastructure, access production credentials, publish, revoke,
award trust labels or self-qualify a release by default. Do not make a
third-party executable runnable by inserting a path into registry metadata;
external execution still requires signed installation and sandbox policy.
Missing upstream or cloud evidence blocks promotion, not local analysis.
