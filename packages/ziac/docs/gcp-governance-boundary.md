# GCP Governance Boundaries

Ziac manages Google Cloud organization policy, Resource Manager tags, Access
Context Manager and VPC Service Controls as one typed governance surface. The
provider keeps enforced and dry-run policy separate, adopts Google's canonical
server identities and retains governance resources unless deletion is declared
and separately authorized.

## Managed Resources

| Ziac type | Google API | Lifecycle |
| --- | --- | --- |
| `gcp.orgpolicy.Policy` | Organization Policy v2 | Full spec overwrite with the current spec etag |
| `gcp.orgpolicy.CustomConstraint` | Organization Policy v2 | Exact mutable-field update mask |
| `gcp.tags.TagKey` | Resource Manager v3 | Resumable operation; immutable namespace and purpose |
| `gcp.tags.TagValue` | Resource Manager v3 | Resumable operation; server-assigned identity |
| `gcp.tags.TagBinding` | Resource Manager v3 | Immutable relation; read through parent listing |
| `gcp.tags.TagHold` | Resource Manager v3 | Server-assigned hold; read through value listing |
| `gcp.accesscontextmanager.AccessPolicy` | Access Context Manager v1 | Resumable singleton mutation; protected by default |
| `gcp.accesscontextmanager.AccessLevel` | Access Context Manager v1 | Basic or CEL level; resumable mutation |
| `gcp.accesscontextmanager.ServicePerimeter` | Access Context Manager v1 | Enforced and explicit dry-run config; etag update |
| `gcp.accesscontextmanager.GcpUserAccessBinding` | Access Context Manager v1 | Enforced and/or dry-run group access |

The pinned Discovery revisions and SHA-256 digests are included in
`ziac provider resources --json`. A contract upgrade must produce a semantic
diff before these pins move.

## Governed Project Boundary

`GovernedProjectBoundary` is the opinionated layer for a project that joins an
existing organization governance root. It creates project policies, assigns an
existing tag value and places the project in one regular service perimeter.
Access policies, access levels and tag values remain explicit inputs because
they are commonly shared organization-wide singletons.

```zig
var boundary = try ziac.gcp.GovernedProjectBoundary.build(allocator, provider, .{
    .name = "payments-prod",
    .project = project.name,
    .project_full_name = ziac.PublicOutput([]const u8).known(
        "//cloudresourcemanager.googleapis.com/projects/987654321",
    ),
    .policies = &.{.{
        .name = "allowed-regions",
        .constraint = "gcp.resourceLocations",
        .spec = .{ .rules = &.{.{
            .effect = .{ .values = .{ .allowed = &.{"in:eu-locations"} } },
        }} },
        .dry_run_spec = .{ .rules = &.{.{
            .effect = .{ .values = .{ .allowed = &.{"in:europe-west1-locations"} } },
        }} },
    }},
    .tag_value = production_tag.name,
    .access_policy = access_policy.name,
    .access_level = trusted_engineers.name,
    .restricted_services = &.{
        "bigquery.googleapis.com",
        "storage.googleapis.com",
    },
    .dry_run_restricted_services = &.{
        "bigquery.googleapis.com",
        "storage.googleapis.com",
        "secretmanager.googleapis.com",
    },
});
defer boundary.deinit();
```

Pass `base_graph` when the project, tag or access roots are managed in the same
Ziac workspace. Output references create dependency edges automatically and
allow independently deployed project slices to share organization resources.
The complete compilable example is `examples/governed_project_boundary.zig`.

## Policy Safety

- Organization policy rules are a tagged union: boolean enforcement, allow
  all, deny all or typed allowed/denied values.
- Managed-constraint parameters retain string, boolean, integer and string-list
  types instead of becoming unvalidated JSON.
- Access conditions validate CIDRs, principals, regions and required levels.
- Bridge perimeters reject regular-perimeter fields that Google forbids.
- Enforced `status` and dry-run `spec` remain separate in plans, state, drift
  comparison and the visual artifact.
- Imports require canonical Google resource names.

Governance resources retain on removal by default. Deletion requires both the
resource's `removal_policy = .delete` declaration and destructive operation
authority. Access-policy deletion additionally requires `request_delete = true`
because deleting the policy cascades to its access levels and perimeters.

## Agent And Canvas Semantics

Permission synthesis derives only the APIs, RPC methods and IAM permissions
used by the graph. Delete authority is absent until deletion intent appears in
the declaration. The local dashboard receives named relationships for policy
scope, tag membership and assignment, access-policy membership, perimeter
policy, perimeter access and perimeter membership. Governance metadata reports
constraint, group, perimeter type, removal policy, rule counts and enforced or
dry-run state.

Cloud Asset Inventory maps official Organization Policy, Resource Manager and
Access Context Manager asset names to the same Ziac types and canonical physical
identities. Their direct configuration-management cost is explicitly zero;
downstream workload, networking and security-product costs remain separate.

## Qualification

The deterministic local receipt is
`ziac.gcp.governance-boundary-qualification.v1`. It proves graph and visual
digests, exact permission synthesis, create/import/no-op counts, retained
cleanup, resumable operations, list-based discovery and distinct enforced and
dry-run resources. It always records `authenticated=false`.

`scripts/qualify-governance-boundary.sh` is the separate authenticated boundary.
It requires ADC, `gcloud`, `jq`, a project ending in `-ziac-disposable`, an
explicit disposable scope, probe identities and the exact confirmation
`QUALIFY_DISPOSABLE_GOVERNANCE_SCOPE`. Missing prerequisites emit a structured
exit-77 skip. The runner applies a user-owned qualification stack, probes the
policy, tag binding and perimeter, imports every physical identity into a second
state and requires a no-op plan. It deliberately retains resources for explicit
operator cleanup and never silently deletes an organization policy or service
perimeter.
