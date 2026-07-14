# Ziac M67 Application Services Provider Plan

Date: 2026-07-14
Design: `docs/superpowers/specs/2026-07-14-ziac-application-services-provider-design.md`
Status: in progress

## Contract And Tests

- [x] Pin Workflows, API Gateway, Identity Toolkit and Parameter Manager GA
  Discovery contracts.
- [ ] Add failing declarations for all eighteen resource types.
- [ ] Add failing lifecycle tests for CRUD, import, LRO resume and drift.
- [ ] Add failing secret-preservation and destructive-boundary tests.

## Typed Primitives

- [ ] Implement Workflows Workflow.
- [ ] Implement API, API Config, Gateway and additive IAM members.
- [ ] Implement project config, tenants, project/tenant OIDC and SAML, tenant IAM.
- [ ] Implement Parameter, ParameterVersion, Template and TemplateVersion.
- [ ] Export all types and update catalog/contract provenance.

## Hardened Providers

- [ ] Add Workflows CRUD/import/revision and LRO handling.
- [ ] Add API Gateway CRUD/import/IAM and LRO handling.
- [ ] Add Identity Platform singleton, tenant, IdP, IAM and secret-safe refresh.
- [ ] Add Parameter Manager CRUD/import, payload resolution and redaction.
- [ ] Normalize output-only state, maps, masks, etags and immutable fields.
- [ ] Wire all managed types through live-provider dispatch.

## Components And Product Surface

- [ ] Add `WorkflowProgram`.
- [ ] Add `ManagedApiGateway`.
- [ ] Add tagged `IdentityRealm`.
- [ ] Add `ParameterBundle`.
- [ ] Add API/permission synthesis and runtime role mappings.
- [ ] Add supported Cloud Asset identity and ownership reconciliation.
- [ ] Add canvas workflow, gateway, identity and configuration metadata.
- [ ] Add explicit configuration-estimate cost models.

## Distribution And Qualification

- [ ] Add public examples and agent documentation.
- [ ] Add fail-closed authenticated qualification script and local receipt.
- [ ] Compile installed examples under Testing v2.
- [ ] Run formatting, migration guard, root typecheck and release gate.
- [ ] Record exact evidence, update both roadmaps and commit M67.
