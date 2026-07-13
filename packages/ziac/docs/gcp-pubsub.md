# Google Cloud Pub/Sub

Ziac's Pub/Sub support follows the provider's three-layer model:

1. typed low-level declarations for Google resources;
2. handwritten lifecycle adapters for drift, import and IAM safety;
3. `ZigSubscriber`, an opinionated authenticated Cloud Run push graph.

The current catalog stage is `managed`. That means declaration and deterministic
provider lifecycle evidence pass. It does not mean the resources have completed
the disposable-project authenticated qualification required for `qualified`.

## Typed Resources

`gcp.pubsub` exports:

- `Schema` for Protocol Buffer and Avro definitions and committed revisions;
- `Topic` with labels, CMEK, message retention, persistence regions, in-transit
  enforcement and schema settings;
- `Subscription` with pull or push delivery, OIDC, acknowledgment deadline,
  retention, expiration, filtering, ordering, exactly-once delivery, retry and
  dead-letter policy;
- `Snapshot` with retained-on-delete defaults;
- `TopicIamMember` and `SubscriptionIamMember` for one exact optional
  conditional role/member identity.

Pub/Sub resources are retained by default. Destructive ownership must be
explicit with `retain_on_delete = false`.

```zig
var topic = try ziac.gcp.pubsub.Topic.build(allocator, provider, .{
    .name = "orders",
    .message_retention_seconds = 24 * 60 * 60,
    .allowed_persistence_regions = &.{ "europe-west1", "europe-west4" },
    .enforce_in_transit = true,
});
defer topic.deinit(allocator);

var subscription = try ziac.gcp.pubsub.Subscription.build(allocator, provider, .{
    .name = "orders-worker",
    .topic = topic.name,
    .delivery = .{ .push = .{
        .endpoint = "https://orders-worker.example.run.app/events/orders",
        .oidc_service_account_email = "orders-push@example.iam.gserviceaccount.com",
        .oidc_audience = "https://orders-worker.example.run.app",
    } },
    .expiration = .never,
    .dead_letter_topic = dead_letter.name,
    .max_delivery_attempts = 10,
    .retry_policy = .{ .minimum_backoff_seconds = 10, .maximum_backoff_seconds = 300 },
});
defer subscription.deinit(allocator);
```

Topic, subscription and snapshot names are canonical
`projects/<project>/...` outputs. Wiring one resource output into another adds
the graph dependency automatically.

## Lifecycle Semantics

The handwritten provider uses the pinned Google RPC contract and exact REST
transcoding:

- topic, subscription and snapshot creation use `PUT` on their canonical name;
- schema creation uses `POST` plus `schemaId`;
- schema definition changes commit a new revision;
- mutable changes use canonical field masks;
- changing a schema type or a subscription's source topic requires replacement;
- snapshot source changes conservatively require replacement;
- import reads the canonical Google resource name and normalizes remote defaults.

IAM resources request policy version 3 and preserve the remote etag. They mutate
only the matching role/member/condition identity, retry bounded conflicts and
leave unrelated bindings untouched. Ziac also provides
`gcp.run.ServiceIamMember` for resource-scoped Cloud Run access; the provider
does not widen an invoker grant to the project.

## ZigSubscriber

`ZigSubscriber` composes around an existing Cloud Run service. It creates:

- one source topic;
- one push subscription with retry and dead-letter policy;
- one dead-letter topic;
- one dedicated OIDC service account;
- one exact `roles/run.invoker` member on the target Cloud Run service;
- exact Pub/Sub service-agent publisher and subscriber members required for
  dead-letter forwarding;
- optional exact publisher members on the source topic.

```zig
var subscriber = try ziac.gcp.ZigSubscriber.build(allocator, provider, .{
    .base_graph = &service.graph,
    .name = "orders",
    .project_number = "123456789012",
    .service = cloud_run_service.name,
    .push_endpoint = "https://orders-worker.example.run.app/events/orders",
    .oidc_audience = "https://orders-worker.example.run.app",
    .publishers = &.{"serviceAccount:orders-api@example.iam.gserviceaccount.com"},
    .allowed_persistence_regions = &.{ "europe-west1", "europe-west4" },
});
defer subscriber.deinit();
```

The project number is required because Google's Pub/Sub service agent is
`service-<project-number>@gcp-sa-pubsub.iam.gserviceaccount.com`. Ziac validates
that boundary before planning and synthesizes the required Pub/Sub, Cloud Run
and IAM API permissions from the resulting graph.

Use a Google-generated `run.app` endpoint and audience for the directly covered
path. A custom domain or global load-balancer audience also requires the target
Cloud Run service to accept that custom audience. The component records the
requested OIDC audience but does not yet configure Cloud Run custom audiences;
authenticated global-load-balancer delivery remains part of the live
qualification work.

## Estate, Canvas And Cost

Cloud Asset Inventory topics and subscriptions map to the same managed physical
IDs. Subscription-to-topic relationships become `event` edges in the visual
artifact. Topic metadata includes retention, CMEK and persistence regions;
subscription metadata includes delivery mode, ack deadline, retention and
dead-letter attempts. The standalone dashboard packages Google's official
Pub/Sub icon from the Google Cloud icon archive.

`pubsubConfigurationEstimate` keeps assumed throughput GiB, retained GiB-month
and egress GiB separate. It consumes explicit SKU prices and returns a
`configuration_estimate`; it is not actual billed cost. Authoritative cost still
requires Cloud Billing export attribution.

## Qualification Boundary

Deterministic tests cover CRUD/import, schema revisions, push/OIDC payloads,
snapshots, field masks, exact conditional IAM, Run invoker IAM, graph preflight,
estate identity, topology, icon selection and cost arithmetic. The remaining
M58 gate needs Google credentials and a disposable project to publish a message,
observe authenticated delivery and retry, confirm dead-letter forwarding, import
the deployed graph, and clean it up.

Official references:

- [Pub/Sub REST API](https://cloud.google.com/pubsub/docs/reference/rest)
- [Create topics](https://cloud.google.com/pubsub/docs/create-topic)
- [Push subscriptions](https://cloud.google.com/pubsub/docs/push)
- [Dead-letter topics](https://cloud.google.com/pubsub/docs/dead-letter-topics)
- [Pub/Sub access control](https://cloud.google.com/pubsub/docs/access-control)
- [Pub/Sub pricing](https://cloud.google.com/pubsub/pricing)
- [Cloud Run service IAM](https://cloud.google.com/run/docs/reference/rest/v2/projects.locations.services)
- [Cloud Run custom audiences](https://cloud.google.com/run/docs/configuring/custom-audiences)
