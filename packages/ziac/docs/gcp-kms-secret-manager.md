# Cloud KMS and Secret Manager

M77 completes Ziac's first security-key lifecycle slice with typed Cloud KMS
keys and versions, replicated Secret Manager secrets, conditional resource IAM,
safe retention defaults and separately authorized irreversible actions.

## Managed resources

- `gcp.kms.KeyRing`
- `gcp.kms.KeyRingIamMember`
- `gcp.kms.CryptoKey`
- `gcp.kms.CryptoKeyIamMember`
- `gcp.kms.CryptoKeyVersion`
- `gcp.secret.Secret`
- `gcp.secret.SecretIamMember`
- `gcp.secret.SecretVersion`

Key rings, cryptographic keys, cryptographic key versions and secrets are
retained by default. Secret versions default to retention and can instead use
the reversible `disable` removal policy. A normal plan or destroy never
schedules KMS key destruction or destroys secret payloads.

## Typed security topology

`CryptoKey` validates purpose, algorithm, protection level, rotation and
scheduled-destruction compatibility at graph construction. Mutable labels and
rotation fields use exact update masks; immutable purpose, template and import
properties replace. Google assigns numeric `CryptoKeyVersion` identities, and
Ziac reconciles only the reversible enabled/disabled states during ordinary
deployment.

`Secret` supports automatic replication with a global CMEK, or user-managed
regional replicas with location-matched keys. Topics, rotation, aliases,
annotations and labels are normalized before drift comparison. Replication is
immutable. Secret metadata updates carry the latest etag and a semantic field
mask.

The canvas exposes key containment, key-version, CMEK, secret-version and IAM
relationships. User-managed secret replicas contribute their actual regions to
the topology rather than relying on Cloud Asset Inventory's generic `location`
field.

## Irreversible actions

Three actions live outside normal resource reconciliation:

- `schedule_kms_destroy`
- `restore_kms_version`
- `destroy_secret_version`

Each action requires a capability bound to its action, target, stage and
project by SHA-256. The handler refreshes current state, rejects invalid
transitions and emits a receipt with previous and resulting state. Secret
destruction sends the current version etag. The local qualification receipt
does not exercise these operations and records that exclusion explicitly.

## IAM ownership

KMS key-ring, KMS key and Secret Manager IAM members use additive
read-modify-write policy updates. Conditions request policy version 3, current
etags protect concurrent changes and unrelated bindings remain untouched.
Permission synthesis derives deployer operations and runtime decrypt, encrypt
or secret-access authority independently.

## Cost and discovery

Cloud Asset Inventory mapping follows Google's supported KeyRing, CryptoKey,
CryptoKeyVersion, Secret and SecretVersion types. Configuration estimates keep
software, HSM, external key-version months, active secret replica-version
months and secret access operations as explicit assumptions. They are never
presented as actual billed cost.

The contract lock pins Cloud KMS v1 Discovery revision `20260702` and Secret
Manager v1 revision `20260705`, including their document digests. See Google's
[Cloud KMS REST reference](https://cloud.google.com/kms/docs/reference/rest),
[Secret resource contract](https://cloud.google.com/secret-manager/docs/reference/rest/v1/projects.secrets),
[SecretVersion contract](https://cloud.google.com/secret-manager/docs/reference/rest/v1/projects.secrets.versions),
and [Cloud Asset supported types](https://cloud.google.com/asset-inventory/docs/asset-types).

## Qualification

Build the installed example with `zig build examples`. The authenticated runner
is `scripts/qualify-kms-secret.sh`. It fails closed unless ADC, all resource
identities and a project ending in `-ziac-disposable` are supplied. It proves
resource reachability, reversible KMS and Secret Manager transitions, import
and refreshed no-op. Irreversible actions stay excluded; final cleanup is
deletion of the disposable project because Google does not permit key-ring or
key deletion.
