# Ziac Cloud Bootstrap Completion Plan

## Acceptance target

A fresh repository created with `ziac init --preset ziac-cloud` passes `ziac
check` for all generated projects, opens a merged dashboard, can save and apply a
digest-approved plan through the native host, and contains deployable bootstrap,
control-plane, and billing stacks. Billing fixtures and live adapters preserve
authoritative provenance and attribution coverage.

## Work items

### M37. Self-host resource kernel

- [x] Add Cloud KMS key-ring and crypto-key typed resources.
- [x] Add live read/create/update/delete/import handling for both resources.
- [x] Add self-host bootstrap and hosted-service graph builders.
- [x] Verify every self-host graph resource is supported by the selected live
      provider.

### M38. Installable `ziac-cloud` preset

- [x] Add `--preset ziac-cloud` to the interactive/non-interactive init flow.
- [x] Generate independent bootstrap, Cockroach data, control-plane, and billing
      projects.
- [x] Install the existing multi-harness skills at the repository root.
- [x] Add an external-project E2E that compiles every generated project.

### M39. Real dashboard operations

- [x] Define bounded request and operation receipt schemas.
- [ ] Add fixed-argv plan/apply/watch/cancel host operations. Plan and apply are
      complete; asynchronous watch and cancellation remain.
- [x] Require saved-plan digest approval and explicit destructive confirmation.
- [x] Replace simulated frontend deploy timers with host operation state.
- [ ] Render real watch phases and cancellation. Plan/apply receipts and errors
      are complete.

### M40. Affected-project workspace revisions

- [x] Add stable project input revisions.
- [x] Cache per-project artifacts and preserve last known good output.
- [x] Recompile only changed projects.
- [ ] Publish monotonic workspace revision and diagnostics.
- [ ] Stop refetching unchanged full artifacts in the frontend. The current
      bridge interval is cheap because unchanged projects no longer compile.

### M41. Authoritative billing adapters

- [x] Add Cloud Billing and BigQuery endpoints to the authenticated GCP client.
- [x] Implement paginated Catalog SKU parsing with tiers, currency, and effective
      time.
- [x] Implement bounded BigQuery query/poll/result parsing.
- [x] Add exact attribution, unattributed total, and coverage basis points.
- [x] Add the authenticated ingestion service entrypoint, Cockroach persistence,
      and managed hourly OIDC scheduler.
- [ ] Add label fallback attribution. Exact Google global-name attribution,
      explicit unattributed totals, and complete project totals are implemented.
- [x] Project cost provenance into the dashboard contract and remove fabricated
      estimates.

### M42. Bootstrap qualification

- [x] Add `self-host-gate` to the package build.
- [x] Add a fail-closed authenticated qualification script.
- [x] Build and verify both hosted Linux container targets locally.
- [x] Run final package tests, dashboard tests, external scaffold E2E, release
      gate, hosted Linux image builds, and Testing v2 receipt inspection.
- [x] Update the public roadmap with exact completed and credential-gated status.

## Completion evidence

- Credential-free gate output and Testing v2 receipt.
- Generated external repository paths and successful check receipts.
- Dashboard unit tests proving no simulated deployment path remains.
- Billing fixture receipt where attributed plus unattributed equals billed total.
- Authenticated gate result reported as pass or explicit credential skip.
