# Ziac M67 Application Services Provider Plan

Date: 2026-07-14
Design: `docs/superpowers/specs/2026-07-14-ziac-application-services-provider-design.md`
Status: locally complete; authenticated disposable-project qualification pending

## Contract And Tests

- [x] Pin Workflows, API Gateway, Identity Toolkit and Parameter Manager GA
  Discovery contracts.
- [x] Add failing declarations for all eighteen resource types.
- [x] Add failing lifecycle tests for CRUD, import, LRO resume and drift.
- [x] Add failing secret-preservation and destructive-boundary tests.

## Typed Primitives

- [x] Implement Workflows Workflow.
- [x] Implement API, API Config, Gateway and additive IAM members.
- [x] Implement project config, tenants, project/tenant OIDC and SAML, tenant IAM.
- [x] Implement Parameter, ParameterVersion, Template and TemplateVersion.
- [x] Export all types and update catalog/contract provenance.

## Hardened Providers

- [x] Add Workflows CRUD/import/revision and LRO handling.
- [x] Add API Gateway CRUD/import/IAM and LRO handling.
- [x] Add Identity Platform singleton, tenant, IdP, IAM and secret-safe refresh.
- [x] Add Parameter Manager CRUD/import, payload resolution and redaction.
- [x] Normalize output-only state, maps, masks, etags and immutable fields.
- [x] Wire all managed types through live-provider dispatch.

## Components And Product Surface

- [x] Add `WorkflowProgram`.
- [x] Add `ManagedApiGateway`.
- [x] Add tagged `IdentityRealm`.
- [x] Add `ParameterBundle`.
- [x] Add API/permission synthesis and runtime role mappings.
- [x] Add supported Cloud Asset identity and ownership reconciliation.
- [x] Add canvas workflow, gateway, identity and configuration metadata.
- [x] Add explicit configuration-estimate cost models.

## Distribution And Qualification

- [x] Add public examples and agent documentation.
- [x] Add fail-closed authenticated qualification script and local receipt.
- [x] Compile installed examples under Testing v2.
- [x] Run formatting, migration guard, root typecheck and release gate.
- [x] Record exact evidence, update both roadmaps and commit M67.

## Local Evidence

- Testing v2: 671 discovered and executed, 670 passed, one authenticated skip,
  zero failed, pending, leaks or logged errors.
- Release gate: 134/134 steps succeeded and 684/685 checks passed with the same
  authenticated skip.
- Root TypeScript typecheck, dashboard production build, relocatable install,
  container smoke test and all public examples passed.
- The authenticated runner emitted the expected structured exit-77 skip without
  ADC or disposable-project inputs; no remote qualification is claimed.
