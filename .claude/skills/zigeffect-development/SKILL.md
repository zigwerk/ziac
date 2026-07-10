---
name: zigeffect-development
description: Build, change, debug, or review Zig applications, services, libraries, packages, and local systems that use zigeffect, zigeffect-std, zigeffect.project.json, causal evidence, or the zigeffect CLI. Use this skill for requirements-driven zigeffect development and agent handoffs.
---

# zigeffect Development

Use the project contract and causal evidence as the source of truth.

## Orient

1. Read `zigeffect.project.json` before editing code.
2. Identify the requirement, acceptance check, component, and allowed command IDs
   affected by the request.
3. Read the component's public facade, layers, schemas, tests, and causal helpers.
4. Run `zigeffect project validate --json`. Treat an unsupported manifest or
   failed validation as blocking evidence, not a prompt to bypass the contract.

## Implement

- Import application services through `zigeffect_std` and component public
  facades. Do not reach into another component's internals.
- Model boundaries with typed effects, service layers, Schema, and typed errors.
- Use `zigeffect generate` or `zigeffect add` for conventional structure before
  hand-creating framework wiring.
- Add a failing test first for behavior changes. Keep deterministic fakes for
  config, clock, filesystem, process, HTTP, and SQL boundaries.
- Emit semantic application facts at CLI, config, schema, HTTP, SQL, external
  process, artifact, dependency, and acceptance boundaries.
- Never place tokens, passwords, credential-bearing URLs, or raw terminal
  scrollback in manifests, facts, receipts, fixtures, or workbench payloads.

## Verify

Run only manifest-owned commands:

```sh
zigeffect project validate --json
zigeffect project check --json
zigeffect project test --json
```

When a check fails, query the structured project/evidence output first. Correlate
the failed check to its requirement, component, session, and causal facts before
inferring a fix from unstructured output.

## Handoff

Before stopping:

1. Record changed requirements and acceptance status.
2. Attach bounded, redacted artifacts and causal evidence IDs.
3. Run `zigeffect agent handoff --json`.
4. State failed or unrun checks plainly. Never mark a requirement satisfied
   without passing evidence.
