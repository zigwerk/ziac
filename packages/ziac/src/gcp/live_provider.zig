const std = @import("std");
const client_mod = @import("client.zig");
const bigquery_provider = @import("bigquery_provider.zig");
const application_services_provider = @import("application_services_provider.zig");
const build_delivery_provider = @import("build_delivery_provider.zig");
const cloud_deploy_provider = @import("cloud_deploy_provider.zig");
const data_pipelines_provider = @import("data_pipelines_provider.zig");
const dataform_provider = @import("dataform_provider.zig");
const dataproc_provider = @import("dataproc_provider.zig");
const data_engineering_iam_provider = @import("data_engineering_iam_provider.zig");
const eventarc_advanced_provider = @import("eventarc_advanced_provider.zig");
const connectors_provider = @import("connectors_provider.zig");
const event_integration_iam_provider = @import("event_integration_iam_provider.zig");
const vertex_ai_provider = @import("vertex_ai_provider.zig");
const vertex_ai_iam_provider = @import("vertex_ai_iam_provider.zig");
const cloud_build_provider = @import("cloud_build_provider.zig");
const container_platform_provider = @import("container_platform_provider.zig");
const monitoring_provider = @import("monitoring_provider.zig");
const organization_provider = @import("organization_provider.zig");
const governance_provider = @import("governance_provider.zig");
const securitycenter_provider = @import("securitycenter_provider.zig");
const binary_authorization_provider = @import("binary_authorization_provider.zig");
const private_ca_provider = @import("private_ca_provider.zig");
const logging_provider = @import("logging_provider.zig");
const compute_provider = @import("compute_provider.zig");
const compute_workloads_provider = @import("compute_workloads_provider.zig");
const connectivity_provider = @import("connectivity_provider.zig");
const edge_security_provider = @import("edge_security_provider.zig");
const network_delivery_provider = @import("network_delivery_provider.zig");
const dns_provider = @import("dns_provider.zig");
const network_provider = @import("network_provider.zig");
const kms_provider = @import("kms_provider.zig");
const scheduler_provider = @import("scheduler_provider.zig");
const service_networking_provider = @import("service_networking_provider.zig");
const sql_provider = @import("sql_provider.zig");
const spanner_provider = @import("spanner_provider.zig");
const redis_provider = @import("redis_provider.zig");
const pubsub_provider = @import("pubsub_provider.zig");
const tasks_provider = @import("tasks_provider.zig");
const eventarc_provider = @import("eventarc_provider.zig");
const firestore_provider = @import("firestore_provider.zig");
const iam_admin_provider = @import("iam_admin_provider.zig");
const iam_provider = @import("iam_provider.zig");
const operation = @import("operation.zig");
const run_provider = @import("run_provider.zig");
const run_workloads_provider = @import("run_workloads_provider.zig");
const run_iam_provider = @import("run_iam_provider.zig");
const storage_provider = @import("storage_provider.zig");
const provider_mod = @import("../provider.zig");
const resource = @import("../resource.zig");
const secret_mod = @import("../secret.zig");
const state = @import("../state.zig");
const value = @import("../value.zig");

const ProviderError = provider_mod.ProviderError;

const project_service_type = "gcp.project.Service";
const service_account_type = "gcp.iam.ServiceAccount";
const project_member_type = "gcp.iam.ProjectMember";
const artifact_repository_type = "gcp.artifact.Repository";
const secret_type = "gcp.secret.Secret";
const secret_version_type = "gcp.secret.SecretVersion";
const secret_iam_member_type = "gcp.secret.SecretIamMember";
const cloud_run_service_type = "gcp.run.Service";

pub const managed_type_names = [_][]const u8{
    "gcp.accesscontextmanager.AccessLevel",
    "gcp.accesscontextmanager.AccessPolicy",
    "gcp.accesscontextmanager.GcpUserAccessBinding",
    "gcp.accesscontextmanager.ServicePerimeter",
    "gcp.apigateway.Api",
    "gcp.apigateway.ApiConfig",
    "gcp.apigateway.ApiConfigIamMember",
    "gcp.apigateway.ApiIamMember",
    "gcp.apigateway.Gateway",
    "gcp.apigateway.GatewayIamMember",
    "gcp.artifact.ProjectSettings",
    "gcp.artifact.Repository",
    "gcp.artifact.VpcscConfig",
    "gcp.batch.Job",
    "gcp.bigquery.CapacityCommitment",
    "gcp.bigquery.Connection",
    "gcp.bigquery.ConnectionIamMember",
    "gcp.bigquery.Dataset",
    "gcp.bigquery.DatasetIamMember",
    "gcp.bigquery.Reservation",
    "gcp.bigquery.ReservationAssignment",
    "gcp.bigquery.ReservationIamMember",
    "gcp.bigquery.Routine",
    "gcp.bigquery.RoutineIamMember",
    "gcp.bigquery.Table",
    "gcp.bigquery.TableIamMember",
    "gcp.bigquery.View",
    "gcp.billing.ProjectBillingAssociation",
    "gcp.binaryauthorization.Attestor",
    "gcp.binaryauthorization.AttestorIamMember",
    "gcp.binaryauthorization.Policy",
    "gcp.certificatemanager.Certificate",
    "gcp.certificatemanager.CertificateMap",
    "gcp.certificatemanager.CertificateMapEntry",
    "gcp.certificatemanager.DnsAuthorization",
    "gcp.cloudbuild.Connection",
    "gcp.cloudbuild.Repository",
    "gcp.cloudbuild.Trigger",
    "gcp.cloudbuild.WorkerPool",
    "gcp.cloudbuild.ZigImage",
    "gcp.compute.Autoscaler",
    "gcp.compute.BackendBucket",
    "gcp.compute.BackendService",
    "gcp.compute.CertificateMapTargetHttpsProxy",
    "gcp.compute.Disk",
    "gcp.compute.ExternalVpnGateway",
    "gcp.compute.Firewall",
    "gcp.compute.ForwardingRule",
    "gcp.compute.GlobalAddress",
    "gcp.compute.GlobalForwardingRule",
    "gcp.compute.HaVpnGateway",
    "gcp.compute.HealthCheck",
    "gcp.compute.HttpRedirectUrlMap",
    "gcp.compute.Image",
    "gcp.compute.Instance",
    "gcp.compute.InstanceGroupManager",
    "gcp.compute.InstanceTemplate",
    "gcp.compute.InternalAddress",
    "gcp.compute.ManagedSslCertificate",
    "gcp.compute.Network",
    "gcp.compute.NetworkPeering",
    "gcp.compute.PrivateServiceRange",
    "gcp.compute.PscAddress",
    "gcp.compute.PscEndpoint",
    "gcp.compute.RegionAutoscaler",
    "gcp.compute.RegionBackendService",
    "gcp.compute.RegionDisk",
    "gcp.compute.RegionHealthCheck",
    "gcp.compute.RegionInstanceGroupManager",
    "gcp.compute.RegionServerlessNeg",
    "gcp.compute.RegionTargetHttpProxy",
    "gcp.compute.RegionUrlMap",
    "gcp.compute.RegionalAddress",
    "gcp.compute.Route",
    "gcp.compute.Router",
    "gcp.compute.RouterBgpPeer",
    "gcp.compute.RouterInterface",
    "gcp.compute.RouterNat",
    "gcp.compute.SecurityPolicy",
    "gcp.compute.SslPolicy",
    "gcp.compute.Subnetwork",
    "gcp.compute.TargetHttpProxy",
    "gcp.compute.TargetHttpsProxy",
    "gcp.compute.UrlMap",
    "gcp.compute.VpnTunnel",
    "gcp.connectors.Connection",
    "gcp.connectors.ConnectionIamMember",
    "gcp.connectors.EndpointAttachment",
    "gcp.connectors.EventSubscription",
    "gcp.connectors.ManagedZone",
    "gcp.connectors.RegionalSettings",
    "gcp.container.Cluster",
    "gcp.container.NodePool",
    "gcp.dataform.ReleaseConfig",
    "gcp.dataform.Repository",
    "gcp.dataform.RepositoryIamMember",
    "gcp.dataform.WorkflowConfig",
    "gcp.dataform.Workspace",
    "gcp.dataform.WorkspaceIamMember",
    "gcp.datapipelines.Pipeline",
    "gcp.dataproc.AutoscalingPolicy",
    "gcp.dataproc.AutoscalingPolicyIamMember",
    "gcp.dataproc.Cluster",
    "gcp.dataproc.ClusterIamMember",
    "gcp.dataproc.WorkflowTemplate",
    "gcp.dataproc.WorkflowTemplateIamMember",
    "gcp.deploy.Automation",
    "gcp.deploy.CustomTargetType",
    "gcp.deploy.DeliveryPipeline",
    "gcp.deploy.DeployPolicy",
    "gcp.deploy.Target",
    "gcp.dns.ManagedZone",
    "gcp.dns.RecordSet",
    "gcp.eventarc.Enrollment",
    "gcp.eventarc.EnrollmentIamMember",
    "gcp.eventarc.GoogleApiSource",
    "gcp.eventarc.GoogleApiSourceIamMember",
    "gcp.eventarc.MessageBus",
    "gcp.eventarc.MessageBusIamMember",
    "gcp.eventarc.Pipeline",
    "gcp.eventarc.PipelineIamMember",
    "gcp.eventarc.Trigger",
    "gcp.firestore.BackupSchedule",
    "gcp.firestore.Database",
    "gcp.firestore.DatabaseIamMember",
    "gcp.firestore.Field",
    "gcp.firestore.Index",
    "gcp.functions.FunctionIamMember",
    "gcp.functions.FunctionV2",
    "gcp.gkehub.Fleet",
    "gcp.gkehub.Membership",
    "gcp.iam.FolderBinding",
    "gcp.iam.FolderMember",
    "gcp.iam.FolderPolicy",
    "gcp.iam.OrganizationBinding",
    "gcp.iam.OrganizationCustomRole",
    "gcp.iam.OrganizationMember",
    "gcp.iam.OrganizationPolicy",
    "gcp.iam.ProjectBinding",
    "gcp.iam.ProjectCustomRole",
    "gcp.iam.ProjectMember",
    "gcp.iam.ProjectPolicy",
    "gcp.iam.ServiceAccount",
    "gcp.iam.ServiceAccountIamBinding",
    "gcp.iam.ServiceAccountIamMember",
    "gcp.iam.WorkloadIdentityPool",
    "gcp.iam.WorkloadIdentityPoolProvider",
    "gcp.identity.ProjectConfig",
    "gcp.identity.ProjectInboundSamlConfig",
    "gcp.identity.ProjectOAuthIdpConfig",
    "gcp.identity.Tenant",
    "gcp.identity.TenantIamMember",
    "gcp.identity.TenantInboundSamlConfig",
    "gcp.identity.TenantOAuthIdpConfig",
    "gcp.kms.CryptoKey",
    "gcp.kms.CryptoKeyIamMember",
    "gcp.kms.CryptoKeyVersion",
    "gcp.kms.KeyRing",
    "gcp.kms.KeyRingIamMember",
    "gcp.logging.Bucket",
    "gcp.logging.Exclusion",
    "gcp.logging.Metric",
    "gcp.logging.Sink",
    "gcp.logging.View",
    "gcp.monitoring.AlertPolicy",
    "gcp.monitoring.Dashboard",
    "gcp.monitoring.NotificationChannel",
    "gcp.monitoring.Service",
    "gcp.monitoring.ServiceLevelObjective",
    "gcp.monitoring.UptimeCheck",
    "gcp.networkconnectivity.Hub",
    "gcp.networkconnectivity.ServiceConnectionPolicy",
    "gcp.networkconnectivity.Spoke",
    "gcp.orgpolicy.CustomConstraint",
    "gcp.orgpolicy.Policy",
    "gcp.parametermanager.Parameter",
    "gcp.parametermanager.ParameterVersion",
    "gcp.parametermanager.Template",
    "gcp.parametermanager.TemplateVersion",
    "gcp.privateca.CaPool",
    "gcp.privateca.CaPoolIamMember",
    "gcp.privateca.Certificate",
    "gcp.privateca.CertificateAuthority",
    "gcp.privateca.CertificateTemplate",
    "gcp.privateca.CertificateTemplateIamMember",
    "gcp.project.Service",
    "gcp.pubsub.Schema",
    "gcp.pubsub.Snapshot",
    "gcp.pubsub.Subscription",
    "gcp.pubsub.SubscriptionIamMember",
    "gcp.pubsub.Topic",
    "gcp.pubsub.TopicIamMember",
    "gcp.redis.AclPolicy",
    "gcp.redis.Cluster",
    "gcp.redis.Instance",
    "gcp.resourcemanager.Folder",
    "gcp.resourcemanager.Lien",
    "gcp.resourcemanager.Project",
    "gcp.run.Job",
    "gcp.run.JobIamMember",
    "gcp.run.Service",
    "gcp.run.ServiceIamMember",
    "gcp.run.WorkerPool",
    "gcp.scheduler.Job",
    "gcp.secret.Secret",
    "gcp.secret.SecretIamMember",
    "gcp.secret.SecretVersion",
    "gcp.securitycenter.BigQueryExport",
    "gcp.securitycenter.MuteConfig",
    "gcp.securitycenter.NotificationConfig",
    "gcp.securitycenter.ResourceValueConfig",
    "gcp.securitycenter.Source",
    "gcp.servicenetworking.Connection",
    "gcp.serviceusage.ServiceIdentity",
    "gcp.spanner.Backup",
    "gcp.spanner.BackupSchedule",
    "gcp.spanner.Database",
    "gcp.spanner.DatabaseIamMember",
    "gcp.spanner.Instance",
    "gcp.spanner.InstanceIamMember",
    "gcp.sql.ClientCertificate",
    "gcp.sql.Database",
    "gcp.sql.Instance",
    "gcp.sql.ReadReplica",
    "gcp.sql.User",
    "gcp.storage.Bucket",
    "gcp.storage.BucketIamMember",
    "gcp.storage.BuildBucket",
    "gcp.storage.Object",
    "gcp.storage.SourceObject",
    "gcp.tags.TagBinding",
    "gcp.tags.TagHold",
    "gcp.tags.TagKey",
    "gcp.tags.TagValue",
    "gcp.tasks.Queue",
    "gcp.tasks.QueueIamMember",
    "gcp.vertex.Dataset",
    "gcp.vertex.DatasetIamMember",
    "gcp.vertex.Endpoint",
    "gcp.vertex.Feature",
    "gcp.vertex.FeatureGroup",
    "gcp.vertex.FeatureGroupIamMember",
    "gcp.vertex.FeatureOnlineStore",
    "gcp.vertex.FeatureOnlineStoreIamMember",
    "gcp.vertex.FeatureView",
    "gcp.vertex.FeatureViewIamMember",
    "gcp.vertex.Index",
    "gcp.vertex.IndexEndpoint",
    "gcp.vertex.MetadataStore",
    "gcp.vertex.Model",
    "gcp.vertex.ModelIamMember",
    "gcp.vertex.Tensorboard",
    "gcp.workflows.Workflow",
};

pub const PayloadDeinitObserver = secret_mod.PayloadDeinitObserver;
pub const SecretPayload = secret_mod.SecretPayload;
pub const SecretSource = secret_mod.SecretSource;

pub const LiveProvider = struct {
    client: *client_mod.Client,
    operation_policy: operation.Policy = .{},
    iam_conflict_retries: usize = 3,
    compute_conflict_retries: usize = 3,
    secret_source: ?SecretSource = null,
    payload_source: ?storage_provider.PayloadSource = null,
    cloud_build_poll_policy: operation.Policy = .{},
    cloud_build_failure_reporter: ?cloud_build_provider.FailureReporter = null,

    pub fn init(client: *client_mod.Client) LiveProvider {
        return .{ .client = client };
    }

    pub fn provider(self: *LiveProvider) provider_mod.Provider {
        return .{
            .ptr = self,
            .readFn = read,
            .diffFn = diff,
            .createFn = create,
            .updateFn = update,
            .deleteFn = delete,
            .importFn = importResource,
        };
    }

    fn read(ptr: *anyopaque, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ReadResult {
        const self: *LiveProvider = @ptrCast(@alignCast(ptr));
        if (isType(node, project_service_type)) return self.readProjectService(context, node);
        if (isType(node, service_account_type)) return self.readServiceAccount(context, node, null);
        if (organization_provider.Handler.supports(node)) return self.organizationHandler().read(context, node, null);
        if (governance_provider.Handler.supports(node)) return self.governanceHandler().read(context, node, null);
        if (securitycenter_provider.Handler.supports(node)) return self.securityCenterHandler().read(context, node, null);
        if (binary_authorization_provider.Handler.supports(node)) return self.binaryAuthorizationHandler().read(context, node, null);
        if (private_ca_provider.Handler.supports(node)) return self.privateCaHandler().read(context, node, null);
        if (iam_provider.supports(node)) return self.iamHandler().read(context, node, null);
        if (iam_admin_provider.supports(node)) return self.iamAdminHandler().read(context, node, null);
        if (build_delivery_provider.Handler.supports(node)) return self.buildDeliveryHandler().read(context, node, null);
        if (cloud_deploy_provider.Handler.supports(node)) return self.cloudDeployHandler().read(context, node, null);
        if (data_pipelines_provider.Handler.supports(node)) return self.dataPipelinesHandler().read(context, node, null);
        if (dataproc_provider.Handler.supports(node)) return self.dataprocHandler().read(context, node, null);
        if (dataform_provider.Handler.supports(node)) return self.dataformHandler().read(context, node, null);
        if (data_engineering_iam_provider.Handler.supports(node)) return self.dataEngineeringIamHandler().read(context, node, null);
        if (eventarc_advanced_provider.Handler.supports(node)) return self.eventarcAdvancedHandler().read(context, node, null);
        if (connectors_provider.Handler.supports(node)) return self.connectorsHandler().read(context, node, null);
        if (event_integration_iam_provider.Handler.supports(node)) return self.eventIntegrationIamHandler().read(context, node, null);
        if (vertex_ai_provider.Handler.supports(node)) return self.vertexAiHandler().read(context, node, null);
        if (vertex_ai_iam_provider.Handler.supports(node)) return self.vertexAiIamHandler().read(context, node, null);
        if (isType(node, artifact_repository_type)) return self.readArtifactRepository(context, node, null);
        if (isType(node, secret_type)) return self.readSecret(context, node, null);
        if (isType(node, secret_version_type)) return self.readSecretVersion(context, node, context.physical_id);
        if (isType(node, secret_iam_member_type)) return self.readSecretIamMember(context, node);
        if (isType(node, cloud_run_service_type)) return self.runHandler().read(context, node, null);
        if (run_workloads_provider.supports(node)) return self.runWorkloadsHandler().read(context, node, null);
        if (run_iam_provider.supports(node)) return self.runIamHandler().read(context, node, null);
        if (network_provider.supports(node)) return self.networkHandler().read(context, node, null);
        if (connectivity_provider.supports(node)) return self.connectivityHandler().read(context, node, null);
        if (container_platform_provider.supports(node)) return self.containerPlatformHandler().read(context, node, null);
        if (monitoring_provider.supports(node)) return self.monitoringHandler().read(context, node, null);
        if (logging_provider.supports(node)) return self.loggingHandler().read(context, node, null);
        if (compute_workloads_provider.supports(node)) return self.computeWorkloadsHandler().read(context, node, null);
        if (network_delivery_provider.supports(node)) return self.networkDeliveryHandler().read(context, node, null);
        if (edge_security_provider.supports(node)) return self.edgeSecurityHandler().read(context, node, null);
        if (compute_provider.supports(node)) return self.computeHandler().read(context, node, null);
        if (service_networking_provider.supports(node)) return self.serviceNetworkingHandler().read(context, node, null);
        if (dns_provider.supports(node)) return self.dnsHandler().read(context, node, null);
        if (storage_provider.supports(node)) return self.storageHandler().read(context, node, null);
        if (cloud_build_provider.supports(node)) return self.cloudBuildHandler().read(context, node, null);
        if (kms_provider.supports(node)) return self.kmsHandler().read(context, node, null);
        if (scheduler_provider.supports(node)) return self.schedulerHandler().read(context, node, null);
        if (pubsub_provider.supports(node)) return self.pubsubHandler().read(context, node, null);
        if (tasks_provider.supports(node)) return self.tasksHandler().read(context, node, null);
        if (eventarc_provider.supports(node)) return self.eventarcHandler().read(context, node, null);
        if (firestore_provider.supports(node)) return self.firestoreHandler().read(context, node, null);
        if (sql_provider.supports(node)) return self.sqlHandler().read(context, node, null);
        if (bigquery_provider.supports(node)) return self.bigqueryHandler().read(context, node, null);
        if (spanner_provider.supports(node)) return self.spannerHandler().read(context, node, null);
        if (redis_provider.supports(node)) return self.redisHandler().read(context, node, null);
        if (application_services_provider.supports(node)) return self.applicationServicesHandler().read(context, node, null);
        return error.InvalidConfiguration;
    }

    fn diff(
        _: *anyopaque,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        observed: *const provider_mod.ResourceResult,
    ) ProviderError!provider_mod.DiffResult {
        try context.checkActive();
        if (!isSupported(node)) return error.InvalidConfiguration;
        if (isType(node, cloud_run_service_type)) return run_provider.Handler.diff(context, node, observed);
        if (organization_provider.Handler.supports(node)) return organization_provider.Handler.diff(context, node, observed);
        if (governance_provider.Handler.supports(node)) return governance_provider.Handler.diff(context, node, observed);
        if (securitycenter_provider.Handler.supports(node)) return securitycenter_provider.Handler.diff(context, node, observed);
        if (binary_authorization_provider.Handler.supports(node)) return binary_authorization_provider.Handler.diff(context, node, observed);
        if (private_ca_provider.Handler.supports(node)) return private_ca_provider.Handler.diff(context, node, observed);
        if (run_workloads_provider.supports(node)) return run_workloads_provider.Handler.diff(context, node, observed);
        if (run_iam_provider.supports(node)) return run_iam_provider.Handler.diff(context, node, observed);
        if (iam_provider.supports(node)) return iam_provider.Handler.diff(context, node, observed);
        if (iam_admin_provider.supports(node)) return iam_admin_provider.Handler.diff(context, node, observed);
        if (build_delivery_provider.Handler.supports(node)) return build_delivery_provider.Handler.diff(context, node, observed);
        if (cloud_deploy_provider.Handler.supports(node)) return cloud_deploy_provider.Handler.diff(context, node, observed);
        if (data_pipelines_provider.Handler.supports(node)) return data_pipelines_provider.Handler.diff(context, node, observed);
        if (dataproc_provider.Handler.supports(node)) return dataproc_provider.Handler.diff(context, node, observed);
        if (dataform_provider.Handler.supports(node)) return dataform_provider.Handler.diff(context, node, observed);
        if (data_engineering_iam_provider.Handler.supports(node)) return data_engineering_iam_provider.Handler.diff(context, node, observed);
        if (eventarc_advanced_provider.Handler.supports(node)) return eventarc_advanced_provider.Handler.diff(context, node, observed);
        if (connectors_provider.Handler.supports(node)) return connectors_provider.Handler.diff(context, node, observed);
        if (event_integration_iam_provider.Handler.supports(node)) return event_integration_iam_provider.Handler.diff(context, node, observed);
        if (vertex_ai_provider.Handler.supports(node)) return vertex_ai_provider.Handler.diff(context, node, observed);
        if (vertex_ai_iam_provider.Handler.supports(node)) return vertex_ai_iam_provider.Handler.diff(context, node, observed);
        if (network_provider.supports(node)) return network_provider.Handler.diff(context, node, observed);
        if (connectivity_provider.supports(node)) return connectivity_provider.Handler.diff(context, node, observed);
        if (container_platform_provider.supports(node)) return container_platform_provider.Handler.diff(context, node, observed);
        if (monitoring_provider.supports(node)) return monitoring_provider.Handler.diff(context, node, observed);
        if (logging_provider.supports(node)) return logging_provider.Handler.diff(context, node, observed);
        if (compute_workloads_provider.supports(node)) return compute_workloads_provider.Handler.diff(context, node, observed);
        if (network_delivery_provider.supports(node)) return network_delivery_provider.Handler.diff(context, node, observed);
        if (edge_security_provider.supports(node)) return edge_security_provider.Handler.diff(context, node, observed);
        if (compute_provider.supports(node)) return compute_provider.Handler.diff(context, node, observed);
        if (service_networking_provider.supports(node)) return service_networking_provider.Handler.diff(context, node, observed);
        if (dns_provider.supports(node)) return dns_provider.Handler.diff(context, node, observed);
        if (storage_provider.supports(node)) return storage_provider.Handler.diff(context, node, observed);
        if (cloud_build_provider.supports(node)) return cloud_build_provider.Handler.diff(context, node, observed);
        if (kms_provider.supports(node)) return kms_provider.Handler.diff(context, node, observed);
        if (scheduler_provider.supports(node)) return scheduler_provider.Handler.diff(context, node, observed);
        if (pubsub_provider.supports(node)) return pubsub_provider.Handler.diff(context, node, observed);
        if (tasks_provider.supports(node)) return tasks_provider.Handler.diff(context, node, observed);
        if (eventarc_provider.supports(node)) return eventarc_provider.Handler.diff(context, node, observed);
        if (firestore_provider.supports(node)) return firestore_provider.Handler.diff(context, node, observed);
        if (sql_provider.supports(node)) return sql_provider.Handler.diff(context, node, observed);
        if (bigquery_provider.supports(node)) return bigquery_provider.Handler.diff(context, node, observed);
        if (spanner_provider.supports(node)) return spanner_provider.Handler.diff(context, node, observed);
        if (redis_provider.supports(node)) return redis_provider.Handler.diff(context, node, observed);
        if (application_services_provider.supports(node)) return application_services_provider.Handler.diff(context, node, observed);
        const kind: provider_mod.DiffKind = if (std.mem.eql(u8, &node.inputs_hash, &observed.observed_hash))
            .noop
        else if (isType(node, artifact_repository_type))
            artifactRepositoryDiff(node, observed.observed_inputs)
        else if (isType(node, secret_type))
            secretDiff(node, observed.observed_inputs)
        else if (isType(node, secret_version_type))
            secretVersionDiff(node, observed.observed_inputs)
        else if (isType(node, secret_iam_member_type))
            .replace
        else if (isType(node, project_service_type))
            .replace
        else
            .update;
        const reasons: []const []const u8 = if (kind == .noop) &.{} else &.{"observed inputs differ from desired inputs"};
        return provider_mod.DiffResult.init(context.allocator, kind, reasons);
    }

    fn create(ptr: *anyopaque, context: *provider_mod.OperationContext, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
        const self: *LiveProvider = @ptrCast(@alignCast(ptr));
        if (isType(node, project_service_type)) return self.enableProjectService(context, node);
        if (isType(node, service_account_type)) return self.createServiceAccount(context, node);
        if (organization_provider.Handler.supports(node)) return self.organizationHandler().create(context, node);
        if (governance_provider.Handler.supports(node)) return self.governanceHandler().create(context, node);
        if (securitycenter_provider.Handler.supports(node)) return self.securityCenterHandler().create(context, node);
        if (binary_authorization_provider.Handler.supports(node)) return self.binaryAuthorizationHandler().create(context, node);
        if (private_ca_provider.Handler.supports(node)) return self.privateCaHandler().create(context, node);
        if (iam_provider.supports(node)) return self.iamHandler().create(context, node);
        if (iam_admin_provider.supports(node)) return self.iamAdminHandler().create(context, node);
        if (build_delivery_provider.Handler.supports(node)) return self.buildDeliveryHandler().create(context, node);
        if (cloud_deploy_provider.Handler.supports(node)) return self.cloudDeployHandler().create(context, node);
        if (data_pipelines_provider.Handler.supports(node)) return self.dataPipelinesHandler().create(context, node);
        if (dataproc_provider.Handler.supports(node)) return self.dataprocHandler().create(context, node);
        if (dataform_provider.Handler.supports(node)) return self.dataformHandler().create(context, node);
        if (data_engineering_iam_provider.Handler.supports(node)) return self.dataEngineeringIamHandler().create(context, node);
        if (eventarc_advanced_provider.Handler.supports(node)) return self.eventarcAdvancedHandler().create(context, node);
        if (connectors_provider.Handler.supports(node)) return self.connectorsHandler().create(context, node);
        if (event_integration_iam_provider.Handler.supports(node)) return self.eventIntegrationIamHandler().create(context, node);
        if (vertex_ai_provider.Handler.supports(node)) return self.vertexAiHandler().create(context, node);
        if (vertex_ai_iam_provider.Handler.supports(node)) return self.vertexAiIamHandler().create(context, node);
        if (isType(node, artifact_repository_type)) return self.createArtifactRepository(context, node);
        if (isType(node, secret_type)) return self.createSecret(context, node);
        if (isType(node, secret_version_type)) return self.createSecretVersion(context, node);
        if (isType(node, secret_iam_member_type)) return self.ensureSecretIamMember(context, node, true);
        if (isType(node, cloud_run_service_type)) return self.runHandler().create(context, node);
        if (run_workloads_provider.supports(node)) return self.runWorkloadsHandler().create(context, node);
        if (run_iam_provider.supports(node)) return self.runIamHandler().create(context, node);
        if (network_provider.supports(node)) return self.networkHandler().create(context, node);
        if (connectivity_provider.supports(node)) return self.connectivityHandler().create(context, node);
        if (container_platform_provider.supports(node)) return self.containerPlatformHandler().create(context, node);
        if (monitoring_provider.supports(node)) return self.monitoringHandler().create(context, node);
        if (logging_provider.supports(node)) return self.loggingHandler().create(context, node);
        if (compute_workloads_provider.supports(node)) return self.computeWorkloadsHandler().create(context, node);
        if (network_delivery_provider.supports(node)) return self.networkDeliveryHandler().create(context, node);
        if (edge_security_provider.supports(node)) return self.edgeSecurityHandler().create(context, node);
        if (compute_provider.supports(node)) return self.computeHandler().create(context, node);
        if (service_networking_provider.supports(node)) return self.serviceNetworkingHandler().create(context, node);
        if (dns_provider.supports(node)) return self.dnsHandler().create(context, node);
        if (storage_provider.supports(node)) return self.storageHandler().create(context, node);
        if (cloud_build_provider.supports(node)) return self.cloudBuildHandler().create(context, node);
        if (kms_provider.supports(node)) return self.kmsHandler().create(context, node);
        if (scheduler_provider.supports(node)) return self.schedulerHandler().create(context, node);
        if (pubsub_provider.supports(node)) return self.pubsubHandler().create(context, node);
        if (tasks_provider.supports(node)) return self.tasksHandler().create(context, node);
        if (eventarc_provider.supports(node)) return self.eventarcHandler().create(context, node);
        if (firestore_provider.supports(node)) return self.firestoreHandler().create(context, node);
        if (sql_provider.supports(node)) return self.sqlHandler().create(context, node);
        if (bigquery_provider.supports(node)) return self.bigqueryHandler().create(context, node);
        if (spanner_provider.supports(node)) return self.spannerHandler().create(context, node);
        if (redis_provider.supports(node)) return self.redisHandler().create(context, node);
        if (application_services_provider.supports(node)) return self.applicationServicesHandler().create(context, node);
        return error.InvalidConfiguration;
    }

    fn update(
        ptr: *anyopaque,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        observed: *const provider_mod.ResourceResult,
    ) ProviderError!provider_mod.ResourceResult {
        const self: *LiveProvider = @ptrCast(@alignCast(ptr));
        if (isType(node, service_account_type)) return self.updateServiceAccount(context, node, observed.physical_id);
        if (organization_provider.Handler.supports(node)) return self.organizationHandler().update(context, node, observed);
        if (governance_provider.Handler.supports(node)) return self.governanceHandler().update(context, node, observed);
        if (securitycenter_provider.Handler.supports(node)) return self.securityCenterHandler().update(context, node, observed);
        if (binary_authorization_provider.Handler.supports(node)) return self.binaryAuthorizationHandler().update(context, node, observed);
        if (private_ca_provider.Handler.supports(node)) return self.privateCaHandler().update(context, node, observed);
        if (iam_provider.supports(node)) return self.iamHandler().update(context, node, observed.physical_id);
        if (iam_admin_provider.supports(node)) return self.iamAdminHandler().update(context, node, observed);
        if (build_delivery_provider.Handler.supports(node)) return self.buildDeliveryHandler().update(context, node, observed);
        if (cloud_deploy_provider.Handler.supports(node)) return self.cloudDeployHandler().update(context, node, observed);
        if (data_pipelines_provider.Handler.supports(node)) return self.dataPipelinesHandler().update(context, node, observed);
        if (dataproc_provider.Handler.supports(node)) return self.dataprocHandler().update(context, node, observed);
        if (dataform_provider.Handler.supports(node)) return self.dataformHandler().update(context, node, observed);
        if (data_engineering_iam_provider.Handler.supports(node)) return self.dataEngineeringIamHandler().update(context, node, observed);
        if (eventarc_advanced_provider.Handler.supports(node)) return self.eventarcAdvancedHandler().update(context, node, observed);
        if (connectors_provider.Handler.supports(node)) return self.connectorsHandler().update(context, node, observed);
        if (event_integration_iam_provider.Handler.supports(node)) return self.eventIntegrationIamHandler().update(context, node, observed);
        if (vertex_ai_provider.Handler.supports(node)) return self.vertexAiHandler().update(context, node, observed);
        if (vertex_ai_iam_provider.Handler.supports(node)) return self.vertexAiIamHandler().update(context, node, observed);
        if (isType(node, artifact_repository_type)) return self.updateArtifactRepository(context, node, observed);
        if (isType(node, secret_type)) return self.updateSecret(context, node, observed);
        if (isType(node, secret_version_type)) return self.updateSecretVersion(context, node, observed.physical_id);
        if (isType(node, cloud_run_service_type)) return self.runHandler().update(context, node, observed);
        if (run_workloads_provider.supports(node)) return self.runWorkloadsHandler().update(context, node, observed);
        if (run_iam_provider.supports(node)) return self.runIamHandler().update(context, node, observed.physical_id);
        if (network_provider.supports(node)) return self.networkHandler().update(context, node, observed.physical_id);
        if (connectivity_provider.supports(node)) return self.connectivityHandler().update(context, node, observed);
        if (container_platform_provider.supports(node)) return self.containerPlatformHandler().update(context, node, observed);
        if (monitoring_provider.supports(node)) return self.monitoringHandler().update(context, node, observed);
        if (logging_provider.supports(node)) return self.loggingHandler().update(context, node, observed);
        if (compute_workloads_provider.supports(node)) return self.computeWorkloadsHandler().update(context, node, observed);
        if (network_delivery_provider.supports(node)) return self.networkDeliveryHandler().update(context, node, observed);
        if (edge_security_provider.supports(node)) return self.edgeSecurityHandler().update(context, node, observed);
        if (compute_provider.supports(node)) return self.computeHandler().update(context, node, observed.physical_id);
        if (service_networking_provider.supports(node)) return self.serviceNetworkingHandler().update(context, node, observed);
        if (dns_provider.supports(node)) return self.dnsHandler().update(context, node, observed.physical_id);
        if (storage_provider.supports(node)) return self.storageHandler().update(context, node, observed.physical_id);
        if (cloud_build_provider.supports(node)) return self.cloudBuildHandler().update(context, node, observed.physical_id);
        if (kms_provider.supports(node)) return self.kmsHandler().update(context, node, observed);
        if (scheduler_provider.supports(node)) return self.schedulerHandler().update(context, node, observed.physical_id);
        if (pubsub_provider.supports(node)) return self.pubsubHandler().update(context, node, observed.physical_id);
        if (tasks_provider.supports(node)) return self.tasksHandler().update(context, node, observed.physical_id);
        if (eventarc_provider.supports(node)) return self.eventarcHandler().update(context, node, observed);
        if (firestore_provider.supports(node)) return self.firestoreHandler().update(context, node, observed);
        if (sql_provider.supports(node)) return self.sqlHandler().update(context, node, observed);
        if (bigquery_provider.supports(node)) return self.bigqueryHandler().update(context, node, observed);
        if (spanner_provider.supports(node)) return self.spannerHandler().update(context, node, observed);
        if (redis_provider.supports(node)) return self.redisHandler().update(context, node, observed);
        if (application_services_provider.supports(node)) return self.applicationServicesHandler().update(context, node, observed);
        return error.InvalidConfiguration;
    }

    fn delete(
        ptr: *anyopaque,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!void {
        const self: *LiveProvider = @ptrCast(@alignCast(ptr));
        if (isType(node, project_service_type)) return self.disableProjectService(context, physical_id);
        if (isType(node, service_account_type)) return self.deleteServiceAccount(context, physical_id);
        if (organization_provider.Handler.supports(node)) return self.organizationHandler().delete(context, node, physical_id);
        if (governance_provider.Handler.supports(node)) return self.governanceHandler().delete(context, node, physical_id);
        if (securitycenter_provider.Handler.supports(node)) return self.securityCenterHandler().delete(context, node, physical_id);
        if (binary_authorization_provider.Handler.supports(node)) return self.binaryAuthorizationHandler().delete(context, node, physical_id);
        if (private_ca_provider.Handler.supports(node)) return self.privateCaHandler().delete(context, node, physical_id);
        if (iam_provider.supports(node)) return self.iamHandler().delete(context, node, physical_id);
        if (iam_admin_provider.supports(node)) return self.iamAdminHandler().delete(context, node, physical_id);
        if (build_delivery_provider.Handler.supports(node)) return self.buildDeliveryHandler().delete(context, node, physical_id);
        if (cloud_deploy_provider.Handler.supports(node)) return self.cloudDeployHandler().delete(context, node, physical_id);
        if (data_pipelines_provider.Handler.supports(node)) return self.dataPipelinesHandler().delete(context, node, physical_id);
        if (dataproc_provider.Handler.supports(node)) return self.dataprocHandler().delete(context, node, physical_id);
        if (dataform_provider.Handler.supports(node)) return self.dataformHandler().delete(context, node, physical_id);
        if (data_engineering_iam_provider.Handler.supports(node)) return self.dataEngineeringIamHandler().delete(context, node, physical_id);
        if (eventarc_advanced_provider.Handler.supports(node)) return self.eventarcAdvancedHandler().delete(context, node, physical_id);
        if (connectors_provider.Handler.supports(node)) return self.connectorsHandler().delete(context, node, physical_id);
        if (event_integration_iam_provider.Handler.supports(node)) return self.eventIntegrationIamHandler().delete(context, node, physical_id);
        if (vertex_ai_provider.Handler.supports(node)) return self.vertexAiHandler().delete(context, node, physical_id);
        if (vertex_ai_iam_provider.Handler.supports(node)) return self.vertexAiIamHandler().delete(context, node, physical_id);
        if (isType(node, artifact_repository_type)) return self.deleteArtifactRepository(context, physical_id);
        if (isType(node, secret_type)) return self.deleteSecret(context, physical_id);
        if (isType(node, secret_version_type)) return self.removeSecretVersion(context, node, physical_id);
        if (isType(node, cloud_run_service_type)) return self.runHandler().delete(context, physical_id);
        if (run_workloads_provider.supports(node)) return self.runWorkloadsHandler().delete(context, node, physical_id);
        if (run_iam_provider.supports(node)) return self.runIamHandler().delete(context, node, physical_id);
        if (network_provider.supports(node)) return self.networkHandler().delete(context, node, physical_id);
        if (connectivity_provider.supports(node)) return self.connectivityHandler().delete(context, node, physical_id);
        if (container_platform_provider.supports(node)) return self.containerPlatformHandler().delete(context, node, physical_id);
        if (monitoring_provider.supports(node)) return self.monitoringHandler().delete(context, node, physical_id);
        if (logging_provider.supports(node)) return self.loggingHandler().delete(context, node, physical_id);
        if (compute_workloads_provider.supports(node)) return self.computeWorkloadsHandler().delete(context, node, physical_id);
        if (network_delivery_provider.supports(node)) return self.networkDeliveryHandler().delete(context, node, physical_id);
        if (edge_security_provider.supports(node)) return self.edgeSecurityHandler().delete(context, node, physical_id);
        if (compute_provider.supports(node)) return self.computeHandler().delete(context, node, physical_id);
        if (service_networking_provider.supports(node)) return self.serviceNetworkingHandler().delete(context, node, physical_id);
        if (dns_provider.supports(node)) return self.dnsHandler().delete(context, node, physical_id);
        if (storage_provider.supports(node)) return self.storageHandler().delete(context, node, physical_id);
        if (cloud_build_provider.supports(node)) return self.cloudBuildHandler().delete(context, node, physical_id);
        if (kms_provider.supports(node)) return self.kmsHandler().delete(context, node, physical_id);
        if (scheduler_provider.supports(node)) return self.schedulerHandler().delete(context, node, physical_id);
        if (pubsub_provider.supports(node)) return self.pubsubHandler().delete(context, node, physical_id);
        if (tasks_provider.supports(node)) return self.tasksHandler().delete(context, node, physical_id);
        if (eventarc_provider.supports(node)) return self.eventarcHandler().delete(context, node, physical_id);
        if (firestore_provider.supports(node)) return self.firestoreHandler().delete(context, node, physical_id);
        if (sql_provider.supports(node)) return self.sqlHandler().delete(context, node, physical_id);
        if (bigquery_provider.supports(node)) return self.bigqueryHandler().delete(context, node, physical_id);
        if (spanner_provider.supports(node)) return self.spannerHandler().delete(context, node, physical_id);
        if (redis_provider.supports(node)) return self.redisHandler().delete(context, node, physical_id);
        if (application_services_provider.supports(node)) return self.applicationServicesHandler().delete(context, node, physical_id);
        if (isType(node, secret_iam_member_type)) {
            var removed = try self.ensureSecretIamMember(context, node, false);
            removed.deinit();
            return;
        }
        return error.InvalidConfiguration;
    }

    fn importResource(
        ptr: *anyopaque,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!provider_mod.ResourceResult {
        const self: *LiveProvider = @ptrCast(@alignCast(ptr));
        if (isType(node, service_account_type)) {
            const result = try self.readServiceAccount(context, node, physical_id);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (organization_provider.Handler.supports(node)) return self.organizationHandler().importResource(context, node, physical_id);
        if (governance_provider.Handler.supports(node)) return self.governanceHandler().importResource(context, node, physical_id);
        if (securitycenter_provider.Handler.supports(node)) return self.securityCenterHandler().importResource(context, node, physical_id);
        if (binary_authorization_provider.Handler.supports(node)) return self.binaryAuthorizationHandler().importResource(context, node, physical_id);
        if (private_ca_provider.Handler.supports(node)) return self.privateCaHandler().importResource(context, node, physical_id);
        if (isType(node, project_service_type)) {
            const result = try self.readProjectService(context, node);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (isType(node, project_member_type)) {
            const result = try self.iamHandler().read(context, node, physical_id);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (iam_provider.supports(node)) {
            const result = try self.iamHandler().read(context, node, physical_id);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (iam_admin_provider.supports(node)) {
            const result = try self.iamAdminHandler().read(context, node, physical_id);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (build_delivery_provider.Handler.supports(node)) return self.buildDeliveryHandler().importResource(context, node, physical_id);
        if (cloud_deploy_provider.Handler.supports(node)) return self.cloudDeployHandler().importResource(context, node, physical_id);
        if (data_pipelines_provider.Handler.supports(node)) return self.dataPipelinesHandler().importResource(context, node, physical_id);
        if (dataproc_provider.Handler.supports(node)) return self.dataprocHandler().importResource(context, node, physical_id);
        if (dataform_provider.Handler.supports(node)) return self.dataformHandler().importResource(context, node, physical_id);
        if (data_engineering_iam_provider.Handler.supports(node)) return self.dataEngineeringIamHandler().importResource(context, node, physical_id);
        if (eventarc_advanced_provider.Handler.supports(node)) return self.eventarcAdvancedHandler().importResource(context, node, physical_id);
        if (connectors_provider.Handler.supports(node)) return self.connectorsHandler().importResource(context, node, physical_id);
        if (event_integration_iam_provider.Handler.supports(node)) return self.eventIntegrationIamHandler().importResource(context, node, physical_id);
        if (vertex_ai_provider.Handler.supports(node)) return self.vertexAiHandler().importResource(context, node, physical_id);
        if (vertex_ai_iam_provider.Handler.supports(node)) return self.vertexAiIamHandler().importResource(context, node, physical_id);
        if (isType(node, artifact_repository_type)) {
            const result = try self.readArtifactRepository(context, node, physical_id);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (isType(node, secret_type)) {
            const result = try self.readSecret(context, node, physical_id);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (isType(node, secret_version_type)) {
            const result = try self.readSecretVersion(context, node, physical_id);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (isType(node, secret_iam_member_type)) {
            const result = try self.readSecretIamMember(context, node);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (isType(node, cloud_run_service_type)) {
            const result = try self.runHandler().read(context, node, physical_id);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (run_workloads_provider.supports(node)) {
            const result = try self.runWorkloadsHandler().read(context, node, physical_id);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (run_iam_provider.supports(node)) {
            const result = try self.runIamHandler().read(context, node, physical_id);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (network_provider.supports(node)) {
            const result = try self.networkHandler().read(context, node, physical_id);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (connectivity_provider.supports(node)) return self.connectivityHandler().importResource(context, node, physical_id);
        if (container_platform_provider.supports(node)) return self.containerPlatformHandler().importResource(context, node, physical_id);
        if (monitoring_provider.supports(node)) return self.monitoringHandler().importResource(context, node, physical_id);
        if (logging_provider.supports(node)) return self.loggingHandler().importResource(context, node, physical_id);
        if (compute_workloads_provider.supports(node)) return self.computeWorkloadsHandler().importResource(context, node, physical_id);
        if (network_delivery_provider.supports(node)) return self.networkDeliveryHandler().importResource(context, node, physical_id);
        if (edge_security_provider.supports(node)) return self.edgeSecurityHandler().importResource(context, node, physical_id);
        if (compute_provider.supports(node)) {
            const result = try self.computeHandler().read(context, node, physical_id);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (service_networking_provider.supports(node)) return self.serviceNetworkingHandler().importResource(context, node, physical_id);
        if (dns_provider.supports(node)) {
            const result = try self.dnsHandler().read(context, node, physical_id);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (storage_provider.supports(node)) {
            const result = try self.storageHandler().read(context, node, physical_id);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (cloud_build_provider.supports(node)) {
            const result = try self.cloudBuildHandler().read(context, node, physical_id);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (kms_provider.supports(node)) {
            const result = try self.kmsHandler().read(context, node, physical_id);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (scheduler_provider.supports(node)) {
            const result = try self.schedulerHandler().read(context, node, physical_id);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (pubsub_provider.supports(node)) {
            const result = try self.pubsubHandler().read(context, node, physical_id);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (tasks_provider.supports(node)) {
            const result = try self.tasksHandler().read(context, node, physical_id);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (eventarc_provider.supports(node)) {
            const result = try self.eventarcHandler().read(context, node, physical_id);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (firestore_provider.supports(node)) {
            const result = try self.firestoreHandler().read(context, node, physical_id);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (sql_provider.supports(node)) return self.sqlHandler().importResource(context, node, physical_id);
        if (bigquery_provider.supports(node)) {
            const result = try self.bigqueryHandler().read(context, node, physical_id);
            return switch (result) {
                .absent => error.NotFound,
                .present => |present| present,
            };
        }
        if (spanner_provider.supports(node)) return self.spannerHandler().importResource(context, node, physical_id);
        if (redis_provider.supports(node)) return self.redisHandler().importResource(context, node, physical_id);
        if (application_services_provider.supports(node)) return self.applicationServicesHandler().importResource(context, node, physical_id);
        return error.InvalidConfiguration;
    }

    fn readProjectService(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ReadResult {
        const physical_id = try projectServiceNameAlloc(context.allocator, node);
        defer context.allocator.free(physical_id);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical_id});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .service_usage, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);

        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const object = jsonObject(parsed.value) orelse return error.ProviderBug;
        const service_state = jsonString(object.get("state")) orelse return error.ProviderBug;
        if (!std.mem.eql(u8, service_state, "ENABLED")) return .absent;
        return .{ .present = try projectServiceResult(context.allocator, node, physical_id, null) };
    }

    fn enableProjectService(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        const physical_id = try projectServiceNameAlloc(context.allocator, node);
        defer context.allocator.free(physical_id);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}:enable", .{physical_id});
        defer context.allocator.free(path);
        const operation_name = try self.startOperation(context, .service_usage, path, "POST", "{}");
        defer context.allocator.free(operation_name);
        try self.waitForServiceUsageOperation(context, operation_name);
        return projectServiceResult(context.allocator, node, physical_id, operation_name);
    }

    fn disableProjectService(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        physical_id: []const u8,
    ) ProviderError!void {
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}:disable", .{physical_id});
        defer context.allocator.free(path);
        const operation_name = self.startOperation(context, .service_usage, path, "POST", "{}") catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer context.allocator.free(operation_name);
        try self.waitForServiceUsageOperation(context, operation_name);
    }

    fn startOperation(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        api: client_mod.Api,
        path: []const u8,
        method: []const u8,
        body: []const u8,
    ) ProviderError![]const u8 {
        var response = try self.request(context, .{ .api = api, .method = method, .path = path, .body = body });
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const object = jsonObject(parsed.value) orelse return error.ProviderBug;
        const name = jsonString(object.get("name")) orelse return error.ProviderBug;
        return context.allocator.dupe(u8, name) catch return error.OutOfMemory;
    }

    fn waitForServiceUsageOperation(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        operation_name: []const u8,
    ) ProviderError!void {
        const base = try std.fmt.allocPrint(
            context.allocator,
            "{s}/v1",
            .{std.mem.trimEnd(u8, self.client.endpoints.service_usage, "/")},
        );
        defer context.allocator.free(base);
        var target = operation.Target.genericAlloc(context.allocator, base, operation_name) catch return error.OutOfMemory;
        defer target.deinit(context.allocator);
        var result = try operation.waitAlloc(self.client, context, target, self.operation_policy);
        result.deinit(context.allocator);
    }

    fn readServiceAccount(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_override: ?[]const u8,
    ) ProviderError!provider_mod.ReadResult {
        const generated = if (physical_override == null) try serviceAccountNameAlloc(context.allocator, node) else null;
        defer if (generated) |name| context.allocator.free(name);
        const physical_id = physical_override orelse generated.?;
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical_id});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .iam, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try serviceAccountResultFromJson(context.allocator, node, response.body) };
    }

    fn createServiceAccount(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        const project_id = try requiredInput(node, "project_id");
        const account_id = try requiredInput(node, "account_id");
        const display_name = try requiredInput(node, "display_name");
        const description = try requiredInput(node, "description");
        const path = try std.fmt.allocPrint(context.allocator, "/v1/projects/{s}/serviceAccounts", .{project_id});
        defer context.allocator.free(path);
        const body = std.json.Stringify.valueAlloc(context.allocator, .{
            .accountId = account_id,
            .serviceAccount = .{
                .displayName = display_name,
                .description = description,
            },
        }, .{}) catch return error.OutOfMemory;
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .iam, .method = "POST", .path = path, .body = body });
        defer response.deinit(context.allocator);
        return serviceAccountResultFromJson(context.allocator, node, response.body);
    }

    fn updateServiceAccount(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!provider_mod.ResourceResult {
        const display_name = try requiredInput(node, "display_name");
        const description = try requiredInput(node, "description");
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical_id});
        defer context.allocator.free(path);
        const body = std.json.Stringify.valueAlloc(context.allocator, .{
            .serviceAccount = .{
                .name = physical_id,
                .displayName = display_name,
                .description = description,
            },
            .updateMask = "displayName,description",
        }, .{}) catch return error.OutOfMemory;
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .iam, .method = "PATCH", .path = path, .body = body });
        defer response.deinit(context.allocator);
        return serviceAccountResultFromJson(context.allocator, node, response.body);
    }

    fn deleteServiceAccount(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        physical_id: []const u8,
    ) ProviderError!void {
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical_id});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .iam, .method = "DELETE", .path = path }) catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        response.deinit(context.allocator);
    }

    fn readArtifactRepository(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_override: ?[]const u8,
    ) ProviderError!provider_mod.ReadResult {
        const generated = if (physical_override == null) try artifactRepositoryNameAlloc(context.allocator, node) else null;
        defer if (generated) |name| context.allocator.free(name);
        const physical_id = physical_override orelse generated.?;
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical_id});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .artifact_registry, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try artifactRepositoryResultFromJson(context, node, response.body) };
    }

    fn createArtifactRepository(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        const project_id = try requiredInput(node, "project_id");
        const location = try requiredInput(node, "location");
        const name = try requiredInput(node, "name");
        const path = try std.fmt.allocPrint(
            context.allocator,
            "/v1/projects/{s}/locations/{s}/repositories?repositoryId={s}",
            .{ project_id, location, name },
        );
        defer context.allocator.free(path);
        const body = try artifactRepositoryBodyAlloc(context, node, null);
        defer context.allocator.free(body);
        const operation_name = self.startOperation(context, .artifact_registry, path, "POST", body) catch |err| {
            if (err != error.Conflict) return err;
            const existing = try self.readArtifactRepository(context, node, null);
            return switch (existing) {
                .absent => error.Conflict,
                .present => |present| if (std.mem.eql(u8, &node.inputs_hash, &present.observed_hash))
                    present
                else conflict: {
                    var mutable = present;
                    mutable.deinit();
                    break :conflict error.Conflict;
                },
            };
        };
        defer context.allocator.free(operation_name);
        try self.waitForArtifactOperation(context, operation_name);
        return artifactRepositoryDesiredResult(context.allocator, node, operation_name);
    }

    fn updateArtifactRepository(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        observed: *const provider_mod.ResourceResult,
    ) ProviderError!provider_mod.ResourceResult {
        const mask = try artifactRepositoryUpdateMaskAlloc(context.allocator, node, observed.observed_inputs);
        defer context.allocator.free(mask);
        if (mask.len == 0) return observed.clone(context.allocator);
        const encoded_mask = try percentEncodeAlloc(context.allocator, mask);
        defer context.allocator.free(encoded_mask);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}?updateMask={s}", .{ observed.physical_id, encoded_mask });
        defer context.allocator.free(path);
        const body = try artifactRepositoryBodyAlloc(context, node, observed.physical_id);
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .artifact_registry, .method = "PATCH", .path = path, .body = body });
        defer response.deinit(context.allocator);
        return artifactRepositoryResultFromJson(context, node, response.body);
    }

    fn deleteArtifactRepository(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        physical_id: []const u8,
    ) ProviderError!void {
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical_id});
        defer context.allocator.free(path);
        const operation_name = self.startOperation(context, .artifact_registry, path, "DELETE", "") catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        defer context.allocator.free(operation_name);
        try self.waitForArtifactOperation(context, operation_name);
    }

    fn waitForArtifactOperation(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        operation_name: []const u8,
    ) ProviderError!void {
        const base = try std.fmt.allocPrint(
            context.allocator,
            "{s}/v1",
            .{std.mem.trimEnd(u8, self.client.endpoints.artifact_registry, "/")},
        );
        defer context.allocator.free(base);
        var target = operation.Target.genericAlloc(context.allocator, base, operation_name) catch return error.OutOfMemory;
        defer target.deinit(context.allocator);
        var result = try operation.waitAlloc(self.client, context, target, self.operation_policy);
        result.deinit(context.allocator);
    }

    fn readSecret(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_override: ?[]const u8,
    ) ProviderError!provider_mod.ReadResult {
        const generated = if (physical_override == null) try secretNameAlloc(context.allocator, node) else null;
        defer if (generated) |name| context.allocator.free(name);
        const physical_id = physical_override orelse generated.?;
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical_id});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .secret_manager, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        return .{ .present = try secretResultFromJson(context.allocator, node, response.body) };
    }

    fn createSecret(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        const project_id = try requiredInput(node, "project_id");
        const name = try requiredInput(node, "name");
        const path = try std.fmt.allocPrint(context.allocator, "/v1/projects/{s}/secrets?secretId={s}", .{ project_id, name });
        defer context.allocator.free(path);
        const body = try secretBodyAlloc(context.allocator, node, null, null);
        defer context.allocator.free(body);
        var response = self.request(context, .{ .api = .secret_manager, .method = "POST", .path = path, .body = body }) catch |err| {
            if (err != error.Conflict) return err;
            const existing = try self.readSecret(context, node, null);
            return switch (existing) {
                .absent => error.Conflict,
                .present => |present| if (std.mem.eql(u8, &node.inputs_hash, &present.observed_hash))
                    present
                else conflict: {
                    var mutable = present;
                    mutable.deinit();
                    break :conflict error.Conflict;
                },
            };
        };
        defer response.deinit(context.allocator);
        return secretResultFromJson(context.allocator, node, response.body);
    }

    fn updateSecret(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        observed: *const provider_mod.ResourceResult,
    ) ProviderError!provider_mod.ResourceResult {
        const mask = try secretUpdateMaskAlloc(context.allocator, node, observed.observed_inputs);
        defer context.allocator.free(mask);
        if (mask.len == 0) return observed.clone(context.allocator);
        const etag = stateOutputString(observed.outputs, "etag") orelse return error.InvalidConfiguration;
        const encoded_mask = try percentEncodeAlloc(context.allocator, mask);
        defer context.allocator.free(encoded_mask);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}?updateMask={s}", .{ observed.physical_id, encoded_mask });
        defer context.allocator.free(path);
        const body = try secretBodyAlloc(context.allocator, node, observed.physical_id, etag);
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .secret_manager, .method = "PATCH", .path = path, .body = body });
        defer response.deinit(context.allocator);
        return secretResultFromJson(context.allocator, node, response.body);
    }

    fn deleteSecret(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        physical_id: []const u8,
    ) ProviderError!void {
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{physical_id});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .secret_manager, .method = "DELETE", .path = path }) catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        response.deinit(context.allocator);
    }

    fn readSecretVersion(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: ?[]const u8,
    ) ProviderError!provider_mod.ReadResult {
        const version_name = physical_id orelse return .absent;
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}", .{version_name});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .secret_manager, .method = "GET", .path = path }) catch |err| {
            if (err == error.NotFound) return .absent;
            return err;
        };
        defer response.deinit(context.allocator);
        var parsed = std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
        defer parsed.deinit();
        const object = jsonObject(parsed.value) orelse return error.ProviderBug;
        const version_state = jsonString(object.get("state")) orelse return error.ProviderBug;
        if (std.mem.eql(u8, version_state, "DESTROYED")) return .absent;
        return .{ .present = try secretVersionResultFromJson(context.allocator, node, response.body) };
    }

    fn createSecretVersion(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ResourceResult {
        const source = self.secret_source orelse return error.InvalidConfiguration;
        const reference = try requiredSecretInput(node, "source");
        var payload = try source.resolve(context, context.allocator, reference);
        defer payload.deinit();
        const encoded_size = std.base64.standard.Encoder.calcSize(payload.bytes.len);
        const encoded = context.allocator.alloc(u8, encoded_size) catch return error.OutOfMemory;
        defer {
            std.crypto.secureZero(u8, encoded);
            context.allocator.free(encoded);
        }
        _ = std.base64.standard.Encoder.encode(encoded, payload.bytes);
        const body = std.json.Stringify.valueAlloc(context.allocator, .{
            .payload = .{ .data = encoded },
        }, .{}) catch return error.OutOfMemory;
        defer {
            std.crypto.secureZero(u8, body);
            context.allocator.free(body);
        }
        const secret_name = try secretNameAlloc(context.allocator, node);
        defer context.allocator.free(secret_name);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}:addVersion", .{secret_name});
        defer context.allocator.free(path);
        var response = try self.request(context, .{ .api = .secret_manager, .method = "POST", .path = path, .body = body });
        defer response.deinit(context.allocator);
        var created = try secretVersionResultFromJson(context.allocator, node, response.body);
        const desired_state = try requiredInput(node, "state");
        if (std.mem.eql(u8, desired_state, "ENABLED")) return created;
        const physical_id = try context.allocator.dupe(u8, created.physical_id);
        defer context.allocator.free(physical_id);
        created.deinit();
        return self.updateSecretVersion(context, node, physical_id);
    }

    fn updateSecretVersion(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        physical_id: []const u8,
    ) ProviderError!provider_mod.ResourceResult {
        const desired_state = try requiredInput(node, "state");
        const suffix: []const u8 = if (std.mem.eql(u8, desired_state, "ENABLED")) "enable" else if (std.mem.eql(u8, desired_state, "DISABLED")) "disable" else return error.InvalidConfiguration;
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}:{s}", .{ physical_id, suffix });
        defer context.allocator.free(path);
        var response = try self.request(context, .{ .api = .secret_manager, .method = "POST", .path = path, .body = "{}" });
        defer response.deinit(context.allocator);
        return secretVersionResultFromJson(context.allocator, node, response.body);
    }

    fn removeSecretVersion(self: *LiveProvider, context: *provider_mod.OperationContext, node: resource.ResourceNode, physical_id: []const u8) ProviderError!void {
        const policy = try requiredInput(node, "removal_policy");
        if (std.mem.eql(u8, policy, "retain")) return;
        if (!std.mem.eql(u8, policy, "disable")) return error.InvalidConfiguration;
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}:disable", .{physical_id});
        defer context.allocator.free(path);
        var response = self.request(context, .{ .api = .secret_manager, .method = "POST", .path = path, .body = "{}" }) catch |err| {
            if (err == error.NotFound) return;
            return err;
        };
        response.deinit(context.allocator);
    }

    fn readSecretIamMember(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ReadResult {
        const role = try requiredInput(node, "role");
        const member = try requiredInput(node, "member");
        var policy = try self.getSecretPolicy(context, node);
        defer policy.deinit();
        if (!policyHasMember(policy.value, role, member)) return .absent;
        return .{ .present = try secretIamMemberResult(context.allocator, node) };
    }

    fn ensureSecretIamMember(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        should_exist: bool,
    ) ProviderError!provider_mod.ResourceResult {
        const role = try requiredInput(node, "role");
        const member = try requiredInput(node, "member");
        var conflicts: usize = 0;
        while (true) {
            try context.checkActive();
            var policy = try self.getSecretPolicy(context, node);
            defer policy.deinit();
            const changed = try mutatePolicy(&policy, role, member, should_exist);
            if (!changed) return secretIamMemberResult(context.allocator, node);
            self.setSecretPolicy(context, node, policy.value) catch |err| {
                if (err == error.Conflict and conflicts < self.iam_conflict_retries) {
                    conflicts += 1;
                    continue;
                }
                return err;
            };
            return secretIamMemberResult(context.allocator, node);
        }
    }

    fn getSecretPolicy(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!std.json.Parsed(std.json.Value) {
        const secret_name = try secretNameAlloc(context.allocator, node);
        defer context.allocator.free(secret_name);
        const path = try std.fmt.allocPrint(
            context.allocator,
            "/v1/{s}:getIamPolicy?options.requestedPolicyVersion=3",
            .{secret_name},
        );
        defer context.allocator.free(path);
        var response = try self.request(context, .{ .api = .secret_manager, .method = "GET", .path = path });
        defer response.deinit(context.allocator);
        return std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
    }

    fn setSecretPolicy(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        policy: std.json.Value,
    ) ProviderError!void {
        const secret_name = try secretNameAlloc(context.allocator, node);
        defer context.allocator.free(secret_name);
        const path = try std.fmt.allocPrint(context.allocator, "/v1/{s}:setIamPolicy", .{secret_name});
        defer context.allocator.free(path);
        const body = std.json.Stringify.valueAlloc(context.allocator, .{ .policy = policy }, .{}) catch return error.OutOfMemory;
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .secret_manager, .method = "POST", .path = path, .body = body });
        response.deinit(context.allocator);
    }

    fn readProjectMember(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
    ) ProviderError!provider_mod.ReadResult {
        const project_id = try requiredInput(node, "project_id");
        const role = try requiredInput(node, "role");
        const member = try requiredInput(node, "member");
        var policy = try self.getProjectPolicy(context, project_id);
        defer policy.deinit();
        if (!policyHasMember(policy.value, role, member)) return .absent;
        return .{ .present = try projectMemberResult(context.allocator, node) };
    }

    fn ensureProjectMember(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        node: resource.ResourceNode,
        should_exist: bool,
    ) ProviderError!provider_mod.ResourceResult {
        const project_id = try requiredInput(node, "project_id");
        const role = try requiredInput(node, "role");
        const member = try requiredInput(node, "member");
        var conflicts: usize = 0;
        while (true) {
            try context.checkActive();
            var policy = try self.getProjectPolicy(context, project_id);
            defer policy.deinit();
            const changed = try mutatePolicy(&policy, role, member, should_exist);
            if (!changed) return projectMemberResult(context.allocator, node);
            self.setProjectPolicy(context, project_id, policy.value) catch |err| {
                if (err == error.Conflict and conflicts < self.iam_conflict_retries) {
                    conflicts += 1;
                    continue;
                }
                return err;
            };
            return projectMemberResult(context.allocator, node);
        }
    }

    fn getProjectPolicy(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        project_id: []const u8,
    ) ProviderError!std.json.Parsed(std.json.Value) {
        const path = try std.fmt.allocPrint(context.allocator, "/v1/projects/{s}:getIamPolicy", .{project_id});
        defer context.allocator.free(path);
        var response = try self.request(context, .{
            .api = .resource_manager,
            .method = "POST",
            .path = path,
            .body = "{\"options\":{\"requestedPolicyVersion\":3}}",
        });
        defer response.deinit(context.allocator);
        return std.json.parseFromSlice(std.json.Value, context.allocator, response.body, .{}) catch return error.ProviderBug;
    }

    fn setProjectPolicy(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        project_id: []const u8,
        policy: std.json.Value,
    ) ProviderError!void {
        const path = try std.fmt.allocPrint(context.allocator, "/v1/projects/{s}:setIamPolicy", .{project_id});
        defer context.allocator.free(path);
        const body = std.json.Stringify.valueAlloc(context.allocator, .{ .policy = policy }, .{}) catch return error.OutOfMemory;
        defer context.allocator.free(body);
        var response = try self.request(context, .{ .api = .resource_manager, .method = "POST", .path = path, .body = body });
        response.deinit(context.allocator);
    }

    fn request(
        self: *LiveProvider,
        context: *provider_mod.OperationContext,
        request_value: client_mod.Request,
    ) ProviderError!@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(context, request_value, &diagnostic);
    }

    fn runHandler(self: *LiveProvider) run_provider.Handler {
        return .{ .client = self.client, .operation_policy = self.operation_policy };
    }

    fn organizationHandler(self: *LiveProvider) organization_provider.Handler {
        return .{ .client = self.client, .operation_policy = self.operation_policy };
    }

    fn governanceHandler(self: *LiveProvider) governance_provider.Handler {
        return .{ .client = self.client, .operation_policy = self.operation_policy };
    }

    fn securityCenterHandler(self: *LiveProvider) securitycenter_provider.Handler {
        return .{ .client = self.client };
    }

    fn binaryAuthorizationHandler(self: *LiveProvider) binary_authorization_provider.Handler {
        return .{ .client = self.client };
    }

    fn privateCaHandler(self: *LiveProvider) private_ca_provider.Handler {
        return .{ .client = self.client, .operation_policy = self.operation_policy };
    }

    fn runWorkloadsHandler(self: *LiveProvider) run_workloads_provider.Handler {
        return .{ .client = self.client, .operation_policy = self.operation_policy };
    }

    fn runIamHandler(self: *LiveProvider) run_iam_provider.Handler {
        return .{ .client = self.client, .conflict_retries = self.iam_conflict_retries };
    }

    fn iamHandler(self: *LiveProvider) iam_provider.Handler {
        return .{ .client = self.client, .conflict_retries = self.iam_conflict_retries };
    }

    fn iamAdminHandler(self: *LiveProvider) iam_admin_provider.Handler {
        return .{ .client = self.client, .operation_policy = self.operation_policy };
    }

    fn computeHandler(self: *LiveProvider) compute_provider.Handler {
        return .{
            .client = self.client,
            .operation_policy = self.operation_policy,
            .conflict_retries = self.compute_conflict_retries,
        };
    }

    fn computeWorkloadsHandler(self: *LiveProvider) compute_workloads_provider.Handler {
        return .{
            .client = self.client,
            .operation_policy = self.operation_policy,
            .conflict_retries = self.compute_conflict_retries,
            .secret_source = self.secret_source,
        };
    }

    fn networkDeliveryHandler(self: *LiveProvider) network_delivery_provider.Handler {
        return .{
            .client = self.client,
            .operation_policy = self.operation_policy,
            .conflict_retries = self.compute_conflict_retries,
        };
    }

    fn edgeSecurityHandler(self: *LiveProvider) edge_security_provider.Handler {
        return .{
            .client = self.client,
            .operation_policy = self.operation_policy,
            .conflict_retries = self.compute_conflict_retries,
        };
    }

    fn networkHandler(self: *LiveProvider) network_provider.Handler {
        return .{
            .client = self.client,
            .operation_policy = self.operation_policy,
            .conflict_retries = self.compute_conflict_retries,
        };
    }

    fn connectivityHandler(self: *LiveProvider) connectivity_provider.Handler {
        return .{
            .client = self.client,
            .operation_policy = self.operation_policy,
            .conflict_retries = self.compute_conflict_retries,
            .secret_source = self.secret_source,
        };
    }

    fn containerPlatformHandler(self: *LiveProvider) container_platform_provider.Handler {
        return .{ .client = self.client, .operation_policy = self.operation_policy };
    }

    fn monitoringHandler(self: *LiveProvider) monitoring_provider.Handler {
        return .{
            .client = self.client,
            .secret_source = self.secret_source,
            .conflict_retries = self.compute_conflict_retries,
        };
    }

    fn loggingHandler(self: *LiveProvider) logging_provider.Handler {
        return .{ .client = self.client, .operation_policy = self.operation_policy };
    }

    fn serviceNetworkingHandler(self: *LiveProvider) service_networking_provider.Handler {
        return .{ .client = self.client, .operation_policy = self.operation_policy };
    }

    fn dnsHandler(self: *LiveProvider) dns_provider.Handler {
        return .{ .client = self.client };
    }

    fn storageHandler(self: *LiveProvider) storage_provider.Handler {
        return .{
            .client = self.client,
            .payload_source = self.payload_source,
            .iam_conflict_retries = self.iam_conflict_retries,
        };
    }

    fn buildDeliveryHandler(self: *LiveProvider) build_delivery_provider.Handler {
        return .{
            .client = self.client,
            .operation_policy = self.operation_policy,
            .secret_source = self.secret_source,
        };
    }

    fn cloudDeployHandler(self: *LiveProvider) cloud_deploy_provider.Handler {
        return .{ .client = self.client, .operation_policy = self.operation_policy };
    }

    fn dataPipelinesHandler(self: *LiveProvider) data_pipelines_provider.Handler {
        return .{ .client = self.client };
    }

    fn dataprocHandler(self: *LiveProvider) dataproc_provider.Handler {
        return .{ .client = self.client, .operation_policy = self.operation_policy };
    }

    fn dataformHandler(self: *LiveProvider) dataform_provider.Handler {
        return .{ .client = self.client };
    }

    fn dataEngineeringIamHandler(self: *LiveProvider) data_engineering_iam_provider.Handler {
        return .{ .client = self.client };
    }

    fn eventarcAdvancedHandler(self: *LiveProvider) eventarc_advanced_provider.Handler {
        return .{ .client = self.client, .operation_policy = self.operation_policy };
    }

    fn connectorsHandler(self: *LiveProvider) connectors_provider.Handler {
        return .{ .client = self.client, .operation_policy = self.operation_policy };
    }

    fn eventIntegrationIamHandler(self: *LiveProvider) event_integration_iam_provider.Handler {
        return .{ .client = self.client };
    }

    fn vertexAiHandler(self: *LiveProvider) vertex_ai_provider.Handler {
        return .{ .client = self.client, .operation_policy = self.operation_policy };
    }

    fn vertexAiIamHandler(self: *LiveProvider) vertex_ai_iam_provider.Handler {
        return .{ .client = self.client };
    }

    fn cloudBuildHandler(self: *LiveProvider) cloud_build_provider.Handler {
        return .{
            .client = self.client,
            .poll_policy = self.cloud_build_poll_policy,
            .failure_reporter = self.cloud_build_failure_reporter,
        };
    }

    fn kmsHandler(self: *LiveProvider) kms_provider.Handler {
        return .{ .client = self.client };
    }

    fn schedulerHandler(self: *LiveProvider) scheduler_provider.Handler {
        return .{ .client = self.client };
    }

    fn pubsubHandler(self: *LiveProvider) pubsub_provider.Handler {
        return .{ .client = self.client, .iam_conflict_retries = self.iam_conflict_retries };
    }

    fn tasksHandler(self: *LiveProvider) tasks_provider.Handler {
        return .{ .client = self.client, .iam_conflict_retries = self.iam_conflict_retries };
    }

    fn eventarcHandler(self: *LiveProvider) eventarc_provider.Handler {
        return .{ .client = self.client, .operation_policy = self.operation_policy };
    }

    fn firestoreHandler(self: *LiveProvider) firestore_provider.Handler {
        return .{ .client = self.client, .operation_policy = self.operation_policy };
    }

    fn sqlHandler(self: *LiveProvider) sql_provider.Handler {
        return .{
            .client = self.client,
            .operation_policy = self.operation_policy,
            .secret_source = self.secret_source,
        };
    }

    fn bigqueryHandler(self: *LiveProvider) bigquery_provider.Handler {
        return .{ .client = self.client };
    }

    fn spannerHandler(self: *LiveProvider) spanner_provider.Handler {
        return .{ .client = self.client, .operation_policy = self.operation_policy };
    }

    fn redisHandler(self: *LiveProvider) redis_provider.Handler {
        return .{ .client = self.client, .operation_policy = self.operation_policy, .secret_source = self.secret_source };
    }

    fn applicationServicesHandler(self: *LiveProvider) application_services_provider.Handler {
        return .{ .client = self.client, .operation_policy = self.operation_policy, .secret_source = self.secret_source };
    }
};

fn projectServiceResult(
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    physical_id: []const u8,
    operation_handle: ?[]const u8,
) ProviderError!provider_mod.ResourceResult {
    const outputs = [_]state.StateOutput{
        .{ .name = "resource_name", .value = .{ .string = physical_id } },
    };
    return provider_mod.ResourceResult.init(allocator, physical_id, node.inputs, &outputs, operation_handle);
}

fn serviceAccountResultFromJson(
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    body: []const u8,
) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const object = jsonObject(parsed.value) orelse return error.ProviderBug;
    const name = jsonString(object.get("name")) orelse return error.ProviderBug;
    const email = jsonString(object.get("email")) orelse return error.ProviderBug;
    const unique_id = jsonString(object.get("uniqueId")) orelse return error.ProviderBug;
    const display_name = jsonString(object.get("displayName")) orelse "";
    const description = jsonString(object.get("description")) orelse "";
    const account_id = try requiredInput(node, "account_id");
    const project_id = try requiredInput(node, "project_id");
    const fields = [_]value.Field{
        .{ .name = "account_id", .value = .{ .string = account_id } },
        .{ .name = "description", .value = .{ .string = description } },
        .{ .name = "display_name", .value = .{ .string = display_name } },
        .{ .name = "project_id", .value = .{ .string = project_id } },
    };
    const outputs = [_]state.StateOutput{
        .{ .name = "email", .value = .{ .string = email } },
        .{ .name = "unique_id", .value = .{ .string = unique_id } },
    };
    return provider_mod.ResourceResult.init(allocator, name, .{ .object = &fields }, &outputs, null);
}

fn artifactRepositoryBodyAlloc(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    physical_id: ?[]const u8,
) ProviderError![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(context.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root = std.json.ObjectMap.empty;
    if (physical_id) |name| try root.put(arena, "name", .{ .string = name });
    try root.put(arena, "format", .{ .string = try requiredInput(node, "format") });
    try root.put(arena, "labels", try valueToJson(arena, try requiredInputValue(node.inputs, "labels")));
    if (node.schema_version >= 2) {
        try root.put(arena, "description", .{ .string = try requiredInput(node, "description") });
        try root.put(arena, "mode", .{ .string = try requiredInput(node, "mode") });
        const kms_key = try resolvedInputString(context, node.inputs, "kms_key_name");
        if (kms_key.len != 0) try root.put(arena, "kmsKeyName", .{ .string = kms_key });
        try root.put(arena, "cleanupPolicies", try cleanupPoliciesToJson(arena, try requiredInputValue(node.inputs, "cleanup_policies")));
        try root.put(arena, "cleanupPolicyDryRun", .{ .bool = try requiredInputBoolean(node.inputs, "cleanup_policy_dry_run") });
        var scanning = std.json.ObjectMap.empty;
        try scanning.put(arena, "enablementConfig", .{ .string = try requiredInput(node, "vulnerability_scanning") });
        try root.put(arena, "vulnerabilityScanningConfig", .{ .object = scanning });
    }
    return std.json.Stringify.valueAlloc(context.allocator, std.json.Value{ .object = root }, .{}) catch return error.OutOfMemory;
}

fn artifactRepositoryUpdateMaskAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, observed: value.Value) ProviderError![]const u8 {
    if (node.schema_version < 2) return allocator.dupe(u8, if (inputChanged(node.inputs, observed, "labels")) "labels" else "") catch return error.OutOfMemory;
    const fields = [_]struct { input: []const u8, api: []const u8 }{
        .{ .input = "cleanup_policies", .api = "cleanupPolicies" },
        .{ .input = "cleanup_policy_dry_run", .api = "cleanupPolicyDryRun" },
        .{ .input = "description", .api = "description" },
        .{ .input = "labels", .api = "labels" },
        .{ .input = "vulnerability_scanning", .api = "vulnerabilityScanningConfig.enablementConfig" },
    };
    var mask = std.ArrayList(u8).empty;
    errdefer mask.deinit(allocator);
    for (fields) |field| {
        if (!inputChanged(node.inputs, observed, field.input)) continue;
        if (mask.items.len != 0) try mask.append(allocator, ',');
        try mask.appendSlice(allocator, field.api);
    }
    return mask.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn artifactRepositoryResultFromJson(
    context: *provider_mod.OperationContext,
    node: resource.ResourceNode,
    body: []const u8,
) ProviderError!provider_mod.ResourceResult {
    const allocator = context.allocator;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const object = jsonObject(parsed.value) orelse return error.ProviderBug;
    const physical_id = jsonString(object.get("name")) orelse return error.ProviderBug;
    const format = jsonString(object.get("format")) orelse return error.ProviderBug;
    const project_id = try requiredInput(node, "project_id");
    const location = try requiredInput(node, "location");
    const name = try requiredInput(node, "name");
    const registry_uri = jsonString(object.get("registryUri")) orelse return error.ProviderBug;
    const label_object = if (object.get("labels")) |labels_value|
        jsonObject(labels_value) orelse return error.ProviderBug
    else
        std.json.ObjectMap.empty;
    const label_fields = try allocator.alloc(value.Field, label_object.count());
    defer allocator.free(label_fields);
    var iterator = label_object.iterator();
    var label_index: usize = 0;
    while (iterator.next()) |entry| : (label_index += 1) {
        const label_value = jsonString(entry.value_ptr.*) orelse return error.ProviderBug;
        label_fields[label_index] = .{ .name = entry.key_ptr.*, .value = .{ .string = label_value } };
    }
    const fields = [_]value.Field{
        .{ .name = "format", .value = .{ .string = format } },
        .{ .name = "labels", .value = .{ .object = label_fields } },
        .{ .name = "location", .value = .{ .string = location } },
        .{ .name = "name", .value = .{ .string = name } },
        .{ .name = "project_id", .value = .{ .string = project_id } },
    };
    const outputs = [_]state.StateOutput{
        .{ .name = "repository_url", .value = .{ .string = registry_uri } },
    };
    if (node.schema_version < 2) return provider_mod.ResourceResult.init(allocator, physical_id, .{ .object = &fields }, &outputs, null);

    var observed = node.inputs.clone(allocator) catch return error.OutOfMemory;
    defer observed.deinit(allocator);
    try replaceInputString(allocator, &observed, "format", format);
    try replaceInputString(allocator, &observed, "description", jsonString(object.get("description")) orelse "");
    try replaceInputString(allocator, &observed, "mode", jsonString(object.get("mode")) orelse "STANDARD_REPOSITORY");
    try replaceInputJson(allocator, &observed, "labels", object.get("labels") orelse .{ .object = std.json.ObjectMap.empty });
    if (object.get("cleanupPolicies")) |policies| {
        var normalized = try cleanupPoliciesFromJsonAlloc(allocator, policies);
        defer normalized.deinit(allocator);
        try replaceInputValue(allocator, &observed, "cleanup_policies", normalized);
    } else try replaceInputValue(allocator, &observed, "cleanup_policies", .{ .list = &.{} });
    try replaceInputBoolean(allocator, &observed, "cleanup_policy_dry_run", jsonBooleanValue(object.get("cleanupPolicyDryRun")) orelse false);
    const scanning = jsonObject(object.get("vulnerabilityScanningConfig") orelse .{ .object = std.json.ObjectMap.empty });
    try replaceInputString(allocator, &observed, "vulnerability_scanning", if (scanning) |config| jsonString(config.get("enablementConfig")) orelse "INHERITED" else "INHERITED");
    const remote_kms = jsonString(object.get("kmsKeyName")) orelse "";
    const current_kms = try requiredInputValue(observed, "kms_key_name");
    const preserve_kms_ref = switch (current_kms) {
        .output_ref => |reference| std.mem.eql(u8, try context.resolveOutputString(reference), remote_kms),
        else => false,
    };
    if (!preserve_kms_ref) try replaceInputString(allocator, &observed, "kms_key_name", remote_kms);
    const size_bytes = jsonI64(object.get("sizeBytes")) orelse 0;
    const generic_outputs = [_]state.StateOutput{
        .{ .name = "repository_url", .value = .{ .string = registry_uri } },
        .{ .name = "size_bytes", .value = .{ .integer = size_bytes } },
    };
    return provider_mod.ResourceResult.init(allocator, physical_id, observed, &generic_outputs, null);
}

fn artifactRepositoryDesiredResult(
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    operation_handle: ?[]const u8,
) ProviderError!provider_mod.ResourceResult {
    const project_id = try requiredInput(node, "project_id");
    const location = try requiredInput(node, "location");
    const name = try requiredInput(node, "name");
    const physical_id = try artifactRepositoryNameAlloc(allocator, node);
    defer allocator.free(physical_id);
    const format = try requiredInput(node, "format");
    const format_slug = artifactFormatSlug(format) orelse return error.InvalidConfiguration;
    const registry_uri = try std.fmt.allocPrint(allocator, "{s}-{s}.pkg.dev/{s}/{s}", .{ location, format_slug, project_id, name });
    defer allocator.free(registry_uri);
    const outputs_v1 = [_]state.StateOutput{
        .{ .name = "repository_url", .value = .{ .string = registry_uri } },
    };
    const outputs_v2 = [_]state.StateOutput{
        .{ .name = "repository_url", .value = .{ .string = registry_uri } },
        .{ .name = "size_bytes", .value = .{ .unknown_reason = "Artifact Registry size is available after refresh" } },
    };
    return provider_mod.ResourceResult.init(allocator, physical_id, node.inputs, if (node.schema_version >= 2) &outputs_v2 else &outputs_v1, operation_handle);
}

fn secretBodyAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, physical_id: ?[]const u8, etag: ?[]const u8) ProviderError![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var root: std.json.ObjectMap = .empty;
    if (physical_id) |name| try root.put(arena, "name", .{ .string = name });
    if (etag) |tag| try root.put(arena, "etag", .{ .string = tag });
    try root.put(arena, "labels", try valueToJson(arena, try requiredInputValue(node.inputs, "labels")));
    try root.put(arena, "annotations", try valueToJson(arena, try requiredInputValue(node.inputs, "annotations")));
    var replication: std.json.ObjectMap = .empty;
    const mode = try requiredInput(node, "replication_mode");
    if (std.mem.eql(u8, mode, "automatic")) {
        var automatic: std.json.ObjectMap = .empty;
        if (inputStringFromValue(node.inputs, "automatic_kms_key_name")) |kms| {
            var encryption: std.json.ObjectMap = .empty;
            try encryption.put(arena, "kmsKeyName", .{ .string = kms });
            try automatic.put(arena, "customerManagedEncryption", .{ .object = encryption });
        }
        try replication.put(arena, "automatic", .{ .object = automatic });
    } else if (std.mem.eql(u8, mode, "user_managed")) {
        const replicas_json = try requiredInput(node, "replicas_json");
        var parsed = std.json.parseFromSlice(std.json.Value, arena, replicas_json, .{}) catch return error.InvalidConfiguration;
        defer parsed.deinit();
        const replicas = jsonArray(parsed.value) orelse return error.InvalidConfiguration;
        var api_replicas: std.json.Array = .init(arena);
        for (replicas.items) |replica_value| {
            const replica = jsonObject(replica_value) orelse return error.InvalidConfiguration;
            var api_replica: std.json.ObjectMap = .empty;
            try api_replica.put(arena, "location", .{ .string = jsonString(replica.get("location")) orelse return error.InvalidConfiguration });
            if (jsonString(replica.get("kms_key_name"))) |kms| {
                var encryption: std.json.ObjectMap = .empty;
                try encryption.put(arena, "kmsKeyName", .{ .string = kms });
                try api_replica.put(arena, "customerManagedEncryption", .{ .object = encryption });
            }
            try api_replicas.append(.{ .object = api_replica });
        }
        var managed: std.json.ObjectMap = .empty;
        try managed.put(arena, "replicas", .{ .array = api_replicas });
        try replication.put(arena, "userManaged", .{ .object = managed });
    } else return error.InvalidConfiguration;
    try root.put(arena, "replication", .{ .object = replication });

    var topics: std.json.Array = .init(arena);
    const topic_values = switch (try requiredInputValue(node.inputs, "topics")) {
        .list => |items| items,
        else => return error.InvalidConfiguration,
    };
    for (topic_values) |topic_value| {
        const topic = switch (topic_value) {
            .string => |text| text,
            else => return error.InvalidConfiguration,
        };
        var entry: std.json.ObjectMap = .empty;
        try entry.put(arena, "name", .{ .string = topic });
        try topics.append(.{ .object = entry });
    }
    try root.put(arena, "topics", .{ .array = topics });

    var aliases: std.json.ObjectMap = .empty;
    const alias_fields = valueObjectFields(try requiredInputValue(node.inputs, "version_aliases")) orelse return error.InvalidConfiguration;
    for (alias_fields) |field| {
        const version = switch (field.value) {
            .integer => |number| number,
            else => return error.InvalidConfiguration,
        };
        const text = try std.fmt.allocPrint(arena, "{d}", .{version});
        try aliases.put(arena, field.name, .{ .string = text });
    }
    try root.put(arena, "versionAliases", .{ .object = aliases });
    if (inputStringFromValue(node.inputs, "next_rotation_time")) |next| {
        const seconds = switch (try requiredInputValue(node.inputs, "rotation_period_seconds")) {
            .integer => |number| number,
            else => return error.InvalidConfiguration,
        };
        const period = try std.fmt.allocPrint(arena, "{d}s", .{seconds});
        var rotation: std.json.ObjectMap = .empty;
        try rotation.put(arena, "nextRotationTime", .{ .string = next });
        try rotation.put(arena, "rotationPeriod", .{ .string = period });
        try root.put(arena, "rotation", .{ .object = rotation });
    }
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = root }, .{}) catch error.OutOfMemory;
}

fn secretUpdateMaskAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode, observed: value.Value) ProviderError![]u8 {
    const fields = [_]struct { input: []const u8, api: []const u8 }{
        .{ .input = "labels", .api = "labels" },
        .{ .input = "annotations", .api = "annotations" },
        .{ .input = "topics", .api = "topics" },
        .{ .input = "next_rotation_time", .api = "rotation" },
        .{ .input = "rotation_period_seconds", .api = "rotation" },
        .{ .input = "version_aliases", .api = "version_aliases" },
    };
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    for (fields) |field| {
        if (!inputChangedOptional(node.inputs, observed, field.input)) continue;
        if (std.mem.indexOf(u8, result.items, field.api) != null) continue;
        if (result.items.len > 0) try result.append(allocator, ',');
        try result.appendSlice(allocator, field.api);
    }
    return result.toOwnedSlice(allocator) catch error.OutOfMemory;
}

fn secretReplicasJsonAlloc(allocator: std.mem.Allocator, input: std.json.Value) ProviderError![]u8 {
    const replicas = jsonArray(input) orelse return error.ProviderBug;
    const Item = struct { location: []const u8, kms: ?[]const u8 };
    const items = try allocator.alloc(Item, replicas.items.len);
    defer allocator.free(items);
    for (replicas.items, 0..) |replica_value, index| {
        const replica = jsonObject(replica_value) orelse return error.ProviderBug;
        const encryption = if (replica.get("customerManagedEncryption")) |entry| jsonObject(entry) else null;
        items[index] = .{ .location = jsonString(replica.get("location")) orelse return error.ProviderBug, .kms = if (encryption) |entry| jsonString(entry.get("kmsKeyName")) else null };
    }
    std.mem.sort(Item, items, {}, struct {
        fn less(_: void, a: Item, b: Item) bool {
            return std.mem.lessThan(u8, a.location, b.location);
        }
    }.less);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var array: std.json.Array = .init(arena);
    for (items) |item| {
        var object: std.json.ObjectMap = .empty;
        try object.put(arena, "location", .{ .string = item.location });
        if (item.kms) |kms| try object.put(arena, "kms_key_name", .{ .string = kms });
        try array.append(.{ .object = object });
    }
    return std.json.Stringify.valueAlloc(allocator, std.json.Value{ .array = array }, .{}) catch error.OutOfMemory;
}

fn secretTopicsValueAlloc(allocator: std.mem.Allocator, input: ?std.json.Value) ProviderError!value.Value {
    const array = if (input) |entry| jsonArray(entry) orelse return error.ProviderBug else return ownValue(allocator, .{ .list = &.{} });
    const values = try allocator.alloc(value.Value, array.items.len);
    defer allocator.free(values);
    for (array.items, 0..) |entry, index| {
        const topic = jsonObject(entry) orelse return error.ProviderBug;
        values[index] = .{ .string = jsonString(topic.get("name")) orelse return error.ProviderBug };
    }
    std.mem.sort(value.Value, values, {}, lessThanValueString);
    return ownValue(allocator, .{ .list = values });
}

fn secretAliasesValueAlloc(allocator: std.mem.Allocator, input: ?std.json.Value) ProviderError!value.Value {
    const object = if (input) |entry| jsonObject(entry) orelse return error.ProviderBug else return ownValue(allocator, .{ .object = &.{} });
    const fields = try allocator.alloc(value.Field, object.count());
    defer allocator.free(fields);
    var iterator = object.iterator();
    var index: usize = 0;
    while (iterator.next()) |entry| : (index += 1) {
        const number = switch (entry.value_ptr.*) {
            .integer => |integer| integer,
            .string => |text| std.fmt.parseInt(i64, text, 10) catch return error.ProviderBug,
            else => return error.ProviderBug,
        };
        fields[index] = .{ .name = entry.key_ptr.*, .value = .{ .integer = number } };
    }
    return ownValue(allocator, .{ .object = fields });
}

fn durationSeconds(text: []const u8) ?i64 {
    if (text.len < 2 or text[text.len - 1] != 's') return null;
    return std.fmt.parseInt(i64, text[0 .. text.len - 1], 10) catch null;
}

fn stateOutputString(outputs: []const state.StateOutput, name: []const u8) ?[]const u8 {
    for (outputs) |entry| if (std.mem.eql(u8, entry.name, name)) return switch (entry.value) {
        .string => |text| text,
        else => null,
    };
    return null;
}

fn secretResultFromJson(
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    body: []const u8,
) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const object = jsonObject(parsed.value) orelse return error.ProviderBug;
    const physical_id = jsonString(object.get("name")) orelse return error.ProviderBug;
    const replication = jsonObject(object.get("replication") orelse return error.ProviderBug) orelse return error.ProviderBug;
    var observed = value.Value.initOwned(allocator, node.inputs) catch |err| return mapValueError(err);
    defer observed.deinit(allocator);
    try replaceInputJson(allocator, &observed, "labels", object.get("labels") orelse .{ .object = std.json.ObjectMap.empty });
    try replaceInputJson(allocator, &observed, "annotations", object.get("annotations") orelse .{ .object = std.json.ObjectMap.empty });
    if (replication.get("automatic")) |automatic_value| {
        try replaceInputString(allocator, &observed, "replication_mode", "automatic");
        if (hasInput(observed, "automatic_kms_key_name")) {
            const automatic = jsonObject(automatic_value) orelse return error.ProviderBug;
            const encryption = if (automatic.get("customerManagedEncryption")) |entry| jsonObject(entry) else null;
            try replaceInputString(allocator, &observed, "automatic_kms_key_name", if (encryption) |entry| jsonString(entry.get("kmsKeyName")) orelse "" else "");
        }
    } else if (replication.get("userManaged")) |managed_value| {
        try replaceInputString(allocator, &observed, "replication_mode", "user_managed");
        const managed = jsonObject(managed_value) orelse return error.ProviderBug;
        const normalized = try secretReplicasJsonAlloc(allocator, managed.get("replicas") orelse return error.ProviderBug);
        defer allocator.free(normalized);
        try replaceInputString(allocator, &observed, "replicas_json", normalized);
    } else return error.ProviderBug;
    var topics = try secretTopicsValueAlloc(allocator, object.get("topics"));
    defer topics.deinit(allocator);
    try replaceInputValue(allocator, &observed, "topics", topics);
    var aliases = try secretAliasesValueAlloc(allocator, object.get("versionAliases"));
    defer aliases.deinit(allocator);
    try replaceInputValue(allocator, &observed, "version_aliases", aliases);
    if (hasInput(observed, "next_rotation_time")) {
        const rotation = if (object.get("rotation")) |entry| jsonObject(entry) else null;
        try replaceInputString(allocator, &observed, "next_rotation_time", if (rotation) |entry| jsonString(entry.get("nextRotationTime")) orelse "" else "");
        try replaceInputValue(allocator, &observed, "rotation_period_seconds", .{ .integer = if (rotation) |entry| durationSeconds(jsonString(entry.get("rotationPeriod")) orelse "") orelse 0 else 0 });
    }
    const etag = jsonString(object.get("etag")) orelse "";
    const outputs = [_]state.StateOutput{
        .{ .name = "resource_name", .value = .{ .string = physical_id } },
        .{ .name = "etag", .value = .{ .string = etag } },
    };
    return provider_mod.ResourceResult.init(allocator, physical_id, observed, &outputs, null);
}

fn secretVersionResultFromJson(
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    body: []const u8,
) ProviderError!provider_mod.ResourceResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.ProviderBug;
    defer parsed.deinit();
    const object = jsonObject(parsed.value) orelse return error.ProviderBug;
    const physical_id = jsonString(object.get("name")) orelse return error.ProviderBug;
    const marker = "/versions/";
    const version_index = std.mem.lastIndexOf(u8, physical_id, marker) orelse return error.ProviderBug;
    const secret_name = physical_id[0..version_index];
    const version = physical_id[version_index + marker.len ..];
    if (version.len == 0) return error.ProviderBug;
    const remote_state = jsonString(object.get("state")) orelse "ENABLED";
    var observed = value.Value.initOwned(allocator, node.inputs) catch |err| return mapValueError(err);
    defer observed.deinit(allocator);
    try replaceInputString(allocator, &observed, "state", remote_state);
    const outputs = [_]state.StateOutput{
        .{ .name = "version", .value = .{ .secret_ref = .{
            .provider = "gcp-secret-manager",
            .resource = secret_name,
            .version = version,
        } } },
        .{ .name = "state", .value = .{ .string = remote_state } },
    };
    return provider_mod.ResourceResult.init(allocator, physical_id, observed, &outputs, null);
}

fn secretIamMemberResult(
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
) ProviderError!provider_mod.ResourceResult {
    const secret_name = try secretNameAlloc(allocator, node);
    defer allocator.free(secret_name);
    const name = try requiredInput(node, "name");
    const role = try requiredInput(node, "role");
    const member = try requiredInput(node, "member");
    const physical_id = try std.fmt.allocPrint(allocator, "{s}/iam/{s}", .{ secret_name, name });
    defer allocator.free(physical_id);
    const binding_id = try std.fmt.allocPrint(allocator, "{s}|{s}|{s}", .{ secret_name, role, member });
    defer allocator.free(binding_id);
    const outputs = [_]state.StateOutput{
        .{ .name = "binding_id", .value = .{ .string = binding_id } },
    };
    return provider_mod.ResourceResult.init(allocator, physical_id, node.inputs, &outputs, null);
}

fn jsonLabelFieldsAlloc(
    allocator: std.mem.Allocator,
    label_object: std.json.ObjectMap,
) ProviderError![]value.Field {
    const label_fields = try allocator.alloc(value.Field, label_object.count());
    var iterator = label_object.iterator();
    var label_index: usize = 0;
    while (iterator.next()) |entry| : (label_index += 1) {
        const label_value = jsonString(entry.value_ptr.*) orelse return error.ProviderBug;
        label_fields[label_index] = .{ .name = entry.key_ptr.*, .value = .{ .string = label_value } };
    }
    return label_fields;
}

fn projectMemberResult(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError!provider_mod.ResourceResult {
    const project_id = try requiredInput(node, "project_id");
    const name = try requiredInput(node, "name");
    const role = try requiredInput(node, "role");
    const member = try requiredInput(node, "member");
    const physical_id = try std.fmt.allocPrint(allocator, "projects/{s}/iam/{s}", .{ project_id, name });
    defer allocator.free(physical_id);
    const binding_id = try std.fmt.allocPrint(allocator, "{s}|{s}|{s}", .{ project_id, role, member });
    defer allocator.free(binding_id);
    const outputs = [_]state.StateOutput{
        .{ .name = "binding_id", .value = .{ .string = binding_id } },
    };
    return provider_mod.ResourceResult.init(allocator, physical_id, node.inputs, &outputs, null);
}

fn policyHasMember(policy: std.json.Value, role: []const u8, member: []const u8) bool {
    const object = jsonObject(policy) orelse return false;
    const bindings_value = object.get("bindings") orelse return false;
    const bindings = switch (bindings_value) {
        .array => |array| array.items,
        else => return false,
    };
    for (bindings) |binding_value| {
        const binding = jsonObject(binding_value) orelse continue;
        if (binding.get("condition") != null) continue;
        const binding_role = jsonString(binding.get("role")) orelse continue;
        if (!std.mem.eql(u8, binding_role, role)) continue;
        const members_value = binding.get("members") orelse continue;
        const members = switch (members_value) {
            .array => |array| array.items,
            else => continue,
        };
        for (members) |member_value| {
            const candidate = jsonString(member_value) orelse continue;
            if (std.mem.eql(u8, candidate, member)) return true;
        }
    }
    return false;
}

fn mutatePolicy(
    parsed: *std.json.Parsed(std.json.Value),
    role: []const u8,
    member: []const u8,
    should_exist: bool,
) ProviderError!bool {
    const allocator = parsed.arena.allocator();
    const root = switch (parsed.value) {
        .object => |*object| object,
        else => return error.ProviderBug,
    };
    var bindings_value = root.getPtr("bindings");
    if (bindings_value == null) {
        if (!should_exist) return false;
        try root.put(allocator, "bindings", .{ .array = std.json.Array.init(allocator) });
        bindings_value = root.getPtr("bindings");
    }
    const bindings = switch (bindings_value.?.*) {
        .array => |*array| array,
        else => return error.ProviderBug,
    };

    for (bindings.items, 0..) |*binding_value, binding_index| {
        const binding = switch (binding_value.*) {
            .object => |*object| object,
            else => continue,
        };
        if (binding.get("condition") != null) continue;
        const binding_role = jsonString(binding.get("role")) orelse continue;
        if (!std.mem.eql(u8, binding_role, role)) continue;
        const members_value = binding.getPtr("members") orelse continue;
        const members = switch (members_value.*) {
            .array => |*array| array,
            else => continue,
        };
        for (members.items, 0..) |member_value, member_index| {
            const candidate = jsonString(member_value) orelse continue;
            if (!std.mem.eql(u8, candidate, member)) continue;
            if (should_exist) return false;
            _ = members.orderedRemove(member_index);
            if (members.items.len == 0) _ = bindings.orderedRemove(binding_index);
            return true;
        }
        if (!should_exist) return false;
        try members.append(.{ .string = member });
        return true;
    }

    if (!should_exist) return false;
    var members = std.json.Array.init(allocator);
    try members.append(.{ .string = member });
    var binding: std.json.ObjectMap = .empty;
    try binding.put(allocator, "role", .{ .string = role });
    try binding.put(allocator, "members", .{ .array = members });
    try bindings.append(.{ .object = binding });
    return true;
}

fn projectServiceNameAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]const u8 {
    const project_id = try requiredInput(node, "project_id");
    const service = try requiredInput(node, "service");
    return std.fmt.allocPrint(allocator, "projects/{s}/services/{s}", .{ project_id, service }) catch return error.OutOfMemory;
}

fn serviceAccountNameAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]const u8 {
    const project_id = try requiredInput(node, "project_id");
    const account_id = try requiredInput(node, "account_id");
    return std.fmt.allocPrint(
        allocator,
        "projects/{s}/serviceAccounts/{s}@{s}.iam.gserviceaccount.com",
        .{ project_id, account_id, project_id },
    ) catch return error.OutOfMemory;
}

fn artifactRepositoryNameAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]const u8 {
    const project_id = try requiredInput(node, "project_id");
    const location = try requiredInput(node, "location");
    const name = try requiredInput(node, "name");
    return std.fmt.allocPrint(
        allocator,
        "projects/{s}/locations/{s}/repositories/{s}",
        .{ project_id, location, name },
    ) catch return error.OutOfMemory;
}

fn secretNameAlloc(allocator: std.mem.Allocator, node: resource.ResourceNode) ProviderError![]const u8 {
    const project_id = try requiredInput(node, "project_id");
    const secret_id = inputStringFromValue(node.inputs, "secret_id") orelse
        inputStringFromValue(node.inputs, "name") orelse return error.InvalidConfiguration;
    return std.fmt.allocPrint(allocator, "projects/{s}/secrets/{s}", .{ project_id, secret_id }) catch return error.OutOfMemory;
}

fn artifactRepositoryDiff(node: resource.ResourceNode, observed: value.Value) provider_mod.DiffKind {
    for ([_][]const u8{ "project_id", "location", "name", "format" }) |field| {
        if (inputChanged(node.inputs, observed, field)) return .replace;
    }
    if (node.schema_version >= 2) for ([_][]const u8{ "kms_key_name", "mode" }) |field| if (inputChanged(node.inputs, observed, field)) return .replace;
    return .update;
}

fn secretDiff(node: resource.ResourceNode, observed: value.Value) provider_mod.DiffKind {
    for ([_][]const u8{ "project_id", "name" }) |field| {
        const desired_value = inputStringFromValue(node.inputs, field) orelse return .replace;
        const observed_value = inputStringFromValue(observed, field) orelse return .replace;
        if (!std.mem.eql(u8, desired_value, observed_value)) return .replace;
    }
    if (node.schema_version >= 2) for ([_][]const u8{ "replication_mode", "automatic_kms_key_name", "replicas_json" }) |field| {
        if (inputChangedOptional(node.inputs, observed, field)) return .replace;
    };
    return .update;
}

fn secretVersionDiff(node: resource.ResourceNode, observed: value.Value) provider_mod.DiffKind {
    for ([_][]const u8{ "project_id", "secret_id", "source" }) |field| if (inputChanged(node.inputs, observed, field)) return .replace;
    return .update;
}

fn cleanupPoliciesToJson(allocator: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    const policies = switch (input) {
        .list => |items| items,
        else => return error.InvalidConfiguration,
    };
    var result = std.json.ObjectMap.empty;
    for (policies) |policy_value| {
        const policy = valueObjectFields(policy_value) orelse return error.InvalidConfiguration;
        const name = valueFieldString(policy, "name") orelse return error.InvalidConfiguration;
        const rule = valueObjectFields(valueField(policy, "rule") orelse return error.InvalidConfiguration) orelse return error.InvalidConfiguration;
        const kind = valueFieldString(rule, "kind") orelse return error.InvalidConfiguration;
        const action = valueFieldString(rule, "action") orelse return error.InvalidConfiguration;
        var encoded = std.json.ObjectMap.empty;
        try encoded.put(allocator, "id", .{ .string = name });
        try encoded.put(allocator, "action", .{ .string = action });
        if (std.mem.eql(u8, kind, "condition")) {
            var condition = std.json.ObjectMap.empty;
            try condition.put(allocator, "tagState", .{ .string = valueFieldString(rule, "tag_state") orelse return error.InvalidConfiguration });
            const older = valueFieldInteger(rule, "older_than_seconds") orelse return error.InvalidConfiguration;
            if (older > 0) try condition.put(allocator, "olderThan", .{ .string = try std.fmt.allocPrint(allocator, "{d}s", .{older}) });
            const newer = valueFieldInteger(rule, "newer_than_seconds") orelse return error.InvalidConfiguration;
            if (newer > 0) try condition.put(allocator, "newerThan", .{ .string = try std.fmt.allocPrint(allocator, "{d}s", .{newer}) });
            try condition.put(allocator, "packageNamePrefixes", try valueToJson(allocator, valueField(rule, "package_prefixes") orelse return error.InvalidConfiguration));
            try condition.put(allocator, "versionNamePrefixes", try valueToJson(allocator, valueField(rule, "version_prefixes") orelse return error.InvalidConfiguration));
            try condition.put(allocator, "tagPrefixes", try valueToJson(allocator, valueField(rule, "tag_prefixes") orelse return error.InvalidConfiguration));
            try encoded.put(allocator, "condition", .{ .object = condition });
        } else if (std.mem.eql(u8, kind, "most_recent")) {
            var recent = std.json.ObjectMap.empty;
            try recent.put(allocator, "packageNamePrefixes", try valueToJson(allocator, valueField(rule, "package_prefixes") orelse return error.InvalidConfiguration));
            try recent.put(allocator, "keepCount", .{ .integer = valueFieldInteger(rule, "count") orelse return error.InvalidConfiguration });
            try encoded.put(allocator, "mostRecentVersions", .{ .object = recent });
        } else return error.InvalidConfiguration;
        try result.put(allocator, name, .{ .object = encoded });
    }
    return .{ .object = result };
}

fn cleanupPoliciesFromJsonAlloc(allocator: std.mem.Allocator, input: std.json.Value) ProviderError!value.Value {
    const object = jsonObject(input) orelse return error.ProviderBug;
    const names = try allocator.alloc([]const u8, object.count());
    defer allocator.free(names);
    var iterator = object.iterator();
    var name_index: usize = 0;
    while (iterator.next()) |entry| : (name_index += 1) names[name_index] = entry.key_ptr.*;
    std.mem.sort([]const u8, names, {}, lessThanString);
    const policies = try allocator.alloc(value.Value, names.len);
    defer allocator.free(policies);
    var initialized: usize = 0;
    defer for (policies[0..initialized]) |*policy| policy.deinit(allocator);
    for (names, 0..) |name, index| {
        const encoded = jsonObject(object.get(name) orelse return error.ProviderBug) orelse return error.ProviderBug;
        const action = jsonString(encoded.get("action")) orelse return error.ProviderBug;
        var rule: value.Value = undefined;
        if (encoded.get("condition")) |condition_value| {
            const condition = jsonObject(condition_value) orelse return error.ProviderBug;
            var packages = try jsonStringArrayValueAlloc(allocator, condition.get("packageNamePrefixes"));
            defer packages.deinit(allocator);
            var versions = try jsonStringArrayValueAlloc(allocator, condition.get("versionNamePrefixes"));
            defer versions.deinit(allocator);
            var tags = try jsonStringArrayValueAlloc(allocator, condition.get("tagPrefixes"));
            defer tags.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "action", .value = .{ .string = action } },
                .{ .name = "kind", .value = .{ .string = "condition" } },
                .{ .name = "newer_than_seconds", .value = .{ .integer = jsonDurationSeconds(condition.get("newerThan")) orelse 0 } },
                .{ .name = "older_than_seconds", .value = .{ .integer = jsonDurationSeconds(condition.get("olderThan")) orelse 0 } },
                .{ .name = "package_prefixes", .value = packages },
                .{ .name = "tag_prefixes", .value = tags },
                .{ .name = "tag_state", .value = .{ .string = jsonString(condition.get("tagState")) orelse "ANY" } },
                .{ .name = "version_prefixes", .value = versions },
            };
            rule = try ownValue(allocator, .{ .object = &fields });
        } else if (encoded.get("mostRecentVersions")) |recent_value| {
            const recent = jsonObject(recent_value) orelse return error.ProviderBug;
            var packages = try jsonStringArrayValueAlloc(allocator, recent.get("packageNamePrefixes"));
            defer packages.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "action", .value = .{ .string = action } },
                .{ .name = "count", .value = .{ .integer = jsonI64(recent.get("keepCount")) orelse return error.ProviderBug } },
                .{ .name = "kind", .value = .{ .string = "most_recent" } },
                .{ .name = "package_prefixes", .value = packages },
            };
            rule = try ownValue(allocator, .{ .object = &fields });
        } else return error.ProviderBug;
        defer rule.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "name", .value = .{ .string = name } },
            .{ .name = "rule", .value = rule },
        };
        policies[index] = try ownValue(allocator, .{ .object = &fields });
        initialized += 1;
    }
    return ownValue(allocator, .{ .list = policies });
}

fn jsonStringArrayValueAlloc(allocator: std.mem.Allocator, input: ?std.json.Value) ProviderError!value.Value {
    const array = switch (input orelse return ownValue(allocator, .{ .list = &.{} })) {
        .array => |items| items.items,
        else => return error.ProviderBug,
    };
    const values = try allocator.alloc(value.Value, array.len);
    defer allocator.free(values);
    for (array, 0..) |item, index| values[index] = .{ .string = jsonString(item) orelse return error.ProviderBug };
    return ownValue(allocator, .{ .list = values });
}

fn valueToJson(allocator: std.mem.Allocator, input: value.Value) ProviderError!std.json.Value {
    return switch (input) {
        .string => |text| .{ .string = text },
        .integer => |number| .{ .integer = number },
        .boolean => |flag| .{ .bool = flag },
        .list => |items| blk: {
            var array = std.json.Array.init(allocator);
            for (items) |item| try array.append(try valueToJson(allocator, item));
            break :blk .{ .array = array };
        },
        .object => |fields| blk: {
            var object = std.json.ObjectMap.empty;
            for (fields) |field| try object.put(allocator, field.name, try valueToJson(allocator, field.value));
            break :blk .{ .object = object };
        },
        else => error.InvalidConfiguration,
    };
}

fn jsonToValueAlloc(allocator: std.mem.Allocator, input: std.json.Value) ProviderError!value.Value {
    return switch (input) {
        .string => |text| ownValue(allocator, .{ .string = text }),
        .integer => |number| ownValue(allocator, .{ .integer = number }),
        .bool => |flag| ownValue(allocator, .{ .boolean = flag }),
        .array => |array| blk: {
            const items = try allocator.alloc(value.Value, array.items.len);
            defer allocator.free(items);
            var initialized: usize = 0;
            defer for (items[0..initialized]) |*item| item.deinit(allocator);
            for (array.items, 0..) |item, index| {
                items[index] = try jsonToValueAlloc(allocator, item);
                initialized += 1;
            }
            break :blk try ownValue(allocator, .{ .list = items });
        },
        .object => |object| blk: {
            const fields = try allocator.alloc(value.Field, object.count());
            defer allocator.free(fields);
            var iterator = object.iterator();
            var index: usize = 0;
            defer for (fields[0..index]) |*field| field.value.deinit(allocator);
            while (iterator.next()) |entry| : (index += 1) fields[index] = .{ .name = entry.key_ptr.*, .value = try jsonToValueAlloc(allocator, entry.value_ptr.*) };
            break :blk try ownValue(allocator, .{ .object = fields });
        },
        else => error.ProviderBug,
    };
}

fn replaceInputJson(allocator: std.mem.Allocator, inputs: *value.Value, name: []const u8, replacement: std.json.Value) ProviderError!void {
    var converted = try jsonToValueAlloc(allocator, replacement);
    defer converted.deinit(allocator);
    return replaceInputValue(allocator, inputs, name, converted);
}

fn replaceInputString(allocator: std.mem.Allocator, inputs: *value.Value, name: []const u8, replacement: []const u8) ProviderError!void {
    return replaceInputValue(allocator, inputs, name, .{ .string = replacement });
}

fn replaceInputBoolean(allocator: std.mem.Allocator, inputs: *value.Value, name: []const u8, replacement: bool) ProviderError!void {
    return replaceInputValue(allocator, inputs, name, .{ .boolean = replacement });
}

fn replaceInputValue(allocator: std.mem.Allocator, inputs: *value.Value, name: []const u8, replacement: value.Value) ProviderError!void {
    if (inputs.* != .object) return error.ProviderBug;
    const fields: []value.Field = @constCast(inputs.object);
    for (fields) |*field| {
        if (!std.mem.eql(u8, field.name, name)) continue;
        const owned = try ownValue(allocator, replacement);
        field.value.deinit(allocator);
        field.value = owned;
        return;
    }
    return error.ProviderBug;
}

fn ownValue(allocator: std.mem.Allocator, input: value.Value) ProviderError!value.Value {
    return value.Value.initOwned(allocator, input) catch |err| switch (err) {
        error.DuplicateField => error.ProviderBug,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn mapValueError(err: value.ValueError) ProviderError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateField => error.ProviderBug,
    };
}

fn requiredInputValue(inputs: value.Value, name: []const u8) ProviderError!value.Value {
    return valueField(valueObjectFields(inputs) orelse return error.InvalidConfiguration, name) orelse error.InvalidConfiguration;
}

fn requiredInputBoolean(inputs: value.Value, name: []const u8) ProviderError!bool {
    return switch (try requiredInputValue(inputs, name)) {
        .boolean => |flag| flag,
        else => error.InvalidConfiguration,
    };
}

fn resolvedInputString(context: *provider_mod.OperationContext, inputs: value.Value, name: []const u8) ProviderError![]const u8 {
    return switch (try requiredInputValue(inputs, name)) {
        .string => |text| text,
        .output_ref => |reference| context.resolveOutputString(reference),
        else => error.InvalidConfiguration,
    };
}

fn inputChanged(desired: value.Value, observed: value.Value, name: []const u8) bool {
    const left = requiredInputValue(desired, name) catch return true;
    const right = requiredInputValue(observed, name) catch return true;
    const left_hash = left.sha256(std.heap.page_allocator) catch return true;
    const right_hash = right.sha256(std.heap.page_allocator) catch return true;
    return !std.mem.eql(u8, &left_hash, &right_hash);
}

fn inputChangedOptional(desired: value.Value, observed: value.Value, name: []const u8) bool {
    const left = requiredInputValue(desired, name) catch null;
    const right = requiredInputValue(observed, name) catch null;
    if (left == null or right == null) return left != null or right != null;
    const left_hash = left.?.sha256(std.heap.page_allocator) catch return true;
    const right_hash = right.?.sha256(std.heap.page_allocator) catch return true;
    return !std.mem.eql(u8, &left_hash, &right_hash);
}

fn hasInput(inputs: value.Value, name: []const u8) bool {
    _ = requiredInputValue(inputs, name) catch return false;
    return true;
}

fn valueObjectFields(input: value.Value) ?[]const value.Field {
    return switch (input) {
        .object => |fields| fields,
        else => null,
    };
}

fn valueField(fields: []const value.Field, name: []const u8) ?value.Value {
    for (fields) |field| if (std.mem.eql(u8, field.name, name)) return field.value;
    return null;
}

fn valueFieldString(fields: []const value.Field, name: []const u8) ?[]const u8 {
    return switch (valueField(fields, name) orelse return null) {
        .string => |text| text,
        else => null,
    };
}

fn valueFieldInteger(fields: []const value.Field, name: []const u8) ?i64 {
    return switch (valueField(fields, name) orelse return null) {
        .integer => |number| number,
        else => null,
    };
}

fn jsonBooleanValue(input: ?std.json.Value) ?bool {
    return switch (input orelse return null) {
        .bool => |flag| flag,
        else => null,
    };
}

fn jsonI64(input: ?std.json.Value) ?i64 {
    return switch (input orelse return null) {
        .integer => |number| number,
        .string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
}

fn jsonDurationSeconds(input: ?std.json.Value) ?i64 {
    const text = jsonString(input) orelse return null;
    if (!std.mem.endsWith(u8, text, "s")) return null;
    return std.fmt.parseInt(i64, text[0 .. text.len - 1], 10) catch null;
}

fn artifactFormatSlug(format: []const u8) ?[]const u8 {
    const formats = [_]struct { api: []const u8, slug: []const u8 }{
        .{ .api = "APT", .slug = "apt" },
        .{ .api = "DOCKER", .slug = "docker" },
        .{ .api = "GENERIC", .slug = "generic" },
        .{ .api = "GO", .slug = "go" },
        .{ .api = "GOOGET", .slug = "googet" },
        .{ .api = "KFP", .slug = "kfp" },
        .{ .api = "MAVEN", .slug = "maven" },
        .{ .api = "NPM", .slug = "npm" },
        .{ .api = "PYTHON", .slug = "python" },
        .{ .api = "RUBY", .slug = "ruby" },
        .{ .api = "YUM", .slug = "yum" },
    };
    for (formats) |candidate| if (std.mem.eql(u8, candidate.api, format)) return candidate.slug;
    return null;
}

fn percentEncodeAlloc(allocator: std.mem.Allocator, input: []const u8) ProviderError![]const u8 {
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (input) |byte| if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') try output.append(allocator, byte) else {
        try output.append(allocator, '%');
        try output.append(allocator, hex[byte >> 4]);
        try output.append(allocator, hex[byte & 0x0f]);
    };
    return output.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

fn inputJsonAlloc(
    allocator: std.mem.Allocator,
    node: resource.ResourceNode,
    name: []const u8,
) ProviderError![]const u8 {
    const fields = switch (node.inputs) {
        .object => |fields| fields,
        else => return error.InvalidConfiguration,
    };
    for (fields) |field| {
        if (!std.mem.eql(u8, field.name, name)) continue;
        return field.value.canonicalJsonAlloc(allocator) catch |err| switch (err) {
            error.DuplicateField => error.InvalidConfiguration,
            error.OutOfMemory => error.OutOfMemory,
        };
    }
    return error.InvalidConfiguration;
}

fn requiredInput(node: resource.ResourceNode, name: []const u8) ProviderError![]const u8 {
    return inputStringFromValue(node.inputs, name) orelse error.InvalidConfiguration;
}

fn requiredSecretInput(node: resource.ResourceNode, name: []const u8) ProviderError!value.SecretReference {
    const fields = switch (node.inputs) {
        .object => |fields| fields,
        else => return error.InvalidConfiguration,
    };
    for (fields) |field| {
        if (!std.mem.eql(u8, field.name, name)) continue;
        return switch (field.value) {
            .secret_ref => |reference| reference,
            else => error.InvalidConfiguration,
        };
    }
    return error.InvalidConfiguration;
}

fn inputStringFromValue(input: value.Value, name: []const u8) ?[]const u8 {
    const fields = switch (input) {
        .object => |fields| fields,
        else => return null,
    };
    for (fields) |field| {
        if (!std.mem.eql(u8, field.name, name)) continue;
        return switch (field.value) {
            .string => |text| text,
            else => null,
        };
    }
    return null;
}

fn jsonObject(json_value: std.json.Value) ?std.json.ObjectMap {
    return switch (json_value) {
        .object => |object| object,
        else => null,
    };
}

fn jsonArray(json_value: std.json.Value) ?std.json.Array {
    return switch (json_value) {
        .array => |array| array,
        else => null,
    };
}

fn lessThanValueString(_: void, left: value.Value, right: value.Value) bool {
    const left_text = switch (left) {
        .string => |text| text,
        else => "",
    };
    const right_text = switch (right) {
        .string => |text| text,
        else => "",
    };
    return std.mem.lessThan(u8, left_text, right_text);
}

fn jsonString(json_value: ?std.json.Value) ?[]const u8 {
    const present = json_value orelse return null;
    return switch (present) {
        .string => |text| text,
        else => null,
    };
}

fn isType(node: resource.ResourceNode, expected: []const u8) bool {
    return std.mem.eql(u8, node.type_name, expected);
}

pub fn supports(node: resource.ResourceNode) bool {
    return supportsType(node.type_name);
}

pub fn supportsType(type_name: []const u8) bool {
    for (managed_type_names) |candidate| if (std.mem.eql(u8, candidate, type_name)) return true;
    return false;
}

fn isSupported(node: resource.ResourceNode) bool {
    return supports(node);
}
