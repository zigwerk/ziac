const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    DuplicateKey,
    DuplicateRule,
    DuplicateStage,
    DuplicateUsage,
    InvalidAutomation,
    InvalidCanary,
    InvalidDescription,
    InvalidDuration,
    InvalidExecution,
    InvalidName,
    InvalidPolicy,
    InvalidRegion,
    InvalidServiceAccount,
    InvalidTarget,
    InvalidTimeWindow,
    InvalidValue,
    OutputNotKnown,
};

pub const KeyValue = struct { key: []const u8, value: []const u8 };

pub const StandardStrategy = struct {
    verify: bool = false,
    predeploy_actions: []const []const u8 = &.{},
    postdeploy_actions: []const []const u8 = &.{},
};

pub const CanaryStrategy = struct {
    percentages: []const u8,
    verify: bool = false,
    predeploy_actions: []const []const u8 = &.{},
    postdeploy_actions: []const []const u8 = &.{},
};

pub const CanaryPhase = struct {
    id: []const u8,
    percentage: u8,
    profiles: []const []const u8 = &.{},
    verify: bool = false,
};

pub const CustomCanaryStrategy = struct {
    phases: []const CanaryPhase,
};

pub const Strategy = union(enum) {
    standard: StandardStrategy,
    canary: CanaryStrategy,
    custom_canary: CustomCanaryStrategy,
};

pub const Stage = struct {
    target: output.Output([]const u8, .public),
    profiles: []const []const u8 = &.{},
    deploy_parameters: []const KeyValue = &.{},
    strategy: Strategy = .{ .standard = .{} },
};

pub const DeliveryPipelineArgs = struct {
    name: []const u8,
    location: []const u8,
    description: []const u8 = "",
    stages: []const Stage,
    suspended: bool = false,
    labels: []const KeyValue = &.{},
    annotations: []const KeyValue = &.{},
    protect: bool = true,
};

pub const DeliveryPipeline = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
        pub const Ready = output.Descriptor("ready", bool, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    etag: Outputs.Etag.OutputType,
    ready: Outputs.Ready.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: DeliveryPipelineArgs) BuildError!DeliveryPipeline {
        try provider.validate();
        try validateCommon(provider, args.name, args.location, args.description);
        if (args.stages.len == 0) return error.InvalidTarget;
        var stages = try stagesValue(allocator, args.stages);
        defer stages.deinit(allocator);
        var labels = try mapValue(allocator, args.labels, 128);
        defer labels.deinit(allocator);
        var annotations = try mapValue(allocator, args.annotations, 1024);
        defer annotations.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "annotations", .value = annotations },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "stages", .value = stages },
            .{ .name = "suspended", .value = .{ .boolean = args.suspended } },
        };
        const node = try nodeOwned(allocator, "gcp.deploy.DeliveryPipeline", args.location, args.name, &fields, .{ .protect = args.protect });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .etag = Outputs.Etag.fromResource(node.id),
            .ready = Outputs.Ready.fromResource(node.id),
        };
    }

    pub fn deinit(self: *DeliveryPipeline, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const ExecutionUsage = enum {
    render,
    deploy,
    verify,
    predeploy,
    postdeploy,
    analysis,

    pub fn apiName(self: ExecutionUsage) []const u8 {
        return switch (self) {
            .render => "RENDER",
            .deploy => "DEPLOY",
            .verify => "VERIFY",
            .predeploy => "PREDEPLOY",
            .postdeploy => "POSTDEPLOY",
            .analysis => "ANALYSIS",
        };
    }
};

pub const ExecutionEnvironment = struct {
    usages: []const ExecutionUsage,
    worker_pool: ?output.Output([]const u8, .public) = null,
    service_account: ?[]const u8 = null,
    artifact_storage: ?[]const u8 = null,
    timeout_seconds: u32 = 3600,
    verbose: bool = false,
};

pub const GkeTarget = struct {
    cluster: output.Output([]const u8, .public),
    internal_ip: bool = false,
    dns_endpoint: bool = false,
    proxy_url: ?[]const u8 = null,
};

pub const AnthosTarget = struct { membership: output.Output([]const u8, .public) };
pub const CloudRunTarget = struct { location: []const u8 };
pub const MultiTarget = struct { targets: []const output.Output([]const u8, .public) };
pub const CustomTarget = struct { target_type: output.Output([]const u8, .public) };

pub const TargetRuntime = union(enum) {
    gke: GkeTarget,
    anthos: AnthosTarget,
    cloud_run: CloudRunTarget,
    multi: MultiTarget,
    custom: CustomTarget,
};

pub const TargetArgs = struct {
    name: []const u8,
    location: []const u8,
    description: []const u8 = "",
    runtime: TargetRuntime,
    require_approval: bool = false,
    deploy_parameters: []const KeyValue = &.{},
    execution: []const ExecutionEnvironment = &.{},
    labels: []const KeyValue = &.{},
    annotations: []const KeyValue = &.{},
    protect: bool = true,
};

pub const Target = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    etag: Outputs.Etag.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: TargetArgs) BuildError!Target {
        try provider.validate();
        try validateCommon(provider, args.name, args.location, args.description);
        var runtime = try targetRuntimeValue(allocator, provider, args.runtime);
        defer runtime.deinit(allocator);
        var execution = try executionValue(allocator, provider, args.execution);
        defer execution.deinit(allocator);
        var deploy_parameters = try mapValue(allocator, args.deploy_parameters, 1024);
        defer deploy_parameters.deinit(allocator);
        var labels = try mapValue(allocator, args.labels, 128);
        defer labels.deinit(allocator);
        var annotations = try mapValue(allocator, args.annotations, 1024);
        defer annotations.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "annotations", .value = annotations },
            .{ .name = "deploy_parameters", .value = deploy_parameters },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "execution", .value = execution },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "require_approval", .value = .{ .boolean = args.require_approval } },
            .{ .name = "runtime", .value = runtime },
        };
        const node = try nodeOwned(allocator, "gcp.deploy.Target", args.location, args.name, &fields, .{ .protect = args.protect });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .etag = Outputs.Etag.fromResource(node.id) };
    }

    pub fn deinit(self: *Target, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const CustomActions = struct {
    deploy: []const u8,
    render: ?[]const u8 = null,
    include_modules: []const []const u8 = &.{},
};

pub const CustomTargetTypeArgs = struct {
    name: []const u8,
    location: []const u8,
    description: []const u8 = "",
    actions: CustomActions,
    labels: []const KeyValue = &.{},
    annotations: []const KeyValue = &.{},
    protect: bool = true,
};

pub const CustomTargetType = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    etag: Outputs.Etag.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: CustomTargetTypeArgs) BuildError!CustomTargetType {
        try provider.validate();
        try validateCommon(provider, args.name, args.location, args.description);
        try validateToken(args.actions.deploy);
        if (args.actions.render) |render| try validateToken(render);
        var modules = try stringListValue(allocator, args.actions.include_modules);
        defer modules.deinit(allocator);
        var labels = try mapValue(allocator, args.labels, 128);
        defer labels.deinit(allocator);
        var annotations = try mapValue(allocator, args.annotations, 1024);
        defer annotations.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "annotations", .value = annotations },
            .{ .name = "deploy_action", .value = .{ .string = args.actions.deploy } },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "include_modules", .value = modules },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "render_action", .value = .{ .string = args.actions.render orelse "" } },
        };
        const node = try nodeOwned(allocator, "gcp.deploy.CustomTargetType", args.location, args.name, &fields, .{ .protect = args.protect });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .etag = Outputs.Etag.fromResource(node.id) };
    }

    pub fn deinit(self: *CustomTargetType, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const PromoteRule = struct {
    id: []const u8,
    destination_target_id: []const u8 = "@next",
    destination_phase: []const u8 = "",
    wait_seconds: u32 = 0,
};

pub const TimedPromoteRule = struct {
    id: []const u8,
    schedule: []const u8,
    time_zone: []const u8,
    destination_target_id: []const u8 = "@next",
    destination_phase: []const u8 = "",
};

pub const AdvanceRule = struct {
    id: []const u8,
    source_phases: []const []const u8 = &.{},
    wait_seconds: u32 = 0,
};

pub const Backoff = enum { linear, exponential };
pub const Retry = struct { attempts: u8, wait_seconds: u32 = 0, backoff: Backoff = .linear };
pub const Rollback = struct { destination_phase: []const u8 = "", disable_if_pending: bool = true };
pub const RepairRule = struct {
    id: []const u8,
    phases: []const []const u8 = &.{},
    jobs: []const []const u8 = &.{},
    retry: ?Retry = null,
    rollback: ?Rollback = null,
};

pub const AutomationRule = union(enum) {
    promote: PromoteRule,
    timed_promote: TimedPromoteRule,
    advance: AdvanceRule,
    repair: RepairRule,
};

pub const AutomationArgs = struct {
    name: []const u8,
    location: []const u8,
    pipeline_name: []const u8,
    pipeline: output.Output([]const u8, .public),
    description: []const u8 = "",
    service_account: []const u8,
    target_ids: []const []const u8,
    rules: []const AutomationRule,
    suspended: bool = true,
    labels: []const KeyValue = &.{},
    annotations: []const KeyValue = &.{},
    protect: bool = true,
};

pub const Automation = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    etag: Outputs.Etag.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: AutomationArgs) BuildError!Automation {
        try provider.validate();
        try validateCommon(provider, args.name, args.location, args.description);
        try validateName(args.pipeline_name);
        try validateServiceAccount(args.service_account);
        if (args.target_ids.len == 0 or args.rules.len == 0 or args.rules.len > 250) return error.InvalidAutomation;
        var pipeline = try publicOutputValue(allocator, args.pipeline);
        defer pipeline.deinit(allocator);
        var targets = try stringListValue(allocator, args.target_ids);
        defer targets.deinit(allocator);
        var rules = try automationRulesValue(allocator, args.rules);
        defer rules.deinit(allocator);
        var labels = try mapValue(allocator, args.labels, 63);
        defer labels.deinit(allocator);
        var annotations = try mapValue(allocator, args.annotations, 1024);
        defer annotations.deinit(allocator);
        const logical = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ args.pipeline_name, args.name });
        defer allocator.free(logical);
        const fields = [_]value.Field{
            .{ .name = "annotations", .value = annotations },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "pipeline", .value = pipeline },
            .{ .name = "pipeline_name", .value = .{ .string = args.pipeline_name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "rules", .value = rules },
            .{ .name = "service_account", .value = .{ .string = args.service_account } },
            .{ .name = "suspended", .value = .{ .boolean = args.suspended } },
            .{ .name = "target_ids", .value = targets },
        };
        const node = try nodeOwned(allocator, "gcp.deploy.Automation", args.location, logical, &fields, .{ .protect = args.protect });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .etag = Outputs.Etag.fromResource(node.id) };
    }

    pub fn deinit(self: *Automation, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const Invoker = enum {
    user,
    automation,

    pub fn apiName(self: Invoker) []const u8 {
        return switch (self) {
            .user => "USER",
            .automation => "DEPLOY_AUTOMATION",
        };
    }
};

pub const RolloutAction = enum {
    advance,
    approve,
    cancel,
    create,
    ignore_job,
    retry_job,
    rollback,
    terminate_job_run,

    pub fn apiName(self: RolloutAction) []const u8 {
        return switch (self) {
            .advance => "ADVANCE",
            .approve => "APPROVE",
            .cancel => "CANCEL",
            .create => "CREATE",
            .ignore_job => "IGNORE_JOB",
            .retry_job => "RETRY_JOB",
            .rollback => "ROLLBACK",
            .terminate_job_run => "TERMINATE_JOBRUN",
        };
    }
};

pub const Day = enum {
    monday,
    tuesday,
    wednesday,
    thursday,
    friday,
    saturday,
    sunday,

    pub fn apiName(self: Day) []const u8 {
        return switch (self) {
            .monday => "MONDAY",
            .tuesday => "TUESDAY",
            .wednesday => "WEDNESDAY",
            .thursday => "THURSDAY",
            .friday => "FRIDAY",
            .saturday => "SATURDAY",
            .sunday => "SUNDAY",
        };
    }
};

pub const TimeOfDay = struct { hour: u8, minute: u8 = 0, second: u8 = 0 };
pub const Date = struct { year: u16, month: u8, day: u8 };
pub const WeeklyWindow = struct { days: []const Day = &.{}, start: ?TimeOfDay = null, end: ?TimeOfDay = null };
pub const OneTimeWindow = struct { start_date: Date, start: TimeOfDay, end_date: Date, end: TimeOfDay };

pub const RolloutRestriction = struct {
    id: []const u8,
    invokers: []const Invoker = &.{},
    actions: []const RolloutAction = &.{},
    time_zone: []const u8,
    weekly_windows: []const WeeklyWindow = &.{},
    one_time_windows: []const OneTimeWindow = &.{},
};

pub const PolicySelector = struct {
    pipeline_id: ?[]const u8 = null,
    target_id: ?[]const u8 = null,
    pipeline_labels: []const KeyValue = &.{},
    target_labels: []const KeyValue = &.{},
};

pub const DeployPolicyArgs = struct {
    name: []const u8,
    location: []const u8,
    description: []const u8 = "",
    selectors: []const PolicySelector,
    rules: []const RolloutRestriction,
    suspended: bool = false,
    labels: []const KeyValue = &.{},
    annotations: []const KeyValue = &.{},
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const DeployPolicy = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    etag: Outputs.Etag.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: DeployPolicyArgs) BuildError!DeployPolicy {
        try provider.validate();
        try validateCommon(provider, args.name, args.location, args.description);
        if (args.selectors.len == 0 or args.rules.len == 0) return error.InvalidPolicy;
        var selectors = try policySelectorsValue(allocator, args.selectors);
        defer selectors.deinit(allocator);
        var rules = try policyRulesValue(allocator, args.rules);
        defer rules.deinit(allocator);
        var labels = try mapValue(allocator, args.labels, 128);
        defer labels.deinit(allocator);
        var annotations = try mapValue(allocator, args.annotations, 1024);
        defer annotations.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "annotations", .value = annotations },
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = args.location } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "rules", .value = rules },
            .{ .name = "selectors", .value = selectors },
            .{ .name = "suspended", .value = .{ .boolean = args.suspended } },
        };
        const node = try nodeOwned(allocator, "gcp.deploy.DeployPolicy", args.location, args.name, &fields, .{ .protect = args.protect, .retain_on_delete = args.retain_on_delete });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .etag = Outputs.Etag.fromResource(node.id) };
    }

    pub fn deinit(self: *DeployPolicy, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn stagesValue(allocator: std.mem.Allocator, stages: []const Stage) BuildError!value.Value {
    const values = try allocator.alloc(value.Value, stages.len);
    defer allocator.free(values);
    var initialized: usize = 0;
    defer for (values[0..initialized]) |*item| item.deinit(allocator);
    for (stages, 0..) |stage, index| {
        for (stages[0..index]) |previous| if (outputsEqual(previous.target, stage.target)) return error.DuplicateStage;
        var target = try publicOutputValue(allocator, stage.target);
        defer target.deinit(allocator);
        var profiles = try stringListValue(allocator, stage.profiles);
        defer profiles.deinit(allocator);
        var parameters = try mapValue(allocator, stage.deploy_parameters, 1024);
        defer parameters.deinit(allocator);
        var strategy = try strategyValue(allocator, stage.strategy);
        defer strategy.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "deploy_parameters", .value = parameters },
            .{ .name = "profiles", .value = profiles },
            .{ .name = "strategy", .value = strategy },
            .{ .name = "target", .value = target },
        };
        values[index] = try value.Value.initOwned(allocator, .{ .object = &fields });
        initialized += 1;
    }
    return value.Value.initOwned(allocator, .{ .list = values });
}

fn strategyValue(allocator: std.mem.Allocator, strategy: Strategy) BuildError!value.Value {
    return switch (strategy) {
        .standard => |item| strategyFields(allocator, "standard", item.verify, item.predeploy_actions, item.postdeploy_actions, null),
        .canary => |item| blk: {
            try validatePercentages(item.percentages);
            var percentages = try integerListValue(allocator, item.percentages);
            defer percentages.deinit(allocator);
            break :blk try strategyFields(allocator, "canary", item.verify, item.predeploy_actions, item.postdeploy_actions, percentages);
        },
        .custom_canary => |item| blk: {
            if (item.phases.len == 0) return error.InvalidCanary;
            const phases = try allocator.alloc(value.Value, item.phases.len);
            defer allocator.free(phases);
            var initialized: usize = 0;
            defer for (phases[0..initialized]) |*phase| phase.deinit(allocator);
            var previous: u8 = 0;
            for (item.phases, 0..) |phase, index| {
                try validateName(phase.id);
                if (phase.percentage == 0 or phase.percentage >= 100 or phase.percentage <= previous) return error.InvalidCanary;
                for (item.phases[0..index]) |seen| if (std.mem.eql(u8, seen.id, phase.id)) return error.InvalidCanary;
                previous = phase.percentage;
                var profiles = try stringListValue(allocator, phase.profiles);
                defer profiles.deinit(allocator);
                const fields = [_]value.Field{
                    .{ .name = "id", .value = .{ .string = phase.id } },
                    .{ .name = "percentage", .value = .{ .integer = phase.percentage } },
                    .{ .name = "profiles", .value = profiles },
                    .{ .name = "verify", .value = .{ .boolean = phase.verify } },
                };
                phases[index] = try value.Value.initOwned(allocator, .{ .object = &fields });
                initialized += 1;
            }
            const fields = [_]value.Field{
                .{ .name = "kind", .value = .{ .string = "custom_canary" } },
                .{ .name = "phases", .value = .{ .list = phases } },
            };
            break :blk try value.Value.initOwned(allocator, .{ .object = &fields });
        },
    };
}

fn strategyFields(allocator: std.mem.Allocator, kind: []const u8, verify: bool, predeploy: []const []const u8, postdeploy: []const []const u8, percentages: ?value.Value) BuildError!value.Value {
    var pre = try stringListValue(allocator, predeploy);
    defer pre.deinit(allocator);
    var post = try stringListValue(allocator, postdeploy);
    defer post.deinit(allocator);
    var percentage_value = if (percentages) |present| try present.clone(allocator) else try value.Value.initOwned(allocator, .{ .list = &.{} });
    defer percentage_value.deinit(allocator);
    const fields = [_]value.Field{
        .{ .name = "kind", .value = .{ .string = kind } },
        .{ .name = "percentages", .value = percentage_value },
        .{ .name = "postdeploy_actions", .value = post },
        .{ .name = "predeploy_actions", .value = pre },
        .{ .name = "verify", .value = .{ .boolean = verify } },
    };
    return value.Value.initOwned(allocator, .{ .object = &fields });
}

fn targetRuntimeValue(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, runtime: TargetRuntime) BuildError!value.Value {
    return switch (runtime) {
        .cloud_run => |item| blk: {
            if (!configuredLocation(provider, item.location)) return error.InvalidRegion;
            const location = try std.fmt.allocPrint(allocator, "projects/{s}/locations/{s}", .{ provider.project_id, item.location });
            defer allocator.free(location);
            const fields = [_]value.Field{
                .{ .name = "kind", .value = .{ .string = "cloud_run" } },
                .{ .name = "location", .value = .{ .string = location } },
            };
            break :blk try value.Value.initOwned(allocator, .{ .object = &fields });
        },
        .gke => |item| blk: {
            if (item.internal_ip and item.dns_endpoint) return error.InvalidTarget;
            if (item.proxy_url) |uri| if (!std.mem.startsWith(u8, uri, "https://")) return error.InvalidTarget;
            var cluster = try publicOutputValue(allocator, item.cluster);
            defer cluster.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "cluster", .value = cluster },
                .{ .name = "dns_endpoint", .value = .{ .boolean = item.dns_endpoint } },
                .{ .name = "internal_ip", .value = .{ .boolean = item.internal_ip } },
                .{ .name = "kind", .value = .{ .string = "gke" } },
                .{ .name = "proxy_url", .value = .{ .string = item.proxy_url orelse "" } },
            };
            break :blk try value.Value.initOwned(allocator, .{ .object = &fields });
        },
        .anthos => |item| blk: {
            var membership = try publicOutputValue(allocator, item.membership);
            defer membership.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "kind", .value = .{ .string = "anthos" } },
                .{ .name = "membership", .value = membership },
            };
            break :blk try value.Value.initOwned(allocator, .{ .object = &fields });
        },
        .multi => |item| blk: {
            if (item.targets.len < 2) return error.InvalidTarget;
            var targets = try outputListValue(allocator, item.targets);
            defer targets.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "kind", .value = .{ .string = "multi" } },
                .{ .name = "targets", .value = targets },
            };
            break :blk try value.Value.initOwned(allocator, .{ .object = &fields });
        },
        .custom => |item| blk: {
            var target_type = try publicOutputValue(allocator, item.target_type);
            defer target_type.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "kind", .value = .{ .string = "custom" } },
                .{ .name = "target_type", .value = target_type },
            };
            break :blk try value.Value.initOwned(allocator, .{ .object = &fields });
        },
    };
}

fn executionValue(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, environments: []const ExecutionEnvironment) BuildError!value.Value {
    const values = try allocator.alloc(value.Value, environments.len);
    defer allocator.free(values);
    var initialized: usize = 0;
    defer for (values[0..initialized]) |*item| item.deinit(allocator);
    var used = [_]bool{false} ** @typeInfo(ExecutionUsage).@"enum".fields.len;
    for (environments, 0..) |environment, index| {
        if (environment.usages.len == 0 or environment.timeout_seconds < 600 or environment.timeout_seconds > 86_400) return error.InvalidExecution;
        const usage_values = try allocator.alloc(value.Value, environment.usages.len);
        defer allocator.free(usage_values);
        for (environment.usages, 0..) |usage, usage_index| {
            const ordinal = @intFromEnum(usage);
            if (used[ordinal]) return error.DuplicateUsage;
            used[ordinal] = true;
            usage_values[usage_index] = .{ .string = usage.apiName() };
        }
        var usages = try value.Value.initOwned(allocator, .{ .list = usage_values });
        defer usages.deinit(allocator);
        var worker = if (environment.worker_pool) |pool| try publicOutputValue(allocator, pool) else try value.Value.initOwned(allocator, .{ .string = "" });
        defer worker.deinit(allocator);
        if (environment.service_account) |account| try validateServiceAccount(account);
        if (environment.artifact_storage) |storage| if (!std.mem.startsWith(u8, storage, "gs://")) return error.InvalidExecution;
        _ = provider;
        const fields = [_]value.Field{
            .{ .name = "artifact_storage", .value = .{ .string = environment.artifact_storage orelse "" } },
            .{ .name = "service_account", .value = .{ .string = environment.service_account orelse "" } },
            .{ .name = "timeout_seconds", .value = .{ .integer = environment.timeout_seconds } },
            .{ .name = "usages", .value = usages },
            .{ .name = "verbose", .value = .{ .boolean = environment.verbose } },
            .{ .name = "worker_pool", .value = worker },
        };
        values[index] = try value.Value.initOwned(allocator, .{ .object = &fields });
        initialized += 1;
    }
    return value.Value.initOwned(allocator, .{ .list = values });
}

fn automationRulesValue(allocator: std.mem.Allocator, rules: []const AutomationRule) BuildError!value.Value {
    const sorted = try allocator.dupe(AutomationRule, rules);
    defer allocator.free(sorted);
    std.mem.sort(AutomationRule, sorted, {}, automationRuleLessThan);
    for (sorted, 0..) |rule, index| {
        try validateName(automationRuleId(rule));
        if (index != 0 and std.mem.eql(u8, automationRuleId(sorted[index - 1]), automationRuleId(rule))) return error.DuplicateRule;
    }
    const values = try allocator.alloc(value.Value, sorted.len);
    defer allocator.free(values);
    var initialized: usize = 0;
    defer for (values[0..initialized]) |*item| item.deinit(allocator);
    for (sorted, 0..) |rule, index| {
        values[index] = try automationRuleValue(allocator, rule);
        initialized += 1;
    }
    return value.Value.initOwned(allocator, .{ .list = values });
}

fn automationRuleValue(allocator: std.mem.Allocator, rule: AutomationRule) BuildError!value.Value {
    return switch (rule) {
        .promote => |item| promoteRuleValue(allocator, "promote", item.id, item.destination_target_id, item.destination_phase, item.wait_seconds, "", ""),
        .timed_promote => |item| blk: {
            if (!validCron(item.schedule) or !validTimeZone(item.time_zone)) return error.InvalidAutomation;
            break :blk promoteRuleValue(allocator, "timed_promote", item.id, item.destination_target_id, item.destination_phase, 0, item.schedule, item.time_zone);
        },
        .advance => |item| blk: {
            try validateDuration(item.wait_seconds, 14 * 24 * 3600);
            var phases = try stringListValue(allocator, item.source_phases);
            defer phases.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "id", .value = .{ .string = item.id } },
                .{ .name = "kind", .value = .{ .string = "advance" } },
                .{ .name = "source_phases", .value = phases },
                .{ .name = "wait_seconds", .value = .{ .integer = item.wait_seconds } },
            };
            break :blk try value.Value.initOwned(allocator, .{ .object = &fields });
        },
        .repair => |item| blk: {
            if (item.retry == null and item.rollback == null) return error.InvalidAutomation;
            var phases = try stringListValue(allocator, item.phases);
            defer phases.deinit(allocator);
            var jobs = try stringListValue(allocator, item.jobs);
            defer jobs.deinit(allocator);
            if (item.retry) |retry| {
                if (retry.attempts == 0 or retry.attempts > 10) return error.InvalidAutomation;
                try validateDuration(retry.wait_seconds, 14 * 24 * 3600);
            }
            if (item.rollback) |rollback| if (rollback.destination_phase.len != 0) try validateName(rollback.destination_phase);
            const fields = [_]value.Field{
                .{ .name = "backoff", .value = .{ .string = if (item.retry) |retry| @tagName(retry.backoff) else "linear" } },
                .{ .name = "disable_rollback_if_pending", .value = .{ .boolean = if (item.rollback) |rollback| rollback.disable_if_pending else false } },
                .{ .name = "id", .value = .{ .string = item.id } },
                .{ .name = "jobs", .value = jobs },
                .{ .name = "kind", .value = .{ .string = "repair" } },
                .{ .name = "phases", .value = phases },
                .{ .name = "retry_attempts", .value = .{ .integer = if (item.retry) |retry| retry.attempts else 0 } },
                .{ .name = "retry_wait_seconds", .value = .{ .integer = if (item.retry) |retry| retry.wait_seconds else 0 } },
                .{ .name = "rollback", .value = .{ .boolean = item.rollback != null } },
                .{ .name = "rollback_phase", .value = .{ .string = if (item.rollback) |rollback| rollback.destination_phase else "" } },
            };
            break :blk try value.Value.initOwned(allocator, .{ .object = &fields });
        },
    };
}

fn promoteRuleValue(allocator: std.mem.Allocator, kind: []const u8, id: []const u8, destination: []const u8, phase: []const u8, wait: u32, schedule: []const u8, time_zone: []const u8) BuildError!value.Value {
    if (!std.mem.eql(u8, destination, "@next")) try validateName(destination);
    if (phase.len != 0) try validateName(phase);
    try validateDuration(wait, 14 * 24 * 3600);
    const fields = [_]value.Field{
        .{ .name = "destination_phase", .value = .{ .string = phase } },
        .{ .name = "destination_target_id", .value = .{ .string = destination } },
        .{ .name = "id", .value = .{ .string = id } },
        .{ .name = "kind", .value = .{ .string = kind } },
        .{ .name = "schedule", .value = .{ .string = schedule } },
        .{ .name = "time_zone", .value = .{ .string = time_zone } },
        .{ .name = "wait_seconds", .value = .{ .integer = wait } },
    };
    return value.Value.initOwned(allocator, .{ .object = &fields });
}

fn policySelectorsValue(allocator: std.mem.Allocator, selectors: []const PolicySelector) BuildError!value.Value {
    const values = try allocator.alloc(value.Value, selectors.len);
    defer allocator.free(values);
    var initialized: usize = 0;
    defer for (values[0..initialized]) |*item| item.deinit(allocator);
    for (selectors, 0..) |selector, index| {
        if (selector.pipeline_id == null and selector.target_id == null and selector.pipeline_labels.len == 0 and selector.target_labels.len == 0) return error.InvalidPolicy;
        if (selector.pipeline_id) |id| if (!std.mem.eql(u8, id, "*")) try validateName(id);
        if (selector.target_id) |id| if (!std.mem.eql(u8, id, "*")) try validateName(id);
        var pipeline_labels = try mapValue(allocator, selector.pipeline_labels, 128);
        defer pipeline_labels.deinit(allocator);
        var target_labels = try mapValue(allocator, selector.target_labels, 128);
        defer target_labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "pipeline_id", .value = .{ .string = selector.pipeline_id orelse "" } },
            .{ .name = "pipeline_labels", .value = pipeline_labels },
            .{ .name = "target_id", .value = .{ .string = selector.target_id orelse "" } },
            .{ .name = "target_labels", .value = target_labels },
        };
        values[index] = try value.Value.initOwned(allocator, .{ .object = &fields });
        initialized += 1;
    }
    return value.Value.initOwned(allocator, .{ .list = values });
}

fn policyRulesValue(allocator: std.mem.Allocator, rules: []const RolloutRestriction) BuildError!value.Value {
    const sorted = try allocator.dupe(RolloutRestriction, rules);
    defer allocator.free(sorted);
    std.mem.sort(RolloutRestriction, sorted, {}, policyRuleLessThan);
    const values = try allocator.alloc(value.Value, sorted.len);
    defer allocator.free(values);
    var initialized: usize = 0;
    defer for (values[0..initialized]) |*item| item.deinit(allocator);
    for (sorted, 0..) |rule, index| {
        try validateName(rule.id);
        if (index != 0 and std.mem.eql(u8, sorted[index - 1].id, rule.id)) return error.DuplicateRule;
        if (!validTimeZone(rule.time_zone) or (rule.weekly_windows.len == 0 and rule.one_time_windows.len == 0)) return error.InvalidTimeWindow;
        var invokers = try invokersValue(allocator, rule.invokers);
        defer invokers.deinit(allocator);
        var actions = try actionsValue(allocator, rule.actions);
        defer actions.deinit(allocator);
        var weekly = try weeklyWindowsValue(allocator, rule.weekly_windows);
        defer weekly.deinit(allocator);
        var one_time = try oneTimeWindowsValue(allocator, rule.one_time_windows);
        defer one_time.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "actions", .value = actions },
            .{ .name = "id", .value = .{ .string = rule.id } },
            .{ .name = "invokers", .value = invokers },
            .{ .name = "one_time_windows", .value = one_time },
            .{ .name = "time_zone", .value = .{ .string = rule.time_zone } },
            .{ .name = "weekly_windows", .value = weekly },
        };
        values[index] = try value.Value.initOwned(allocator, .{ .object = &fields });
        initialized += 1;
    }
    return value.Value.initOwned(allocator, .{ .list = values });
}

fn weeklyWindowsValue(allocator: std.mem.Allocator, windows: []const WeeklyWindow) BuildError!value.Value {
    const values = try allocator.alloc(value.Value, windows.len);
    defer allocator.free(values);
    var initialized: usize = 0;
    defer for (values[0..initialized]) |*item| item.deinit(allocator);
    for (windows, 0..) |window, index| {
        if ((window.start == null) != (window.end == null)) return error.InvalidTimeWindow;
        if (window.start) |start| try validateTime(start);
        if (window.end) |end| try validateTime(end);
        const day_values = try allocator.alloc(value.Value, window.days.len);
        defer allocator.free(day_values);
        for (window.days, 0..) |day, day_index| day_values[day_index] = .{ .string = day.apiName() };
        var days = try value.Value.initOwned(allocator, .{ .list = day_values });
        defer days.deinit(allocator);
        var start = try timeValue(allocator, window.start);
        defer start.deinit(allocator);
        var end = try timeValue(allocator, window.end);
        defer end.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "days", .value = days },
            .{ .name = "end", .value = end },
            .{ .name = "start", .value = start },
        };
        values[index] = try value.Value.initOwned(allocator, .{ .object = &fields });
        initialized += 1;
    }
    return value.Value.initOwned(allocator, .{ .list = values });
}

fn oneTimeWindowsValue(allocator: std.mem.Allocator, windows: []const OneTimeWindow) BuildError!value.Value {
    const values = try allocator.alloc(value.Value, windows.len);
    defer allocator.free(values);
    var initialized: usize = 0;
    defer for (values[0..initialized]) |*item| item.deinit(allocator);
    for (windows, 0..) |window, index| {
        try validateDate(window.start_date);
        try validateDate(window.end_date);
        try validateTime(window.start);
        try validateTime(window.end);
        var start_date = try dateValue(allocator, window.start_date);
        defer start_date.deinit(allocator);
        var end_date = try dateValue(allocator, window.end_date);
        defer end_date.deinit(allocator);
        var start = try timeValue(allocator, window.start);
        defer start.deinit(allocator);
        var end = try timeValue(allocator, window.end);
        defer end.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "end", .value = end },
            .{ .name = "end_date", .value = end_date },
            .{ .name = "start", .value = start },
            .{ .name = "start_date", .value = start_date },
        };
        values[index] = try value.Value.initOwned(allocator, .{ .object = &fields });
        initialized += 1;
    }
    return value.Value.initOwned(allocator, .{ .list = values });
}

fn timeValue(allocator: std.mem.Allocator, candidate: ?TimeOfDay) BuildError!value.Value {
    if (candidate == null) return value.Value.initOwned(allocator, .{ .object = &.{} });
    const present = candidate.?;
    const fields = [_]value.Field{
        .{ .name = "hour", .value = .{ .integer = present.hour } },
        .{ .name = "minute", .value = .{ .integer = present.minute } },
        .{ .name = "second", .value = .{ .integer = present.second } },
    };
    return value.Value.initOwned(allocator, .{ .object = &fields });
}

fn dateValue(allocator: std.mem.Allocator, date: Date) BuildError!value.Value {
    const fields = [_]value.Field{
        .{ .name = "day", .value = .{ .integer = date.day } },
        .{ .name = "month", .value = .{ .integer = date.month } },
        .{ .name = "year", .value = .{ .integer = date.year } },
    };
    return value.Value.initOwned(allocator, .{ .object = &fields });
}

fn invokersValue(allocator: std.mem.Allocator, items: []const Invoker) BuildError!value.Value {
    const values = try allocator.alloc(value.Value, items.len);
    defer allocator.free(values);
    for (items, 0..) |item, index| values[index] = .{ .string = item.apiName() };
    return value.Value.initOwned(allocator, .{ .list = values });
}

fn actionsValue(allocator: std.mem.Allocator, items: []const RolloutAction) BuildError!value.Value {
    const values = try allocator.alloc(value.Value, items.len);
    defer allocator.free(values);
    for (items, 0..) |item, index| values[index] = .{ .string = item.apiName() };
    return value.Value.initOwned(allocator, .{ .list = values });
}

fn outputListValue(allocator: std.mem.Allocator, items: []const output.Output([]const u8, .public)) BuildError!value.Value {
    const values = try allocator.alloc(value.Value, items.len);
    defer allocator.free(values);
    var initialized: usize = 0;
    defer for (values[0..initialized]) |*item| item.deinit(allocator);
    for (items, 0..) |item, index| {
        for (items[0..index]) |previous| if (outputsEqual(previous, item)) return error.InvalidTarget;
        values[index] = try publicOutputValue(allocator, item);
        initialized += 1;
    }
    return value.Value.initOwned(allocator, .{ .list = values });
}

fn integerListValue(allocator: std.mem.Allocator, items: []const u8) BuildError!value.Value {
    const values = try allocator.alloc(value.Value, items.len);
    defer allocator.free(values);
    for (items, 0..) |item, index| values[index] = .{ .integer = item };
    return value.Value.initOwned(allocator, .{ .list = values });
}

fn stringListValue(allocator: std.mem.Allocator, items: []const []const u8) BuildError!value.Value {
    const values = try allocator.alloc(value.Value, items.len);
    defer allocator.free(values);
    for (items, 0..) |item, index| {
        try validateToken(item);
        for (items[0..index]) |previous| if (std.mem.eql(u8, previous, item)) return error.InvalidValue;
        values[index] = .{ .string = item };
    }
    return value.Value.initOwned(allocator, .{ .list = values });
}

fn mapValue(allocator: std.mem.Allocator, items: []const KeyValue, max_value: usize) BuildError!value.Value {
    const sorted = try allocator.dupe(KeyValue, items);
    defer allocator.free(sorted);
    std.mem.sort(KeyValue, sorted, {}, keyValueLessThan);
    const fields = try allocator.alloc(value.Field, sorted.len);
    defer allocator.free(fields);
    for (sorted, 0..) |item, index| {
        if (item.key.len == 0 or item.key.len > 128 or item.value.len > max_value or std.mem.indexOfAny(u8, item.key, "\x00\r\n") != null or std.mem.indexOfAny(u8, item.value, "\x00\r\n") != null) return error.InvalidValue;
        if (index != 0 and std.mem.eql(u8, sorted[index - 1].key, item.key)) return error.DuplicateKey;
        fields[index] = .{ .name = item.key, .value = .{ .string = item.value } };
    }
    return value.Value.initOwned(allocator, .{ .object = fields }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateKey,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn publicOutputValue(allocator: std.mem.Allocator, candidate: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (candidate) {
        .value => |text| value.Value.initOwned(allocator, .{ .string = text }),
        .resource_ref => |reference| value.Value.initOwned(allocator, .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } }),
        .unknown_reason => error.OutputNotKnown,
    };
}

fn nodeOwned(allocator: std.mem.Allocator, type_name: []const u8, scope: []const u8, logical: []const u8, fields: []const value.Field, lifecycle: resource.Lifecycle) BuildError!resource.ResourceNode {
    const id = try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ type_name, scope, logical });
    defer allocator.free(id);
    return resource.ResourceNode.initOwned(allocator, .{ .id = id, .provider = .gcp, .type_name = type_name, .logical_id = logical, .inputs = .{ .object = fields }, .lifecycle = lifecycle }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
    };
}

fn validateCommon(provider: config_mod.ProviderConfig, name: []const u8, location: []const u8, description: []const u8) BuildError!void {
    try validateName(name);
    if (!configuredLocation(provider, location)) return error.InvalidRegion;
    if (description.len > 255 or std.mem.indexOfAny(u8, description, "\x00\r\n") != null) return error.InvalidDescription;
}

fn validateName(name: []const u8) BuildError!void {
    if (name.len == 0 or name.len > 63 or !std.ascii.isLower(name[0])) return error.InvalidName;
    if (!std.ascii.isLower(name[name.len - 1]) and !std.ascii.isDigit(name[name.len - 1])) return error.InvalidName;
    for (name) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return error.InvalidName;
}

fn validateToken(token: []const u8) BuildError!void {
    if (token.len == 0 or token.len > 1024 or std.mem.indexOfAny(u8, token, "\x00\r\n") != null) return error.InvalidValue;
}

fn validatePercentages(percentages: []const u8) BuildError!void {
    if (percentages.len == 0) return error.InvalidCanary;
    var previous: u8 = 0;
    for (percentages) |percentage| {
        if (percentage == 0 or percentage >= 100 or percentage <= previous) return error.InvalidCanary;
        previous = percentage;
    }
}

fn validateDuration(seconds: u32, maximum: u32) BuildError!void {
    if (seconds > maximum) return error.InvalidDuration;
}

fn validateServiceAccount(account: []const u8) BuildError!void {
    if (!std.mem.endsWith(u8, account, ".iam.gserviceaccount.com") or std.mem.indexOfScalar(u8, account, '@') == null or std.mem.indexOfAny(u8, account, " \t\r\n") != null) return error.InvalidServiceAccount;
}

fn validateTime(time: TimeOfDay) BuildError!void {
    if (time.hour > 24 or time.minute > 59 or time.second > 59 or (time.hour == 24 and (time.minute != 0 or time.second != 0))) return error.InvalidTimeWindow;
}

fn validateDate(date: Date) BuildError!void {
    if (date.year < 1970 or date.month == 0 or date.month > 12 or date.day == 0 or date.day > 31) return error.InvalidTimeWindow;
}

fn configuredLocation(provider: config_mod.ProviderConfig, location: []const u8) bool {
    if (std.mem.eql(u8, location, "global") or std.mem.eql(u8, provider.primary_region, location)) return true;
    for (provider.service_regions) |candidate| if (std.mem.eql(u8, candidate, location)) return true;
    return false;
}

fn validCron(schedule: []const u8) bool {
    var fields: usize = 0;
    var iterator = std.mem.tokenizeScalar(u8, schedule, ' ');
    while (iterator.next()) |field| {
        if (field.len == 0 or std.mem.indexOfAny(u8, field, "\x00\r\n") != null) return false;
        fields += 1;
    }
    return fields == 5;
}

fn validTimeZone(time_zone: []const u8) bool {
    return std.mem.eql(u8, time_zone, "UTC") or
        (time_zone.len >= 3 and std.mem.indexOfScalar(u8, time_zone, '/') != null and std.mem.indexOfAny(u8, time_zone, " \t\r\n") == null);
}

fn outputsEqual(left: output.Output([]const u8, .public), right: output.Output([]const u8, .public)) bool {
    return switch (left) {
        .value => |text| switch (right) {
            .value => |other| std.mem.eql(u8, text, other),
            else => false,
        },
        .resource_ref => |reference| switch (right) {
            .resource_ref => |other| std.mem.eql(u8, reference.resource_id, other.resource_id) and std.mem.eql(u8, reference.field, other.field),
            else => false,
        },
        .unknown_reason => |reason| switch (right) {
            .unknown_reason => |other| std.mem.eql(u8, reason, other),
            else => false,
        },
    };
}

fn automationRuleId(rule: AutomationRule) []const u8 {
    return switch (rule) {
        .promote => |item| item.id,
        .timed_promote => |item| item.id,
        .advance => |item| item.id,
        .repair => |item| item.id,
    };
}

fn automationRuleLessThan(_: void, left: AutomationRule, right: AutomationRule) bool {
    return std.mem.order(u8, automationRuleId(left), automationRuleId(right)) == .lt;
}

fn policyRuleLessThan(_: void, left: RolloutRestriction, right: RolloutRestriction) bool {
    return std.mem.order(u8, left.id, right.id) == .lt;
}

fn keyValueLessThan(_: void, left: KeyValue, right: KeyValue) bool {
    return std.mem.order(u8, left.key, right.key) == .lt;
}
