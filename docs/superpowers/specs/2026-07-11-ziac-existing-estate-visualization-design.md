# Ziac Existing Estate Visualization Design

Date: 2026-07-11

Status: Workbench slice implemented and browser verified; live provider wiring open

## Product Decision

The first paid estate-intelligence feature is read-only visualization of an
existing GCP project in the same 3D canvas used for Ziac-managed
infrastructure. It does not import resources into state, generate code, or
authorize mutations.

The canvas exposes three explicit scopes:

- `Ziac`: resources owned by the current Ziac stack;
- `Existing`: resources observed in GCP but not owned by Ziac;
- `Combined`: both sets plus references between them.

`Import` is reserved for future code generation and `Adopt` is reserved for a
proved zero-change ownership transfer. This feature is called an estate scan.

## Artifact Contract

`ziac.visual.v1` remains backward compatible. Each resource accepts an optional
ownership value:

- `managed` (the default for older artifacts);
- `observed`;
- `referenced`.

Observed resources use `read` operations and carry a bounded discovery object
with provider, project identity, observation time, and source resource name.
The artifact contains no OAuth token, refresh token, authorization code,
credential URL, billing identity, or user email.

The Workbench session carries a separate estate-access projection:

- identity provider (`google`);
- authentication state;
- entitlement (`none` or `pro`);
- GCP connection state;
- connected project ID;
- last completed scan time.

The Existing and Combined scopes are available only when Google identity, Pro
entitlement, and a GCP connection are all ready. The browser treats missing or
malformed access data as locked.

## Authentication Boundary

Google sign-in establishes the Ziac account. The Ziac billing system establishes
the Pro entitlement. A distinct least-privilege GCP connection authorizes the
host to read Cloud Asset Inventory. These facts must never be inferred from one
another.

The production flow uses a server-side Google authorization exchange or
customer-configured Workload Identity Federation. The Zig host owns tokens,
refresh, Cloud Asset Inventory pagination, redaction, and the resulting
observation artifact. The static Workbench owns no Google credentials and makes
no direct Cloud Asset Inventory request.

## Canvas Experience

The compact estate scope control sits beside topology mode rather than adding a
new page. Switching scope recomputes resources, edges, routes, groups, bounds,
selection, navigator counts, map regions, and inspector content through the
existing visual model.

Observed resources use a restrained neutral-teal ownership accent and an
`Observed` face marker. Their inspector shows ownership, discovery source,
project, and observation time. Managed resources retain plan semantics.

When Existing is active:

- the primary command is a read-only scan status, not Deploy;
- the deployment dock is collapsed by default;
- lifecycle controls are not presented as owned controls;
- observed resources can be inspected but never planned or mutated.

The connected development sample contains realistic unmanaged Cloud Run,
Cloud SQL, Storage, VPC, and load-balancing resources alongside the existing
managed global API. It is explicitly marked as sample observation data.

## Acceptance Criteria

- older visual artifacts parse every resource as `managed`;
- ownership and discovery fields are strictly validated and secret scanned;
- Existing, Ziac, and Combined filters keep edges, routes, regions, counts, and
  selection synchronized;
- Existing and Combined fail closed without Google authentication, Pro
  entitlement, and a connected GCP project;
- the connected sample visibly renders unmanaged resources in the 3D canvas;
- observed resources are clearly read-only in the face texture and inspector;
- no OAuth or credential material reaches an artifact or session;
- desktop and narrow browser views have no overflow or overlapping controls;
- Workbench tests, TypeScript, production build, and relevant Ziac gates pass.

## Deferred Provider Work

- production Google Identity callback and Ziac subscription lookup;
- customer Workload Identity Federation onboarding;
- paginated Cloud Asset Inventory scanner and provider-specific hydration;
- scheduled scans, asset feeds, billing attribution, code generation, and
  zero-change adoption.

The UI contract is deliberately ready for these provider milestones without
claiming that the local sample performed a live Google scan.

## Delivery Evidence

- Connected sample: `?sample=ziac-estate`.
- Browser captures:
  - `/tmp/ziac-estate-combined.png`;
  - `/tmp/ziac-estate-existing.png`;
  - `/tmp/ziac-estate-access-gate.png`;
  - `/tmp/ziac-estate-mobile.png`.
- 145 Workbench tests and 1,176 expectations pass; TypeScript, Vite production
  build, JSON validation, and whitespace validation pass.
- `zig build test` exits successfully for Ziac. This worktree's Ziac dependency
  does not expose the Testing v2 runner and therefore emits no suite receipt;
  that missing evidence is not represented as a Testing v2-qualified pass.
