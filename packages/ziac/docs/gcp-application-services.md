# GCP Application Services

This package provides a focused application-services layer for orchestration,
API ingress, customer identity, and versioned runtime configuration. It follows
the same three-layer model as the rest of the provider: typed primitives,
hardened lifecycle adapters and opinionated components.

## Managed Resources

Workflows manages `Workflow`. API Gateway manages `Api`, immutable `ApiConfig`,
`Gateway`, and additive IAM members at all three scopes. Identity Platform
manages the protected project singleton, tenants, project and tenant OIDC/SAML
providers, and additive tenant IAM. Parameter Manager manages parameters,
immutable versions, templates and immutable template versions.

Every secret-bearing field is a typed reference. API documents, OIDC client
secrets, SAML private keys and parameter payloads are resolved only inside the
mutation scope, zeroed after use and never persisted. Declared SHA-256 values
must match resolved API documents and parameter payloads before a request is
sent.

## Components

- `WorkflowProgram` compiles a workflow with service identity, CMEK, logging,
  execution history, labels and environment.
- `ManagedApiGateway` compiles API, immutable config, regional gateway and
  optional additive management access.
- `IdentityRealm` selects project or tenant scope and composes OIDC/SAML
  providers without mixing identities.
- `ParameterBundle` selects parameter or template scope and composes one or
  more immutable secret-backed versions.

The installed `examples/application_services.zig` demonstrates all four in one
acyclic graph. Any component can also be used independently or appended to an
existing graph.

## Agent And Product Intelligence

Graph synthesis derives the four service APIs and exact deployer permissions
from the methods each resource uses. Runtime roles such as
`roles/workflows.invoker` and `roles/parametermanager.parameterAccessor` become
separate runtime permissions, keeping deployer and application authority
distinct.

The visual artifact emits workflow, gateway, identity and parameter metadata,
including content digests but never resolved bytes. Cloud Asset adoption maps
only resource kinds currently documented by Google. Parameter Manager template
assets remain generic observed resources until Google lists them as supported
Cloud Asset types.

Cost estimates use explicit Google Cloud Catalog SKUs and operator-provided
usage for Workflows internal/external steps, API Gateway calls and Identity
Platform tier-one/tier-two MAUs. They are labelled configuration estimates, not
billed or live costs.

## Qualification

The deterministic product test applies the complete graph with the fake
provider, imports it into empty state, refreshes to no-op, performs
retention-aware cleanup and emits
`ziac.gcp.application-services-qualification.v1` evidence.

`scripts/qualify-application-services.sh` is the separate authenticated gate.
It requires ADC, a project ending in `-ziac-disposable`, an end-client workspace
and explicit probe resource names. Missing credentials or configuration emit a
structured exit-77 skip. A passing remote receipt requires active Workflow and
Gateway reads, Identity tenant access, rendered Parameter Manager data, a
second-state no-op import and cleanup.

## Google Contracts

- [Workflows v1 REST](https://cloud.google.com/workflows/docs/reference/rest/v1/projects.locations.workflows)
- [API Gateway v1 REST](https://cloud.google.com/api-gateway/docs/reference/rest)
- [Identity Platform v2 REST](https://cloud.google.com/identity-platform/docs/reference/rest/v2)
- [Parameter Manager v1 REST](https://cloud.google.com/secret-manager/parameter-manager/docs/reference/rest)
- [Cloud Asset supported types](https://cloud.google.com/asset-inventory/docs/asset-types)
- [Workflows pricing](https://cloud.google.com/workflows/pricing)
- [API Gateway pricing](https://cloud.google.com/api-gateway/pricing)
- [Identity Platform pricing](https://cloud.google.com/identity-platform/pricing)
