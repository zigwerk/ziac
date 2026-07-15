# GCP Vertex AI

Ziac M83 provides a stable-v1 Vertex AI platform surface across all three GCP
provider layers: typed declarations, hardened lifecycle adapters and
opinionated production components.

## Managed Resources

The low-level layer manages datasets, models, prediction endpoints, vector
indexes and index endpoints, feature groups and features, feature online stores
and views, Tensorboards and metadata stores. Additive policy-v3 IAM is available
for datasets, models, feature groups, feature online stores and feature views,
the resources for which Vertex v1 exposes native IAM methods.

The catalog contains 16 Vertex entries and 253 managed GCP resource types in
total. Requests use `https://{location}-aiplatform.googleapis.com` and the
checked-in contract pins `aiplatform:v1` revision `20260704` with SHA-256
`d71d9b40a874d02185acad480058d99d280749a219f2b6a85e36c61e8a7e431a`.
The digest covers compact JSON with recursively sorted object keys because
Google's raw response key order is not stable across otherwise identical reads.

## Lifecycle Safety

Declarations reject cross-region references, mutable model image tags,
unbounded metadata JSON, invalid schema or artifact URIs, plaintext secrets and
unsupported connectivity. Updates use exact masks and observed etags. Identity,
schema, artifact, encryption, network and storage-mode changes replace rather
than mutating an incompatible resource. Long-running operations are
checkpointed and resumable; retained resources are never deleted implicitly.

`OnlinePredictionPlatform`, `VectorSearchPlatform` and `FeaturePlatform`
compose durable resources and typed wiring. Deploying or undeploying models and
indexes, submitting or cancelling pipeline jobs and synchronizing feature
views are governed actions. They require target- and payload-bound capability
digests and never execute during ordinary reconciliation.

## Import And Canvas

Cloud Asset Inventory currently exposes Dataset, Endpoint, FeatureGroup,
FeatureOnlineStore, Index, IndexEndpoint, MetadataStore, Model and Tensorboard.
Those nine identities map to typed observed resources. Feature and FeatureView
remain generic observed assets because Google does not expose them through CAI;
Ziac does not pretend they can be safely adopted.

The local dashboard receives bounded `vertex_ai` metadata for prediction,
vector search, feature serving, lineage, experiment and IAM objects. It keeps
observed and managed resources distinct while rendering their shared regional
topology.

## IAM And Cost

Permission synthesis emits exact control-plane methods and keeps runtime
prediction and feature-serving access separate. The seven governed actions add
only their required permissions.

Vertex prices depend on model, machine, accelerator, index, online-store
implementation, usage and region. `vertexAiConfigurationEstimate` therefore
requires explicit usage assumptions and matching catalog rates. Missing usage
or a missing regional SKU returns an error; the dashboard reports
`usage_assumptions_required` until evidence exists. Billing export remains the
only source of actual billed cost.

## Qualification

`scripts/qualify-vertex-ai.sh` fails closed unless Application Default
Credentials, an explicitly disposable project, a region, exact resource probes
and destructive confirmation are present. It deploys a user-owned Vertex stack,
performs authenticated reads, imports the resources into a second state and
requires a no-op plan. Model/index deployment, pipeline execution and data-plane
requests remain excluded unless a later runner adds separate confirmation.
