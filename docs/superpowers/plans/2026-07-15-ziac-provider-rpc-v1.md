# Ziac Provider RPC v1 Implementation Plan

## Goal

Ship a bounded, versioned provider process protocol that implements Ziac's
existing provider vtable and is represented explicitly in the package registry.

## Phase 1: Contract Tests

- Add `provider_rpc_test.zig` to the Testing v2 suite.
- Define handshake and operation fixtures covering all provider methods.
- Assert deterministic wire encoding and strict parsing.
- Assert exact provider error and diagnostic round trips.
- Add adversarial cases for bounds, IDs, versions, provider IDs, resource type
  authority, and calls before handshake.

## Phase 2: RPC Kernel

- Add `src/provider_rpc.zig` and export it from `src/ziac.zig`.
- Define v1 protocol constants, method and capability enums, descriptors,
  frame limits, and stable error names.
- Implement canonical request/response codecs using structured JSON parsing.
- Encode resource nodes, lifecycle settings, `Value`, state snapshots, observed
  results, outputs, operation handles, and diagnostics.
- Implement a server session that validates handshake state and dispatches to a
  normal `Provider`.
- Implement an in-memory transport for deterministic unit tests.

## Phase 3: Process Transport

- Add a serialized stdio client that starts an explicit executable path,
  performs the handshake, enforces 8 MiB frames, and rejects mismatched IDs.
- Expose the client as a normal `Provider`.
- Add a fixture provider server executable.
- Add a process conformance executable that exercises the full provider
  lifecycle through OS pipes.
- Attach process conformance to `zig build test`.

## Phase 4: Registry Provider Kind

- Extend package kind with `provider`.
- Parse and validate a strict `provider_rpc` object only for provider packages.
- Preserve canonical manifest digests for existing component and template
  manifests.
- Publish official GCP and verified CockroachDB provider records.
- Update the registry index, digests, docs, and scaffold E2E expectations.

## Phase 5: Runtime Adoption

- Install provider fixture/server artifacts through the package build.
- Keep local and bundled providers compatible with the same vtable.
- Document how a locked provider artifact becomes an RPC client without
  allowing registry data to launch code.
- Record live GCP/Cockroach process migration as a separate credentialed
  qualification milestone unless it can be completed without weakening the
  current authenticated paths.

## Verification

1. Run the focused provider RPC Testing v2 tests.
2. Run the registry/ecosystem tests.
3. Run the process conformance gate.
4. Run `zig build test` from `packages/ziac`.
5. Inspect `.zigeffect/tests/suites/ziac-tests.json` and require complete
   discovered/executed counts, zero failures, zero pending tests, zero leaks,
   and zero logged errors except documented credential skips.
6. Run `packages/zigeffect/scripts/check_testing_v2_migration.sh` because the
   Ziac build graph changes.
