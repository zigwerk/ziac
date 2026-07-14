# M79 Governance Boundary Design

Date: 2026-07-14

## Objective

Make Ziac useful for organization governance by managing Organization Policy,
Resource Manager tags, Access Context Manager and VPC Service Controls through
typed resources. Enforced and dry-run policy must remain visibly different,
destructive policy removal must be explicit, and the canvas must explain which
projects and APIs a governance rule affects.

## Google Contracts

- Organization Policy v2 Discovery revision `20260702`, SHA-256
  `24db4f5718b279cee104b4b0f88b2a3997037c78d12ba7fa0759612aaf8d76f4`.
- Access Context Manager v1 Discovery revision `20260707`, SHA-256
  `88981fd8ecb1ec305364999172fdd6061843c97a373e78595883fc2b2da1c57a`.
- Cloud Resource Manager v3 Discovery revision `20260709`, SHA-256
  `19b05a73c08cb7650e9da7072503cd602ddb68b7341f29ce3ea15999f9f69253`.

## Public Resources

- `gcp.orgpolicy.Policy`: hierarchy-scoped policy for boolean, list, custom or
  managed constraints; typed enforced and dry-run specs; etag-safe overwrite.
- `gcp.orgpolicy.CustomConstraint`: organization custom constraint with CEL,
  action, resource and method types.
- `gcp.tags.TagKey`: organization/project tag key with immutable namespace,
  short name and purpose plus mutable description.
- `gcp.tags.TagValue`: server-assigned value under one key, with immutable short
  name and mutable description.
- `gcp.tags.TagBinding`: immutable relation between a full Google resource name
  and one permanent or namespaced tag value.
- `gcp.tags.TagHold`: server-assigned deletion guard under a tag value.
- `gcp.accesscontextmanager.AccessPolicy`: organization policy container with at
  most one immutable project/folder scope.
- `gcp.accesscontextmanager.AccessLevel`: basic or CEL custom access level with
  deterministic conditions.
- `gcp.accesscontextmanager.ServicePerimeter`: regular or bridge perimeter,
  enforced and optional explicit dry-run configurations, typed ingress/egress
  rules and etag-safe updates.
- `gcp.accesscontextmanager.GcpUserAccessBinding`: server-assigned group binding
  with one enforced and/or dry-run access level.

The managed catalog increases from 186 to 196 resources.

## Typed Policy Model

Organization Policy rules use a tagged union: boolean enforcement, allow all,
deny all, or allowed/denied values. Conditions are explicit CEL strings.
Managed-constraint parameters use typed string, bool, integer and string-list
values rather than opaque JSON.

Access levels support basic conditions over CIDRs, principals, regions,
required levels and negation, or one custom CEL expression. Perimeter
configuration supports projects/VPC networks, restricted services, access
levels, VPC-accessible services and typed ingress/egress policies. Bridge
perimeters reject fields Google forbids. Dry-run configuration can be planned
without claiming enforcement.

## Provider Behavior

Org Policy is synchronous and uses full overwrite with current spec etags.
Custom constraints are synchronous and use exact update masks. Tag keys,
values, bindings and holds use Resource Manager v3 long-running operations and
server-assigned identities. Access Context Manager mutations are resumable v1
operations. Imports always accept canonical Google resource names.

Tags and access resources are retained by default. Policy deletion, custom
constraint deletion, tag removal, access-level/perimeter removal and access
policy deletion require an explicit removal policy plus destructive operation
authority. Access-policy deletion also requires a declaration flag because it
cascades to child levels and perimeters.

## Opinionated Component

`GovernedProjectBoundary` composes project-level organization policies, tag
bindings and membership in one regular VPC Service Controls perimeter. It
accepts existing Access Policy, Access Level and Tag Value outputs, so it does
not invent organization-wide singleton ownership. Dependencies remain explicit
and several project boundaries can share one root graph.

## Product Integration

Permission synthesis emits organization-policy, tag and Access Context Manager
authority only for operations represented by the graph. Cloud Asset discovery
maps supported tags, policies, access resources and perimeters to the same
physical identities. Canvas artifacts show policy scope, tag inheritance,
perimeter membership, restricted services, ingress/egress direction and
enforced versus dry-run state. Governance resources carry an explicit zero
configuration-management estimate; downstream workload and security product
charges remain separate.

The local qualification receipt is unauthenticated and records create/import,
resumable operations, no-op reconciliation, dry-run visibility and retained
cleanup. The remote runner requires ADC, a disposable organization/folder
scope and exact destructive confirmation; it never silently removes an
organization policy or perimeter.
