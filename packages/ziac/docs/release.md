# Release And End-To-End Verification

## Release Boundary

Ziac separates deterministic release evidence from authenticated acceptance:

- `zig build release-gate --summary all` is reproducible from a clean checkout
  and does not access cloud accounts.
- `release/live-tests.json` declares every test that needs real credentials,
  the required environment names, safety constraints, commands, and permitted
  evidence.
- A release is locally qualified when the automated gate passes. It is live
  qualified only after every authenticated manifest entry passes against
  disposable infrastructure.

Never record an authenticated skip as a pass.

## Clean Checkout Gate

Requirements:

- Zig compatible with the package build
- Docker for the native ZigService container probe
- Bash, Git, and curl
- repository dependencies present through the normal checkout

Run:

```sh
cd packages/ziac
zig build release-gate --summary all
```

The gate includes formatting, unit and compile-fail contracts, scripted GCP and
CockroachDB provider lifecycles, retries and interruption recovery, state
format/migration/CAS/lock tests, all examples, CLI compilation, the native
container probe, required-document checks, generated credential detection, and
secret sentinel scanning.

Run repository integration gates from the repository root:

```sh
bun run check
bun run zigeffect:std:test
bun run zigeffect:postgres:test
bash packages/zigeffect/tools/check_tool_hygiene.sh
bun run zigeffect:postgres:cockroach-live-test
```

## Authenticated Inputs

The global GCP gate requires:

```text
ZIAC_LIVE_PROJECT
ZIAC_LIVE_IMAGE
ZIAC_LIVE_REGIONS
ZIAC_LIVE_DOMAIN
ZIAC_LIVE_DNS_ZONE
```

The project must end in `-ziac-disposable`, the image must be an immutable
Artifact Registry digest, and the region list must contain at least two GCP
regions. ADC or WIF must authorize all resources in the graph. Optional
`ZIAC_LIVE_REMOTE_PROBES` URLs provide observations from other geographies.

The Cockroach Cloud SQL gate requires disposable `verify-full` administrator
and application URLs through `ZIAC_COCKROACH_ADMIN_LIVE_URL` and
`ZIAC_COCKROACH_APP_LIVE_URL`. Cockroach cluster/PSC provisioning additionally
requires the API-key and cluster inputs documented by the selected stack.

## Authenticated Run

Validate auth, then run the manifest commands exactly:

```sh
cd packages/ziac
zig build
zig-out/bin/ziac auth doctor
bash scripts/live-global-gate.sh
bash scripts/qualify-hermes-compute.sh
```

The global script deploys, waits for HTTPS, verifies direct `run.app` ingress is
denied, removes one regional Cloud Run service, verifies continued global
availability, refreshes and restores it, checks a no-op plan, scans state for an
optional secret sentinel, and destroys the stack through an exit trap.

The Hermes Compute script runs the M84C third-party compatibility lane. It
requires the additional hostname, Cloud DNS, OAuth and secret inputs documented
in `docs/hermes-compute.md`. It proves valid public TLS, Nous OAuth provider
advertisement, rejected unauthenticated WebSocket access, localhost-only Hermes
ports, IAP recovery, restart persistence, a no-op plan, and empty cleanup
inventory.

Run the Cockroach SQL live test with the manifest environment set, then run the
local verified-TLS container gate from the repository root.

## Evidence Policy

Release evidence may record:

- commit and tool versions
- test counts and skipped authenticated gates
- project alias, regions, resource IDs, image digest, and state generation
- request IDs, provider categories, HTTP status, timing, and probe outcomes
- destroy and final no-op outcomes

It must not record:

- access, refresh, identity, or subject tokens
- service-account private keys or generated credential files
- Cockroach API keys, passwords, or connection URLs
- Secret Manager payloads or secret environment values
- state object bodies containing secret data

Store evidence outside source archives and run `scripts/release-checks.sh` after
collection. Set `ZIAC_RELEASE_SECRET_SENTINEL` when an acceptance stack uses a
known sentinel that must remain absent from `.ziac` and `release-evidence`.

## Release Decision

1. Automated gate passes from a clean checkout.
2. Repository and verified-TLS integration gates pass.
3. Every authenticated manifest scenario passes, or the release is explicitly
   labelled as awaiting live qualification.
4. The final live plan is no-op and cleanup/protected-retention outcomes match
   the manifest.
5. Secret scan and `git diff --check` pass.
