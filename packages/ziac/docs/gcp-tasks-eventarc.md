# Cloud Tasks And Eventarc

Ziac manages asynchronous HTTP delivery through Cloud Tasks and Google-originated
events through Eventarc without hiding the Google resource model. This tranche
contains three managed resource types:

- `gcp.tasks.Queue`
- `gcp.tasks.QueueIamMember`
- `gcp.eventarc.Trigger`

Authenticated disposable-project qualification is tracked separately. The local
provider contract is deterministic and complete; it is not presented as live GCP
evidence when Application Default Credentials are unavailable.

## Cloud Tasks Queues

`Queue` covers regional identity, dispatch rate, concurrency, retry duration and
backoff, logging sampling, HTTP method, URI overrides, header overrides, and
queue-level OIDC or OAuth identity. Queue reads normalize the Google response
before diffing, so console changes are detected and server-only values such as
burst size do not create drift.

OIDC is the default fit for Cloud Run targets. OAuth is available for Google API
targets. Both require an explicit same-project service account, and graph
preflight includes `iam.serviceAccounts.actAs`. `QueueIamMember` owns one exact
role/member identity and updates policy version 3 with etag-preserving,
conflict-bounded read-modify-write behavior.

Queues are retained by default. Explicit deletion can remove queued work and
Google can reserve the deleted name for a tombstone window of up to three days.
Ziac therefore treats deletion as an operator-owned lifecycle decision and never
interprets a successful create response alone as proof that a tombstoned name is
available.

## Eventarc Triggers

`Trigger` covers exact and path-pattern event filters, required event type,
service identity, Cloud Run, GKE, Workflow and private HTTP destinations,
transport topics, labels, channels, content type and supported retry policy.
Create, update and delete use Google long-running operations. Updates preserve
etags and field masks; refresh resumes a saved operation handle and then
normalizes filters, destinations, transport and labels into observed state.

Transport subscriptions are output-only and never enter desired-state drift.
Google state conditions are considered ready only when every reported condition
has an OK code. Pub/Sub transport topics can be supplied as Ziac outputs without
causing perpetual diffs.

## Components

`ZigTaskWorker` creates a dedicated runtime identity, an authenticated queue,
resource-scoped Cloud Run invoker access and exact enqueuer grants.

`EventPipeline` creates a dedicated trigger identity, an optional transport
topic, Eventarc trigger, Cloud Run invoker access and explicit publisher grants.
Existing topics can be referenced without transferring ownership.

Both components emit ordinary resource graphs. Their IAM, API, estate, cost and
canvas behavior is inspectable before deployment and available to agent harnesses
through the same provider catalog.

## Delivery And Cost Semantics

The deterministic delivery policy distinguishes acknowledge, retry, dead-letter,
duplicate suppression and cancellation. It does not claim exactly-once execution
for either service.

Cost estimates keep usage assumptions explicit:

- Cloud Tasks billable operations are separate from network transfer.
- Eventarc chargeable events are separate from Pub/Sub transport throughput.
- A regional resource can use a global catalog SKU only when the exact regional
  SKU is absent.

These values are configuration estimates. Actual billed and projected month-end
cost still require the billing export pipeline and retain their separate
provenance labels.

## Official Contracts

- [Cloud Tasks queues](https://cloud.google.com/tasks/docs/reference/rest/v2/projects.locations.queues)
- [Cloud Tasks queue deletion](https://cloud.google.com/tasks/docs/reference/rest/v2/projects.locations.queues/delete)
- [Cloud Tasks pricing](https://cloud.google.com/tasks/pricing)
- [Eventarc triggers](https://cloud.google.com/eventarc/docs/reference/rest/v1/projects.locations.triggers)
- [Eventarc IAM](https://cloud.google.com/eventarc/docs/roles-permissions)
- [Eventarc pricing](https://cloud.google.com/eventarc/pricing)
