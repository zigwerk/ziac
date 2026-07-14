# Ziac M68 Compute Workloads Provider Plan

Date: 2026-07-14
Design: `docs/superpowers/specs/2026-07-14-ziac-compute-workloads-provider-design.md`
Status: complete locally; authenticated disposable-project qualification pending

## Contract And Tests

- [x] Add failing declarations for all nine resource types.
- [x] Add failing zonal/regional/global operation-resume tests.
- [x] Add failing replacement, resize, fingerprint and secret-boundary tests.

## Typed Primitives

- [x] Implement zonal and regional disks.
- [x] Implement image, instance and immutable instance template.
- [x] Implement zonal/regional MIG and autoscaler.
- [x] Re-export through `ziac.gcp.compute` and update catalog provenance.

## Hardened Provider

- [x] Add zonal Compute operation targets.
- [x] Add CRUD/import/refresh for all nine resources.
- [x] Add native disk resize, MIG fingerprint update and autoscaler update.
- [x] Resolve and digest-check startup scripts only inside mutation scope.
- [x] Normalize remote output-only state and wire live-provider dispatch.

## Components And Product Surface

- [x] Add `VirtualMachine`.
- [x] Add tagged `ManagedInstanceFleet`.
- [x] Add exact API/permission and runtime-role synthesis.
- [x] Add supported Cloud Asset identities and ownership reconciliation.
- [x] Add canvas VM/disk/image/template/group/autoscaler metadata.
- [x] Add explicit Compute and disk/image configuration estimates.

## Distribution And Qualification

- [x] Add public example and installed agent documentation.
- [x] Add local receipt and fail-closed authenticated qualification runner.
- [x] Compile installed examples under Testing v2.
- [x] Run formatting, migration guard, root typecheck and release gate.
- [x] Record exact evidence, update both roadmaps and commit M68.

## Evidence

- `zig build test </dev/null` completed with the Testing v2 `ziac-tests`
  receipt reporting 688 discovered and executed tests, 687 passed, one
  credential-gated skip, and zero failures, pending tests, leaks or logged
  errors.
- `zig build examples` compiled the public Compute workloads example.
- `zig build release-gate </dev/null` passed the relocatable install, fresh
  project and self-host scaffolds, dashboard build, static/secret checks and
  native arm64 container probe.
- `bash packages/zigeffect/scripts/check_testing_v2_migration.sh` passed for
  eight build files and three generated templates.
- `bun run typecheck` passed every root, dashboard and site TypeScript project.
- `scripts/qualify-compute-workloads.sh` emitted the structured exit-77 skip
  without ADC; no authenticated claim is made.
