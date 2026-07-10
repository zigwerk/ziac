# Ziac Release Gate Design

Date: 2026-07-10
Status: validated for implementation

## Goal

Turn the completed Ziac engine and provider work into one reproducible release
contract that can be run from a clean checkout, while keeping authenticated
cloud acceptance explicit and auditable.

## Decisions

1. `zig build release-gate` is credential-free and deterministic. It runs
   formatting, unit and compile-fail tests, provider contracts, interruption
   and state migration coverage, all examples, the CLI build, a native
   ZigService container probe, static release checks, and a secret leak scan.
2. Authenticated tests are declared in `release/live-tests.json`. The manifest
   records commands, required environment, safety constraints, and expected
   evidence. Unit tests parse it strictly so release automation cannot drift
   into an undocumented cloud mutation.
3. The complete example composes an adopted Cockroach cluster, application
   database and generated Secret Manager reference, Cockroach/GCP Private
   Service Connect, and a source-built globally routed ZigService. Its `Env`
   contract consumes the database secret through a typed secret output.
4. The README becomes the shortest working path. Detailed bootstrap,
   operations, security, state, rollout, and live verification remain in
   focused documents linked from it.
5. Release checks fail closed on accidental credential files, private-key
   material outside the deliberate auth fixture/parser, or a configured secret
   sentinel in generated Ziac artifacts.

## Boundaries

- The automated gate does not provision billable infrastructure.
- The manifest does not contain credentials, project IDs, database URLs, or
  API keys.
- Authenticated evidence may contain resource IDs, request IDs, regions, and
  HTTP outcomes, but never tokens, secret values, or connection strings.
- A skipped authenticated test is reported as an external gate, not counted as
  proof of live readiness.

## Acceptance

- `zig build release-gate --summary all` passes from a clean checkout.
- The release manifest is strictly parsed and covers GCP global lifecycle,
  Cockroach Cloud SQL lifecycle, and local verified-TLS Cockroach transport.
- The complete example compiles, runs its graph test, and contains no public
  Cockroach allowlist.
- Documentation reproduces local validation and gives exact authenticated gate
  prerequisites and recovery commands.
