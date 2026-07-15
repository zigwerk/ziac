const std = @import("std");
const config_mod = @import("config.zig");
const data_pipelines = @import("data_pipelines.zig");
const dataform = @import("dataform.zig");
const dataproc = @import("dataproc.zig");
const iam = @import("iam.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");

pub const BuildError = config_mod.ValidationError || data_pipelines.BuildError || dataform.BuildError || dataproc.BuildError || iam.BuildError || resource.ResourceGraphError || std.mem.Allocator.Error || error{InvalidComponent};

pub const ScheduledDataflowPipelineArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    pipeline: data_pipelines.PipelineArgs,
    scheduler_member: []const u8,
    worker_member: []const u8,
};

pub const ScheduledDataflowPipeline = struct {
    graph: resource.ResourceGraph,
    pipeline: data_pipelines.Pipeline.Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ScheduledDataflowPipelineArgs) BuildError!ScheduledDataflowPipeline {
        if (args.pipeline.schedule == null or args.pipeline.scheduler_service_account_email == null) return error.InvalidComponent;
        const expected_scheduler = try std.fmt.allocPrint(allocator, "serviceAccount:{s}", .{args.pipeline.scheduler_service_account_email.?});
        defer allocator.free(expected_scheduler);
        if (!std.mem.eql(u8, expected_scheduler, args.scheduler_member) or !std.mem.startsWith(u8, args.worker_member, "serviceAccount:")) return error.InvalidComponent;
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);

        var pipeline = try data_pipelines.Pipeline.build(allocator, provider, args.pipeline);
        defer pipeline.deinit(allocator);
        try graph.addResource(pipeline.node);
        const pipeline_id = graph.resources.items[graph.resources.items.len - 1].id;

        const grants = [_]struct { suffix: []const u8, role: []const u8, member: []const u8 }{
            .{ .suffix = "scheduler-dataflow", .role = "roles/dataflow.developer", .member = args.scheduler_member },
            .{ .suffix = "scheduler-act-as", .role = "roles/iam.serviceAccountUser", .member = args.scheduler_member },
            .{ .suffix = "worker-runtime", .role = "roles/dataflow.worker", .member = args.worker_member },
        };
        for (grants) |grant| {
            const name = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ args.pipeline.name, grant.suffix });
            defer allocator.free(name);
            var member = try iam.ProjectMember.build(allocator, provider, .{ .name = name, .role = grant.role, .member = grant.member });
            defer member.deinit(allocator);
            try graph.addResource(member.node);
        }
        try graph.validateAcyclic();
        return .{ .graph = graph, .pipeline = data_pipelines.Pipeline.Outputs.Name.fromResource(pipeline_id) };
    }

    pub fn deinit(self: *ScheduledDataflowPipeline) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

pub const DataprocWorkflowPlatformArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    autoscaling: dataproc.AutoscalingPolicyArgs,
    cluster: ?dataproc.ClusterArgs = null,
    workflow: dataproc.WorkflowTemplateArgs,
    operators: []const []const u8 = &.{},
};

pub const DataprocWorkflowPlatform = struct {
    graph: resource.ResourceGraph,
    autoscaling_policy: dataproc.AutoscalingPolicy.Outputs.Name.OutputType,
    cluster: ?dataproc.Cluster.Outputs.Name.OutputType,
    workflow: dataproc.WorkflowTemplate.Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: DataprocWorkflowPlatformArgs) BuildError!DataprocWorkflowPlatform {
        if (!std.mem.eql(u8, args.autoscaling.region, args.workflow.region)) return error.InvalidComponent;
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);

        var scaling = try dataproc.AutoscalingPolicy.build(allocator, provider, args.autoscaling);
        defer scaling.deinit(allocator);
        try graph.addResource(scaling.node);
        const scaling_id = graph.resources.items[graph.resources.items.len - 1].id;
        const scaling_output = dataproc.AutoscalingPolicy.Outputs.Name.fromResource(scaling_id);

        var cluster_output: ?output.Output([]const u8, .public) = null;
        if (args.cluster) |selected| {
            if (!std.mem.eql(u8, selected.region, args.workflow.region)) return error.InvalidComponent;
            var cluster_args = selected;
            cluster_args.autoscaling_policy = scaling_output;
            var cluster = try dataproc.Cluster.build(allocator, provider, cluster_args);
            defer cluster.deinit(allocator);
            try graph.addResource(cluster.node);
            cluster_output = dataproc.Cluster.Outputs.Name.fromResource(graph.resources.items[graph.resources.items.len - 1].id);
        }

        var workflow_args = args.workflow;
        if (cluster_output) |selected| workflow_args.placement = .{ .cluster = selected };
        var workflow = try dataproc.WorkflowTemplate.build(allocator, provider, workflow_args);
        defer workflow.deinit(allocator);
        try graph.addResource(workflow.node);
        const workflow_id = graph.resources.items[graph.resources.items.len - 1].id;
        const workflow_output = dataproc.WorkflowTemplate.Outputs.Name.fromResource(workflow_id);

        for (args.operators, 0..) |operator, index| {
            if (cluster_output) |cluster_name| {
                const name = try std.fmt.allocPrint(allocator, "{s}-cluster-operator-{d}", .{ args.workflow.name, index + 1 });
                defer allocator.free(name);
                var member = try dataproc.ClusterIamMember.build(allocator, provider, .{ .name = name, .resource = cluster_name, .role = "roles/dataproc.editor", .member = operator });
                defer member.deinit(allocator);
                try graph.addResource(member.node);
            }
            const name = try std.fmt.allocPrint(allocator, "{s}-workflow-operator-{d}", .{ args.workflow.name, index + 1 });
            defer allocator.free(name);
            var member = try dataproc.WorkflowTemplateIamMember.build(allocator, provider, .{ .name = name, .resource = workflow_output, .role = "roles/dataproc.editor", .member = operator });
            defer member.deinit(allocator);
            try graph.addResource(member.node);
        }
        try graph.validateAcyclic();
        return .{ .graph = graph, .autoscaling_policy = scaling_output, .cluster = cluster_output, .workflow = workflow_output };
    }

    pub fn deinit(self: *DataprocWorkflowPlatform) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

pub const DataformReleasePipelineArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    repository: dataform.RepositoryArgs,
    release: dataform.ReleaseConfigArgs,
    workflow: dataform.WorkflowConfigArgs,
    workspace_name: ?[]const u8 = null,
    operators: []const []const u8 = &.{},
};

pub const DataformReleasePipeline = struct {
    graph: resource.ResourceGraph,
    repository: dataform.Repository.Outputs.Name.OutputType,
    release: dataform.ReleaseConfig.Outputs.Name.OutputType,
    workflow: dataform.WorkflowConfig.Outputs.Name.OutputType,
    workspace: ?dataform.Workspace.Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: DataformReleasePipelineArgs) BuildError!DataformReleasePipeline {
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);

        var repository = try dataform.Repository.build(allocator, provider, args.repository);
        defer repository.deinit(allocator);
        try graph.addResource(repository.node);
        const repository_id = graph.resources.items[graph.resources.items.len - 1].id;
        const repository_output = dataform.Repository.Outputs.Name.fromResource(repository_id);

        var release_args = args.release;
        release_args.repository = repository_output;
        var release = try dataform.ReleaseConfig.build(allocator, provider, release_args);
        defer release.deinit(allocator);
        try graph.addResource(release.node);
        const release_id = graph.resources.items[graph.resources.items.len - 1].id;
        const release_output = dataform.ReleaseConfig.Outputs.Name.fromResource(release_id);

        var workflow_args = args.workflow;
        workflow_args.repository = repository_output;
        workflow_args.release_config = release_output;
        var workflow = try dataform.WorkflowConfig.build(allocator, provider, workflow_args);
        defer workflow.deinit(allocator);
        try graph.addResource(workflow.node);
        const workflow_id = graph.resources.items[graph.resources.items.len - 1].id;
        const workflow_output = dataform.WorkflowConfig.Outputs.Name.fromResource(workflow_id);

        var workspace_output: ?output.Output([]const u8, .public) = null;
        if (args.workspace_name) |name| {
            var workspace = try dataform.Workspace.build(allocator, provider, .{ .name = name, .repository = repository_output });
            defer workspace.deinit(allocator);
            try graph.addResource(workspace.node);
            workspace_output = dataform.Workspace.Outputs.Name.fromResource(graph.resources.items[graph.resources.items.len - 1].id);
        }

        for (args.operators, 0..) |operator, index| {
            const name = try std.fmt.allocPrint(allocator, "{s}-operator-{d}", .{ args.repository.name, index + 1 });
            defer allocator.free(name);
            var member = try dataform.RepositoryIamMember.build(allocator, provider, .{ .name = name, .resource = repository_output, .role = "roles/dataform.editor", .member = operator });
            defer member.deinit(allocator);
            try graph.addResource(member.node);
        }
        try graph.validateAcyclic();
        return .{ .graph = graph, .repository = repository_output, .release = release_output, .workflow = workflow_output, .workspace = workspace_output };
    }

    pub fn deinit(self: *DataformReleasePipeline) void {
        self.graph.deinit();
        self.* = undefined;
    }
};
