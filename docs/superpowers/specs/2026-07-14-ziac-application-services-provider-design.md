# Ziac Application Services Provider Design

Date: 2026-07-14
Milestone: M67
Status: Approved for implementation

## Objective

Complete the first application-services wave beyond Cloud Run with production
coverage for Workflows, API Gateway, Identity Platform and Parameter Manager.
Each service ships through Ziac's three provider layers:

1. typed low-level resources generated from pinned Google contracts;
2. hardened lifecycle adapters with import, drift and recovery semantics;
3. opinionated components with compile-time graph validation.

## Contract Provenance

The implementation pins these GA Discovery documents:

- `workflows:v1`, revision `20260701`, SHA-256
  `bb944a9423276c3366343834e2bc51a67d11f2ca972317ba2e784ac1a1289202`;
- `apigateway:v1`, revision `20260625`, SHA-256
  `c59cfb39aa30bd6a96ddd94db1194e7a5ace2a0bc2c423cb450d96762f565f6e`;
- `identitytoolkit:v2`, revision `20260703`, SHA-256
  `a845b96dfef3ecd5eae8022be598b8622a18e9e1be707b2c2bf7a938ef5a3713`;
- `parametermanager:v1`, revision `20260629`, SHA-256
  `670701cb42522540ae5af279318d8db584cbc442953d6873ebeed15b8fdd526b`.

## Managed Surface

### Workflows

- `gcp.workflows.Workflow`

The workflow owns source, service account, CMEK, call logging, execution history,
labels and bounded public environment variables. Source must pass the repository
secret scanner and is represented by content plus digest so deployment remains
deterministic. Service-account and KMS dependencies are typed graph edges.
Workflows IAM remains project-scoped and uses Ziac's existing general IAM
resources; the API does not expose resource IAM methods for workflows.

### API Gateway

- `gcp.apigateway.Api`
- `gcp.apigateway.ApiConfig`
- `gcp.apigateway.Gateway`
- `gcp.apigateway.ApiIamMember`
- `gcp.apigateway.ApiConfigIamMember`
- `gcp.apigateway.GatewayIamMember`

API Config owns one OpenAPI document or one or more gRPC service definitions.
Documents are supplied by secret-safe content references and resolved only at
the mutation boundary; state and canvas artifacts contain digests and source
identities, never source bytes. A Gateway has a typed dependency on an API
Config and exposes its default hostname.

IAM resources use additive etag-safe mutation and preserve unrelated bindings.
API Gateway authentication and authorization declared inside OpenAPI remain
application policy and are not inferred from management-plane IAM.

### Identity Platform

- `gcp.identity.ProjectConfig`
- `gcp.identity.Tenant`
- `gcp.identity.ProjectOAuthIdpConfig`
- `gcp.identity.ProjectInboundSamlConfig`
- `gcp.identity.TenantOAuthIdpConfig`
- `gcp.identity.TenantInboundSamlConfig`
- `gcp.identity.TenantIamMember`

ProjectConfig is a managed singleton: it imports and patches the existing
project config but is never deleted. It owns selected sign-in, authorized
domain, multi-tenant, MFA, password-policy, monitoring and email-privacy fields
without claiming Google output-only hash configuration.

OAuth client secrets, SAML private keys and test-phone codes are secret
references. They are resolved only inside mutation calls and preserved across
refresh because Google does not return write-only values. Tenant providers are
separate types so parent identity and replacement behavior remain unambiguous.
Tenant IAM uses additive etag-safe policy mutation.

### Parameter Manager

- `gcp.parametermanager.Parameter`
- `gcp.parametermanager.ParameterVersion`
- `gcp.parametermanager.Template`
- `gcp.parametermanager.TemplateVersion`

Parameters own format, CMEK, labels and optional Secret Manager policy-member
configuration. Templates own format and labels. Versions own disabled state and
payload by secret reference. The provider resolves payload bytes only during
create, zeros transient buffers and stores source digest/reference metadata,
never rendered payload. Render is an explicit read action, not part of refresh.

## Hardened Lifecycle

Workflows and API Gateway mutations resume Google long-running operations and
read the final resource after completion. API Gateway API Config source changes
replace the config; gateways can roll to a new typed config. Workflow source and
service-account updates create a Google revision but retain Ziac identity.

Identity Platform uses field masks and write-only-secret preservation. Project
config deletion is forbidden. Tenant and provider IDs, parent, issuer and SAML
entity IDs are replacement inputs; enabled state, display names and endpoint
metadata are mutable where the v2 API permits.

Parameter Manager uses etags where returned, treats parent/name/format/CMEK as
replacement boundaries and allows labels or disabled state to update. Versions
are protected and retained by default because payload history can be an
application dependency.

## High-Level Components

`WorkflowProgram` composes one workflow with explicit runtime identity and
returns canonical name, revision and state outputs.

`ManagedApiGateway` composes API, immutable versioned config, regional gateway
and optional additive management IAM. It returns the default hostname and keeps
document source wiring secret-safe.

`IdentityRealm` is a tagged project or tenant realm. It composes selected OIDC
and SAML providers, validates provider IDs and secret references, and rejects
cross-realm parent wiring.

`ParameterBundle` composes either a parameter or template with one or more
immutable payload versions and exposes typed version names without payload
material.

## Product Integration

The milestone synchronizes catalog and live dispatch, exact deployer/runtime
permissions, supported Cloud Asset identities, observed/managed reconciliation,
canvas workflow/API/identity/configuration semantics and explicit cost models.
Configuration estimates remain separate from billing-export actuals.

## Qualification

Local tests prove declarations, graph composition, CRUD, import, refresh/no-op,
secret preservation, LRO resume, protected cleanup and redacted receipts. A
remote disposable-project runner deploys a workflow, an API Gateway backed by a
probe endpoint, a tenant identity provider and parameter/template versions;
then it executes or reads each safe data path, imports into an empty state,
proves no-op and cleans up. Missing ADC, tools, a disposable project or explicit
secret fixtures returns a structured exit-77 skip.
