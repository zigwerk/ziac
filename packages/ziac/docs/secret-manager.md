# Ziac Secret Manager Contract

Ziac separates secret identity from secret payload. Resource graphs, plans,
state, outputs, diagnostics, and causal facts may retain a `SecretReference`;
they must never retain the referenced bytes.

## Resources

The first live provider exposes:

- `gcp.secret.Secret` with automatic replication and mutable labels;
- `gcp.secret.SecretVersion` with a logical name and opaque source reference;
- `gcp.secret.SecretIamMember` for unconditional resource-level IAM grants.

Secret versions are append-only. A changed version declaration replaces the
managed version, and deletion calls Secret Manager's destroy operation. The
state output is a secret-typed reference containing the Secret Manager resource
name and numeric version, never the payload.

## Payload Ownership

`ziac.secret.SecretSource` resolves an input `SecretReference` with the active
provider operation context only when a version create or access call executes.
It returns an owned `SecretPayload`. The GCP provider:

1. keeps the plaintext in that owned buffer;
2. base64-encodes it for the Google request;
3. sends `projects.secrets.addVersion`;
4. securely zeros the plaintext, encoded bytes, and serialized request body;
5. deinitializes the source payload on every success or error path.

A missing source fails before any Google mutation. Scripted tests prove payload
deinitialization and reject plaintext sentinel values in desired and observed
documents and captured request bodies.

`gcp.secret_access.SecretManagerSource` implements the inverse boundary for
consumers. It accepts only a typed `gcp-secret-manager` reference with a valid
resource path and numeric version, calls `versions:access`, and base64-decodes
the response directly into an owned zeroing payload. This is used by the
Cockroach SQL-user provider after the version is durably checkpointed.

## Refresh And IAM

Google assigns secret version numbers. Ziac therefore passes the physical ID
from tracked state into provider read contexts. A new version with no tracked
physical ID reads absent; a managed or imported version reads its exact metadata
path. Destroyed versions normalize to absent.

Secret IAM uses policy-version-3 reads and etag-preserving read-modify-write.
Only the requested unconditional role binding changes. Conditional bindings,
policy version, etag, and unknown fields are serialized back unchanged, with
bounded conflict refetches.
