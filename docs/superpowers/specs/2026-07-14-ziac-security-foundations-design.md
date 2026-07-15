# M80 Security Foundations Design

Date: 2026-07-14

## Objective

Make Ziac useful for security platform teams by managing Security Command Center
configuration, Binary Authorization trust policy and Certificate Authority
Service through typed resources. Security observations and execution history
remain observed data; irreversible revocation and CA teardown remain explicit,
target-bound actions.

## Google Contracts

- Security Command Center v2 Discovery revision `20260710`, SHA-256
  `91e993e41abb8bbd2ab9d9bfd767a546068f5f2db527f26dfcb94feae26c1e1a`.
- Binary Authorization v1 Discovery revision `20260703`, SHA-256
  `d1200ac1c6c0fa48969db1c2298c5f1806c6c08334bd16b4f496c4f2e0bc9cbb`.
- Certificate Authority Service v1 Discovery revision `20260629`, SHA-256
  `662081545e79d34242c1e373228225eebc2182378c39e45d752ab19b1e4b3050`.

## Public Resources

Security Command Center:

- `gcp.securitycenter.Source`
- `gcp.securitycenter.NotificationConfig`
- `gcp.securitycenter.MuteConfig`
- `gcp.securitycenter.BigQueryExport`
- `gcp.securitycenter.ResourceValueConfig`

Binary Authorization:

- `gcp.binaryauthorization.Policy`
- `gcp.binaryauthorization.Attestor`
- `gcp.binaryauthorization.AttestorIamMember`

Certificate Authority Service:

- `gcp.privateca.CaPool`
- `gcp.privateca.CertificateAuthority`
- `gcp.privateca.CertificateTemplate`
- `gcp.privateca.Certificate`
- `gcp.privateca.CaPoolIamMember`
- `gcp.privateca.CertificateTemplateIamMember`

The managed catalog increases from 196 to 210 resources.

## Typed Security Model

SCC configuration accepts project, folder or organization parents where v2
supports them. Notification filters and mute filters remain explicit expressions
with bounded validation. BigQuery exports reference a canonical dataset and
publish their generated principal as an output. Resource value configurations
use typed value, provider, resource type, labels and tag selectors.

Binary Authorization admission rules are a tagged evaluation mode with an
explicit enforcement mode. Attestor references are required only for
attestation rules. One project policy owns the complete policy document and
uses the current etag. Attestors use a canonical Container Analysis note and
typed PGP or PKIX public keys. Attestor IAM is additive and preserves unrelated
bindings.

CA pools type tier, issuance lifetime, publishing and KMS encryption. CAs type
root/subordinate identity, key algorithm, lifetime, X.509 subject and reusable
labels. Templates type maximum lifetime, CA/basic constraints, key usage and
identity passthrough. Certificates accept exactly one typed config or PEM CSR,
are retained, and never persist private key material. IAM is additive and
conditional-policy capable.

## Lifecycle Safety

SCC synchronous resources use canonical v2 names and exact update masks.
Resource value creation wraps one item in Google's batch-create request. Sources
have no delete endpoint and are permanently retained.

Binary Authorization policy is a project singleton and reconciles with etags.
Policy deletion means restoring an explicitly declared safe baseline, never an
HTTP delete. Attestor note identity is immutable; description and public keys
are etag-updated. IAM uses version 3 and bounded conflict retries.

Private CA resources checkpoint and resume long-running operations. Pool tier,
CA type/key/config and certificate identity are immutable replacement
boundaries. CAs and certificates retain by default. CA disable/enable, soft
delete/undelete, certificate revocation and issuance are represented by
governed actions with payload-bound capability digests; an ordinary plan cannot
perform them implicitly. Certificate resources can be imported and label-
updated but have no delete operation.

## Opinionated Components

- `SecurityFindingPipeline` routes selected SCC findings to Pub/Sub and BigQuery
  and optionally installs scoped mute and value rules.
- `TrustedArtifactPolicy` composes an attestor, verifier IAM and a project policy
  that requires its attestations while keeping dry-run enforcement explicit.
- `PrivateCertificateAuthority` composes a retained pool, root CA, template and
  least-privilege issuer/readers without issuing leaf certificates implicitly.

## Product Integration

Permission synthesis separates deployer permissions, runtime publisher and
certificate requester roles, and governed action authority. Cloud Asset
identity covers supported SCC, Binary Authorization and Private CA assets.
Canvas artifacts show finding routes, admission trust, pool/CA/template
membership, signer identity and enforced versus audit-only policy. Costs remain
configuration estimates: SCC service subscription is not inferred, Binary
Authorization management is zero direct charge, and Private CA tier/active-CA
plus certificate issuance assumptions are explicit.

The local qualification proves apply/import/no-op, retained resources, LRO
resume, etag drift, SCC routing, admission enforcement and private trust
topology. The authenticated runner requires ADC, a billing-enabled disposable
project, SCC activation, a Container Analysis note and exact security-action
confirmation. It never revokes a certificate or deletes a CA automatically.
