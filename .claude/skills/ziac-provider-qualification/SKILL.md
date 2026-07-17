---
name: ziac-provider-qualification
description: Independently qualify immutable first-party or third-party Ziac provider candidates. Use for provider conformance, manifest and digest verification, RPC fault tests, lifecycle evidence, import and drift checks, state migrations, compatibility matrices, authenticated cloud qualification, or registry trust recommendations.
---

# Ziac Provider Qualification

Qualify evidence, not author intent. Start from an **immutable package digest**
and keep candidate source unchanged for the entire run. Do not repair a failing
candidate; return it to the creator or maintainer with exact evidence.

## Proof-carrying qualification loop

Freeze candidate digest, source revision, manifest digest, work-packet identity,
receipt digest, graph session/cursor, and claimed proof handoff before a gate.
Query any project context endpoint read-only and require those identities to
agree. Never claim the implementer's lease, edit source, or promote raw receipts
to stable evidence.

Validate stable receipts, proof handoffs, replay commands, suite completeness,
and exact causal graph paths independently. Reject a mapped assertion ID that
does not resolve through the project-mounted graph. Re-query context after the
gate and report identity drift as `incomplete`. Name every receipt digest, proof path,
causal ID, environment bound, limitation, and pass/fail/incomplete verdict.

## Deterministic Gate

1. Record candidate digest, source revision, manifest, provider identity,
   protocol, compatibility range, declared prefixes and requested label.
2. Run `ziac package verify .`. Reject mutable identities, hooks, commands,
   credential-shaped fields, undeclared resource types and digest mismatch.
3. Run `zig build provider-rpc-test` and package-owned tests. Require handshake
   before operations, exact request/response IDs, bounded frames, typed errors,
   unauthorized-type rejection, process-loss handling and stdout discipline.
4. Verify deterministic read/diff/create/update/delete/import fixtures,
   replacement decisions, output secrecy, redaction, deadline behavior,
   interrupted-operation resume, import followed by no-op, drift repair and
   versioned state migration where supported. Reject candidate product code
   that constructs causal stores, calls low-level recording APIs or accepts a
   recorder instead of relying on the reusable provider adapter.
5. Inspect the Testing v2 receipt. Discovered and executed counts must match;
   required tests, failures, pending tests, leaks and logged errors must be zero.
6. Test from outside the Ziac source checkout against the declared Zig and Ziac
   compatibility matrix. Registry discovery must not execute provider code.

## Authenticated Cloud Gate

Run live qualification only under an explicit disposable-project capability
envelope with bounded regions, cost, time, operations and cleanup. Never use
production credentials. Capture immutable plan, RPC, state, drift, import,
resume, cleanup and billing-inventory evidence. A skipped or expired live gate
cannot support `cloud_qualified`.

## Result Contract

Report candidate digest, environment, commands, receipt paths, passed and
failed contracts, credential-gated evidence, residual risks and one outcome:
`pass`, `fail` or `incomplete`. Recommend at most the evidence-backed label:

- `community`: metadata only;
- `verified`: deterministic package and conformance evidence;
- `official`: Ziac governance and release ownership, awarded outside this role;
- `cloud_qualified`: current authenticated evidence for the declared matrix.

Do not edit candidate source, apply a repair, publish, revoke or award the label
during qualification. Independence is part of the evidence.
