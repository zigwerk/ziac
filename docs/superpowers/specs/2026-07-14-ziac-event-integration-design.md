# M82 Event Integration Design

Date: 2026-07-14

## Objective

Make Ziac useful for event-platform and integration teams by managing Eventarc
Advanced buses, sources, routes and Integration Connectors configuration while
keeping message publication, repair, retry and schema refresh as explicit,
target-bound operations. Credentials must remain Secret Manager references and
must never enter plans, state, logs or visual artifacts.

## Google Contracts

- Eventarc v1 Discovery revision `20260706`, SHA-256
  `c71e50f2d1dd6161eafb10394ba850ecff12204d7df2ffd2d39e0e3f5265e91c`.
- Connectors v1 Discovery revision `20260701`, SHA-256
  `b23c2352fcefc564827e05f2ab953507307e795d1d6dd7c711e44e76ac13ebb8`.

Both are pinned from Google's public Discovery endpoints. Eventarc Advanced is
an extension of the existing Eventarc v1 service. Integration Connectors uses
`connectors.googleapis.com` and a separate client endpoint.

## Public Resources

Eventarc Advanced:

- `gcp.eventarc.MessageBus`
- `gcp.eventarc.MessageBusIamMember`
- `gcp.eventarc.Pipeline`
- `gcp.eventarc.PipelineIamMember`
- `gcp.eventarc.Enrollment`
- `gcp.eventarc.EnrollmentIamMember`
- `gcp.eventarc.GoogleApiSource`
- `gcp.eventarc.GoogleApiSourceIamMember`

Integration Connectors:

- `gcp.connectors.Connection`
- `gcp.connectors.ConnectionIamMember`
- `gcp.connectors.EndpointAttachment`
- `gcp.connectors.EventSubscription`
- `gcp.connectors.ManagedZone`
- `gcp.connectors.RegionalSettings`

The managed catalog increases from 223 to 237 resources.

## Typed Eventarc Model

A message bus owns display name, labels, annotations, platform logging and an
optional CMEK reference. A pipeline has exactly one typed destination: HTTPS,
Workflow, Pub/Sub topic or another message bus. HTTPS destinations can declare
OIDC or OAuth service-account authentication and a regional network attachment.
Retry bounds, payload formats and an optional CEL transformation are typed.

An enrollment requires a bus, pipeline and bounded CEL match expression. Ziac
validates that locally-built resources use the same region and that the pipeline
and enrollment are in the same project. A Google API source targets one bus and
chooses exactly one project-subscription mode: explicit project numbers or the
owning organization. Cross-project source authority stays explicit.

## Typed Connector Model

A connection owns a stable connector-version resource name, service account,
node bounds, suspension, logging, typed config variables and destinations.
Authentication is a tagged union. Passwords, client secrets and private keys
are represented only as Secret Manager version resource names. Config variables
can use strings, integers, booleans or Secret Manager references; duplicate keys
and inline credential-shaped values are rejected.

Endpoint attachments type a PSC service attachment and global-access policy.
Managed zones type target project, VPC and DNS suffix. Regional settings type
egress mode and optional CMEK. Event subscriptions belong to a connection and
route a connector event to Pub/Sub or HTTPS with an optional runtime service
account. Trigger configuration secrets use the same reference-only model.

## Lifecycle Safety

Eventarc Advanced mutations are long-running operations. Create, patch and
delete checkpoint operation names, preserve request IDs, use exact field masks,
and send current etags. Bus/source CMEK, resource identity, location and
destination kind changes replace where Google cannot safely migrate them.

Connector mutations also checkpoint native operations. Connection connector
version, region and authentication mode changes replace; mutable parameters use
exact masks. Endpoint PSC target and managed-zone ownership changes replace.
Regional settings is an update-only singleton and can be imported but not
deleted. Connection IAM uses policy version 3, etags and bounded conflict
retries. Retained resources require declared removal and destructive authority.

Ordinary apply never publishes an event, repairs connector eventing, retries a
subscription, refreshes a runtime schema or invokes a connector action. Those
operations require target-bound capabilities and emit redacted receipts.

## Opinionated Components

- `AdvancedEventRoute` composes a message bus, pipeline, enrollment, optional
  Google API source and least-authority publisher/invoker IAM.
- `PrivateConnector` composes regional settings, managed DNS zone, PSC endpoint
  attachment and a Secret-Manager-backed connection.
- `ConnectorEventBridge` composes a connection event subscription, Pub/Sub
  destination and exact runtime authority without adopting the destination.

## Product Integration

Permission synthesis separates deployer, Eventarc delivery identity, connector
runtime identity and governed operator authority. Cloud Asset identity maps all
published Eventarc Advanced and Connectors asset types. Runtime-only schemas and
connector provider catalogs remain observed metadata, not managed resources.

Canvas artifacts show source-to-bus, bus-to-enrollment, enrollment-to-pipeline,
pipeline-to-destination, connection-to-PSC/DNS and subscription-to-destination
edges. Secret references are represented as redacted dependencies. Eventarc
cost estimates require bus-message, pipeline-message and transformation counts.
Connector estimates require connector class, active node-hours and processed
GiB; without those assumptions the dashboard reports unavailable, never zero.

The local qualification receipt proves create/import/no-op, replacement
boundaries, operation resume, exact masks/etags, additive IAM, action exclusion,
secret redaction, permission synthesis, visual topology and cost provenance.
Authenticated qualification uses only a disposable project and bounded
configuration probes. It does not publish customer events or invoke third-party
systems.

## Visible Exclusions

Custom connector definitions and version publication are excluded from M82
because their publish/deprecate/withdraw lifecycle is operational and connector
specific. Runtime action/entity schemas and runtime config are observed-only.
Preview resources remain opt-in and must carry a migration policy before they
can enter the stable catalog.
