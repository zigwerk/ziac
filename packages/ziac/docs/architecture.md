# Ziac Architecture

Ziac is a separate package from zigeffect. zigeffect provides effects, layers,
structured concurrency, scopes, and causal traces. zigeffect-std provides the
application-facing standard library facade that Ziac imports as its substrate.

Ziac provides the IaC product layer: stacks, resources, outputs, providers,
state, plans, applies, and component libraries.

Initial source domains:

- `core.zig`: names, IDs, physical names, diagnostics.
- `output.zig`: lazy outputs and secret references.
- `resource.zig`: resource graph and dependency validation.
- `state.zig`: resource state records and in-memory store.
- `plan.zig`: deterministic plan operations.
- `plan_format.zig`: immutable saved-plan encoding, loading, and integrity.
- `provider.zig`: provider lifecycle vtable and fake provider.
- `apply.zig`: one-operation lifecycle and state transitions.
- `executor.zig`: stable dependency levels, bounded zigeffect execution, retry,
  deadlines, cancellation, and causal operation facts.
- `checkpoint.zig`: serialized state checkpoint interface and local-state
  adapter.
- `ci.zig`: repository-bound preview identity, provider name/domain scoping,
  and cleanup policy.
- `rollout.zig`: complete-graph Cloud Run rollback transformation and immutable
  image-history validation.
- `refresh.zig`: read-only provider refresh into observed state.
- `importer.zig`: validated adoption of existing provider resources.

Provider implementations must sit behind the provider lifecycle interface so the
engine can be tested without live cloud credentials. Every provider operation
receives an `OperationContext` containing its allocator, clock, absolute
deadline, cooperative cancellation handle, and read-only access to dependency
outputs in the current state snapshot. Providers must not retain the context or
borrowed output values after returning.

Operation contexts can also publish a bounded provider diagnostic to a shared,
thread-safe recorder. GCP maps redacted HTTP status, request ID, retry delay,
and quota identifiers into that generic shape before discarding the response.
Diagnostics remain process-local and are not part of state or plans.

Plans own sorted dependency IDs for every operation. Apply phases execute
dependencies before consumers; destroy phases reverse that relationship.
Independent operations in one topological level are split into deterministic
batches and handed to zigeffect's structured `forEachPar` primitive. State and
the fake remote provider protect concurrent mutations with zigeffect spinlocks.

Each completed provider mutation checkpoints a deep, serial-consistent state
snapshot. Local resources and outputs use temporary-file replacement so a failed
write cannot truncate the previous state. Pending provider results retain their
operation handles and transitional status. On the next run the executor reads
the remote before applying: matching remote objects are adopted, absent objects
with live handles remain pending, and absent operations without handles resume
from the recovery plan. A refreshed noop with no local record is also re-read and
adopted, covering remote success immediately before a local crash.

Local writers coordinate through an exclusive `lock.json` per stack and stage.
Lock metadata records lineage, owner, command, and acquisition time. Inspection
is side-effect free, ordinary release checks owner identity, and forced unlock
checks lineage unless an explicit override is supplied. The CLI exposes
`refresh`, `import`, and `unlock`, and all commands can emit a versioned
`ziac.command.v2` JSON receipt.

`state_backend.Store` generalizes that persistence contract without changing
the in-memory state or executor. The local adapter delegates to atomic files.
The remote adapter consumes an object store whose only writes require absence
or an exact observed generation. Its GCS implementation reads metadata then
downloads bytes pinned to that generation, and all upload/delete requests carry
`ifGenerationMatch`. A mismatch is a terminal state conflict, never an
unconditional retry. Remote lock format v2 adds owner expiry; stale takeover,
renewal, release, and forced unlock all compare the exact inspected generation.

Every plan captures the state lineage hash, state serial, canonical desired
graph digest, and an operation-integrity digest. The executor validates lineage,
serial, operation integrity, and destructive confirmation before refresh,
resume, or provider access. Resource and dependency insertion order do not
affect the desired graph digest, while any mutation of operation inputs or
metadata invalidates the operation digest.

Saved plan format v1 adds stack/stage identity, creation time, full canonical
operations, a derived destructive-approval flag, and a top-level content digest.
Files are created exclusively. `deploy --plan` compiles the current stack and
checks its desired graph digest but never invokes a planner; it executes the
loaded operation set after state and integrity checks. Delete and replacement
plans require the exact saved digest through `--approve`. Lifecycle `protect`
remains an absolute planning block, independent of confirmation or approval.

Preview stages use `pr-<change>-<repository-hash-8>`. State is already
stage-partitioned; `ci.scopedResourceNameAlloc` closes the provider identity
boundary by appending that exact stage under a caller-supplied GCP name limit.
Long bases retain a hash before the full stage suffix. Built-in preview stacks
scope Artifact Registry, Cloud Run, global load-balancer descendants, and DNS,
while persistent stages preserve existing names. `--preview-cleanup` validates
the exact grammar before stack or provider work and can never select production.

GitHub Actions WIF enters through the same native external-account ADC path as
other OIDC providers: URL subject token, STS exchange, optional service-account
impersonation, and token cache. Temporary `gha-creds-*.json` files are excluded
from both version control and deterministic Zig source archives.

Global Cloud Run rollout ordering is graph-native. Under
`canary_then_fleet`, every fleet service depends on one canary service, so its
Google operation and revision readiness complete before the fleet level runs.
Rollback clones the complete graph, rewrites only eligible service image inputs
to stored prior digests, and rejects any plan containing unrelated mutation or
destruction.

Provider output descriptors carry their field name, Zig value type, and secrecy
at comptime. Resource builders expose typed references instead of predicting
provider-assigned values. Typed references are also canonical input values, so
they survive hashing and structured serialization. Adding a consumer resource
recursively discovers those input references and derives one deduplicated graph
edge per producer. At provider execution, references resolve from typed outputs
in dependency state. A matching remote value normalizes back to the reference,
which keeps refresh and subsequent plans stable without replacing the desired
reference with a transient concrete value. Stack output files and CLI output
therefore use observed values rather than builder-side URL conventions.

High-level components transfer or transactionally append owned resource graphs.
Append clones nodes, rebinds edges to destination-owned IDs, validates cycles,
and rolls back every inserted node and edge on conflict. CockroachDB's
`ApplicationDatabase` uses this ownership model to order existing topology,
generated credentials, administrator bootstrap, grants, and migration outputs.

Application `Env` structs use `binding.Value(T)` and `binding.Secret(T)` field
descriptors. `validateBindings` reflects over the environment and supplied output
struct types to enforce required and optional names, value types, secrecy, and
regional scope. It returns the normalized binding struct type and emits stable
`ZIAC100` through `ZIAC104` diagnostics for static contract failures.

`stack.ProviderSet` canonicalizes a comptime provider tuple and rejects
duplicates. `stack.Context(Set)` exposes GCP, CockroachDB, and local namespaces
only when declared, with `ZIAC110` and `ZIAC111` diagnostics for missing cloud
providers. The runtime provider registry is derived by iterating that same static
set, so undeclared provider implementations cannot become available by accident.

`gcp.global.ZigService(App, Bindings, Providers)` closes the application and
infrastructure type boundary. Instantiating the component requires `App.Env`, a
declared GCP provider, and a binding struct accepted by `validateBindings`.
Public and secret bindings lower to typed Cloud Run output references, so the
resource graph derives producer edges before any provider runs. Secret values
must resolve through GCP Secret Manager; foreign-provider, cross-project, and
untyped inline secret values are rejected before cloud mutation.

The source pipeline is content addressed. A sorted, metadata-normalized gzip
archive excludes state, VCS, caches, environment files, keys, and secret
directories. Ziac injects a generated `Dockerfile.ziac`, hashes source plus the
recipe and pinned Cloud Build builder, uploads with generation-zero semantics,
and builds an immutable Artifact Registry digest. The build bucket, repository,
and enabled APIs are retained. Build and runtime service accounts are separate,
and regional Cloud Run services consume the image output rather than a
builder-predicted URL. Provider reads restore the original output references
when remote values match, keeping refresh and subsequent plans stable.

`zig build test` runs isolated compiler fixtures in addition to unit tests. Valid
binding/provider programs must compile. Invalid fixtures must both fail and emit
their exact contract code: `ZIAC100` through `ZIAC104`, `ZIAC110`, `ZIAC111`, or
`ZIAC120`. A syntax or import failure cannot satisfy the harness.

## Release Boundary

`zig build release-gate` composes the package's formatting, compile-time,
provider, executor, state, example, CLI, container, and secret checks. It is
deliberately credential-free. Authenticated acceptance is described by the
strictly parsed `release/live-tests.json` manifest so a local pass cannot be
mistaken for evidence that GCP routing or Cockroach Cloud was exercised. See
`release.md` for the clean-checkout and evidence contract.
