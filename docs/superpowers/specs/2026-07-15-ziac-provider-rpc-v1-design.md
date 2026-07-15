# Ziac Provider RPC v1 Design

## Status

Accepted for implementation on 2026-07-15.

## Objective

Move non-core infrastructure providers behind a versioned, bounded process
boundary without changing Ziac's executor contract. A provider package may be
listed in the Ziac registry, but listing it must never install, trust, or run
code automatically.

The first implementation proves the boundary with a real subprocess and keeps
the existing `Provider` vtable as the engine-facing abstraction. Built-in and
RPC-backed providers can therefore coexist in one plan.

## Product Model

Ziac has three package kinds:

1. `provider`: a low-level resource implementation that speaks the Ziac
   Provider RPC.
2. `component`: a typed, synthetic resource that composes providers.
3. `template`: a project or product scaffold that composes providers and
   components.

The registry is a signed catalogue of package identity, compatibility,
qualification, and digests. It is not an executable plugin loader. Provider
execution requires an explicit installation record, an exact package digest,
an executable path selected outside the manifest, and a successful protocol
handshake.

## Protocol Identity

- Protocol name: `ziac.provider.rpc`
- Major version: `1`
- JSON schema identifier: `ziac.provider.rpc.v1`
- Transport in v1: newline-delimited UTF-8 JSON over stdin/stdout
- Maximum request or response frame: 8 MiB
- Maximum in-flight requests per v1 process: `1`
- Request IDs: positive unsigned 64-bit integers, matched exactly

JSON Lines is the initial transport, not the semantic contract. Future framed
or gRPC transports may carry the same typed messages after negotiation.

## Lifecycle

1. The engine starts a provider executable with stdin and stdout pipes.
2. The engine sends `handshake` before any resource method.
3. The provider returns its package identity, provider ID, protocol version,
   resource type prefixes, operation capabilities, and concurrency limit.
4. The engine rejects protocol, identity, provider, or capability mismatches.
5. Calls are serialized in request-ID order.
6. The engine closes stdin and waits for the process during normal shutdown.
   Broken pipes, malformed responses, oversized frames, or unexpected exit map
   to `ProviderUnavailable` or `ProviderBug`; they never become a successful
   operation.

## Methods

The v1 method set mirrors the existing provider contract:

- `handshake`
- `read`
- `diff`
- `create`
- `update`
- `delete`
- `import`

Every resource call carries the resource node, operation context, and, where
required, the observed result or target physical ID. Results preserve the
existing `ReadResult`, `DiffResult`, and `ResourceResult` semantics, including
asynchronous operation handles and `completed` state.

## Context Transfer

The engine transfers only the provider-relevant operation context:

- absolute deadline in milliseconds;
- physical ID;
- operation handle;
- destructive confirmation;
- a deterministic snapshot of state records required to resolve output
  references.

Function pointers, clocks, cancellation callbacks, filesystem handles, and
engine internals never cross the process boundary. The client checks
cancellation and deadlines before a call. The provider host reconstructs an
in-memory state store and applies the absolute deadline. Process interruption
and cooperative mid-call cancellation remain a later protocol extension.

State values use Ziac's canonical `Value` representation. Secret references
remain references; secret plaintext is not serialized into the RPC frame.

## Error And Diagnostic Semantics

All existing `ProviderError` tags have stable wire names. A provider failure
response contains one error tag and at most one bounded diagnostic. The client
maps the tag back to the exact Zig error and records the diagnostic in the
caller's recorder. Unknown tags, malformed payloads, missing required fields,
duplicate response IDs, and success payloads for the wrong method are provider
bugs.

## Registry Metadata

Provider manifests add a required `provider_rpc` object:

```json
{
  "protocol": "ziac.provider.rpc.v1",
  "provider": "cockroach",
  "executable": "ziac-provider-cockroach",
  "max_inflight": 1
}
```

The executable field is an identity hint used for packaging and display. It is
not executed directly from registry JSON. Installation resolves and verifies
the artifact, records the exact digest, and supplies the executable path to the
runtime.

Components and templates must not contain `provider_rpc`. Provider manifests
must contain it. GCP is published as an `official` provider record even while
it remains bundled with Ziac. CockroachDB is published as a `verified`
third-party provider record.

## Security Invariants

- Registry search and verification are data-only operations.
- Manifests cannot declare install hooks, shell commands, credentials, tokens,
  passwords, or environment values.
- Provider stdout is protocol-only; logs go to stderr.
- Every frame and collection is bounded before allocation or iteration.
- The handshake must complete before resource calls.
- A provider may only receive nodes for its negotiated provider ID and declared
  resource type prefixes.
- The engine remains authoritative for plans, state commits, ownership,
  destructive confirmation, and dependency ordering.

## Qualification

The implementation is shipped when:

1. Contract tests round-trip every method, value kind, lifecycle field, state
   output, result kind, error tag, and diagnostic.
2. Malformed, oversized, mismatched-ID, unhandshaken, unsupported-version, and
   wrong-provider messages fail closed.
3. A real subprocess serves a `FakeProvider`; the existing provider vtable can
   create, read, diff, update, import, and delete through it.
4. Registry tests distinguish providers from components and templates and
   validate provider RPC metadata.
5. The package Testing v2 suite completes with no failures, pending tests,
   leaks, or logged errors, apart from documented credential-gated skips.

## Deferred Extensions

- Process pools and negotiated concurrency above one.
- Mid-call cancel frames and hard termination policy.
- Artifact download, signature verification, install locks, and upgrades.
- OS sandbox profiles and per-provider network/credential authority.
- Out-of-process migration and schema services.
- A protobuf/gRPC transport carrying the same semantic contract.
