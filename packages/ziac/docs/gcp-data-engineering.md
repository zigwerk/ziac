# GCP Data Engineering

Ziac treats data platforms as compiled infrastructure, not a collection of
unrelated JSON documents. The M81 surface covers recurring Dataflow templates,
Dataproc clusters and workflow DAGs, and Dataform release pipelines through the
same three layers used across the provider:

1. typed low-level declarations mirror stable Google resources;
2. hardened lifecycle adapters own identity, drift, update masks, operation
   resume, import and IAM conflict handling;
3. opinionated components compile common platforms with explicit authority.

## Managed Resources

| Ziac type | Google API | Lifecycle |
| --- | --- | --- |
| `gcp.datapipelines.Pipeline` | Data Pipelines v1 | Exact-mask CRUD/import; run and stop excluded |
| `gcp.dataproc.Cluster` | Dataproc v1 | Resumable CRUD; immutable region; protected delete |
| `gcp.dataproc.ClusterIamMember` | Dataproc v1 | Additive conditional IAM policy v3 |
| `gcp.dataproc.AutoscalingPolicy` | Dataproc v1 | Version-safe CRUD/import |
| `gcp.dataproc.AutoscalingPolicyIamMember` | Dataproc v1 | Additive conditional IAM policy v3 |
| `gcp.dataproc.WorkflowTemplate` | Dataproc v1 | Version-safe DAG CRUD/import |
| `gcp.dataproc.WorkflowTemplateIamMember` | Dataproc v1 | Additive conditional IAM policy v3 |
| `gcp.dataform.Repository` | Dataform v1beta1 | Exact-mask CRUD/import; Secret Manager references |
| `gcp.dataform.RepositoryIamMember` | Dataform v1beta1 | Additive conditional IAM policy v3 |
| `gcp.dataform.Workspace` | Dataform v1beta1 | Canonical nested create/read/delete/import |
| `gcp.dataform.WorkspaceIamMember` | Dataform v1beta1 | Additive conditional IAM policy v3 |
| `gcp.dataform.ReleaseConfig` | Dataform v1beta1 | Exact-mask nested CRUD/import |
| `gcp.dataform.WorkflowConfig` | Dataform v1beta1 | Exact-mask nested CRUD/import |

The provider pins dated Discovery contracts and SHA-256 digests for Data
Pipelines, Dataflow, Dataproc and Dataform. Dataflow contributes a governed
launch action rather than a mutable desired-state resource.

## Opinionated Components

`ScheduledDataflowPipeline` composes one recurring classic or Flex Template
pipeline with scheduler act-as, Dataflow developer and worker runtime authority.
`DataprocWorkflowPlatform` composes autoscaling, an optional persistent cluster,
a validated workflow DAG and resource-level operators. `DataformReleasePipeline`
composes a repository, release config, workflow config, optional development
workspace and repository operators.

```zig
var spark = try ziac.gcp.DataprocWorkflowPlatform.build(allocator, provider, .{
    .autoscaling = .{
        .name = "balanced",
        .region = "europe-west1",
        .worker = .{ .min_instances = 2, .max_instances = 10 },
    },
    .cluster = .{
        .name = "analytics",
        .region = "europe-west1",
        .master = .{ .machine_type = "n2-standard-4", .disk_size_gb = 100 },
        .worker = .{ .machine_type = "n2-standard-4", .disk_size_gb = 100, .instances = 2 },
    },
    .workflow = .{
        .name = "daily-orders",
        .region = "europe-west1",
        .placement = .{ .cluster_selector = .{ .labels = &.{.{ .key = "env", .value = "prod" }} } },
        .jobs = &.{.{
            .id = "extract",
            .job = .{ .pyspark = .{ .main_python_file_uri = "gs://jobs/extract.py" } },
        }},
    },
});
defer spark.deinit();
```

The complete compilable graph is `examples/data_engineering.zig`.

## Governed Actions

Ordinary plan/apply never starts compute or runs user code. Pipeline run/stop,
Dataflow Flex Template launch, Dataproc cluster start/stop/repair, Dataproc
workflow instantiation, Dataform compilation and Dataform workflow invocation
use a separate action API. Every action requires process authority plus a
payload- and target-bound capability digest, validates the observed state and
emits a redacted receipt.

This distinction matters to agents: generating or reconciling configuration is
repeatable; executing a workload can spend money, process data or change an
operational state. An agent cannot cross that boundary by changing a field in a
declaration.

## Discovery And Canvas

Cloud Asset Inventory officially exposes Dataproc clusters, autoscaling
policies and workflow templates, plus Dataform repositories, workspaces,
release configs and workflow configs. Estate scans map those seven asset types
to canonical managed identities. Data Pipelines is not advertised as a Cloud
Asset resource type, so Ziac leaves any such observation generic rather than
claiming safe adoption.

The visual artifact names pipeline, cluster, autoscaling, DAG, repository,
workspace, release and workflow roles. Output references remain first-class
edges, and workflow metadata includes job and prerequisite-edge counts. The
local dashboard parser preserves this typed data-engineering surface.

## Cost Semantics

Dataflow estimates require explicit worker vCPU hours, worker memory hours,
shuffle, Streaming Engine and disk assumptions. Dataproc estimates require
cluster vCPU hours and disk usage because the bill combines the management fee
with Compute Engine and Persistent Disk. Dataform itself is a no-charge service;
BigQuery execution and other downstream services remain separate costs.

The canvas uses three honest states:

- `service_no_charge` for Dataform configuration;
- `usage_assumptions_required` with a null amount for Dataflow and Dataproc
  resources before assumptions exist;
- actual or projected cost only when billing-export provenance exists.

## Qualification

The deterministic local receipt is
`ziac.gcp.data-engineering-qualification.v1`. It proves the merged 14-resource
graph, create/import/no-op parity, retained resources, resumable cluster
lifecycle, exact deployer/runtime permissions, seven supported asset identities,
nine governed actions, visual digest and cost-availability boundary. It always
records `authenticated=false`.

`scripts/qualify-data-engineering.sh` is the separate live gate. It requires
ADC, a project ending in `-ziac-disposable`, explicit canonical probe names and
the confirmation `QUALIFY_DISPOSABLE_DATA_ENGINEERING`. Missing prerequisites
produce a structured exit-77 skip. The runner applies a user-owned stack, reads
every managed service, imports it into a second state and requires a no-op plan.
It intentionally does not launch Dataflow, start or stop Dataproc, or invoke
Dataform workflows.

Official references:

- [Cloud Asset Inventory asset types](https://cloud.google.com/asset-inventory/docs/asset-types)
- [Dataflow pricing](https://cloud.google.com/dataflow/pricing)
- [Managed Service for Apache Spark pricing](https://cloud.google.com/products/managed-service-for-apache-spark/pricing)
- [Dataform billing](https://cloud.google.com/dataform/docs/billing-questions)
