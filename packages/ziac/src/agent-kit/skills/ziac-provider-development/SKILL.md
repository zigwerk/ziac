---
name: ziac-provider-development
description: Create or extend first-party and third-party Ziac infrastructure providers and low-level resources. Use for ziac.package.json provider manifests, ziac.provider.rpc.v1 processes, typed resource mappings, lifecycle adapters, imports, provider diagnostics, conformance tests, or new cloud and SaaS provider integrations.
---

# Ziac Provider Development

Build privileged provider behavior as a narrow process behind
`ziac.provider.rpc.v1`. Keep components as unprivileged graph compilers and
templates as user-owned source. Never put cloud CRUD in either layer.

## Proof-carrying provider loop

When a colocated `zigeffect.project.json` exists, start with `ziac_context` or
`zigeffect agent context --task <id> --budget 65536 --json`. Retain the source
revision, manifest digest, graph cursor, authority, and affected scenarios.
Respect supplied work-packet paths, dependencies, verification commands, lease,
and fencing token.

After the failing deterministic test and smallest implementation, require the
current stable process receipt and `.zigeffect/handoffs/tests/<scenario>.json`;
raw receipts and terminal output are diagnostic only. Compare the graph delta,
query exact graph paths, and re-query context. Mapped assertion IDs must resolve
through the project-mounted graph. The creator's proof-carrying
handoff includes source/manifest/candidate digests, changed paths, replay
commands, receipt/proof paths, causal IDs, limitations, and remaining authority.

## Choose The Boundary

- A **resource** is one typed mapping to an upstream API object.
- A **provider** reads, diffs, creates, updates, deletes and imports resources.
- A **component** combines declared resources without credentials or hidden state.
- A **template** scaffolds editable source without executing hooks.
- A **first-party** provider may ship as a sibling executable selected by Ziac.
- A **third-party** provider can implement and qualify the same RPC today, but
  registry metadata is not execution authority. Do not bypass the installed
  executable allowlist while signatures, digest locks and sandboxing are pending.

## Development Loop

1. Resolve the installed Ziac root from `build.zig.zon`. Read
   `docs/provider-rpc.md`, `docs/ecosystem.md`,
   `docs/provider-development-kit.md` and the relevant provider coverage doc.
2. For GCP, delegate current API fields, resource names, IAM, quotas, regions,
   lifecycle and release status to `gcp-developer-researcher`. Pin the official
   source contract used by the implementation.
3. Define package identity, provider ID, resource type prefixes, compatibility,
   executable identity and `ziac.provider.rpc.v1` capabilities in
   `ziac.package.json`. Manifests never contain commands, hooks, credentials or
   environment values.
4. Specify stable resource IDs, desired inputs, output secrecy, immutable and
   updateable fields, import syntax, delete semantics, eventual consistency,
   retry classes, deadlines, etags and long-running operation recovery.
5. Add failing deterministic tests for handshake identity, read/diff and every
   supported mutation. Include malformed frames, mismatched IDs, unauthorized
   types, process loss, redaction, import followed by no-op and interrupted
   operation resume where applicable.
6. Implement through public Ziac contracts. The engine retains graph order,
   plan integrity, approvals, state commits, leases and checkpoints. Provider
   stdout contains protocol frames only; bounded redacted diagnostics use the
   defined error channel.
7. Run `ziac package verify .`, `zig build provider-rpc-test` and
   `zig build test --summary failures` or the package's manifest-owned
   equivalents. Inspect the complete Testing v2 receipt.
8. Hand the immutable candidate digest to `ziac-provider-qualifier`. Creator
   evidence is useful, but it is not independent qualification.

## Safety Contract

Never request, log or serialize plaintext secrets. Preserve provider/resource/
version references. Do not run `ziac deploy`, mutate a cloud account, publish a
package, widen permissions, award a trust label or self-qualify without a
separate explicit authority envelope. Treat missing authenticated evidence as a
visible gate, not a reason to weaken tests.
