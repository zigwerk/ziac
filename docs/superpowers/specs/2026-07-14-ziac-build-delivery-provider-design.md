# Ziac M75 Build And Artifact Delivery Provider Design

Date: 2026-07-14
Status: approved for implementation by the provider-coverage roadmap
Roadmap: `docs/superpowers/plans/2026-07-13-ziac-gcp-provider-coverage.md`

## Objective

Make source connectivity, repeatable builds, private build execution and
artifact lifecycle policy part of the same compiled graph that deploys a Zig
service. M75 applies Ziac's three provider layers:

1. typed Cloud Build and Artifact Registry declarations;
2. handwritten lifecycle adapters for operations, etags, secrets, immutable
   network shape and one-way settings;
3. an opinionated delivery component for a repository-to-registry pipeline.

M75 adds six managed resource types:

- `gcp.cloudbuild.Trigger`
- `gcp.cloudbuild.WorkerPool`
- `gcp.cloudbuild.Connection`
- `gcp.cloudbuild.Repository`
- `gcp.artifact.ProjectSettings`
- `gcp.artifact.VpcscConfig`

It also upgrades the existing `gcp.artifact.Repository` declaration and
lifecycle adapter with general standard repository formats, cleanup policy,
CMEK, vulnerability-scanning configuration and policy dry runs.

## Contract Sources

The provider pins three Discovery documents:

- Cloud Build v1 revision `20260627`, SHA-256
  `2ccaf9685578eb58438cab4a3c0765dc108f3c26148c2399988749e4db80ccf7`;
- Cloud Build v2 revision `20260627`, SHA-256
  `0f278d1563896222cf12a40c013dbacc0ab45ca3e0526f6b83855a5ea62e9f84`;
- Artifact Registry v1 revision `20260702`, SHA-256
  `8db01db5354a58d312b1e627f067741b40fb41bf1940c211e58676a91d1fd719`.

Contract upgrades use the shared semantic-diff gate.

## Typed Declarations

`Connection` models GitHub.com, GitHub Enterprise, GitLab, Bitbucket Data
Center and Bitbucket Cloud as a tagged union. Secret Manager version names are
public references. Credentials represented by the Google API as plaintext,
including a GitHub Enterprise API key, use Ziac secret references and are
resolved only during create or update. Installation state and reconciliation
state are outputs.

`Repository` links a Cloud Build v2 connection to an immutable HTTPS clone URI.
Its connection input accepts an output from `Connection`, making the ownership
and source relationship part of the graph.

`Trigger` initially targets the modern Cloud Build repository event API. Push,
tag and pull-request filters are typed and mutually exclusive. It supports a
checked build-config path, service account, approval, substitutions, included
and ignored files, disablement and explicit regional locality. A repository,
trigger and private pool must share a location. Webhook and deprecated v1 SCM
connections are not silently represented as modern repository triggers.

`WorkerPool` models machine and disk shape plus exactly one private networking
mode: VPC peering or Private Service Connect. Immutable network attachment,
peering range, egress and routing transitions replace the pool. Machine, disk,
display name and annotations update in place. Pool etags are compare-and-swap
preconditions.

The Artifact Registry `Repository` supports every standard package format in
the pinned contract. Remote and virtual repositories remain explicit future
declarations because their upstream and credential unions require separate
ownership semantics. Cleanup policies use typed delete conditions, keep
conditions and most-recent retention. CMEK and format are immutable. Cleanup,
description, labels, scanning enablement and dry-run state update in place.

`ProjectSettings` manages reversible GCR redirection modes and partial pull
percentage. Finalized redirection is observed and protected but cannot be
requested by this ordinary resource; irreversible finalization needs a future
explicit action. `VpcscConfig` manages the regional allow/deny policy for
remote upstream access. Both are retained singleton settings.

## Lifecycle And Drift

Worker pools, v2 connections and v2 repositories use Google long-running
operations. Their operation handles are checkpointed and resumed through the
generic operation contract. Triggers and Artifact singleton settings are
synchronous. Artifact repository create and delete continue through the
Artifact Registry operation endpoint.

Canonical imports require full AIP resource names. Trigger imports accept the
server-generated trigger resource name while preserving the logical user name.
The provider strips output-only timestamps, UIDs, installation state, webhook
IDs, reconciliation state, registry size and scanning state before diffing.
Exact update masks are mandatory. Etag-bearing resources are read immediately
before update and delete, then mutated with the current etag.

Connection and repository credentials never enter desired state, observed
state, plans, receipts or canvas artifacts. Connection readiness requires a
complete installation state rather than object existence. Worker-pool readiness
requires `RUNNING`.

## Opinionated Component

`ZigBuildPipeline` composes:

- a Cloud Build v2 SCM connection and linked repository;
- an optional private worker pool;
- a regional repository trigger;
- a protected Artifact Registry repository with dry-run-first cleanup rules.

The component emits source-link, build-trigger, private-execution,
artifact-publish, retention-policy and CMEK relationships. It accepts explicit
service identities and secret references; it does not grant broad project
roles or create external SCM credentials.

## Product Integration

Permission synthesis emits exact trigger, worker-pool, connection, repository,
Artifact Registry repository, project-settings and VPCSC permissions. Cloud
Asset Inventory maps official BuildTrigger, WorkerPool, Connection, Repository
and Artifact Registry Repository identities. Singleton Artifact settings are
managed but not claimed as Cloud Asset resources.

Canvas metadata exposes source vendor, repository host, event filter, approval,
pool machine/network mode, artifact format, retention policy count, dry-run,
scanning and CMEK without rendering secret references. Cost modelling separates
default/private build minutes, private-pool SSD above the included amount,
artifact storage, transfer and vulnerability scans. Resource object counts do
not receive invented charges.

## Qualification

Deterministic tests prove validation, CRUD, exact masks, operation resume,
etag retries, import/no-op, immutable transitions, secret hygiene and component
topology. The authenticated runner requires a disposable project plus a
dedicated test SCM repository and Secret Manager credentials. It confirms an
installed connection, source linkage, trigger execution, private-pool use when
configured, digest publication, cleanup dry-run visibility, second-state
adoption and cleanup. Missing external SCM prerequisites produce a structured
skip, never a false pass.

Primary references:

- https://cloud.google.com/build/docs/api/reference/rest/v1/projects.locations.triggers
- https://cloud.google.com/build/docs/api/reference/rest/v1/projects.locations.workerPools
- https://cloud.google.com/build/docs/api/reference/rest/v2/projects.locations.connections
- https://cloud.google.com/build/docs/api/reference/rest/v2/projects.locations.connections.repositories
- https://cloud.google.com/artifact-registry/docs/reference/rest/v1/projects.locations.repositories
- https://cloud.google.com/artifact-registry/docs/reference/rest
- https://cloud.google.com/build/pricing
- https://cloud.google.com/artifact-registry/pricing
- https://cloud.google.com/asset-inventory/docs/asset-types
