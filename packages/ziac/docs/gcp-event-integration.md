# GCP Event Integration

Ziac M82 manages Eventarc Advanced and Integration Connectors as typed,
importable infrastructure. It is the event and SaaS-integration tranche of the
three-layer GCP provider model.

## Coverage

The low-level layer includes Eventarc message buses, pipelines, enrollments,
Google API sources and additive IAM. Connectors includes connections, endpoint
attachments, event subscriptions, managed zones, regional settings and
additive connection IAM.

`AdvancedEventRoute`, `PrivateConnector` and `ConnectorEventBridge` compose the
common production graphs. Their output references generate dependency edges,
so locality and wiring are validated before preview.

Provider mutations use the current pinned Google Discovery contracts. Eventarc
updates use exact masks and etags. Both APIs checkpoint long-running operation
names for resume. Connector credentials are Secret Manager version references;
plaintext credential values are rejected by the declaration boundary.

## Governed Actions

Publishing an Eventarc message, repairing connector eventing, retrying an event
subscription and refreshing connector schema are explicit capabilities. They
are not desired-state resources and never run during ordinary reconciliation.
Each action binds its stage, project, target, payload and authority budget into
a SHA-256 digest before contacting Google.

## Import And Visualization

Cloud Asset Inventory identities map Eventarc Advanced and Connectors assets to
the same Ziac type names used by managed graphs. The local dashboard therefore
merges observed and managed event topology without silently adopting observed
resources. Canvas artifacts expose event kind, location, connector version,
event type, egress mode, node bounds and IAM role while redacting secret
references.

## Cost Semantics

Eventarc Advanced estimates require explicit bus events, pipeline events and
transformation operations. Connector estimates require explicit node-hours and
processed GiB, with free allowances represented separately. Until usage is
provided, the canvas reports `usage_assumptions_required`; it never labels a
configuration estimate as billed cost.

## Qualification

Run `scripts/qualify-event-integration.sh` only against a disposable project.
The runner requires Application Default Credentials, exact resource probes and
an explicit destructive confirmation. It deploys the selected user stack,
proves authenticated reads, imports into a second state and requires a no-op
plan. Governed runtime actions remain excluded.
