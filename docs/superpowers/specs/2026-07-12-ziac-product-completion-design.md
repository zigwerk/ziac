# Ziac Product Completion Design

Date: 2026-07-12
Status: Accepted for implementation
Owner: Ziac

## Objective

Turn Ziac from a locally qualified infrastructure engine plus visual prototype
into one installable product that can scaffold, compile, inspect, deploy, and
operate a user-authored Zig backend on Google Cloud with CockroachDB.

The release journey is:

```text
ziac init
  -> user edits src/main.zig and ziac.stack.zig
  -> ziac check
  -> ziac dev --watch
  -> ziac plan
  -> dashboard renders the real graph and causal session
  -> agent harness connects over MCP and proposes a bounded change
  -> ziac deploy --watch
  -> global HTTPS reaches healthy Cloud Run regions
  -> the service reads and writes CockroachDB over the declared binding
  -> billing and observed-estate data remain clearly distinguished
```

## Product Promise

Ziac compiles application requirements, infrastructure resources, provider
capabilities, ownership, output wiring, and operating evidence into one Zig
program. Specialist agents may move quickly because mutation is bounded by the
same typed graph and saved-plan integrity checks used by human operators.

The public promise is valid only when all of the following are true:

1. A project created outside the Ziac repository can drive every CLI command.
2. `App.Env` and infrastructure bindings fail at compile time when incompatible.
3. Local development, planning, deployment, logs, dashboard, and MCP operate on
   the same project graph and causal session.
4. Existing estate resources are observed or referenced without silently
   becoming Ziac-owned.
5. Estimated, projected, and billed costs are visibly different data classes.
6. A clean authenticated run proves source-to-global-service-to-database.

## Architecture

### Project program boundary

Ziac remains a compiled Zig system. It does not load arbitrary native plugins
into the installed CLI process. A user project exposes a small build-time entry
point that serializes a deterministic `ziac.program.v1` artifact. The CLI invokes
the project through a fixed `zig build ziac-program -- --stack ... --stage ...`
argv contract, validates the artifact schema and digest, then uses the decoded
program for plan/apply/visual operations.

`ziac init` generates:

- `build.zig` and `build.zig.zon` pinned to the selected Ziac dependency;
- `ziac.project.json` for requirements, environments, adaptations, and authority;
- `src/main.zig` with an application `Env` contract;
- `ziac.stack.zig` with a real `gcp.global.ZigService` composition;
- `.gitignore`, `.ziacignore`, tests, and agent-harness instructions;
- local skills describing Ziac, Zig, GCP, and dashboard workflows.

Built-in example stacks remain available only under an explicit fixture mode.

### Dashboard host

The standalone Ziac host owns all `ziac_*` bridge functions. It serves the
standalone dashboard bundle and loads project artifacts, sessions, log snapshots,
and estate scans from explicit paths. Missing live artifacts produce a visible
empty/error state; fixture fallback is allowed only with `?sample=` or a test
configuration.

### Agent protocol and authority

`ziac mcp serve` implements MCP over newline-delimited JSON-RPC on stdio:

- `initialize` and initialized notification;
- `tools/list` generated from the Ziac tool registry;
- `tools/call` routed through the capability envelope;
- structured errors, protocol version negotiation, bounded messages, and no
  logging to stdout.

Verification is process authority, not read authority. Acceptance checks use
fixed argv arrays rather than shell strings. The project manifest and command
digest are included in the capability envelope and verification receipt. Native
execution rejects shell interpreters, traversal outside the project root, and
commands not declared by the validated manifest.

### Development and watch deployment

Local watch mode retains the stable proxy and native supervisor. Cloud watch
mode receives a real adapter composed from source archiving, Cloud Build,
Artifact Registry, Cloud Run revision rollout, readiness, traffic shift, and
structured log streaming. It is development-stage only by default, rejects
destructive graph changes, and always carries the saved-plan digest.

### Estate, entitlement, and cost

The paid estate control plane is a separately deployable service with Google
OIDC/PKCE callbacks, account identity, Pro entitlement, encrypted GCP connection
metadata, revocation, and audit records. It never stores Google access tokens in
visual artifacts or browser storage.

Cost data has three explicit origins:

- `configuration_estimate`: asset shape plus public SKU catalogue;
- `projected_month_end`: billing-export usage extrapolation;
- `actual_billed`: Cloud Billing export values including credits when present.

Unknown usage inputs produce ranges or unavailable values, never false precision.

### Qualification

Credential-free gates prove deterministic behavior. Live gates are manifest
declared and fail closed when requested credentials are absent. The final
qualification provisions a disposable project and database, deploys from a clean
source checkout, exercises global HTTPS and database writes, tests one regional
failure, verifies a no-op plan, checks logs and dashboard artifacts, and destroys
all disposable resources while retaining protected data according to policy.

## Safety Invariants

- No shell evaluation is reachable through MCP verification.
- No fixture silently substitutes for missing live dashboard data.
- No observed estate resource is mutated without explicit zero-change adoption.
- No secret value is persisted in state, plans, logs, visual artifacts, receipts,
  billing records, or handoffs.
- No watched cloud deployment may perform a delete or replace.
- No public claim says live, billed, or production-proven without corresponding
  authenticated evidence.
- Every generated project and shipped executable passes Testing v2 qualification.

## Completion Definition

Code-complete means every deterministic milestone below passes from a clean
checkout. Production-qualified additionally requires the authenticated external
suite and its redacted evidence bundle. Documentation must report these states
separately.

