# Ziac Provider RPC

`ziac.provider.rpc.v1` is the process boundary between the Ziac engine and a
credentialed infrastructure provider. GCP and CockroachDB ship as provider
executables beside the `ziac` CLI:

- `ziac-provider-gcp`
- `ziac-provider-cockroach`

The engine starts the selected executable with stdin and stdout pipes and
performs an identity handshake before sending resource operations. The
provider returns its exact package name, package version, provider ID, resource
type prefixes, operation capabilities and concurrency limit. An identity or
protocol mismatch fails before a provider receives a resource node.

## V1 Contract

- Schema: `ziac.provider.rpc.v1`
- Transport: newline-delimited UTF-8 JSON over stdin/stdout
- Frame limit: 8 MiB per request or response
- Concurrency: one ordered in-flight request per process
- Methods: handshake, read, diff, create, update, delete and import
- Results: the existing Ziac read, diff and resource result contracts,
  including operation handles and incomplete long-running operations
- Errors: exact stable `ProviderError` names plus one bounded redacted
  diagnostic

Provider stdout is reserved for protocol frames. Diagnostic process output goes
to stderr.

## Authority Boundary

Registry discovery does not run provider code. A provider registry manifest
declares compatibility and an executable identity hint. The current bundled
runtime starts only sibling executables selected by the installed CLI, never a
path supplied by registry JSON. Future external provider installation must add
artifact digest and signature locks before that boundary is opened. Manifest
fields cannot contain install hooks, commands, scripts, credentials or
environment values.

The engine remains authoritative for graph validation, dependency order,
saved-plan identity, destructive confirmation, state commits, leases,
checkpoints and provider package identity.

The provider receives the resource node, absolute deadline, operation identity,
destructive confirmation and a deterministic state snapshot needed to resolve
output references. Secret values stay as provider/resource/version references;
plaintext secret material is not serialized into provider RPC frames.

## Failure Semantics

Malformed or oversized frames, mismatched response IDs, unsupported protocol
versions, unauthorized resource types and operations before handshake fail
closed. Provider errors preserve their typed category. Broken pipes and process
loss become transient provider failures; malformed success responses become
provider bugs. Failed calls cannot commit successful state.

## Current Limits

V1 intentionally serializes calls per provider process. Process pools,
mid-operation cancel frames, artifact installation and signatures, OS sandbox
profiles and a protobuf/gRPC transport are forward compatibility work. They do
not change the v1 semantic method contract.

The accepted design and implementation plan are recorded in:

- `docs/superpowers/specs/2026-07-15-ziac-provider-rpc-v1-design.md`
- `docs/superpowers/plans/2026-07-15-ziac-provider-rpc-v1.md`
