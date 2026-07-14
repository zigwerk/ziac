# M78 Organization and Project Foundation Design

Date: 2026-07-14

## Objective

Make Ziac useful at the Google Cloud hierarchy boundary by managing folders,
projects, project billing, service identities and liens as typed resources, then
compose those primitives into a safe project foundation.

## Google contracts

- Cloud Resource Manager v3 Discovery revision `20260709`, SHA-256
  `19b05a73c08cb7650e9da7072503cd602ddb68b7341f29ce3ea15999f9f69253`.
- Cloud Billing v1 Discovery revision `20260710`, SHA-256
  `1daf9db8ef1984bbc46adfdeec581e1f1774a87fbec2ae0fda5b4c0cf302f10a`.
- Service Usage v1beta1 Discovery revision `20260629`, SHA-256
  `7fa0f49af58ad3b8d7591c176f0004cb84125abcbc973e4b95cd17426346e61d`.

## Public resources

- `gcp.resourcemanager.Folder`: Google-assigned numeric identity, mutable
  display name, explicit parent move and retained deletion by default.
- `gcp.resourcemanager.Project`: immutable project ID, Google-assigned numeric
  name, mutable display name/labels, explicit parent move and retained deletion
  by default.
- `gcp.resourcemanager.Lien`: Google-assigned identity, immutable parent,
  origin, reason and restrictions, retained by default.
- `gcp.billing.ProjectBillingAssociation`: singleton project billing relation;
  changing accounts is an update and detachment is never inferred.
- `gcp.serviceusage.ServiceIdentity`: idempotent service-agent generation,
  Google-returned email/unique ID and retained lifecycle.

## Provider behavior

Folder and project create, move, delete and undelete use Cloud Resource Manager
v3 operations with resumable handles. Patches use current etags and exact field
masks. A parent change invokes the native move method rather than pretending it
is a normal patch.

Project deletion and folder deletion require both an explicit `request_delete`
declaration and destructive confirmation. Liens retain by default and require
confirmation for removal. Billing associations retain by default; an explicit
detach policy sends an empty billing account only during authorized deletion.
Service identities have no delete path.

## Opinionated component

`ProjectFoundation` optionally creates a folder, creates a project under the
selected parent, attaches billing, enables declared APIs with the existing
`gcp.project.Service`, and materializes requested service identities. Every
dependency remains visible in the resource graph. The component does not invent
organization IAM or broad roles.

## Product integration

Permission intelligence must separate hierarchy, billing and service-agent
authority. Cloud Asset Inventory maps Folder, Project and Lien identities.
Canvas metadata shows hierarchy, billing and service-agent edges. Cost remains
an explicit project-management estimate and does not imply resource workload
cost. The remote runner requires ADC and a disposable organization test parent;
it never deletes a project without the explicit destructive gate.
