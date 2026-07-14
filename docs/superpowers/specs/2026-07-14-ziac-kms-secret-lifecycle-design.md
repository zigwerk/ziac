# Ziac KMS and Secret Lifecycle Design

Date: 2026-07-14
Milestone: M77
Status: Accepted for implementation

## Objective

Make Cloud KMS and Secret Manager safe and useful for platform engineers. Ziac
must model key material, replication, rotation and scoped access without making
irreversible destruction an accidental consequence of deleting a graph node.

## Contract Sources

- Cloud KMS v1 Discovery revision `20260702`, SHA-256
  `d84c07e14c61f76c620f1910ab59a36421721596957c300870a2df003c848d9e`.
- Secret Manager v1 Discovery revision `20260705`, SHA-256
  `f04b20cabd72df1a41c311153a2d674fff9f7b6299d84c426da3a925c68c7131`.

The pinned contracts are the source of truth for methods, mutable fields,
resource identities and enums. Public declarations expose a conservative stable
subset rather than accepting arbitrary JSON.

## Resources

M77 hardens the existing `gcp.kms.KeyRing`, `gcp.kms.CryptoKey`,
`gcp.secret.Secret`, `gcp.secret.SecretVersion` and
`gcp.secret.SecretIamMember` resources and adds:

- `gcp.kms.CryptoKeyVersion`
- `gcp.kms.KeyRingIamMember`
- `gcp.kms.CryptoKeyIamMember`

The catalog increases from 178 to 181 managed types.

### Crypto keys

`CryptoKey` gains typed purpose, version template, labels, automatic rotation,
next rotation time, destroy-scheduled duration and import-only configuration.
Purpose, version-template algorithm/protection level, import-only and destruction
delay are immutable. Labels and valid symmetric-key rotation fields are mutable.
Key rings and keys remain retained because Google does not provide ordinary key
ring deletion and deleting declarations must not discard key material.

`CryptoKeyVersion` represents a Google-assigned numeric version beneath a key.
Its declarative state is limited to `enabled` and `disabled`. Creation records
the returned canonical name; import requires that canonical name. Removing the
node retains the version. A refresh that observes `DESTROY_SCHEDULED` or
`DESTROYED` never silently normalizes it into a healthy desired state.

### KMS IAM

Key-ring and key member resources use exact conditional binding identity,
policy version 3 when conditions exist, current etags, bounded conflict retry and
preservation of unrelated bindings. They share the general IAM ownership
validator and provider rather than maintaining a second policy mutator.

### Secrets

`Secret` gains a typed replication union:

- automatic replication with optional CMEK;
- user-managed replicas, each with a location and optional same-location CMEK.

Replication is immutable and therefore replacement-only. Labels, annotations,
version aliases, Pub/Sub topics and rotation settings are mutable with an exact
field mask and current etag. Rotation requires at least one topic, a next
rotation timestamp, a period of at least one hour and no more than ten topics.
Replica locations, aliases, annotations and topics are canonicalized and
validated for duplicates.

Secret IAM members gain the same typed conditional contract used by the general
IAM subsystem. Existing unconditional declarations remain source compatible.

`SecretVersion` gains a desired enabled/disabled state and explicit removal
policy. The default is `retain`; `disable` is the only declarative cleanup
mutation. Normal graph deletion never calls `:destroy`.

## Governed Irreversible Actions

KMS version destruction scheduling, KMS version restoration and Secret Manager
version destruction are procedural actions, not resource CRUD. Every action:

1. refreshes the target and validates its current state;
2. computes an operation digest from the exact canonical target and action;
3. requires a capability whose digest and operation match;
4. uses the current etag when the API exposes one;
5. emits a redacted receipt containing request identity and resulting state.

A generic delete authority, graph cleanup or caller-supplied free-form digest
cannot authorize these operations. Destroyed secret versions are irreversible;
scheduled KMS versions can be restored only before the Google destruction time.

## Drift And State

Provider reads normalize only fields Ziac owns. Output-only timestamps, primary
version and service metadata are emitted as outputs or inspector metadata and do
not cause drift. Output-backed CMEK references are preserved when their resolved
value equals the remote resource name.

CryptoKey replacement is required when immutable purpose, template, import-only
or destruction delay changes. Secret replacement is required when replication
changes. Version logical names do not pretend to be Google version numbers.

## Product Integration

M77 synchronizes:

- exact API and deployer/runtime permission synthesis;
- supported Cloud Asset identities and observed/managed reconciliation;
- canvas security grouping, encryption and access edges;
- configuration-based KMS and Secret Manager estimates with explicit units;
- installed docs, example and fail-closed disposable-project qualification.

Cost output remains a configuration estimate. It must not be described as
actual billed cost without Billing Export evidence.

## Qualification

The local receipt proves declaration, apply simulation, canonical import,
refresh/no-op and retention-aware cleanup. The authenticated script requires
ADC, an explicitly disposable project, fresh resource names and operator opt-in
before it creates key material or secrets. It must prove reversible state
transitions and IAM behavior. Irreversible destruction is excluded unless a
second explicit environment gate is supplied.

## Non-goals

- imported key material and ImportJob lifecycle;
- EKM and single-tenant HSM administration;
- secret expiration, because it is irreversible and Google recommends rotation
  for most workloads;
- cryptographic data-plane operations;
- authoritative whole-policy ownership for key rings, keys or secrets.
