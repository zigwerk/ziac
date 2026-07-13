# General Google Cloud IAM

Ziac models Google Cloud IAM authority explicitly. Choose the narrowest resource
that owns the change you intend:

| Resource family | Authority | Preserves |
| --- | --- | --- |
| `*Member` | one role, principal and optional condition tuple | every unrelated member and binding |
| `*Binding` | the complete member set for one role and optional condition | every unrelated binding |
| `*Policy` | the complete allow-binding policy for one target | audit configuration only |

The planner rejects overlapping authority for the same target. A policy cannot
coexist with member or binding resources for that target; a binding cannot
overlap members for its role and condition. This makes the potential blast
radius visible before provider access.

## Supported Targets

Ziac manages additive members, authoritative bindings and authoritative policies
for projects, folders and organizations. Service accounts support additive
members and authoritative bindings. Project and organization custom roles, plus
Workload Identity Pools and OIDC Pool Providers, use their native IAM v1
lifecycles.

All principals, roles, conditions and member lists are canonicalized before the
resource enters the graph. The declaration layer rejects:

- malformed or unsupported principal identifiers;
- duplicate members and custom-role permissions;
- conditional grants of basic roles;
- conditional public grants;
- non-HTTPS OIDC issuers;
- federation mappings without `google.subject`;
- overlapping IAM authority in one plan.

## Conditions And Concurrency

Conditional bindings always request and write IAM policy version 3. Member and
binding operations perform an etag-protected read-modify-write and retry a
bounded number of conflicts from a fresh read. Unrelated concurrent edits are
preserved. A policy resource is deliberately broader: it replaces all allow
bindings while carrying the current audit configuration and etag.

```zig
var deployer = try ziac.gcp.iam.ProjectMember.build(allocator, provider, .{
    .name = "ci-artifact-writer",
    .role = "roles/artifactregistry.writer",
    .member = "principalSet://iam.googleapis.com/projects/123456789/locations/global/workloadIdentityPools/github/attribute.repository/acme/api",
    .condition = .{
        .title = "main-branch",
        .expression = "attribute.ref == 'refs/heads/main'",
    },
});
defer deployer.deinit(allocator);
```

Imports use the same canonical target, role, condition and principal identity as
managed state. A refresh reports drift only inside the selected ownership
boundary.

## Keyless CI Federation

`WorkloadIdentityPool` and `WorkloadIdentityPoolProvider` create the trust
boundary used by external CI systems. The provider references its pool through a
typed output, requires an HTTPS issuer, and stores a canonical attribute map and
audience set. Grant the resulting principal or principal set access with the
narrowest `*Member` resource. Service-account impersonation is a separate,
explicit `ServiceAccountIamMember` grant.

```zig
var pool = try ziac.gcp.iam.WorkloadIdentityPool.build(allocator, provider, .{
    .project_number = "123456789",
    .pool_id = "github",
    .display_name = "GitHub Actions",
});
defer pool.deinit(allocator);

var actions = try ziac.gcp.iam.WorkloadIdentityPoolProvider.build(allocator, provider, .{
    .provider_id = "actions",
    .pool_name = pool.name,
    .display_name = "GitHub Actions",
    .issuer_uri = "https://token.actions.githubusercontent.com",
    .attribute_mapping = &.{
        .{ .google_attribute = "google.subject", .assertion_expression = "assertion.sub" },
        .{ .google_attribute = "attribute.repository", .assertion_expression = "assertion.repository" },
    },
});
defer actions.deinit(allocator);
```

Deletion follows Google soft-delete semantics and can be resumed from a saved
long-running-operation handle. `retain_on_delete` remains available for trust
boundaries that must outlive a stack.

## Permission Intelligence

`gcp.intelligence.synthesizePermissionPlan` derives deployer permissions from
the exact RPC operations in a graph and runtime permissions from declared IAM
roles. Every requirement carries its resource and operation provenance. Ziac can
emit separate least-privilege custom-role proposals for deployer and runtime
audiences.

`gcp.permission_preflight.LivePermissionPreflight` calls the target's native
`testIamPermissions` endpoint for projects, folders, organizations or service
accounts. Missing APIs, service agents, quota, organization-policy and VPC
Service Controls constraints remain distinct findings. Inventory evidence is
reported as evidence, not as proof that Google will accept a mutation.

## Estate And Workbench

Cloud Asset Inventory discoveries for service accounts, custom roles, workload
identity pools and pool providers map to the same Ziac identities used by
managed resources. They remain observed until explicitly adopted. Pool and
provider assets are discoverable but do not imply Cloud Asset relationship
analysis support.

The local workbench shows ownership, target, role, condition, principal count
and blast radius. IAM dependency lines remain visually distinct from traffic,
output and ordinary dependency lines.

Official contracts:

- [Allow policies](https://cloud.google.com/iam/docs/policies)
- [IAM Conditions](https://cloud.google.com/iam/docs/conditions-overview)
- [Custom roles](https://cloud.google.com/iam/docs/creating-custom-roles)
- [Workload identity federation](https://cloud.google.com/iam/docs/workload-identity-federation)
- [Cloud Asset supported types](https://cloud.google.com/asset-inventory/docs/asset-types)

Authenticated project qualification can prove project IAM, custom roles and
workload federation. Folder and organization qualification additionally requires
operator-owned hierarchy credentials and is never inferred from scripted tests.
