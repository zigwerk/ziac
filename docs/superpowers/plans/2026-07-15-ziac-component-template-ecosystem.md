# Ziac Component And Template Ecosystem Implementation Plan

**Goal:** Deliver M86A-M86C as a complete local and installed ecosystem
foundation, with M86D-M86E recorded as the externally hosted continuation.

**Architecture:** Keep provider authority in `ziac`; annotate concrete resource
graphs with non-provider component provenance; ship official graph compilers in
an independent `ziac-gcpx` package; ship editable source templates and a static
registry in `ziac-templates`; expose read-only discovery and verification plus
template initialization through the installed CLI.

## 1. Contract Tests

- [x] Add package-manifest tests for valid component and template manifests.
- [x] Reject traversal, absolute entries, duplicate arrays, executable hooks,
      unsupported kinds, malformed versions and secret-shaped fields.
- [x] Prove canonical manifest digests are stable across JSON field ordering.
- [x] Add registry tests for ordering, unique identities, digest matching,
      qualification tiers and bounded search.

## 2. Resource Provenance

- [x] Add optional component origin to `ResourceNode` with owned cloning and
      cleanup.
- [x] Add `component.Descriptor`, origin validation and range stamping.
- [x] Reject conflicting ownership while allowing idempotent stamping.
- [x] Round-trip provenance through `ziac.program.v1` as an optional field.
- [x] Expose provenance through `ziac.visual.v1` without changing provider
      inputs, input hashes or state identity.

## 3. Official `ziac-gcpx` Package

- [x] Create a standalone Zig package importing public `ziac` APIs.
- [x] Export package metadata and descriptors.
- [x] Wrap `AssetBucket` and `HermesCompute` as `AssetBucket` and
      `HermesDesktop`, stamping only resources created by the component.
- [x] Add deterministic graph, output, resource-catalog and provenance tests.
- [x] Use the Testing v2 runner and verify the complete suite receipt.

## 4. Official Template Package

- [x] Create `global-zig-api`, `hermes-desktop` and `event-driven-zig` source
      trees with `ziac.package.json` manifests.
- [x] Keep templates editable, credential-free and free of install hooks.
- [x] Add a deterministic package index with exact manifest digests.
- [x] Implement bounded token rendering and safe recursive copy.
- [x] Ensure generated ZON paths resolve both source-checkout and installed
      `ziac`/`ziac-gcpx` package roots.

## 5. CLI And Installation

- [x] Add `ziac registry list`, `ziac registry search` and
      `ziac package verify` read-only commands.
- [x] Extend `ziac init` with `--template` while preserving the default scaffold.
- [x] Install `ziac-gcpx` and `ziac-templates` beside `share/ziac`.
- [x] Add scaffold E2E coverage for registry search, digest verification and
      fresh-project compilation from official templates.
- [x] Update generated agent skills to explain Resources, Components and
      Templates and to verify registry provenance before reuse.

## 6. Documentation And Roadmap

- [x] Publish ecosystem, package-author and template-author documentation.
- [x] Add M86A-M86E to the canonical roadmap and record accurate status.
- [x] Document the future repository split and compatibility guarantees.
- [x] Keep hosted registry publication, structured remote dependency updates and
      marketplace UI explicitly pending M86D-M86E.

## 7. Verification

- [x] Run focused ecosystem and program/visual artifact tests.
- [x] Run `zig build test --summary all` in `packages/ziac-gcpx`.
- [x] Run `zig build test --summary all` in `packages/ziac`.
- [x] Inspect both Testing v2 receipts for completeness, equal discovered and
      executed counts, zero pending, zero failures, zero leaks and zero logged
      errors.
- [x] Run `packages/zigeffect/scripts/check_testing_v2_migration.sh`.
- [x] Run Zig formatting checks for both packages.

## Completion Boundary

M86A-M86C are complete when the installed CLI can discover, verify and scaffold
all official templates, a separate project compiles an official `ziac-gcpx`
component, and the resulting program and canvas preserve concrete resources and
component provenance. M86D-M86E require a public registry service, maintainer
identity and product UI; they remain forward work and are not implied by local
fixtures.
