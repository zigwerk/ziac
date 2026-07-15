# M83 Vertex AI Platform Design

Status: accepted for implementation

## Goal

Make Ziac useful for the stable Vertex AI platform without turning jobs,
deployments, or data-plane writes into mutable infrastructure resources. M83
keeps the provider's three layers explicit:

1. typed low-level resources for broad stable-v1 coverage;
2. hardened lifecycle adapters for adoption, drift and safe mutation;
3. opinionated platform components for prediction, vector search and features.

## Contract Source

The source of truth is the Vertex AI `v1` discovery document at
`https://aiplatform.googleapis.com/$discovery/rest?version=v1`, revision
`20260704`, SHA-256
`d71d9b40a874d02185acad480058d99d280749a219f2b6a85e36c61e8a7e431a`.
The digest covers compact, recursively key-sorted JSON because Google's raw
response object order is nondeterministic.
Preview-only resources remain excluded unless a later milestone adds an
explicit opt-in and migration policy.

Vertex AI control-plane requests use the regional endpoint
`https://{location}-aiplatform.googleapis.com`. Ziac validates location tokens
before constructing that origin. The generic global endpoint remains available
only as a test override; resource adapters must use the regional origin.

## Managed Surface

M83 adds 16 catalog entries:

- `gcp.vertex.Dataset` and `DatasetIamMember`;
- `gcp.vertex.Model` and `ModelIamMember`;
- `gcp.vertex.Endpoint`;
- `gcp.vertex.Index`;
- `gcp.vertex.IndexEndpoint`;
- `gcp.vertex.FeatureGroup`, `FeatureGroupIamMember`, and `Feature`;
- `gcp.vertex.FeatureOnlineStore` and `FeatureOnlineStoreIamMember`;
- `gcp.vertex.FeatureView` and `FeatureViewIamMember`;
- `gcp.vertex.Tensorboard`;
- `gcp.vertex.MetadataStore`.

The catalog rises from 237 to 253 managed resources. Dataset and model IDs are
server-assigned by their APIs; Ziac stores their returned canonical names and
supports adoption through explicit physical IDs. All other selected resources
accept deterministic client IDs.

## Typed Declarations

Every resource validates provider availability, regional locality, display
names, labels, removal policy and references before graph construction.

- Datasets require a stable metadata schema URI and bounded metadata JSON.
- Models require an artifact URI, serving container image and bounded ports,
  environment, schema and metadata values. Secret material is never accepted;
  only Secret Manager references may appear where supported by a later API.
- Endpoints choose one of public, VPC peering or Private Service Connect.
- Indexes require a schema URI, update method and bounded metadata JSON.
- Index endpoints choose public, VPC peering or Private Service Connect.
- Feature groups require a BigQuery source and entity-id columns.
- Features are nested under a feature group and use the stable v1 feature ID
  grammar.
- Feature online stores choose Bigtable or optimized storage with validated
  serving bounds and private connectivity.
- Feature views choose a BigQuery source or feature registry source and define
  an explicit sync interval.
- Tensorboards and metadata stores expose encryption and retention policy.
- IAM resources are additive members with optional conditions. They preserve
  unrelated bindings and use policy version 3.

## Lifecycle Adapters

The Vertex adapter owns canonical identity, regional request origins, request
bodies, update masks, etags and long-running operation resume.

- `read` normalizes output-only fields and stores a redacted remote snapshot.
- `diff` replaces immutable identity, schema, artifact, encryption, network and
  storage-mode changes; mutable descriptions, display names and labels update
  through exact masks.
- `create`, `update` and `delete` checkpoint Google LRO names and resume them.
- synchronous model, endpoint and index-endpoint updates still enforce etags.
- retained resources require no delete call. Destructive resources require
  explicit confirmation.
- imports validate full canonical names and prove a second-state no-op.

Dataset and model creation responses can return server-assigned identifiers;
their logical names are correlation labels, not claimed physical IDs.

## Governed Actions

The following operations are target- and payload-bound capabilities excluded
from normal graph reconciliation:

- deploy and undeploy a model on an endpoint, including traffic splits;
- deploy and undeploy an index on an index endpoint;
- submit and cancel a pipeline job;
- synchronize a feature view.

Action receipts include target, request digest, operation or job identity,
regional origin and causal ID. Pipeline specs are bounded JSON values and never
passed through a shell.

## Opinionated Components

`OnlinePredictionPlatform` composes a model, endpoint and deployment intent.
The graph contains the durable model and endpoint; the deployment is emitted as
a governed action request and permission requirement.

`VectorSearchPlatform` composes an index, index endpoint and deployment intent,
with optional private network placement.

`FeaturePlatform` composes a feature group, feature definitions, online store
and feature view with cross-region references rejected at compile time.

## Intelligence And Product Surfaces

Permission synthesis separates deployer and runtime authority. APIs include
`aiplatform.googleapis.com` plus referenced KMS, Storage, BigQuery, Compute and
IAM services. Runtime prediction, vector query and feature read permissions are
emitted only when the corresponding component requests them.

Cloud Asset Inventory supports Dataset, Endpoint, FeatureGroup,
FeatureOnlineStore, Index, IndexEndpoint, MetadataStore, Model and Tensorboard.
Feature and FeatureView are explicitly unavailable from CAI and are not faked.

Canvas metadata distinguishes model, endpoint, vector, feature, experiment and
lineage objects. Edges encode deployment, serving, source, sync, network,
encryption and IAM semantics.

Cost output is configuration-based unless billing data is attached. Vertex AI
rates vary by model, machine, accelerator, index, online-store implementation
and region, so M83 requires explicit usage and unit-rate inputs. Empty usage
produces `unavailable`, never a fabricated zero-dollar estimate.

## Qualification

Local qualification proves declarations, replacement boundaries, exact masks,
operation resume, import/no-op, action isolation, permission synthesis, CAI
coverage, visual metadata, cost provenance and redaction.

The authenticated runner fails closed unless ADC, an explicit disposable
project, region and exact confirmation are present. It creates only bounded
low-cost resources, proves adoption/no-op, and retains operator-owned resources
for explicit cleanup. Model/index deployment and pipeline execution are omitted
unless separately confirmed.
