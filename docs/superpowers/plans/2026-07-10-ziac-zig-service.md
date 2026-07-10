# Ziac ZigService Implementation Plan

**Date:** 2026-07-10
**Design:** `docs/superpowers/specs/2026-07-10-ziac-zig-service-design.md`
**Roadmap:** Ziac E2E Milestone M7

Every behavior change starts with a failing focused test. Runtime capability
belongs under `packages/ziac/src`; this milestone adds no zigeffect tool.

## Task 1: Deterministic Source Archives

Files:

- Add `packages/ziac/src/build/source_archive.zig` and build root exports.
- Add `packages/ziac/test/source_archive_test.zig` and fixtures.

Steps:

1. Add failing tests for stable order, timestamps, modes, and digest.
2. Add failing tests for mandatory exclusions and `.ziacignore` glob behavior.
3. Add failing tests for symlink rejection, traversal, duplicate generated
   paths, source limits, and generated recipe digest changes.
4. Implement deterministic tar/gzip generation with an ordered manifest.
5. Prove ignored and timestamp-only changes do not affect archive bytes.

Commit: `Add deterministic Zig build contexts`

Implementation evidence: completed on 2026-07-10 with deterministic archive
byte comparisons, tar manifest/mode inspection, mandatory and custom exclusion
tests, independent source/recipe digest tests, symlink and symlinked-ignore-file
rejection, traversal/collision checks, and file limits.

## Task 2: GCS Build Context Resources

Files:

- Add typed build bucket and source object resources.
- Add Storage JSON API provider handlers and injected source-archive reader.
- Extend GCP client endpoints/content types.

Steps:

1. Test bucket hardening, retention, import, and replacement identity.
2. Test media upload with `ifGenerationMatch=0`, metadata digest checks, adopt
   on matching conflict, and reject on mismatched conflict.
3. Test plan/apply digest mismatch before HTTP and binary payload exclusion from
   state.
4. Implement create/read/diff/import/delete with explicit retention behavior.

## Task 3: Cloud Build Image Resource

Files:

- Add `packages/ziac/src/gcp/cloud_build.zig` and provider handler.
- Add scripted client/provider tests.

Steps:

1. Test builders, identifiers, pinned images/toolchains, and immutable inputs.
2. Test exact regional create request with generation-pinned StorageSource.
3. Test operation persistence, resume polling, cancellation, timeout, and every
   terminal status.
4. Test bounded redacted diagnostics and exact immutable digest extraction.
5. Implement refresh/import/delete semantics and source/build digest noops.

Commit Tasks 2 and 3 as: `Add Zig source-to-image Cloud Build pipeline`

## Task 4: ZigService Component And Sample

Files:

- Add `packages/ziac/src/gcp/global/zig_service.zig`.
- Add a real sample Zig HTTP backend and generated-recipe fixtures.
- Add graph, compile-contract, and Docker integration tests.

Steps:

1. Add failing comptime application/provider/binding contract fixtures.
2. Add failing graph tests from source to image to every regional Cloud Run
   service and global routing resource.
3. Implement generated Dockerfile, API/repository/bucket/build composition,
   binding lowering, defaults, and output surface.
4. Prove source changes alter image/service desired state and ignored changes do
   not.
5. Build and run the sample container locally and probe health/application paths.

Commit: `Add global ZigService component`

## Task 5: Live Gates And Documentation

Files:

- Add credential-gated Cockroach data-path and ZigService live scripts.
- Update package scripts, roadmap, architecture, security, and operations docs.

Steps:

1. Make absent credentials an explicit skip and malformed/non-disposable live
   configuration a hard failure.
2. Exercise clean build, deploy, regional probes, SQL migration/retry, password
   rotation, source update/revert, noop, and protected teardown.
3. Run all local/unit/scripted/container gates regardless of cloud credentials.
4. Record authenticated evidence only when real external execution succeeds.

Authenticated commits:

- `Verify Ziac CockroachDB bindings end to end`
- `Verify Zig source to global Cloud Run deployment`

## Full Verification

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
