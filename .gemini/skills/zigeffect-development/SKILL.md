---
name: zigeffect-development
description: Build, change, debug, test, or review ZigEffect applications, services, libraries, packages, and framework code using zigeffect.project.json, services, layers, ManagedRuntime, Testing v2, causal graphs, statecharts, workflows, and proof-carrying handoffs. Use for requirement-driven development, runtime diagnosis, maintenance, and multi-agent integration.
---

# ZigEffect Development

Treat the manifest and structured runtime evidence as truth. Terminal text is a
bounded diagnostic artifact, never acceptance proof.

## Proof-carrying causal loop

1. Run `zigeffect agent context --task <id-or-summary> --budget 65536 --json`.
   Retain the source identity, manifest digest, graph cursor, authority,
   omissions, affected scenarios, and proof references.
2. Bind the request to a requirement, acceptance check, component, fixed
   command, and deterministic scenario. State the expected before/action/after
   causal path and the application slice that must not change.
3. If a coordinator supplies a work packet, obey its allowed and excluded
   paths, dependencies, verification commands, graph baseline, lease, and
   fencing token. Never invent unavailable coordination or authority.
4. Add the failing native Testing v2 scenario first. Implement with public
   component facades, `zigeffect_std`, typed services, effects, layers, errors,
   scopes, and one process-level `zstd.ManagedRuntime`.
5. Run `zigeffect test affected --changed <path> --json`, then the smallest
   selected scenario. Read the stable
   `.zigeffect/tests/process-receipts/<scenario>.json` and
   `.zigeffect/handoffs/tests/<scenario>.json`. Require matching source,
   manifest, command, toolchain, and completeness identities.
6. Treat `.zigeffect/tests/raw-receipts/`, `.zigeffect/tests/latest.json`, and
   terminal output as diagnostic views. They cannot replace controlled proof.
7. Compare `zigeffect graph since <cursor> --limit 256 --json` with the
   counterfactual. Query `zigeffect graph path <from> <to> --limit 128 --json`
   for exact durable relationships and use the receipt replay command on
   failure.
8. Re-query `agent context`. Reject stale proof, overlapping or undeclared
   paths, expired fencing tokens, missing dependency proof, required gaps,
   dropped evidence, and unread truncation before integration.

## Architecture

- Libraries export service tags, effects, layers, schemas, and typed errors;
  they never hide a runtime.
- Applications compose one root layer and one managed runtime. Recording,
  embedded NenDB, application maps, and checked shutdown are runtime-owned.
- Controlled acceptance runtimes use the owning project or component root.
  Query at least one mapped assertion ID through the project-mounted graph
  before publishing; a temporary graph cannot support CLI proof.
- Use deterministic providers in tests and semantic facts at external,
  workflow, statechart, artifact, and acceptance boundaries.
- Use typed statecharts for inspectable control and durable workflows for
  replayable idempotent activities.
- Never persist credentials, personal data, raw payloads, or terminal
  scrollback in causal or proof artifacts.

## Verification and handoff

Run:

```sh
zigeffect project validate --json
zigeffect test run --requirement <id> --json
zigeffect test coverage --requirement <id> --json
zigeffect test gaps --requirement <id> --json
zigeffect project test --json
zigeffect project check --agent --json
zigeffect agent context --task <id> --budget 65536 --json
zigeffect agent handoff --provider gemini --session <id> --json
```

Inspect the Testing v2 suite receipt after package-native commands. Require a
complete pass, equal discovered/executed counts, zero pending tests, leaks, and
logged errors. Attach exact stable receipt and proof paths, replay commands,
causal IDs, limitations, and remaining authority needs.

For multi-agent work, return a proof bundle bound to the work packet, source
baseline, lease fencing token, changed paths, verification digests, receipts,
and causal IDs. Independent qualifiers do not repair candidates. Repair memory
is advice, not current proof or authority.
