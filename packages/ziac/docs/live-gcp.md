# Live GCP CLI

The Ziac CLI defaults to the deterministic fake provider. Live Google calls are
never inferred from ambient credentials: the command must select `gcp` and
acknowledge mutation explicitly.

## Configuration

The executable reads:

- `ZIAC_LIVE_PROJECT` for the target project and graph configuration;
- `ZIAC_LIVE_REGION`, defaulting to `europe-west1`;
- `ZIAC_LIVE_REGIONS`, a comma-separated list for `global-container`;
- `ZIAC_LIVE_IMAGE` for an existing container image used by `hello-global`;
- `ZIAC_LIVE_SERVICE_ACCOUNT` for the Cloud Run runtime identity;
- `ZIAC_LIVE_DOMAIN` and optional `ZIAC_LIVE_DNS_ZONE` for
  `global-container`;
- `ZIAC_LIVE_HTTP_REDIRECT=false` to omit the default port-80 redirect path;
- normal Google ADC variables and well-known credential locations.

ADC is resolved only when the argument list contains `--provider gcp`. Fake
plans, deploys, tests, and local examples do not inspect credentials or contact
metadata endpoints.

```sh
export ZIAC_LIVE_PROJECT=team-ziac-disposable
export ZIAC_LIVE_IMAGE=europe-west1-docker.pkg.dev/team-ziac-disposable/hello-global/api@sha256:...

zig-out/bin/ziac plan --stack hello-global --stage smoke \
  --provider gcp --allow-live --live-test
zig-out/bin/ziac deploy --stack hello-global --stage smoke \
  --provider gcp --allow-live --live-test
zig-out/bin/ziac refresh --stack hello-global --stage smoke \
  --provider gcp --allow-live --live-test
zig-out/bin/ziac destroy --stack hello-global --stage smoke \
  --provider gcp --allow-live --live-test
```

The high-level global stack uses the same explicit safety flags:

```sh
export ZIAC_LIVE_REGIONS=europe-west1,us-central1
export ZIAC_LIVE_DOMAIN=api.example.com
export ZIAC_LIVE_DNS_ZONE=example-com

zig-out/bin/ziac plan --stack global-container --stage smoke \
  --provider gcp --allow-live --live-test
zig-out/bin/ziac deploy --stack global-container --stage smoke \
  --provider gcp --allow-live --live-test
```

`global-container` refuses a missing image/domain, fewer than two regions, a
duplicate region, or a non-Premium graph before provider mutation. The existing
zone is referenced only when `ZIAC_LIVE_DNS_ZONE` is set.

## Global Live Gate

`scripts/live-global-gate.sh` is the destructive, opt-in M5 harness. It requires
all global stack variables above, a disposable project suffix, ADC, an image
that returns a successful HTTP response, and a domain/managed zone safe for the
test. It performs deploy, HTTPS readiness, direct `run.app` denial, one regional
service deletion through the disposable-only `fail-region` command, global
availability during failure, refresh/deploy restoration, a full noop plan,
optional secret-sentinel scanning, and destroy.

```sh
ZIAC_LIVE_STAGE=global-smoke \
  packages/ziac/scripts/live-global-gate.sh
```

Set `ZIAC_LIVE_REMOTE_PROBES` to comma-separated controlled-location probe URLs
when external vantage points are available. Set `ZIAC_LIVE_FAIL_REGION` to
choose the region deleted by the harness and
`ZIAC_LIVE_READINESS_TIMEOUT_SECONDS` to change the certificate/HTTPS timeout.
The script installs an exit trap that attempts destroy after any failure.

`fail-region` never edits state. It requires `--provider gcp --allow-live
--live-test`, an existing state record, and a project ending in
`-ziac-disposable`. Recovery is intentionally the normal `refresh` then
`deploy` path.

## Safety Order

Before acquiring the writer lock or loading mutable state, the CLI verifies:

1. `--provider` is `fake` or `gcp`;
2. live calls include `--allow-live`;
3. a live provider registry was constructed from ADC;
4. `ZIAC_LIVE_PROJECT` exists and matches every GCP resource in the graph;
5. `--live-test` targets a project ending in `-ziac-disposable`.

Failures use the auth exit category and leave no lock or resource state file.
The project suffix is a guard, not proof of isolation; account-level quotas,
billing, organization policies, and deletion policy still belong to the
operator.

## Current Live Gate

Scripted transports cover the complete M4/M5 resource surface and the
production binary compiles with native HTTP and ADC. The authenticated
disposable-project gates remain environment-dependent and must not be reported
as passed unless their scripts complete against configured cloud resources.
