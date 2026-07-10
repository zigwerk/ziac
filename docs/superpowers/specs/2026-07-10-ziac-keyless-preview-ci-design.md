# Ziac Keyless Preview CI Design

Date: 2026-07-10

Status: validated for implementation

## Objective

Provide a production-safe GitHub Actions pattern that deploys isolated pull
request previews through Google Workload Identity Federation, GCS state, and
immutable saved plans. No workflow input, fixture, or repository setting may
contain a service-account private key.

## Existing Foundation

Ziac already supports native external-account ADC:

- file and URL subject-token sources;
- RFC 8693 STS exchange;
- optional service-account impersonation;
- ADC discovery through `GOOGLE_APPLICATION_CREDENTIALS`;
- refreshable token caching without `gcloud`.

GCS state already partitions keys by stack and stage. Saved plans bind stack,
stage, state serial, desired graph, operations, and destructive approval.

The missing safety boundary is cloud resource identity. The current fixture
stack registry accepts `stage` but does not include it in resource names, so
preview state can be isolated while provider resources still collide.

## Preview Stage Identity

The canonical preview stage is:

```text
pr-<change-number>-<repository-hash-8>
```

The hash is the first eight lowercase hexadecimal characters of SHA-256 over
the lowercase `owner/repository` name. The change number must be positive and
is rendered without leading zeroes.

Properties:

- deterministic for plan, deploy, cleanup, and reruns;
- distinct across repositories sharing a project or state bucket;
- lowercase GCP-safe characters only;
- exact parser, so strings merely beginning with `pr-` are not previews;
- bounded to 32 characters for a `u64` change number.

`ziac preview-stage --repository owner/repository --change 123` prints the
canonical stage for shell use. `--json` emits `ziac.preview-stage.v1`.

## Provider Name Scoping

`ci.scopedResourceNameAlloc` appends the exact preview stage to a base resource
name. Non-preview persistent stages retain current names for compatibility.

When the result exceeds a provider limit, the helper preserves the full stage
suffix and inserts an eight-character hash of the untruncated base:

```text
<base-prefix>-<base-hash-8>-<preview-stage>
```

The helper validates lowercase alphanumeric/hyphen GCP names, start/end
characters, and the caller's maximum length. It never silently drops preview
identity.

The built-in stack registry applies this to:

- Artifact Registry repository names with a 63-character bound;
- Cloud Run service names with a 49-character bound;
- global ContainerService component names with a 49-character bound;
- preview DNS as `<preview-stage>.<configured-domain>`.

The global component name scopes its address, certificate, NEG, backend,
URL-map, proxy, forwarding-rule, and regional service descendants. GCS state
continues to use `<prefix>/<stack>/<preview-stage>/...`.

Public component users can call the same helpers before constructing
`ZigService` or `ContainerService`.

## Cleanup Policy

`destroy --preview-cleanup` is an additional fail-closed guard for automation:

- the stage must match the exact canonical preview grammar;
- `prod` and `production` return `ProductionPreviewCleanupForbidden`;
- malformed or persistent stages return `InvalidPreviewStage`;
- the check runs before stack construction, provider selection, or lock
  acquisition;
- executor `--confirm`, lifecycle protection, state CAS, and live-provider
  safeguards still apply.

The flag does not bypass protected CockroachDB resources. Preview stacks should
adopt shared protected data or create only disposable unprotected data. Any
protected resource must still be explicitly unprotected in a separate deploy.

## GitHub Actions Trust Boundary

The workflow template uses:

- `permissions: id-token: write` and `contents: read` only;
- `google-github-actions/auth@v3` with `workload_identity_provider` and
  `service_account` repository variables;
- the generated external-account credential file through native Ziac ADC;
- no `credentials_json`, service-account key, private key, or `gcloud` setup;
- a same-repository PR condition, so fork code never receives a cloud token;
- GitHub Environments for plan, deploy, and cleanup policy/approval;
- GCS remote state with repository-bound preview stages;
- a create-exclusive Ziac plan uploaded as an immutable Actions artifact;
- deploy from that saved plan, with exact digest approval when destructive;
- guarded cleanup on pull-request close.

The Google WIF provider must restrict assertions to the repository and workflow
identity. The deployment service account receives only the provider and
bucket-scoped permissions required by the selected stack.

Official references:

- https://docs.cloud.google.com/iam/docs/workload-identity-federation-with-deployment-pipelines
- https://github.com/google-github-actions/auth
- https://github.com/actions/upload-artifact

## WIF Contract Fixture

A GitHub Actions fixture models the generated external-account credential:

- GitHub workload identity provider audience;
- JWT subject-token type;
- Google STS token URL;
- service-account impersonation URL;
- file-sourced OIDC subject token;
- no private key fields.

Tests resolve it through `GOOGLE_APPLICATION_CREDENTIALS`, load the subject
token, perform scripted STS and impersonation requests, and assert diagnostics
identify external-account ADC without disclosing the token.

## Workflow Jobs

### Plan

1. Reject fork-originated PR code.
2. Check out the exact PR commit and install the pinned Zig version.
3. Authenticate through WIF.
4. Build and test Ziac.
5. Derive the canonical preview stage through the Ziac CLI.
6. Run live refresh planning against GCS state and save a plan.
7. Publish the plan, JSON receipt, digest, and approval requirement.

### Deploy

1. Run in a protected deploy environment.
2. Check out the same commit and authenticate through WIF.
3. Download the immutable plan artifact.
4. Recompute the same stage.
5. Apply with `deploy --plan`; pass the exact digest when required.

### Cleanup

1. Run only for a closed same-repository pull request.
2. Authenticate in the cleanup environment.
3. Recompute the stage from repository and PR number.
4. Run `destroy --preview-cleanup --confirm` through GCS state.

## Acceptance

- Preview stage output is deterministic, repository-specific, bounded, and
  exactly parseable.
- Preview resource names and domains are distinct and provider-valid.
- Persistent stage resource names remain backward compatible.
- Production and malformed stages cannot use preview cleanup mode.
- The GitHub external-account fixture completes ADC, STS, and impersonation
  contract tests without a service-account key.
- The workflow template contains WIF, saved plans, GCS state, protected
  environments, same-repository gating, and guarded cleanup.
- Static workflow tests reject key JSON fields and long-lived credential text.
