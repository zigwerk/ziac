# Ziac Product Completion Implementation Plan

**Canonical status:** Superseded. Milestones 0-6 and 9 are shipped at their
declared local gates; authenticated product qualification and beta release are
now M84-M90 in `packages/ziac/docs/roadmap.md`.

Date: 2026-07-12
Design: `docs/superpowers/specs/2026-07-12-ziac-product-completion-design.md`

## Milestone 0: Repository Truth

Status: complete

- Commit the standalone dashboard, SolidStart product site, case study, specs,
  and the deliberate removal of Ziac code from the ZigEffect workbench.
- Isolate Solid and Preact TypeScript projects so `bun run check` is green.
- Add clean-checkout checks that require every package referenced by root scripts
  to be tracked and buildable.
- Gate: root typecheck/tests plus Ziac release gate pass without ignored output.

## Milestone 1: User Project Compiler Boundary

Status: complete

- Add `ziac init`, `ziac check`, and deterministic scaffold templates.
- Define and validate `ziac.program.v1`.
- Add a fixed-argv project compiler process and a generated `ziac-program` build
  step that emits the user graph.
- Replace implicit built-in stack selection with project discovery; keep fixtures
  behind explicit test/example configuration.
- Add clean temporary-project tests for init, check, plan, comptime failure,
  visual export, and no-op replay.
- Gate: a generated project outside this repository drives the installed CLI.

Evidence: `zig build test` now includes `test/scaffold_e2e.sh`, which creates a
temporary Git project from the installed relocatable distribution, generates
matching Codex, Claude Code, and Gemini skills, runs its Testing v2 application suite, emits and
integrity-checks `ziac.program.v1`, runs `ziac check`, plans and applies through
the installed CLI, proves the next plan is a no-op, renders the visual artifact,
launches the installed dashboard host, and verifies through the installed MCP
server. A separate acceptance run uses an arbitrary prefix and empty Zig global
cache so source-checkout paths cannot satisfy the build accidentally.

## Milestone 2: Standalone Dashboard Host

Status: complete

- Move the native WebUI host into Ziac ownership.
- Bind `ziac_load_artifact`, `ziac_load_session`, log, estate, and operation APIs.
- Remove implicit sample fallback and add explicit disconnected/error states.
- Add artifact/session refresh events and browser tests against the native host.
- Lazy-load Three.js, map, and operational views to control bundle size.
- Gate: changing a real project graph refreshes the dashboard without fixtures.

Evidence: Ziac now owns a bounded host kernel and `ziac-dashboard-host` WebUI
executable with the five `ziac_*` bindings. `ziac dashboard` compiles the user
program, writes a redacted visual artifact, and launches the sibling host;
`--artifact-only` is covered by the generated-project E2E gate. Fixture fallback
requires an explicit `?sample=` query. The live bridge refetches artifact and
session data, the production bundle is served successfully by WebUI, and Three
and MapLibre/deck.gl are isolated from the 106 kB initial application chunk.

## Milestone 3: Agent Protocol and Safety

Status: complete

- Change acceptance checks from command strings to validated argv arrays, with a
  compatibility migration that fails closed for agent execution.
- Introduce process authority and command/manifest digests.
- Implement `ziac mcp serve`, MCP initialization, tool listing, calls, errors,
  cancellation, bounded stdio frames, and redacted receipts.
- Connect every advertised tool to the production kernel or remove it from the
  advertised registry until implemented.
- Generate installation snippets for Codex, Claude Code, and Gemini CLI.
- Gate: protocol conformance and hostile-command tests pass with no shell path.

Evidence: acceptance checks now use fixed argv and retain legacy command strings
only as non-executable migration data. Verification requires `process` authority,
rejects shell interpreters, absolute executables and parent traversal, and emits
command plus manifest digests. `ziac mcp serve` launches the installed sibling
stdio server with newline-delimited JSON-RPC, MCP `2025-11-25` initialization,
deterministic `tools/list`, bounded messages and tool-result errors. The registry
advertises only simulate, propose and verify because those are the production
kernel implementations. The generated project includes Codex, Claude-compatible
`.mcp.json`, and Gemini configuration, and the E2E gate performs a real MCP
verification through Testing v2.

## Milestone 4: Rapid Development and Deployment

Status: complete locally; authenticated rollout qualification remains in Milestone 7

- Connect project programs to existing local adaptation and stable-proxy watch.
- Implement the native cloud watch runtime over Cloud Build and Cloud Run.
- Stream build, revision, readiness, traffic, application, and diagnosis events
  into one causal log session and dashboard dock.
- Add digest caching and no-op suppression; reject destructive watch plans.
- Gate: one saved source change reaches a development Cloud Run revision and
  healthy traffic with a bounded event receipt.

Evidence: the installed CLI now constructs a graph-derived GCP watch runtime
for every `gcp.run.Service` in the user program. The runtime uses Cloud Run v2
RPCs directly: it reads and preserves the current template, creates the new
immutable-image revision while pinning all traffic to the prior revision, waits
for the Google long-running operation, independently proves terminal readiness,
and only then promotes the exact new revision. The launcher requires an
integrity-checked saved plan, verifies target and desired-graph identity, rejects
destructive plans and cross-project services, derives capability authority from
the verified digest, and writes the phase chain to the durable causal session.
Local source supervision and stable-proxy hot reload remain release-gated by the
native child-process E2E. The provider-level rollout is deterministic-fixture
qualified; a real Cloud Run timing receipt is intentionally part of Milestone 7.

## Milestone 5: Estate Pro Control Plane

Status: complete locally; paid-user qualification remains in Milestone 7

- Add a separately deployable control-plane service and persistence schema.
- Implement Google OIDC/PKCE callback, identity session, Pro entitlement,
  connection resolution, revocation, and audit endpoints.
- Connect the existing CAI scanner through short-lived Google credentials.
- Add managed/observed/referenced isolation and zero-mutation tests.
- Gate: a paid test identity scans a disposable project and no credential reaches
  the browser artifact.

Evidence: `ziac-estate-control-plane` is a separately installed HTTP service
that refuses startup without verified-TLS Cockroach, Google OAuth client, and
Cloud KMS configuration. PKCE challenges are persisted as digests and consumed
atomically; OIDC audience, issuer, nonce, expiry, subject, and verified email are
checked; refresh credentials pass directly into KMS; Cockroach stores only
ciphertext, key version, and digest; session assertions are random, returned
once, and persisted only by digest. Identity, Pro entitlement, connection
ownership, immediate revocation, and append-only audit are enforced by the same
server kernel consumed by the desktop resolver. Browser artifacts expose none of
the assertion, subject, credential, or KMS metadata. The live paid-identity scan
is deliberately retained in Milestone 7 because it needs external OAuth,
billing, GCP, KMS, and Cockroach configuration.

## Milestone 6: Cost Intelligence

Status: complete locally; authenticated billing qualification moved to M88

- Add Cloud Billing Catalog/Pricing adapters and SKU-region matching.
- Attach configuration estimate ranges and confidence/provenance to resources.
- Add BigQuery billing-export ingestion for actual and projected cost.
- Render actual, projected, and estimated values distinctly in the dashboard.
- Gate: pricing fixtures and a disposable billing export reconcile without
  presenting estimates as billed spend.

## Milestone 7: Authenticated Product Qualification

Status: superseded by M84 authenticated qualification

- Extend the live manifest to one clean-checkout source-to-image-to-global-service
  journey with a Cockroach read/write path.
- Exercise HTTPS, private database connectivity, secret binding, regional
  failure, rollback, no-op, import isolation, cost provenance, and cleanup.
- Capture redacted Testing v2, plan, deploy, dashboard, MCP, billing, and cleanup
  evidence.
- Gate: every required live test passes in one run and the roadmap records the
  exact evidence timestamp and environment identity.

## Milestone 8: Beta Release

Status: superseded by M90 private beta release

- Publish installation artifacts, versioned schemas, migration notes, operator
  runbooks, security model, pricing/entitlement terms, and support boundaries.
- Ensure the marketing site makes only evidence-backed claims.
- Gate: a new user completes the documented journey without repository-local
  fixtures or maintainer intervention.

## Milestone 9: Market The Installed Agent Kit

Status: complete

- Add homepage proof that one Ziac installation carries the local agent
  development kit, knowledge baseline, MCP server, and dashboard.
- Update `/how-it-works` to show the actual generated project files, three
  harness skill trees, read-only GCP researcher, and operator-owned credentials.
- Extend SEO and source-level UI contracts with evidence-backed install claims.
- Gate: site tests, strict typecheck, static production build, and desktop/mobile
  browser captures pass before merge to `master`.

Evidence: the homepage now presents the relocatable local compiler, dashboard,
MCP server, reference docs, harness-native skills, and read-only GCP Developer
Researcher as one installed kit. `/how-it-works` uses the real `ziac init --yes`
flow and generated paths, distinguishes bundled capability from user-owned
credentials and apply authority, and publishes matching route and application
SEO metadata. The marketing suite passed 41 tests with 346 assertions, strict
typecheck and static prerender passed, and focused desktop plus 390px browser
checks found no horizontal overflow or console diagnostics.

## Verification Matrix

| Surface | Deterministic evidence | Live evidence |
| --- | --- | --- |
| Engine | Testing v2 suite, compile-fail fixtures | saved-plan apply/no-op |
| Project CLI | generated-project E2E | clean source deployment |
| Dashboard | host contract and browser tests | real graph/log refresh |
| MCP | protocol and authority tests | harness-driven diagnosis |
| Watch | scripted build/rollout state machine | source save to traffic |
| Estate | OIDC/entitlement/CAI fixtures | disposable project scan |
| Cost | SKU and billing-export fixtures | billing reconciliation |
| Global stack | topology/provider tests | HTTPS, failover, Cockroach |
