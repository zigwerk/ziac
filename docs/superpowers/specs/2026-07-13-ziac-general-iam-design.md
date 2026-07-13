# Ziac M61 General IAM Design

Date: 2026-07-13
Status: accepted implementation direction

## Purpose

M61 makes IAM ownership visible in Ziac's type system, plans, state and canvas.
It must be impossible for an additive grant to silently become an authoritative
policy replacement. The implementation also establishes keyless identity and
permission preflight primitives that later provider milestones can reuse.

## Google Contracts

The implementation follows the current Google REST and gRPC-transcoded APIs:

- Cloud Resource Manager v3 `getIamPolicy`, `setIamPolicy` and
  `testIamPermissions` for projects, folders and organizations;
- IAM v1 service-account policy methods;
- IAM v1 project and organization custom-role CRUD with etags and field masks;
- IAM v1 Workload Identity Pool and Provider CRUD through long-running
  operations;
- IAM allow-policy version 3 whenever a binding has a condition.

Ziac never selects an experimental RPC fallback. Resource Manager and IAM use
their supported JSON-transcoded endpoints until the audited gRPC transport is
available.

## Ownership Families

Every allow-policy resource declares one of three ownership modes in both its
type name and normalized inputs.

### Member

`*IamMember` and `ProjectMember` resources own one
`(role, condition, principal)` tuple. Create and delete preserve every unrelated
binding and principal. They use an etag read-modify-write loop with a bounded
conflict retry.

### Binding

`*IamBinding` resources own the complete member set for one
`(role, condition)` binding. Apply replaces that member set while preserving all
other bindings. Delete removes only the owned binding. This is authoritative at
the binding boundary and additive nowhere else.

### Policy

`*IamPolicy` resources own the complete allow policy for one resource. Apply
replaces all bindings represented by the resource while carrying the latest
server etag. Policy ownership is never inferred from a member or binding
resource and must be explicit in source.

The planner rejects overlapping ownership on the same target and tuple: a
policy cannot coexist with member or binding ownership, and a binding cannot
coexist with member ownership for its role and condition.

## Canonical IAM Model

`gcp.iam.Condition` contains `title`, `description` and `expression`. Titles and
expressions are non-empty bounded UTF-8 text. Public principals cannot be used
with conditions, and basic roles cannot be conditional. Conditions participate
in identity, drift and physical IDs.

Principals are accepted only when they use a supported canonical form:

- `user:`, `group:`, `serviceAccount:` and `domain:` identifiers;
- `principal://` and `principalSet://` federated identifiers;
- `deleted:*` tombstone identifiers returned by Google;
- `allUsers` and `allAuthenticatedUsers` where the target supports them.

Member lists, permissions and attribute mappings are canonicalized before they
enter a resource node. This makes hashes stable across source ordering and
prevents perpetual diffs.

## Managed Resources

M61 adds these public families:

- project, folder and organization Member, Binding and Policy resources;
- service-account IAM Member and Binding resources;
- project and organization CustomRole resources;
- WorkloadIdentityPool and OIDC WorkloadIdentityPoolProvider resources.

Project IDs remain valid Resource Manager project names. Workload Identity
Federation resource names require a project number because Google principal
identifiers are number-based. Provider mappings require `google.subject`, have
bounded deterministic keys, and reject non-HTTPS issuers.

## Lifecycle

Policy operations always request version 3. A successful read is normalized to
the declared ownership boundary before hashing. Conditional bindings preserve
their full condition object. All writes carry the latest etag and use an update
mask of `bindings,etag` where the endpoint supports it.

Custom-role updates send explicit masks and etags. Deletes are soft deletes;
create adopts or undeletes an identical soft-deleted role when safe.

Pool and provider create, patch, delete and undelete operations are resumable
Google long-running operations. Immutable resource IDs replace; mutable fields
update through explicit masks.

## Permission Intelligence

Each managed provider operation publishes its exact Google permissions. The
graph derives separate deployer and runtime permission sets, folds those into
least-privilege role proposals, and retains resource and operation provenance
for every permission.

Preflight groups permissions by policy target and calls
`testIamPermissions`. Missing service agents, disabled APIs, organization-policy
constraints and VPC Service Controls findings remain typed blockers or warnings
with source resource IDs. A failed or unavailable preflight is never reported
as proof that permission exists.

## Visual Evidence

Visual artifacts expose `iam_ownership`, policy target, role, condition title
and principal count. Permission edges are flat IAM edges and distinguish
declared grants from derived required permissions. The inspector explains the
blast radius for Member, Binding and Policy ownership before apply.

## Qualification

Deterministic tests must prove:

1. member writes preserve unrelated members and conditional bindings;
2. binding writes preserve unrelated bindings but replace their owned set;
3. policy writes replace bindings only under explicit policy authority;
4. etag conflicts reread and replay without losing concurrent unrelated edits;
5. conditions and principals reject unsafe or non-canonical input;
6. service-account IAM, custom roles and WIF use exact Google paths and masks;
7. permission synthesis and visual ownership are stable and redacted.

Authenticated qualification uses a disposable project and, when supplied, a
folder or organization test boundary. Organization-level proof remains visibly
credential-gated when that authority is not available.
