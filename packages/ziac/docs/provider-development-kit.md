# Ziac Provider Development Kit

Every Ziac installation includes a small specialist team for extending the
provider ecosystem. `ziac init` installs the same skills and role definitions
for Codex, Claude Code and Gemini at a standalone project or monorepo root.

## Team Model

| Role | Owns | Cannot do by default |
| --- | --- | --- |
| Provider creator | New provider packages, resource identities, lifecycle adapters, imports and conformance tests | Apply, publish, access plaintext credentials or self-qualify |
| Provider maintainer | Upstream contract changes, semantic upgrade reports, migrations, drift, deprecations and release handoff | Silently rewrite state, widen permissions, publish or self-qualify |
| Provider qualifier | Independent manifest, RPC, lifecycle, compatibility and disposable-cloud evidence | Repair candidate source, use production credentials or award trust labels |
| GCP researcher | Current official API, IAM, quota, region and lifecycle facts | Edit source or mutate infrastructure |

The corresponding skills are `ziac-provider-development`,
`ziac-provider-maintenance` and `ziac-provider-qualification`. The agent names
are `ziac-provider-creator`, `ziac-provider-maintainer` and
`ziac-provider-qualifier`.

## Provider Creation Flow

1. Decide whether the capability is a low-level resource/provider change, an
   unprivileged component or an editable template. Only provider code performs
   credentialed CRUD.
2. Research and pin the upstream contract. GCP implementations use the
   read-only Google Developer Knowledge specialist for current official facts.
3. Define a strict `ziac.package.v1` provider manifest and
   `ziac.provider.rpc.v1` handshake identity.
4. Design stable resource names, desired inputs, output secrecy, mutable and
   immutable fields, import, retries, deadlines and recovery.
5. Add deterministic failing tests before implementation.
6. Verify the package and RPC process, then hand one immutable candidate digest
   to the independent qualifier.

Provider implementations return typed lifecycle results and diagnostics; they
do not record causal facts themselves. Ziac's provider and executor adapters
automatically bracket every read/diff/create/update/delete/import call, accepted
retry, long-running-operation checkpoint and state commit. Tests may inject a
controlled runtime store to prove those facts and their parent path.
The complete cross-framework boundary is documented in
[`runtime-owned-causal-applications.md`](https://github.com/zigwerk/zigeffect/blob/v0.1.0/packages/zigeffect/docs/runtime-owned-causal-applications.md).

The creator and maintainer work in source. The qualifier works from a frozen
candidate and returns `pass`, `fail` or `incomplete`; it never fixes the
candidate during the same run.

## First-Party And Third-Party

First-party and third-party providers implement the same semantic RPC contract.
The difference is executable trust:

- first-party GCP and Cockroach providers ship as sibling executables selected
  by the installed CLI;
- third-party authors can build, test, package and qualify their process against
  the protocol now; and
- registry metadata cannot make an external binary executable.

Opening third-party execution requires signed artifact installation, digest
locks, maintainer identity, revocation and an OS sandbox. Agents must not work
around that gate with manifest commands, install hooks or arbitrary paths.

## Qualification Ladder

- `community`: bounded schema-valid package metadata.
- `verified`: deterministic package, RPC and lifecycle evidence for one digest.
- `official`: Ziac-owned maintenance and release governance.
- `cloud_qualified`: current authenticated evidence for a declared disposable
  environment and compatibility matrix.

Run the local foundation with:

```sh
ziac package verify .
zig build provider-rpc-test
zig build test --summary failures
```

Equivalent package-owned commands are acceptable when declared explicitly.
Every required Testing v2 receipt must have equal discovered and executed
counts, zero failures, zero pending tests, zero leaks and zero logged errors.

See [`provider-rpc.md`](provider-rpc.md), [`ecosystem.md`](ecosystem.md) and
[`package-authoring.md`](package-authoring.md).
