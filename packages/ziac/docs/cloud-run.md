# Ziac Cloud Run V2 Contract

`gcp.run.Service` is a schema-version-2 resource backed by the Cloud Run Admin
API v2. The resource builder retains a complete canonical runtime declaration;
the provider does not depend on temporary builder values or synthetic URLs.

## Desired Runtime

The canonical service inputs include:

- project, region, service name, image, port, command, and arguments;
- CPU, memory, request concurrency, timeout, and min/max instances;
- service identity, labels, ingress, and unauthenticated-invoker mode;
- startup, liveness, and readiness HTTP probes;
- plain environment values and pinned Secret Manager environment references;
- Secret Manager volumes and mount paths;
- Direct VPC network, subnetwork, tags, and egress mode.

The default ingress is `INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER`, which accepts
traffic from internal sources and external Application Load Balancers without
opening the service to direct external `run.app` ingress. The raw resource keeps
the invoker IAM check enabled unless declared explicitly. `ContainerService`
disables that check for load-balancer traffic while retaining restricted
ingress, so its global URL is public and its direct `run.app` URL is not.

## Translation And Drift

`gcp.run_provider` translates the canonical snake-case Ziac value into the v2
Service request shape. Secret references become `secretKeyRef` or secret-volume
selectors; plaintext is never present in desired state or request translation.

Reads normalize the live Service back into the same canonical fields, including
container resources, probes, environment, volumes, scaling, VPC access, and
identity. Equivalent live state hashes to the desired document and plans noop.
Project, region, and service name changes replace; runtime changes update.

Live outputs are `service_url` from the API's canonical `uri`,
`service_account` from the revision template, and `latest_revision` from
`latestReadyRevision`.

## Operations And Recovery

Create and patch return a pending resource result with the Google operation
name. Apply writes that handle and deterministic physical service name to the
checkpoint before polling. It then completes the operation in the same deploy
and writes terminal outputs with the handle cleared.

If the process stops after the pending checkpoint, refresh, refreshed planning,
and executor resume pass both physical ID and operation handle into the provider
read context. The read polls the original operation and adopts its response,
without issuing a duplicate create or update. Delete currently polls to
completion inside the provider because the delete vtable has no result handle.
