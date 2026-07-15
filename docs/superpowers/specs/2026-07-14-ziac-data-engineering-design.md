# M81 Data Engineering And Orchestration Design

Date: 2026-07-14

## Objective

Make Ziac useful for data-platform teams by managing recurring Dataflow Data
Pipelines, Dataproc infrastructure and Dataform repositories/configuration while
keeping job launches, workflow instantiation, compilation results and workflow
invocations as governed actions or observed execution history.

## Google Contracts

- Dataproc v1 Discovery revision `20260625`, SHA-256
  `2be999f4ce31c3d7b52d7f51c93ac1bf323fd45c10234a7aaa7fac47a4ec69f7`.
- Dataform v1beta1 Discovery revision `20260702`, SHA-256
  `17c7b6b738e05cfbd9e72a24b476f57fa8cba3cb847c080d489d140e67fd799b`.
- Data Pipelines v1 Discovery revision `20260705`, SHA-256
  `451ec2ec62331846dda5b65a8e2e213fa0abe71f88e63e796952319ae721547a`.
- Dataflow v1b3 Discovery revision `20260708`, SHA-256
  `f916f42da2d74bdad508f64eca160ba1d17e7e37c7916bbb7ecb7ce94d45e842`.

## Public Resources

Data Pipelines:

- `gcp.datapipelines.Pipeline`

Dataproc:

- `gcp.dataproc.Cluster`
- `gcp.dataproc.ClusterIamMember`
- `gcp.dataproc.AutoscalingPolicy`
- `gcp.dataproc.AutoscalingPolicyIamMember`
- `gcp.dataproc.WorkflowTemplate`
- `gcp.dataproc.WorkflowTemplateIamMember`

Dataform:

- `gcp.dataform.Repository`
- `gcp.dataform.RepositoryIamMember`
- `gcp.dataform.Workspace`
- `gcp.dataform.WorkspaceIamMember`
- `gcp.dataform.ReleaseConfig`
- `gcp.dataform.WorkflowConfig`

The managed catalog increases from 210 to 223 resources.

## Typed Data Model

Data Pipelines owns display name, batch or streaming type, classic or Flex
Template workload, bounded parameters, worker/runtime settings, scheduler
identity and optional batch schedule. Pipeline run is an action. The API's
permanent stop transition is never inferred from desired state.

Dataproc clusters type region/zone, service identity, network placement,
master/worker/secondary worker shape, autoscaling policy, image, CMEK, component
gateway and initialization actions. Autoscaling policy types worker bounds and
graceful/YARN scaling factors. Workflow templates use a tagged managed-cluster
or existing-cluster placement and a typed DAG of Hadoop, Spark, PySpark and
Presto jobs. Template version is a server concurrency token. Cluster start,
stop, repair and workflow instantiation are actions.

Dataform repositories type service account, CMEK, labels, workspace compilation
overrides and optional Git remote settings. Git credentials are only Secret
Manager version references; credential material never enters state. Workspaces
are explicit development roots. Release and workflow configurations type Git
commitish, schedules, time zones, compilation defaults, included targets/tags,
dependency closure and runtime identity. Compilations, workflow invocations and
workspace file mutations remain actions or developer-tool operations.

## Lifecycle Safety

Dataproc cluster create, patch and delete checkpoint native operations and use
request IDs. Immutable project/region/network and cluster-mode changes replace.
Cluster delete retains by default and requires declared removal plus destructive
authority. IAM uses policy version 3, etags and bounded retries.

Data Pipelines and Dataform CRUD are synchronous. Updates use exact field masks;
server outputs do not cause drift. Dataform repository KMS, region and remote
credential mode changes are replacements where Google cannot migrate safely.
Release/workflow schedules are validated as explicit cron/time-zone pairs.

Every action requires a target-bound capability digest, validates its current
resource state where relevant and emits a redacted receipt. A normal apply
cannot launch a Dataflow job, instantiate a Dataproc workflow, permanently stop
a pipeline or invoke a Dataform workflow.

## Opinionated Components

- `ScheduledDataflowPipeline` composes a typed recurring Data Pipeline and the
  exact project-level invoker/act-as grants required by its scheduler identity.
- `DataprocWorkflowPlatform` composes autoscaling policy, optional persistent
  cluster, workflow template and exact resource IAM.
- `DataformReleasePipeline` composes repository, release config, workflow config
  and optional development workspace with runtime and operator authority.

## Product Integration

Permission synthesis separates deployer authority, scheduler/workflow runtime
authority and governed execution authority. Cloud Asset identity covers
Dataproc and Dataform assets where Google publishes official types; Data
Pipelines falls back to authenticated API discovery without inventing an Asset
Inventory kind.

Canvas artifacts show template-to-pipeline, autoscaler-to-cluster, workflow DAG,
repository-to-release and release-to-workflow relationships. Cost remains an
explicit estimate: Dataflow/Dataproc compute, disk, shuffle and networking need
usage assumptions; Dataform repository configuration has no inferred runtime
cost; BigQuery execution remains attributed to BigQuery.

The local receipt proves create/import/no-op, replacement boundaries, operation
resume, exact masks/version tokens, additive IAM, action exclusion, authority,
visual topology and unavailable-without-usage cost. Authenticated qualification
uses a disposable project, second-state import and bounded execution probes; it
never launches an unbounded streaming job or permanently stops a pipeline.
