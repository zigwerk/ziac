# Ziac Provider Agent Development Kit Implementation Plan

**Design:** `docs/superpowers/specs/2026-07-15-ziac-provider-agent-development-kit-design.md`

## 1. Lock The Scaffold Contract With Tests

- Extend `packages/ziac/test/scaffold_test.zig` with expected skill and agent
  paths, byte-equality checks and role-boundary assertions.
- Extend `packages/ziac/test/scaffold_e2e.sh` to prove a clean initialized
  project and a monorepo root receive the complete kit.
- Add an installed-prefix assertion for `share/ziac/agent-kit`.
- Run the focused unit suite and retain the expected red result before
  implementation.

## 2. Create Canonical Skills

- Initialize `ziac-provider-development`, `ziac-provider-maintenance` and
  `ziac-provider-qualification` with the skill-creator tooling.
- Replace generated placeholders with concise Ziac-specific workflows.
- Generate Codex `agents/openai.yaml` metadata deterministically.
- Validate all three canonical skills with `quick_validate.py`.

## 3. Create Specialist Agents

- Add creator, maintainer and qualifier definitions for Codex, Claude Code and
  Gemini under `packages/ziac/src/agent-kit/agents`.
- Give creator and maintainer workspace editing authority but no implicit cloud
  or publication authority.
- Keep qualification independent: test execution is allowed, candidate repair
  is not.
- Mirror the shipped definitions into this repository's root agent surfaces so
  Ziac can use its own development kit.

## 4. Wire Initialization And Installation

- Embed canonical kit files from `packages/ziac/src/scaffold.zig`.
- Include the new paths in ordinary project rendering and root monorepo setup.
- Register all Codex specialists in generated config and route Gemini provider
  work through the generated context file.
- Install `packages/ziac/agent-kit` under `share/ziac`.

## 5. Document The Operating Model

- Add `packages/ziac/docs/provider-development-kit.md` with role, trust,
  first-party, third-party and contribution guidance.
- Update the agent development kit, ecosystem guide and consolidated roadmap.
- Keep external provider execution and hosted publication accurately marked as
  future gated work.

## 6. Verify End To End

- Run skill validation for every canonical skill.
- Run the focused scaffold test artifact.
- Run `zig build test --summary failures` from `packages/ziac`.
- Inspect the Testing v2 suite receipt for complete discovered/executed counts,
  zero failures, zero pending tests, zero leaks and zero logged errors.
- Run `packages/zigeffect/scripts/check_testing_v2_migration.sh` because the
  package build and scaffold gates are touched.
