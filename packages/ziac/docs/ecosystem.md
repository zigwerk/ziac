# Ziac Resources, Components And Templates

Ziac has three public infrastructure authoring layers and one privileged
execution layer. Their names describe different contracts and must not be used
interchangeably.

| Layer | Purpose | Cloud authority | Ownership |
| --- | --- | --- | --- |
| Resource | One typed mapping to a GCP resource | None | Trusted `ziac-gcp` declaration |
| Provider | Read, create, update and delete that resource | Credentialed | Installed RPC process |
| Component | Compile a product-shaped input into resources | None | Official or community package |
| Template | Scaffold an editable project source tree | None | User after initialization |

The practical rule is simple: provider code talks to Google; component code
builds a graph; template code becomes the user's code.

## Choosing A Layer

Use a raw resource when a platform engineer needs exact control of one Google
API object, an uncommon topology or a lifecycle option that an opinionated
component does not expose.

Use a component when several resources form one repeatable product boundary.
Examples include a governed asset bucket, a desktop-connectable Hermes backend
and a globally routed Zig service. Components retain every concrete resource in
the plan and state. They do not hide a nested state engine.

Use a template when the useful unit includes application source, project
contracts, CI, environment conventions or multiple components. Initialization
copies and renders source without executing hooks. The generated project is
then ordinary user-owned Zig source.

## Installed Discovery

The CLI ships an immutable local registry so discovery works without a hosted
service or Google credentials:

```sh
ziac registry list --json
ziac registry search gcp --kind provider --json
ziac registry search hermes --kind template --json
ziac package verify path/to/package
ziac init team-agent --template hermes-desktop
```

Every registry record pins the canonical SHA-256 digest of its
`ziac.package.json`. Search verifies every bundled manifest before returning
results. Package verification validates bounded fields, package identity,
compatibility metadata, declared providers and resource types. Provider
packages additionally declare a strict `ziac.provider.rpc.v1` identity, but
that executable hint is not execution authority.

## Provenance

Every resource emitted by a component carries non-provider provenance:

```json
{
  "package": "ziac-gcpx",
  "name": "HermesDesktop",
  "version": "0.1.0",
  "instance": "hermes",
  "source_digest": "..."
}
```

`source_digest` is the component package's canonical manifest digest, so the
origin resolves directly to an immutable registry record. Provenance survives
`ziac.program.v1` and `ziac.visual.v1`. It allows plans,
agents and the local canvas to explain which component expanded a concrete
resource. It does not alter resource IDs, desired input hashes, provider request
bodies or state identity.

A component descriptor must declare every provider and resource type it can
emit. Expansion fails if it produces an undeclared type or attempts to claim a
resource already owned by another component instance.

## Trust And Security

The registry does not load provider plugins. GCP and CockroachDB are currently
bundled sibling executables selected by the installed CLI; execution requires a
successful version, package, provider and capability handshake. A future
external-provider installer must resolve and pin the executable artifact outside
the manifest before independently released providers can use the same process
contract.

Community components are unprivileged graph compilers. They receive no provider
client, token source, state backend or secret values. Planning and apply still
pass through the installed provider, capability envelope, saved-plan integrity
and approval checks.

Templates are bounded text trees. The foundation rejects:

- absolute or parent-traversing entries;
- symlinks and unsupported file kinds;
- unknown render tokens;
- executable install hooks and script fields;
- secret, token, password or credential-shaped manifest fields;
- oversized manifests, registries, trees and files; and
- duplicate or mutable package identities.

## Official Packages

The first monorepo implementation is already split at package boundaries:

| Package | Future repository | Contract |
| --- | --- | --- |
| `packages/ziac` | `ziac` | Engine, CLI, state and public contracts |
| `packages/ziac/src/gcp` | `ziac-gcp` | Trusted resources and providers |
| `packages/ziac-gcpx` | `ziac-gcpx` | Official opinionated components |
| `packages/ziac-templates` | `ziac-templates` | Official source templates |
| static package index | `ziac-registry` | Digests, qualification and discovery |

Moving these packages into repositories must preserve manifest identity,
component provenance, graph output, compatibility ranges and qualification
evidence.

The initial official templates are:

- `global-zig-api`, a source-built Zig API on globally routed Cloud Run;
- `hermes-desktop`, an OAuth-gated Hermes backend on an economical Compute VM;
  and
- `event-driven-zig`, a Zig worker with a governed bucket and Pub/Sub.

## Qualification Labels

- `community` means schema-valid metadata with no Ziac support claim.
- `verified` means deterministic package and expansion gates passed.
- `official` means maintained and released by Ziac.
- `cloud_qualified` means current authenticated evidence exists for the
  declared environment.

Qualification belongs to an immutable package digest. A community template
cannot become a supported provider resource through registry metadata.

See [`provider-rpc.md`](provider-rpc.md) for the process contract and authority
model.

## Hosted Continuation

The local registry foundation does not imply a hosted marketplace. M86D adds
signed index publication, maintainer identity, revocation, attestations,
structured dependency updates and upstream review. M86E adds dashboard browse,
component collapse, cost and permission previews, and qualification evidence.

Railway's template model is useful precedent for editable project deployment
and upstream relationships. Ziac's distinct contribution is typed graph
expansion, concrete resource visibility, comptime application wiring and causal
qualification evidence.

See [package-authoring.md](package-authoring.md),
[template-authoring.md](template-authoring.md) and [roadmap.md](roadmap.md).
