# Ziac Provider Agent Development Kit Design

**Status:** Accepted for implementation
**Date:** 2026-07-15

## Objective

Ship a provider-development team with every Ziac installation. A newly
initialized standalone project or monorepo must give Codex, Claude Code and
Gemini the same bounded workflows for creating, maintaining and independently
qualifying first-party or third-party providers.

The kit must accelerate ecosystem work without collapsing Ziac's authority
boundaries. Provider packages are privileged RPC processes. Components remain
unprivileged graph compilers and templates remain editable source trees.

## Roles

### Provider Creator

The creator turns an upstream API contract into typed Ziac resources and a
`ziac.provider.rpc.v1` implementation. It chooses the package boundary,
resource identities, lifecycle model, imports, diagnostics and deterministic
tests. For GCP work it delegates current API, IAM, quota and availability facts
to the read-only GCP researcher before coding.

The creator may edit source and run local tests. It cannot apply infrastructure,
publish a package, award trust labels, weaken the installed-provider allowlist
or request plaintext credentials by default.

### Provider Maintainer

The maintainer owns contract evolution after initial release: upstream schema
diffs, compatibility ranges, state migrations, import stability, drift,
deprecations, retries, long-running operations and release evidence. It must
preserve resource identity and explain every breaking or replacement change.

The maintainer may edit source and run local tests. It cannot silently rewrite
state, widen permissions, publish, apply or self-qualify a release.

### Provider Qualifier

The qualifier independently checks an immutable package candidate. It verifies
manifest identity and digest, RPC handshake and fault behavior, deterministic
lifecycle fixtures, redaction, capability isolation, import/no-op behavior and
the declared compatibility matrix. Authenticated cloud qualification is a
separate explicit lane.

The qualifier may read source and execute declared tests. It must not repair the
candidate while qualifying it, access production credentials, mutate cloud
resources without an explicit qualification envelope or award a label when
evidence is incomplete.

## Skills

The roles consume three reusable skills:

1. `ziac-provider-development` defines first-party and third-party package
   selection, RPC implementation, resource lifecycle design and TDD.
2. `ziac-provider-maintenance` defines upstream contract monitoring, semantic
   upgrade review, state compatibility, deprecation and release discipline.
3. `ziac-provider-qualification` defines independent deterministic and
   authenticated evidence gates, trust labels and publication handoff.

Each skill is concise and points to the installed Ziac docs for the exact
protocol and package version. The package-owned copy is canonical. Workspace
copies for all three harnesses must be byte-identical.

## Distribution

Canonical kit files live under `packages/ziac/src/agent-kit/` and are installed in
`share/ziac/agent-kit/`. `scaffold.zig` embeds those files at compile time.

`ziac init` writes:

- each skill to `.agents/skills`, `.claude/skills` and `.gemini/skills`;
- one creator, maintainer and qualifier agent in each harness's native format;
- Codex registrations for all specialists; and
- a `GEMINI.md` routing note covering provider work.

When several Ziac projects share a Git root, `writeWorkspaceAgentFiles` writes
the same kit once at the root. It does not bind an agent to an arbitrary child
project or add provider execution authority.

## First-Party And Third-Party Providers

Both kinds implement `ziac.provider.rpc.v1` and use a strict provider package
manifest. First-party providers can be bundled sibling executables selected by
the installed CLI. Third-party providers can be authored and qualified against
the protocol now, but registry metadata is not execution authority. External
execution remains blocked until artifact signatures, digest locks, revocation
and sandbox policy ship.

This distinction must appear in every creator and maintainer workflow. Agents
must never bypass it by adding arbitrary executable paths, install hooks or
manifest commands.

## Acceptance Contract

- A rendered scaffold contains all three skills and all nine harness-specific
  agent definitions.
- Skill copies are byte-identical across Codex, Claude Code and Gemini.
- Creator and maintainer instructions forbid implicit apply, publishing,
  credential access and self-qualification.
- Qualifier instructions require independent immutable evidence and forbid
  source repair during a qualification run.
- The skills name the RPC protocol, package verification, deterministic tests,
  first/third-party distinction and GCP research delegation.
- Monorepo-root setup installs the complete kit without selecting a child
  `ziac.project.json`.
- The installed client distribution contains the canonical kit.
- Skill frontmatter and Codex UI metadata pass the skill-creator validator.
- Focused scaffold tests, external scaffold E2E and the full Ziac Testing v2
  gate pass with complete receipts.

## Non-Goals

- Opening external provider execution before signed artifacts and sandboxing.
- Building a hosted registry or publication service in this tranche.
- Granting authenticated cloud authority to generated agents.
- Treating components or templates as providers.
