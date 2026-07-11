# Ziac Live Estate Scan Design

Date: 2026-07-11

Status: validated for implementation

## Objective

A Google-authenticated Pro user can authorize read-only access to one customer
GCP project, scan Cloud Asset Inventory through the Zig host, and render the
result as an observed `ziac.visual.v1` graph without importing any resource
into Ziac state.

## Boundaries

Identity, paid entitlement, and GCP authorization are independent facts. The
scan fails closed unless all three are verified. Customer credentials remain in
the host and never enter the visual artifact, browser session, logs, state, or
test receipts.

Cloud Asset Inventory pagination is bounded. The scanner retains only stable
resource identity, provider type, location, display identity, and declared
relationship names. Provider payloads and additional attributes are not copied
blindly into the artifact.

Observed resources are mutation-isolated. Their ownership is `observed`, their
operation is `read`, and their lifecycle controls are all false. Relationship
edges connect only resources present in the same completed scan.

## Acceptance

- missing Google identity, Pro entitlement, or project connection stops before
  a provider call;
- all pages are consumed once with a bounded asset and page limit;
- stable provider mappings cover Cloud Run, Cloud SQL, Storage, VPC, load
  balancing, and Compute;
- observed resources and relationships form a deterministic valid visual graph;
- credential-shaped data is rejected from access projections and artifacts;
- scripted provider tests and the complete receipt-qualified Ziac suite pass.
