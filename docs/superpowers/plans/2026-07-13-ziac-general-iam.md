# Ziac M61 General IAM Implementation Plan

Date: 2026-07-13
Status: complete at the credential-free local gate; authenticated hierarchy qualification pending operator credentials

## 1. Canonical Declarations

- [x] Add failing declaration tests for conditions, canonical principals,
  stable member ordering and explicit ownership metadata.
- [x] Add shared `Condition`, `Binding` and principal validation APIs.
- [x] Add Project, Folder and Organization Member/Binding/Policy resources.
- [x] Add ServiceAccountIamMember and ServiceAccountIamBinding resources.
- [x] Reject public conditional grants, conditional basic roles and duplicate
  members at construction time.

## 2. Policy Engine

- [x] Add failing mutation tests for additive member, authoritative binding and
  authoritative policy semantics.
- [x] Implement a shared condition-aware allow-policy engine.
- [x] Normalize remote state to each ownership boundary.
- [x] Carry policy version 3, etags and bounded conflict retries.
- [x] Move ProjectMember lifecycle behind the shared IAM provider handler.
- [x] Add service-account and Resource Manager v3 policy endpoints.
- [x] Prove concurrent unrelated edits survive retries.

## 3. Custom Roles And Federation

- [x] Add failing declaration and lifecycle tests for project/organization
  custom roles.
- [x] Implement etag-safe custom-role CRUD, explicit masks and soft-delete
  recovery.
- [x] Add failing declaration and lifecycle tests for Workload Identity Pools
  and OIDC Providers.
- [x] Implement resumable LRO CRUD/import/undelete and exact update masks.
- [x] Validate project-number resource names, `google.subject`, issuer HTTPS and
  attribute mapping bounds.

## 4. Permission Preflight

- [x] Add operation-to-permission metadata for every managed M56-M61 resource.
- [x] Derive deployer and runtime permission sets with resource provenance.
- [x] Add grouped `testIamPermissions` preflight.
- [x] Surface missing service agents, disabled APIs, organization-policy and VPC
  Service Controls findings without overstating proof.
- [x] Emit least-privilege custom-role proposals from derived permissions.

## 5. Graph And Workbench

- [x] Reject overlapping Member, Binding and Policy authority in one graph.
- [x] Add IAM ownership, target, role and condition metadata to visual artifacts.
- [x] Render declared and required permission edges distinctly.
- [x] Explain IAM blast radius in the resource inspector.
- [x] Add dashboard tests, typecheck and production-build evidence.

## 6. Integration And Documentation

- [x] Promote M61 catalog entries from planned to managed.
- [x] Synchronize live provider registry, CAI identity and generated-reference
  output.
- [x] Document ownership selection, conditions, custom roles, WIF and recovery.
- [x] Update the comprehensive roadmap and coverage counts.
- [x] Run the complete Testing v2 package gate and inspect its receipt.
- [x] Run provider catalog, dashboard and repository typecheck gates.
- [ ] Run authenticated disposable-project qualification when credentials are
  available; keep folder/organization gates explicitly credential-qualified.

Gate: a Ziac plan makes IAM authority explicit, uses conflict-safe Google
contracts, and cannot silently overwrite an unowned member or binding.

Local evidence: 62 managed provider types; 585 Testing v2 tests discovered and
executed, 584 passed and one authenticated test skipped; zero failures, pending
tests, leaks or logged errors. Project, folder and organization live
qualification remains an operator-owned credential gate and is not inferred
from deterministic transport tests.
