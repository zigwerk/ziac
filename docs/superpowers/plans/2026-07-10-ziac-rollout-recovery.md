# Ziac Regional Rollout And Recovery Implementation Plan

## Task 1: Canary Graph Contract

1. Add failing component tests for valid, missing, and invalid canary regions.
2. Add `RolloutStrategy` and `RolloutPolicy` to `ContainerService`.
3. Add canary-to-fleet dependency edges after all regional services exist.
4. Enable primary-region canary policy in the built-in global stack and
   examples.

## Task 2: Cloud Run Readiness And Image History

1. Add failing builder/provider tests for schema v3 outputs and readiness.
2. Add `image_ref`, `previous_image_ref`, `latest_created_revision`, and `ready`
   outputs.
3. Preserve the observed image in the pending update result.
4. Validate reconciliation, terminal condition, and created/ready revision
   equality when completing operations.
5. Preserve prior-image history across operation completion and refresh.

## Task 3: Rollback Graph

1. Add failing pure tests for full, partial, unavailable, and mutable-tag
   rollback cases.
2. Implement full graph cloning with Cloud Run image replacement.
3. Resolve desired output references through state without exposing secrets.
4. Export the rollout module through the public facade.

## Task 4: Guarded Rollback CLI

1. Add failing CLI tests for missing confirmation, missing history, and a
   successful checkpointed fake-provider rollback fixture.
2. Add the `rollback` command and option contract.
3. Reuse live-provider safety selection, stack lock, plan builder, executor,
   checkpoint, state/output persistence, and receipt rendering.
4. Document normal-deploy and interrupted-rollback recovery rules.

## Task 5: Provider Diagnostics

1. Add failing generic recorder and GCP quota payload tests.
2. Add a thread-safe bounded provider diagnostic recorder.
3. Parse redacted GCP quota/rate details and publish them through operation
   context.
4. Attach the recorder in deploy, rollback, refresh, import, and live planning
   paths where practical.
5. Add stable human and JSON-safe diagnostic rendering tests.

## Task 6: Recovery Verification And Documentation

1. Add interruption tests before and after canary completion and during
   rollback.
2. Update Cloud Run, ContainerService, operations, architecture, roadmap, and
   README documentation.
3. Run formatting, Ziac tests/examples/build, root check, zigeffect std and
   Postgres suites, tool hygiene, local CockroachDB TLS, and credential scans.
4. Commit the completed M8.4 checkpoint.
