# Ziac Component And Template Ecosystem Design

**Date:** 2026-07-15

## Decision

Ziac will expose four deliberately different product surfaces:

1. **Resources** are close, typed mappings of cloud-authoritative GCP resources.
2. **Providers** are credentialed lifecycle adapters for those resources.
3. **Components** are pure graph compilers that expand a product-shaped input into
   resources and typed outputs.
4. **Templates** are source trees that scaffold complete, independently owned
   Ziac projects.

The word `provider` is reserved for code that reads or mutates a cloud API.
`gcpx` is the official opinionated component package. Templates are not
providers and cannot gain cloud credentials merely by being installed.

The first implementation lives in this monorepo so it can be qualified with
the CLI and installed distribution. Its package boundaries are intentionally
split-ready:

| Future repository | Monorepo package | Responsibility |
| --- | --- | --- |
| `ziac` | `packages/ziac` | engine, state, plans, CLI, contracts |
| `ziac-gcp` | initially `packages/ziac/src/gcp` | trusted resources and providers |
| `ziac-gcpx` | `packages/ziac-gcpx` | official high-level GCP components |
| `ziac-templates` | `packages/ziac-templates` | official deployable source templates |
| `ziac-registry` | initial index in `packages/ziac-templates` | metadata, digests and qualification |

Moving a package to its own repository must not change its public manifest,
provenance identity, graph output, import path semantics or qualification gate.

## Why This Boundary

One-to-one resources must remain predictable enough for platform engineers to
reason about lifecycle and state. High-level components should be able to move
faster, express stronger opinions and compose many resources without being
mistaken for new cloud primitives. Templates solve a different problem again:
they give a user editable source, application structure, CI and operational
defaults, and then leave that source under the user's ownership.

This follows the useful part of the Railway template model: a template packages
a configured project and can retain an upstream relationship, while the user
can deliberately take independent ownership. Ziac adds deterministic graph
expansion, typed resource provenance, comptime application boundaries and
qualification evidence.

## Trust Model

### Trusted provider plane

Provider code is distributed with Ziac, reviewed as privileged code and mapped
to a declared catalog capability. Community additions to the GCP provider are
accepted only through reviewed changes to the trusted provider package. Ziac
does not load arbitrary provider binaries or lifecycle handlers from a registry.

### Unprivileged component plane

A component imports public Ziac resource APIs and returns a resource graph. Its
expansion is deterministic and does not receive a provider client, token source,
state backend or secret material. Planning and applying the resulting resources
still goes through Ziac's trusted provider registry and normal authority checks.

### Source template plane

A template is a bounded file tree plus a manifest. It may contain source,
project contracts, documentation and CI configuration. It may not declare
post-install hooks, shell commands, embedded credentials, absolute output paths,
parent traversal or symlinks. Initialization renders a small allowlist of text
tokens and never executes template code.

### Registry plane

The registry is data, not code. Every record names a package manifest digest,
source location, kind, maturity and qualification tier. The initial registry is
shipped read-only with the CLI. A hosted index can arrive later without changing
the local schema or verification algorithm.

## Package Contract

Every reusable component or template has `ziac.package.json`:

```json
{
  "schema": "ziac.package.v1",
  "name": "ziac/hermes-desktop",
  "version": "0.1.0",
  "kind": "template",
  "summary": "A low-cost Hermes Desktop backend on Compute Engine",
  "license": "Apache-2.0",
  "source": "https://github.com/ziac-run/ziac-templates",
  "entry": "files",
  "compatibility": { "ziac": ">=0.1.0 <0.2.0", "zig": ">=0.16.0 <0.17.0" },
  "providers": ["gcp"],
  "resource_types": ["gcp.compute.Instance", "gcp.dns.RecordSet"],
  "maturity": "preview"
}
```

Validation is bounded and fail-closed:

- names, versions, kinds, paths and compatibility strings use restricted ASCII;
- arrays are bounded, duplicate-free and deterministically ordered;
- provider names and resource type names are explicit;
- an entry is relative and cannot escape its package;
- manifests contain no executable hooks or secret-shaped fields; and
- canonical serialization produces the digest used by the registry.

Kinds are initially `component` and `template`. Provider plugins are not a
registry package kind.

## Component Contract

`ziac.component` exposes:

- `Descriptor`, the compile-time identity and compatibility contract;
- `Origin`, the package, component, version, instance and source digest attached
  to generated resources;
- `stampGraph` and `stampRange`, which annotate component expansion without
  changing provider inputs or their desired hashes; and
- validation that prevents one component instance from silently claiming a
  resource already attributed to another component.

Component provenance is copied with a resource node and survives the external
program artifact. It appears in the visual artifact so the local canvas can
group or filter the concrete resources beneath a component. It does not enter
provider diffing, remote state identity or the cloud request body.

The first `ziac-gcpx` pilots are:

- `AssetBucket`, a governed versioned bucket and IAM graph;
- `HermesDesktop`, the low-cost Compute Engine compatibility product; and
- descriptors for the existing global Zig service family, followed by a full
  wrapper once source ownership moves cleanly out of the core package.

Existing core component imports remain compatibility shims until a declared
major-version migration.

## Template Contract

Official templates live under `packages/ziac-templates/templates/<id>` with:

- `ziac.package.json`;
- `files/`, the bounded source tree;
- optional human-readable `README.md`; and
- registry metadata in the package-level `index.json`.

Supported text tokens are deliberately small:

- `{{project_name}}`
- `{{zig_package_name}}`
- `{{package_fingerprint}}`
- `{{ziac_path}}`
- `{{ziac_gcpx_path}}`

Unknown tokens are errors. Binary files are copied unchanged only after the
template format gains an explicit binary declaration; the first tranche is
text-only. Rendering is deterministic for the same template, project name and
installed package roots.

The first templates are:

- `global-zig-api`, the production-oriented global Cloud Run starting point;
- `hermes-desktop`, a desktop-connectable Hermes backend on one economical VM;
  and
- `event-driven-zig`, a Cloud Run worker with Storage and Pub/Sub wiring.

## CLI Experience

The installed CLI gains:

```text
ziac registry list --json
ziac registry search hermes --kind template --json
ziac package verify packages/ziac-templates/templates/hermes-desktop --json
ziac init my-agent --template hermes-desktop
```

`ziac init` continues to scaffold the default global Zig project when no
template is supplied. Template selection is non-interactive under `--yes` and
can be added to the existing prompt later. Registry and verification commands
are read-only and do not require GCP credentials.

The CLI never performs a package post-install step. A future `component add`
will update Zig dependencies through a structured ZON writer and lock exact
package provenance; it will not download or execute provider plugins.

## Canvas And Evidence

Each visual resource may contain an optional `component` object:

```json
{
  "package": "ziac-gcpx",
  "name": "HermesDesktop",
  "version": "0.1.0",
  "instance": "team-agent",
  "source_digest": "..."
}
```

The canvas may render a component boundary and collapse it while retaining all
real resources and edges. Plans and cost remain resource-level. Template origin
is recorded in the generated project metadata and registry receipt, not stamped
onto every resource unless the template invokes a component.

Qualification evidence includes manifest digest, registry digest, component
expansion digest, concrete resource types, test receipt and, where available,
the authenticated cloud receipt. Labels are:

- `community`: schema-valid, no Ziac qualification claim;
- `verified`: deterministic package and expansion gates pass;
- `official`: maintained and released by Ziac;
- `cloud-qualified`: official or reviewed package with a current authenticated
  receipt for its declared environment.

The registry must never translate `community` into a provider support claim.

## Contribution Model

Community authors can:

- publish components that use public resource APIs;
- publish editable templates;
- submit registry records with immutable source and manifest digests; and
- submit new one-to-one resources or lifecycle behavior to the trusted GCP
  provider through normal code review and conformance tests.

Acceptance requires license metadata, ownership, compatibility ranges, bounded
inputs, deterministic tests, no secret literals, resource-type declarations,
documentation and a security review appropriate to the tier requested.

## Roadmap

### M86A: Ecosystem contracts and provenance

- package schema, parser, canonical digest and qualification tiers;
- component descriptors and resource provenance;
- program and visual artifact round-trip;
- threat model and contribution policy.

**Exit:** a component expansion is visibly and deterministically attributable
without changing provider inputs or hashes.

### M86B: Official component package

- independent `ziac-gcpx` build and Testing v2 receipt;
- Asset Bucket and Hermes Desktop wrappers;
- compatibility shims and migration notes;
- split-repository release contract.

**Exit:** a clean package consumer compiles a `ziac-gcpx` component into only
cataloged GCP resources with complete provenance.

### M86C: Templates and local registry

- three external source templates;
- registry index and digest verification;
- search, list, package verify and template-aware init;
- installed-prefix test proving no source-checkout dependency.

**Exit:** an installed CLI initializes and validates each official template in
a fresh Git directory.

### M86D: Hosted community registry

- immutable object storage and signed index publication;
- maintainer identities, moderation and revocation;
- source attestations, SBOMs and vulnerability reporting;
- structured ZON dependency updates and exact lock records;
- upstream update detection, review branches and deliberate ejection.

**Exit:** a community package can be discovered, verified, installed, updated
and revoked without executing registry-controlled provider code.

### M86E: Product marketplace

- dashboard browse and preview;
- component-collapsed and expanded canvas modes;
- before-and-after plan, cost and permission summaries;
- cloud qualification badges tied to current evidence;
- template ownership, update and ejection UX.

**Exit:** a developer can evaluate a template or component from intent through
concrete graph, cost, permissions and evidence before changing source or cloud.

## Non-Goals For The Foundation

- arbitrary binary provider plugins;
- remote code execution during installation;
- pretending components are new GCP resource types;
- hiding concrete resources or state behind a component;
- automatic adoption of existing resources;
- mutable registry tags without immutable digests; and
- a browser-only marketplace that bypasses the local project and dashboard.
