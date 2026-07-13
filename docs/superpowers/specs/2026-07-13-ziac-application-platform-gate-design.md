# Ziac M62 Application Platform Gate Design

Date: 2026-07-13
Status: accepted implementation direction

## Purpose

M57-M61 prove individual Google Cloud resources and components. M62 proves that
they form one coherent application platform. The deliverable is both a reusable
high-level component and a qualification protocol. Deterministic local evidence
must never be presented as authenticated Google Cloud evidence.

## Component Boundary

`ziac.gcp.ApplicationPlatform` compiles one regional application slice:

- a dedicated runtime service account and private Cloud Run API;
- a versioned upload bucket with exact object-writer authority;
- a Pub/Sub topic, push subscription, dead-letter topic and OIDC identity;
- a Cloud Tasks queue with OIDC delivery and exact enqueuer authority;
- an Eventarc trigger, transport topic and invocation identity;
- a scheduled Cloud Run Job with separate runtime and scheduler identities;
- a Cloud Run Worker Pool with a dedicated runtime identity.

All names derive from a stable platform name except the globally unique bucket
name. The component accepts one immutable container digest for the service, Job
and Worker Pool. It accepts the expected HTTPS service origin explicitly because
push and task target validation must be deterministic before deployment. The
Cloud Run resource output remains the authority used by IAM dependencies.

The component uses the existing high-level components as its implementation
boundary. It does not duplicate provider lifecycle code. Each intermediate graph
is copied through `base_graph`; the returned graph owns the final complete copy.

## Typed Outputs

The result exposes typed outputs for the service, bucket, topic, subscription,
queue, trigger, scheduled Job, schedule and Worker Pool. Application `Env`
contracts remain checked by the existing compile-time binding kernel. The M62
gate includes a valid integrated binding fixture and retains the existing
compile-fail fixtures for missing, extra, secret and scope-invalid bindings.

## Local Qualification

The local gate proves:

1. the graph is deterministic and acyclic;
2. every first-tranche product and identity is present exactly once where
   singular and has no duplicate resource authority;
3. output wiring creates explicit dependency edges;
4. permission synthesis covers every product API and separates deployer/runtime
   permissions;
5. a fake provider apply, import into a second state, refresh and no-op plan
   preserve identity;
6. the visual artifact contains managed topology, permission edges and cost
   provenance without secret material;
7. destroy ordering preserves retained resources and requires explicit authority
   for destructive resources;
8. a redacted `ziac.gcp.application-platform-qualification.v1` receipt records
   graph digest, resource counts, evidence status and limitations.

## Authenticated Qualification

`scripts/qualify-application-platform.sh` fails closed unless all required
configuration is present and the project ends in `-ziac-disposable`. It enables
the required APIs, applies the component with live-provider and live-test gates,
then exercises:

- upload and object metadata read;
- Pub/Sub publish, push delivery, retry and dead-letter evidence;
- Cloud Tasks enqueue and authenticated request delivery;
- Eventarc publication and trigger delivery;
- scheduled and manual Job execution plus cancellation evidence;
- Worker Pool rollout readiness and logs;
- import into an empty second state followed by a no-op plan;
- managed/observed topology generation and bounded cleanup.

The script emits a skipped receipt when tools, ADC or configuration are absent.
Only a completed remote run may set `authenticated=true` and `status=passed`.

## Failure And Recovery

The integrated graph relies on existing etags, metagenerations, long-running
operation handles and state checkpoints. A failed phase leaves a resumable Ziac
state. Cleanup runs only with the disposable-project suffix and explicit live
test authority. Retained buckets, topics and other declared retained resources
must survive the cleanup assertion.

## Out Of Scope

- claiming global routing from this regional application-platform slice;
- creating a Google Cloud project or billing account;
- embedding test credentials or container images;
- treating scripted transport responses as live service delivery;
- replacing the dedicated global `ZigService` and `ContainerService`
  abstractions.
