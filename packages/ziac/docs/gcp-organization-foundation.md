# GCP Organization And Project Foundation

Ziac manages the Google Cloud hierarchy required before application resources
can exist. The M78 surface uses Resource Manager v3, Cloud Billing v1 and
Service Usage v1beta1 contracts pinned in `gcp/discovery_contract.zig`.

## Managed Resources

| Ziac type | Google resource | Default removal behavior |
| --- | --- | --- |
| `gcp.resourcemanager.Folder` | Resource Manager folder | protected and retained |
| `gcp.resourcemanager.Project` | Resource Manager project | protected and retained |
| `gcp.resourcemanager.Lien` | Resource Manager lien | protected and retained |
| `gcp.billing.ProjectBillingAssociation` | project billing singleton | retained |
| `gcp.serviceusage.ServiceIdentity` | Google-managed service agent | retained |

Folders and projects accept organization or folder parents through typed public
outputs. Projects expose their server-assigned numeric name and project number,
so downstream resources do not guess identities. Liens accept project parents
and own an exact reason, origin and restriction set.
Billing associations own the billing account attached to one project. Service
identities generate the Google-managed agent for one API and project number.

## ProjectFoundation

`ziac.gcp.ProjectFoundation` compiles an optional folder, one project, billing,
API enablement and selected service identities into one acyclic graph:

```zig
var foundation = try ziac.gcp.ProjectFoundation.build(allocator, provider, .{
    .name = "platform",
    .parent = ziac.PublicOutput([]const u8).known("organizations/123456789"),
    .folder = .{ .display_name = "Platform" },
    .project_id = "example-platform-prod",
    .billing_account = "billingAccounts/000000-111111-222222",
    .services = &.{ "run.googleapis.com", "secretmanager.googleapis.com" },
    .service_identities = &.{"run.googleapis.com"},
});
defer foundation.deinit();
```

Pass an existing graph as `base_graph` to compose several project foundations.
Billing, API and service-identity logical IDs are scoped to the target project,
so two foundations can enable the same services in one monorepo canvas without
resource collisions.

## Lifecycle And Drift

Folder and project creation checkpoints Google's long-running operation before
polling. A resumed process continues from that operation handle and replaces a
temporary logical identity with the server-assigned numeric resource name.
Project parent changes use the native `projects:move` method. Writable fields
use exact update masks and the last observed etag. An empty project
`display_name` means Ziac does not own that optional value, so another label
change cannot erase a console-managed display name.

Project deletion requires all of the following:

- `request_delete = true` on the declaration;
- `protect = false` and `retain_on_delete = false` on the resource;
- explicit destructive confirmation on the operation.

Folder deletion uses the same gates. Liens require `removal_policy = .delete`,
`protect = false` and destructive confirmation. Billing is never detached by
ordinary graph removal; use `removal_policy = .detach` and destructive
confirmation. Service identities cannot be deleted through Ziac.

## Imports

Imports accept canonical Google resource names:

- `folders/<numeric-id>`
- `projects/<project-id-or-number>`
- `liens/<numeric-id>`
- `projects/<project-id-or-number>/billingInfo`
- a generated service-agent email returned by Google

Import reads the remote object, normalizes observed inputs and then participates
in the same diff path as a created resource. An import is not proof that Ziac
may delete the hierarchy; declaration and operation gates still apply.

## Permissions And Product Data

Graph-derived permission synthesis requests only the RPC authority represented
by the plan. It includes folder/project create, get, update and move; lien
create/get; billing read/update plus the project assignment and Service Usage
reads Google requires; service-agent generation; and conditional delete or
billing-detach permissions only when those destructive declarations are
present. Detach selects the project-side unlink authority from Google's two
documented alternatives. Runtime applications receive none of this hierarchy
authority.

Cloud Asset Inventory maps folders, projects and liens to the same physical
identities. Visual artifacts emit hierarchy, billing, API enablement, service
identity and deletion-guard edges. Resource Manager hierarchy, billing
attachment and service-agent generation have an explicit zero-dollar
configuration estimate; workload usage and billed spend are outside this
estimate.

## Qualification

`scripts/qualify-organization-foundation.sh` is fail closed. It requires ADC,
`gcloud`, `jq`, an external workspace that registers a `ProjectFoundation`
stack, a billing account, an organization, and a project ID ending in
`-ziac-disposable`. It creates and imports the graph, requires a second-state
no-op plan, probes project and billing state, and deletes only after the exact
`DELETE_DISPOSABLE_PROJECT` confirmation phrase.

The deterministic local receipt is always marked `authenticated=false`. It
proves graph shape, retained-resource count, exact permission synthesis,
artifact digest and resumable-operation coverage, but it does not claim live
Google Cloud behavior, billing-account mutation, organization-policy inference
or workload cost evidence.

## Google Contracts

- [Resource Manager v3 folders](https://cloud.google.com/resource-manager/reference/rest/v3/folders)
- [Resource Manager v3 projects](https://cloud.google.com/resource-manager/reference/rest/v3/projects)
- [Resource Manager v3 liens](https://cloud.google.com/resource-manager/reference/rest/v3/liens)
- [Cloud Billing project access control](https://cloud.google.com/billing/docs/access-control)
- [Service Usage service identity generation](https://cloud.google.com/service-usage/docs/reference/rest/v1beta1/services/generateServiceIdentity)
