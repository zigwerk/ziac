const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    DuplicateValue,
    InvalidCondition,
    InvalidGoal,
    InvalidLabel,
    InvalidName,
    InvalidPeriod,
    InvalidSecret,
    InvalidTarget,
    InvalidValue,
    InvalidWidget,
    OutputNotKnown,
};

pub const Label = struct { key: []const u8, value: []const u8 };
pub const Header = Label;
pub const SecretField = struct {
    key: []const u8,
    value: output.Output(value.SecretReference, .secret),
};

pub const NotificationChannelArgs = struct {
    name: []const u8,
    display_name: []const u8,
    type: []const u8,
    description: []const u8 = "",
    labels: []const Label = &.{},
    secret_labels: []const SecretField = &.{},
    user_labels: []const Label = &.{},
    enabled: bool = true,
    force_delete: bool = false,
    protect: bool = false,
};

pub const NotificationChannel = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const VerificationStatus = output.Descriptor("verification_status", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    verification_status: Outputs.VerificationStatus.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: NotificationChannelArgs) BuildError!NotificationChannel {
        try provider.validate();
        try validateName(args.name);
        if (args.display_name.len == 0 or args.type.len == 0) return error.InvalidValue;
        var labels = try labelsValueOwned(allocator, args.labels);
        defer labels.deinit(allocator);
        var secret_labels = try secretFieldsValueOwned(allocator, args.secret_labels);
        defer secret_labels.deinit(allocator);
        var user_labels = try labelsValueOwned(allocator, args.user_labels);
        defer user_labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "description", .value = .{ .string = args.description } },
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "enabled", .value = .{ .boolean = args.enabled } },
            .{ .name = "force_delete", .value = .{ .boolean = args.force_delete } },
            .{ .name = "labels", .value = labels },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "secret_labels", .value = secret_labels },
            .{ .name = "type", .value = .{ .string = args.type } },
            .{ .name = "user_labels", .value = user_labels },
        };
        const node = try nodeOwned(allocator, "gcp.monitoring.NotificationChannel", args.name, args.name, &fields, .{ .protect = args.protect });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .verification_status = Outputs.VerificationStatus.fromResource(node.id),
        };
    }

    pub fn deinit(self: *NotificationChannel, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const Matcher = enum {
    contains_string,
    not_contains_string,
    matches_regex,
    not_matches_regex,
    matches_json_path,
    not_matches_json_path,

    pub fn apiName(self: Matcher) []const u8 {
        return switch (self) {
            .contains_string => "CONTAINS_STRING",
            .not_contains_string => "NOT_CONTAINS_STRING",
            .matches_regex => "MATCHES_REGEX",
            .not_matches_regex => "NOT_MATCHES_REGEX",
            .matches_json_path => "MATCHES_JSON_PATH",
            .not_matches_json_path => "NOT_MATCHES_JSON_PATH",
        };
    }
};

pub const ContentMatcher = struct {
    content: []const u8,
    matcher: Matcher = .contains_string,
    json_path: []const u8 = "",
};

pub const HttpMethod = enum {
    get,
    post,

    pub fn apiName(self: HttpMethod) []const u8 {
        return if (self == .post) "POST" else "GET";
    }
};

pub const BasicAuthentication = struct {
    username: []const u8,
    password: output.Output(value.SecretReference, .secret),
};

pub const HttpTarget = struct {
    host: []const u8,
    path: []const u8 = "/",
    port: u16 = 443,
    method: HttpMethod = .get,
    use_ssl: bool = true,
    validate_ssl: bool = true,
    headers: []const Header = &.{},
    secret_headers: []const SecretField = &.{},
    basic_authentication: ?BasicAuthentication = null,
    body: []const u8 = "",
    accepted_status_classes: []const u16 = &.{2},
};

pub const TcpTarget = struct {
    host: []const u8,
    port: u16,
};

pub const UptimeTarget = union(enum) {
    http: HttpTarget,
    tcp: TcpTarget,
};

pub const CheckerType = enum {
    static_ip_checkers,
    vpc_checkers,

    pub fn apiName(self: CheckerType) []const u8 {
        return if (self == .vpc_checkers) "VPC_CHECKERS" else "STATIC_IP_CHECKERS";
    }
};

pub const UptimeCheckArgs = struct {
    name: []const u8,
    display_name: []const u8,
    target: UptimeTarget,
    period_seconds: u32 = 60,
    timeout_seconds: u32 = 10,
    checker_type: CheckerType = .static_ip_checkers,
    selected_regions: []const []const u8 = &.{ "EUROPE", "USA", "ASIA_PACIFIC" },
    content_matchers: []const ContentMatcher = &.{},
    user_labels: []const Label = &.{},
    disabled: bool = false,
    log_check_failures: bool = true,
    protect: bool = false,
};

pub const UptimeCheck = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: UptimeCheckArgs) BuildError!UptimeCheck {
        try provider.validate();
        try validateName(args.name);
        if (args.display_name.len == 0) return error.InvalidValue;
        if (!validPeriod(args.period_seconds) or args.timeout_seconds == 0 or args.timeout_seconds > 60 or args.timeout_seconds >= args.period_seconds) return error.InvalidPeriod;
        if (args.selected_regions.len == 0) return error.InvalidTarget;
        var target = try uptimeTargetValueOwned(allocator, args.target);
        defer target.deinit(allocator);
        var regions = try stringsValueOwned(allocator, args.selected_regions);
        defer regions.deinit(allocator);
        var matchers = try contentMatchersValueOwned(allocator, args.content_matchers);
        defer matchers.deinit(allocator);
        var user_labels = try labelsValueOwned(allocator, args.user_labels);
        defer user_labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "checker_type", .value = .{ .string = args.checker_type.apiName() } },
            .{ .name = "content_matchers", .value = matchers },
            .{ .name = "disabled", .value = .{ .boolean = args.disabled } },
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "log_check_failures", .value = .{ .boolean = args.log_check_failures } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "period_seconds", .value = .{ .integer = args.period_seconds } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "protocol", .value = .{ .string = if (args.target == .http) "HTTP" else "TCP" } },
            .{ .name = "selected_regions", .value = regions },
            .{ .name = "target", .value = target },
            .{ .name = "timeout_seconds", .value = .{ .integer = args.timeout_seconds } },
            .{ .name = "user_labels", .value = user_labels },
        };
        const node = try nodeOwned(allocator, "gcp.monitoring.UptimeCheck", args.name, args.name, &fields, .{ .protect = args.protect });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
    }

    pub fn deinit(self: *UptimeCheck, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const Comparison = enum {
    greater_than,
    greater_than_or_equal,
    less_than,
    less_than_or_equal,
    equal,
    not_equal,

    pub fn apiName(self: Comparison) []const u8 {
        return switch (self) {
            .greater_than => "COMPARISON_GT",
            .greater_than_or_equal => "COMPARISON_GE",
            .less_than => "COMPARISON_LT",
            .less_than_or_equal => "COMPARISON_LE",
            .equal => "COMPARISON_EQ",
            .not_equal => "COMPARISON_NE",
        };
    }
};

pub const MetricThreshold = struct {
    filter: []const u8,
    comparison: Comparison,
    threshold: f64,
    duration_seconds: u32,
    alignment_period_seconds: u32 = 60,
    per_series_aligner: []const u8 = "ALIGN_MEAN",
    cross_series_reducer: []const u8 = "REDUCE_NONE",
    group_by_fields: []const []const u8 = &.{},
    trigger_count: u32 = 0,
    trigger_percent: f64 = 0,
};

pub const MetricAbsence = struct {
    filter: []const u8,
    duration_seconds: u32,
    alignment_period_seconds: u32 = 60,
    per_series_aligner: []const u8 = "ALIGN_MEAN",
    trigger_count: u32 = 0,
    trigger_percent: f64 = 0,
};

pub const PromqlCondition = struct {
    query: []const u8,
    duration_seconds: u32 = 0,
    evaluation_interval_seconds: u32 = 30,
    disable_metric_validation: bool = false,
};

pub const LogMatchCondition = struct {
    filter: []const u8,
    label_extractors: []const Label = &.{},
};

pub const Condition = union(enum) {
    threshold: MetricThreshold,
    absence: MetricAbsence,
    promql: PromqlCondition,
    log_match: LogMatchCondition,
};

pub const AlertCondition = struct {
    id: []const u8,
    display_name: []const u8,
    condition: Condition,
};

pub const Combiner = enum {
    or_conditions,
    and_conditions,
    and_with_matching_resource,

    pub fn apiName(self: Combiner) []const u8 {
        return switch (self) {
            .or_conditions => "OR",
            .and_conditions => "AND",
            .and_with_matching_resource => "AND_WITH_MATCHING_RESOURCE",
        };
    }
};

pub const Severity = enum {
    none,
    critical,
    error_level,
    warning,

    pub fn apiName(self: Severity) []const u8 {
        return switch (self) {
            .none => "SEVERITY_UNSPECIFIED",
            .critical => "CRITICAL",
            .error_level => "ERROR",
            .warning => "WARNING",
        };
    }
};

pub const Documentation = struct {
    content: []const u8 = "",
    mime_type: []const u8 = "text/markdown",
    subject: []const u8 = "",
};

pub const AlertPolicyArgs = struct {
    name: []const u8,
    display_name: []const u8,
    conditions: []const AlertCondition,
    combiner: Combiner = .or_conditions,
    severity: Severity = .none,
    documentation: Documentation = .{},
    notification_channels: []const output.Output([]const u8, .public) = &.{},
    enabled: bool = true,
    auto_close_seconds: u32 = 0,
    notification_rate_limit_seconds: u32 = 0,
    user_labels: []const Label = &.{},
    protect: bool = false,
};

pub const AlertPolicy = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Validity = output.Descriptor("validity", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    validity: Outputs.Validity.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: AlertPolicyArgs) BuildError!AlertPolicy {
        try provider.validate();
        try validateName(args.name);
        if (args.display_name.len == 0 or args.conditions.len == 0) return error.InvalidCondition;
        var conditions = try conditionsValueOwned(allocator, args.conditions);
        defer conditions.deinit(allocator);
        var channels = try outputStringsValueOwned(allocator, args.notification_channels);
        defer channels.deinit(allocator);
        var labels = try labelsValueOwned(allocator, args.user_labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "auto_close_seconds", .value = .{ .integer = args.auto_close_seconds } },
            .{ .name = "combiner", .value = .{ .string = args.combiner.apiName() } },
            .{ .name = "conditions", .value = conditions },
            .{ .name = "documentation_content", .value = .{ .string = args.documentation.content } },
            .{ .name = "documentation_mime_type", .value = .{ .string = args.documentation.mime_type } },
            .{ .name = "documentation_subject", .value = .{ .string = args.documentation.subject } },
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "enabled", .value = .{ .boolean = args.enabled } },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "notification_channels", .value = channels },
            .{ .name = "notification_rate_limit_seconds", .value = .{ .integer = args.notification_rate_limit_seconds } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "severity", .value = .{ .string = args.severity.apiName() } },
            .{ .name = "user_labels", .value = labels },
        };
        const node = try nodeOwned(allocator, "gcp.monitoring.AlertPolicy", args.name, args.name, &fields, .{ .protect = args.protect });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .validity = Outputs.Validity.fromResource(node.id),
        };
    }

    pub fn deinit(self: *AlertPolicy, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const TimeSeries = struct {
    filter: []const u8,
    legend: []const u8 = "",
    per_series_aligner: []const u8 = "ALIGN_MEAN",
    cross_series_reducer: []const u8 = "REDUCE_NONE",
    alignment_period_seconds: u32 = 60,
    plot_type: []const u8 = "LINE",
};

pub const TextWidget = struct {
    title: []const u8 = "",
    content: []const u8,
};

pub const XyChartWidget = struct {
    title: []const u8,
    series: []const TimeSeries,
};

pub const ScorecardWidget = struct {
    title: []const u8,
    series: TimeSeries,
};

pub const LogsPanelWidget = struct {
    title: []const u8,
    filter: []const u8,
};

pub const AlertChartWidget = struct {
    title: []const u8,
    alert_policy: output.Output([]const u8, .public),
};

pub const IncidentListWidget = struct {
    title: []const u8,
    alert_policies: []const output.Output([]const u8, .public),
};

pub const Widget = union(enum) {
    text: TextWidget,
    xy_chart: XyChartWidget,
    scorecard: ScorecardWidget,
    logs_panel: LogsPanelWidget,
    alert_chart: AlertChartWidget,
    incident_list: IncidentListWidget,
};

pub const DashboardTile = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
    widget: Widget,
};

pub const DashboardArgs = struct {
    name: []const u8,
    display_name: []const u8,
    columns: u16 = 48,
    tiles: []const DashboardTile,
    labels: []const Label = &.{},
    protect: bool = false,
};

pub const Dashboard = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const Etag = output.Descriptor("etag", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    etag: Outputs.Etag.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: DashboardArgs) BuildError!Dashboard {
        try provider.validate();
        try validateName(args.name);
        if (args.display_name.len == 0 or args.columns == 0 or args.tiles.len == 0) return error.InvalidWidget;
        var tiles = try dashboardTilesValueOwned(allocator, args.columns, args.tiles);
        defer tiles.deinit(allocator);
        var labels = try labelsValueOwned(allocator, args.labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "columns", .value = .{ .integer = args.columns } },
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "labels", .value = labels },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "tiles", .value = tiles },
        };
        const node = try nodeOwned(allocator, "gcp.monitoring.Dashboard", args.name, args.name, &fields, .{ .protect = args.protect });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id), .etag = Outputs.Etag.fromResource(node.id) };
    }

    pub fn deinit(self: *Dashboard, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const BasicService = struct {
    service_type: []const u8,
    service_labels: []const Label,
};

pub const CloudRunService = struct {
    service_name: []const u8,
    location: []const u8,
};

pub const GkeWorkloadService = struct {
    project_id: []const u8,
    location: []const u8,
    cluster_name: []const u8,
    namespace_name: []const u8,
    top_level_controller_type: []const u8,
    top_level_controller_name: []const u8,
};

pub const ServiceKind = union(enum) {
    custom,
    basic: BasicService,
    cloud_run: CloudRunService,
    gke_workload: GkeWorkloadService,
};

pub const ServiceArgs = struct {
    name: []const u8,
    display_name: []const u8,
    kind: ServiceKind = .custom,
    user_labels: []const Label = &.{},
    protect: bool = false,
};

pub const Service = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ServiceArgs) BuildError!Service {
        try provider.validate();
        try validateName(args.name);
        if (args.display_name.len == 0) return error.InvalidValue;
        var kind = try serviceKindValueOwned(allocator, args.kind);
        defer kind.deinit(allocator);
        var labels = try labelsValueOwned(allocator, args.user_labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "kind", .value = kind },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "user_labels", .value = labels },
        };
        const node = try nodeOwned(allocator, "gcp.monitoring.Service", args.name, args.name, &fields, .{ .protect = args.protect });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
    }

    pub fn deinit(self: *Service, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

pub const CalendarPeriod = enum {
    day,
    week,
    fortnight,
    month,

    pub fn apiName(self: CalendarPeriod) []const u8 {
        return switch (self) {
            .day => "DAY",
            .week => "WEEK",
            .fortnight => "FORTNIGHT",
            .month => "MONTH",
        };
    }
};

pub const SloPeriod = union(enum) {
    rolling: u32,
    calendar: CalendarPeriod,
};

pub const BasicSli = union(enum) {
    availability,
    latency: struct { threshold_seconds: f64 },
};

pub const RequestRatioSli = struct {
    good_service_filter: []const u8 = "",
    bad_service_filter: []const u8 = "",
    total_service_filter: []const u8,
};

pub const DistributionCutSli = struct {
    distribution_filter: []const u8,
    minimum: ?f64 = null,
    maximum: ?f64 = null,
};

pub const WindowsSli = struct {
    good_bad_metric_filter: []const u8,
    window_period_seconds: u32,
};

pub const Sli = union(enum) {
    basic: BasicSli,
    request_ratio: RequestRatioSli,
    distribution_cut: DistributionCutSli,
    windows: WindowsSli,
};

pub const ServiceLevelObjectiveArgs = struct {
    name: []const u8,
    service_name: []const u8,
    service: output.Output([]const u8, .public),
    display_name: []const u8,
    goal: f64,
    period: SloPeriod,
    indicator: Sli,
    user_labels: []const Label = &.{},
    protect: bool = false,
};

pub const ServiceLevelObjective = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ServiceLevelObjectiveArgs) BuildError!ServiceLevelObjective {
        try provider.validate();
        try validateName(args.name);
        try validateName(args.service_name);
        if (args.display_name.len == 0) return error.InvalidValue;
        if (!std.math.isFinite(args.goal) or args.goal <= 0 or args.goal > 1) return error.InvalidGoal;
        try validateSloPeriod(args.period);
        var period = try sloPeriodValueOwned(allocator, args.period);
        defer period.deinit(allocator);
        var indicator = try sliValueOwned(allocator, args.indicator);
        defer indicator.deinit(allocator);
        var labels = try labelsValueOwned(allocator, args.user_labels);
        defer labels.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "display_name", .value = .{ .string = args.display_name } },
            .{ .name = "goal_micros", .value = .{ .integer = @intFromFloat(args.goal * 1_000_000.0) } },
            .{ .name = "indicator", .value = indicator },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "period", .value = period },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "service", .value = try publicOutputValue(args.service) },
            .{ .name = "service_name", .value = .{ .string = args.service_name } },
            .{ .name = "user_labels", .value = labels },
        };
        const logical_id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ args.service_name, args.name });
        defer allocator.free(logical_id);
        const node = try nodeOwned(allocator, "gcp.monitoring.ServiceLevelObjective", logical_id, args.name, &fields, .{ .protect = args.protect });
        return .{ .node = node, .name = Outputs.Name.fromResource(node.id) };
    }

    pub fn deinit(self: *ServiceLevelObjective, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn uptimeTargetValueOwned(allocator: std.mem.Allocator, target: UptimeTarget) BuildError!value.Value {
    return switch (target) {
        .http => |http| blk: {
            if (!validHost(http.host) or http.path.len == 0 or http.path[0] != '/' or http.port == 0) return error.InvalidTarget;
            if (http.method == .get and http.body.len != 0) return error.InvalidTarget;
            var headers = try labelsValueOwned(allocator, http.headers);
            defer headers.deinit(allocator);
            var secret_headers = try secretFieldsValueOwned(allocator, http.secret_headers);
            defer secret_headers.deinit(allocator);
            var status = try integerListValueOwned(allocator, http.accepted_status_classes);
            defer status.deinit(allocator);
            var basic: value.Value = .{ .object = &.{} };
            if (http.basic_authentication) |authentication| {
                if (authentication.username.len == 0) return error.InvalidSecret;
                const auth_fields = [_]value.Field{
                    .{ .name = "password", .value = try secretOutputValue(authentication.password) },
                    .{ .name = "username", .value = .{ .string = authentication.username } },
                };
                basic = try ownedValue(allocator, .{ .object = &auth_fields });
            } else basic = try ownedValue(allocator, basic);
            defer basic.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "accepted_status_classes", .value = status },
                .{ .name = "basic_authentication", .value = basic },
                .{ .name = "body", .value = .{ .string = http.body } },
                .{ .name = "headers", .value = headers },
                .{ .name = "host", .value = .{ .string = http.host } },
                .{ .name = "method", .value = .{ .string = http.method.apiName() } },
                .{ .name = "path", .value = .{ .string = http.path } },
                .{ .name = "port", .value = .{ .integer = http.port } },
                .{ .name = "secret_headers", .value = secret_headers },
                .{ .name = "use_ssl", .value = .{ .boolean = http.use_ssl } },
                .{ .name = "validate_ssl", .value = .{ .boolean = http.validate_ssl } },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
        .tcp => |tcp| blk: {
            if (!validHost(tcp.host) or tcp.port == 0) return error.InvalidTarget;
            const fields = [_]value.Field{
                .{ .name = "host", .value = .{ .string = tcp.host } },
                .{ .name = "port", .value = .{ .integer = tcp.port } },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
    };
}

fn contentMatchersValueOwned(allocator: std.mem.Allocator, matchers: []const ContentMatcher) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, matchers.len);
    defer allocator.free(items);
    for (matchers, 0..) |matcher, index| {
        if (matcher.content.len == 0) return error.InvalidTarget;
        const fields = [_]value.Field{
            .{ .name = "content", .value = .{ .string = matcher.content } },
            .{ .name = "json_path", .value = .{ .string = matcher.json_path } },
            .{ .name = "matcher", .value = .{ .string = matcher.matcher.apiName() } },
        };
        items[index] = .{ .object = &fields };
    }
    return ownedValue(allocator, .{ .list = items });
}

fn conditionsValueOwned(allocator: std.mem.Allocator, conditions: []const AlertCondition) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, conditions.len);
    defer allocator.free(items);
    var initialized: usize = 0;
    defer for (items[0..initialized]) |*item| item.deinit(allocator);
    for (conditions, 0..) |condition, index| {
        try validateName(condition.id);
        if (condition.display_name.len == 0) return error.InvalidCondition;
        items[index] = try alertConditionValueOwned(allocator, condition);
        initialized += 1;
    }
    return ownedValue(allocator, .{ .list = items });
}

fn alertConditionValueOwned(allocator: std.mem.Allocator, condition: AlertCondition) BuildError!value.Value {
    return switch (condition.condition) {
        .threshold => |threshold| blk: {
            if (threshold.filter.len == 0 or !std.math.isFinite(threshold.threshold) or threshold.duration_seconds == 0 or threshold.alignment_period_seconds == 0 or !validPercent(threshold.trigger_percent)) return error.InvalidCondition;
            if (threshold.trigger_count != 0 and threshold.trigger_percent != 0) return error.InvalidCondition;
            var groups = try stringsValueOwned(allocator, threshold.group_by_fields);
            defer groups.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "alignment_period_seconds", .value = .{ .integer = threshold.alignment_period_seconds } },
                .{ .name = "comparison", .value = .{ .string = threshold.comparison.apiName() } },
                .{ .name = "cross_series_reducer", .value = .{ .string = threshold.cross_series_reducer } },
                .{ .name = "display_name", .value = .{ .string = condition.display_name } },
                .{ .name = "duration_seconds", .value = .{ .integer = threshold.duration_seconds } },
                .{ .name = "filter", .value = .{ .string = threshold.filter } },
                .{ .name = "group_by_fields", .value = groups },
                .{ .name = "id", .value = .{ .string = condition.id } },
                .{ .name = "kind", .value = .{ .string = "THRESHOLD" } },
                .{ .name = "per_series_aligner", .value = .{ .string = threshold.per_series_aligner } },
                .{ .name = "threshold_micros", .value = .{ .integer = @intFromFloat(threshold.threshold * 1_000_000.0) } },
                .{ .name = "trigger_count", .value = .{ .integer = threshold.trigger_count } },
                .{ .name = "trigger_percent_micros", .value = .{ .integer = @intFromFloat(threshold.trigger_percent * 1_000_000.0) } },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
        .absence => |absence| blk: {
            if (absence.filter.len == 0 or absence.duration_seconds == 0 or absence.alignment_period_seconds == 0 or !validPercent(absence.trigger_percent)) return error.InvalidCondition;
            if (absence.trigger_count != 0 and absence.trigger_percent != 0) return error.InvalidCondition;
            const fields = [_]value.Field{
                .{ .name = "alignment_period_seconds", .value = .{ .integer = absence.alignment_period_seconds } },
                .{ .name = "display_name", .value = .{ .string = condition.display_name } },
                .{ .name = "duration_seconds", .value = .{ .integer = absence.duration_seconds } },
                .{ .name = "filter", .value = .{ .string = absence.filter } },
                .{ .name = "id", .value = .{ .string = condition.id } },
                .{ .name = "kind", .value = .{ .string = "ABSENCE" } },
                .{ .name = "per_series_aligner", .value = .{ .string = absence.per_series_aligner } },
                .{ .name = "trigger_count", .value = .{ .integer = absence.trigger_count } },
                .{ .name = "trigger_percent_micros", .value = .{ .integer = @intFromFloat(absence.trigger_percent * 1_000_000.0) } },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
        .promql => |promql| blk: {
            if (promql.query.len == 0 or promql.evaluation_interval_seconds < 30) return error.InvalidCondition;
            const fields = [_]value.Field{
                .{ .name = "disable_metric_validation", .value = .{ .boolean = promql.disable_metric_validation } },
                .{ .name = "display_name", .value = .{ .string = condition.display_name } },
                .{ .name = "duration_seconds", .value = .{ .integer = promql.duration_seconds } },
                .{ .name = "evaluation_interval_seconds", .value = .{ .integer = promql.evaluation_interval_seconds } },
                .{ .name = "id", .value = .{ .string = condition.id } },
                .{ .name = "kind", .value = .{ .string = "PROMQL" } },
                .{ .name = "query", .value = .{ .string = promql.query } },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
        .log_match => |match| blk: {
            if (match.filter.len == 0) return error.InvalidCondition;
            var extractors = try labelsValueOwned(allocator, match.label_extractors);
            defer extractors.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "display_name", .value = .{ .string = condition.display_name } },
                .{ .name = "filter", .value = .{ .string = match.filter } },
                .{ .name = "id", .value = .{ .string = condition.id } },
                .{ .name = "kind", .value = .{ .string = "LOG_MATCH" } },
                .{ .name = "label_extractors", .value = extractors },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
    };
}

fn dashboardTilesValueOwned(allocator: std.mem.Allocator, columns: u16, tiles: []const DashboardTile) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, tiles.len);
    defer allocator.free(items);
    var initialized: usize = 0;
    defer for (items[0..initialized]) |*item| item.deinit(allocator);
    for (tiles, 0..) |tile, index| {
        if (tile.width == 0 or tile.height == 0 or tile.x + tile.width > columns) return error.InvalidWidget;
        var widget = try widgetValueOwned(allocator, tile.widget);
        defer widget.deinit(allocator);
        const fields = [_]value.Field{
            .{ .name = "height", .value = .{ .integer = tile.height } },
            .{ .name = "widget", .value = widget },
            .{ .name = "width", .value = .{ .integer = tile.width } },
            .{ .name = "x", .value = .{ .integer = tile.x } },
            .{ .name = "y", .value = .{ .integer = tile.y } },
        };
        items[index] = try ownedValue(allocator, .{ .object = &fields });
        initialized += 1;
    }
    return ownedValue(allocator, .{ .list = items });
}

fn widgetValueOwned(allocator: std.mem.Allocator, widget: Widget) BuildError!value.Value {
    return switch (widget) {
        .text => |text| blk: {
            if (text.content.len == 0) return error.InvalidWidget;
            const fields = [_]value.Field{
                .{ .name = "content", .value = .{ .string = text.content } },
                .{ .name = "kind", .value = .{ .string = "TEXT" } },
                .{ .name = "title", .value = .{ .string = text.title } },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
        .xy_chart => |chart| blk: {
            if (chart.title.len == 0 or chart.series.len == 0) return error.InvalidWidget;
            var series = try timeSeriesValueOwned(allocator, chart.series);
            defer series.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "kind", .value = .{ .string = "XY_CHART" } },
                .{ .name = "series", .value = series },
                .{ .name = "title", .value = .{ .string = chart.title } },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
        .scorecard => |scorecard| blk: {
            if (scorecard.title.len == 0) return error.InvalidWidget;
            var series = try timeSeriesValueOwned(allocator, &.{scorecard.series});
            defer series.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "kind", .value = .{ .string = "SCORECARD" } },
                .{ .name = "series", .value = series },
                .{ .name = "title", .value = .{ .string = scorecard.title } },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
        .logs_panel => |logs| blk: {
            if (logs.title.len == 0 or logs.filter.len == 0) return error.InvalidWidget;
            const fields = [_]value.Field{
                .{ .name = "filter", .value = .{ .string = logs.filter } },
                .{ .name = "kind", .value = .{ .string = "LOGS_PANEL" } },
                .{ .name = "title", .value = .{ .string = logs.title } },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
        .alert_chart => |chart| blk: {
            if (chart.title.len == 0) return error.InvalidWidget;
            const fields = [_]value.Field{
                .{ .name = "alert_policy", .value = try publicOutputValue(chart.alert_policy) },
                .{ .name = "kind", .value = .{ .string = "ALERT_CHART" } },
                .{ .name = "title", .value = .{ .string = chart.title } },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
        .incident_list => |incidents| blk: {
            if (incidents.title.len == 0 or incidents.alert_policies.len == 0) return error.InvalidWidget;
            var policies = try outputStringsValueOwned(allocator, incidents.alert_policies);
            defer policies.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "alert_policies", .value = policies },
                .{ .name = "kind", .value = .{ .string = "INCIDENT_LIST" } },
                .{ .name = "title", .value = .{ .string = incidents.title } },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
    };
}

fn timeSeriesValueOwned(allocator: std.mem.Allocator, series: []const TimeSeries) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, series.len);
    defer allocator.free(items);
    for (series, 0..) |item, index| {
        if (item.filter.len == 0 or item.alignment_period_seconds == 0) return error.InvalidWidget;
        const fields = [_]value.Field{
            .{ .name = "alignment_period_seconds", .value = .{ .integer = item.alignment_period_seconds } },
            .{ .name = "cross_series_reducer", .value = .{ .string = item.cross_series_reducer } },
            .{ .name = "filter", .value = .{ .string = item.filter } },
            .{ .name = "legend", .value = .{ .string = item.legend } },
            .{ .name = "per_series_aligner", .value = .{ .string = item.per_series_aligner } },
            .{ .name = "plot_type", .value = .{ .string = item.plot_type } },
        };
        items[index] = .{ .object = &fields };
    }
    return ownedValue(allocator, .{ .list = items });
}

fn serviceKindValueOwned(allocator: std.mem.Allocator, kind: ServiceKind) BuildError!value.Value {
    return switch (kind) {
        .custom => ownedValue(allocator, .{ .object = &.{.{ .name = "kind", .value = .{ .string = "CUSTOM" } }} }),
        .basic => |basic| blk: {
            if (basic.service_type.len == 0 or basic.service_labels.len == 0) return error.InvalidTarget;
            var labels = try labelsValueOwned(allocator, basic.service_labels);
            defer labels.deinit(allocator);
            const fields = [_]value.Field{
                .{ .name = "kind", .value = .{ .string = "BASIC" } },
                .{ .name = "service_labels", .value = labels },
                .{ .name = "service_type", .value = .{ .string = basic.service_type } },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
        .cloud_run => |run| blk: {
            if (run.service_name.len == 0 or run.location.len == 0) return error.InvalidTarget;
            const fields = [_]value.Field{
                .{ .name = "kind", .value = .{ .string = "CLOUD_RUN" } },
                .{ .name = "location", .value = .{ .string = run.location } },
                .{ .name = "service_name", .value = .{ .string = run.service_name } },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
        .gke_workload => |gke| blk: {
            if (gke.project_id.len == 0 or gke.location.len == 0 or gke.cluster_name.len == 0 or gke.namespace_name.len == 0 or gke.top_level_controller_type.len == 0 or gke.top_level_controller_name.len == 0) return error.InvalidTarget;
            const fields = [_]value.Field{
                .{ .name = "cluster_name", .value = .{ .string = gke.cluster_name } },
                .{ .name = "kind", .value = .{ .string = "GKE_WORKLOAD" } },
                .{ .name = "location", .value = .{ .string = gke.location } },
                .{ .name = "namespace_name", .value = .{ .string = gke.namespace_name } },
                .{ .name = "project_id", .value = .{ .string = gke.project_id } },
                .{ .name = "top_level_controller_name", .value = .{ .string = gke.top_level_controller_name } },
                .{ .name = "top_level_controller_type", .value = .{ .string = gke.top_level_controller_type } },
            };
            break :blk try ownedValue(allocator, .{ .object = &fields });
        },
    };
}

fn sloPeriodValueOwned(allocator: std.mem.Allocator, period: SloPeriod) BuildError!value.Value {
    return switch (period) {
        .rolling => |seconds| ownedValue(allocator, .{ .object = &.{
            .{ .name = "kind", .value = .{ .string = "ROLLING" } },
            .{ .name = "seconds", .value = .{ .integer = seconds } },
        } }),
        .calendar => |calendar| ownedValue(allocator, .{ .object = &.{
            .{ .name = "kind", .value = .{ .string = "CALENDAR" } },
            .{ .name = "value", .value = .{ .string = calendar.apiName() } },
        } }),
    };
}

fn sliValueOwned(allocator: std.mem.Allocator, indicator: Sli) BuildError!value.Value {
    return switch (indicator) {
        .basic => |basic| switch (basic) {
            .availability => ownedValue(allocator, .{ .object = &.{
                .{ .name = "kind", .value = .{ .string = "BASIC_AVAILABILITY" } },
            } }),
            .latency => |latency| blk: {
                if (!std.math.isFinite(latency.threshold_seconds) or latency.threshold_seconds <= 0) return error.InvalidGoal;
                break :blk ownedValue(allocator, .{ .object = &.{
                    .{ .name = "kind", .value = .{ .string = "BASIC_LATENCY" } },
                    .{ .name = "threshold_micros", .value = .{ .integer = @intFromFloat(latency.threshold_seconds * 1_000_000.0) } },
                } });
            },
        },
        .request_ratio => |ratio| blk: {
            if (ratio.total_service_filter.len == 0 or (ratio.good_service_filter.len == 0) == (ratio.bad_service_filter.len == 0)) return error.InvalidGoal;
            const fields = [_]value.Field{
                .{ .name = "bad_service_filter", .value = .{ .string = ratio.bad_service_filter } },
                .{ .name = "good_service_filter", .value = .{ .string = ratio.good_service_filter } },
                .{ .name = "kind", .value = .{ .string = "REQUEST_RATIO" } },
                .{ .name = "total_service_filter", .value = .{ .string = ratio.total_service_filter } },
            };
            break :blk ownedValue(allocator, .{ .object = &fields });
        },
        .distribution_cut => |cut| blk: {
            if (cut.distribution_filter.len == 0 or (cut.minimum == null and cut.maximum == null)) return error.InvalidGoal;
            if (cut.minimum) |minimum| if (!std.math.isFinite(minimum)) return error.InvalidGoal;
            if (cut.maximum) |maximum| if (!std.math.isFinite(maximum)) return error.InvalidGoal;
            const minimum = if (cut.minimum) |number| @as(i64, @intFromFloat(number * 1_000_000.0)) else std.math.minInt(i64);
            const maximum = if (cut.maximum) |number| @as(i64, @intFromFloat(number * 1_000_000.0)) else std.math.maxInt(i64);
            const fields = [_]value.Field{
                .{ .name = "distribution_filter", .value = .{ .string = cut.distribution_filter } },
                .{ .name = "kind", .value = .{ .string = "DISTRIBUTION_CUT" } },
                .{ .name = "maximum_micros", .value = .{ .integer = maximum } },
                .{ .name = "minimum_micros", .value = .{ .integer = minimum } },
            };
            break :blk ownedValue(allocator, .{ .object = &fields });
        },
        .windows => |windows| blk: {
            if (windows.good_bad_metric_filter.len == 0 or windows.window_period_seconds < 60) return error.InvalidGoal;
            const fields = [_]value.Field{
                .{ .name = "good_bad_metric_filter", .value = .{ .string = windows.good_bad_metric_filter } },
                .{ .name = "kind", .value = .{ .string = "WINDOWS" } },
                .{ .name = "window_period_seconds", .value = .{ .integer = windows.window_period_seconds } },
            };
            break :blk ownedValue(allocator, .{ .object = &fields });
        },
    };
}

fn labelsValueOwned(allocator: std.mem.Allocator, labels: []const Label) BuildError!value.Value {
    const fields = try allocator.alloc(value.Field, labels.len);
    defer allocator.free(fields);
    for (labels, 0..) |label, index| {
        try validateLabel(label.key, label.value);
        fields[index] = .{ .name = label.key, .value = .{ .string = label.value } };
    }
    return ownedValue(allocator, .{ .object = fields }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateValue,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn secretFieldsValueOwned(allocator: std.mem.Allocator, fields_source: []const SecretField) BuildError!value.Value {
    const fields = try allocator.alloc(value.Field, fields_source.len);
    defer allocator.free(fields);
    for (fields_source, 0..) |field, index| {
        try validateLabel(field.key, "");
        fields[index] = .{ .name = field.key, .value = try secretOutputValue(field.value) };
    }
    return ownedValue(allocator, .{ .object = fields }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateValue,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn stringsValueOwned(allocator: std.mem.Allocator, strings: []const []const u8) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, strings.len);
    defer allocator.free(items);
    for (strings, 0..) |text, index| {
        if (text.len == 0) return error.InvalidValue;
        items[index] = .{ .string = text };
    }
    return ownedValue(allocator, .{ .list = items });
}

fn integerListValueOwned(allocator: std.mem.Allocator, integers: []const u16) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, integers.len);
    defer allocator.free(items);
    for (integers, 0..) |number, index| {
        if (number == 0 or number > 5) return error.InvalidTarget;
        items[index] = .{ .integer = number };
    }
    return ownedValue(allocator, .{ .list = items });
}

fn outputStringsValueOwned(allocator: std.mem.Allocator, outputs: []const output.Output([]const u8, .public)) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, outputs.len);
    defer allocator.free(items);
    for (outputs, 0..) |candidate, index| items[index] = try publicOutputValue(candidate);
    return ownedValue(allocator, .{ .list = items });
}

fn nodeOwned(allocator: std.mem.Allocator, type_name: []const u8, logical_id: []const u8, name: []const u8, fields: []const value.Field, lifecycle: resource.Lifecycle) BuildError!resource.ResourceNode {
    const id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ type_name, logical_id });
    defer allocator.free(id);
    return resource.ResourceNode.initOwned(allocator, .{
        .id = id,
        .provider = .gcp,
        .type_name = type_name,
        .logical_id = name,
        .inputs = .{ .object = fields },
        .lifecycle = lifecycle,
    }) catch |err| switch (err) {
        error.DuplicateField => error.DuplicateField,
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
    };
}

fn ownedValue(allocator: std.mem.Allocator, source: value.Value) (std.mem.Allocator.Error || error{DuplicateField})!value.Value {
    return value.Value.initOwned(allocator, source);
}

fn publicOutputValue(candidate: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (candidate) {
        .value => |text| .{ .string = text },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn secretOutputValue(candidate: output.Output(value.SecretReference, .secret)) BuildError!value.Value {
    return switch (candidate) {
        .value => |reference| .{ .secret_ref = reference },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn validateName(name: []const u8) BuildError!void {
    if (name.len == 0 or name.len > 63 or !std.ascii.isLower(name[0])) return error.InvalidName;
    if (!std.ascii.isLower(name[name.len - 1]) and !std.ascii.isDigit(name[name.len - 1])) return error.InvalidName;
    for (name) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return error.InvalidName;
}

fn validateLabel(key: []const u8, text: []const u8) BuildError!void {
    if (key.len == 0 or key.len > 63 or text.len > 1_024) return error.InvalidLabel;
    for (key) |character| if (!std.ascii.isAlphanumeric(character) and character != '_' and character != '-') return error.InvalidLabel;
    if (std.mem.indexOfAny(u8, text, "\x00\r\n") != null) return error.InvalidLabel;
}

fn validPeriod(seconds: u32) bool {
    return seconds == 60 or seconds == 300 or seconds == 600 or seconds == 900;
}

fn validateSloPeriod(period: SloPeriod) BuildError!void {
    switch (period) {
        .rolling => |seconds| if (seconds < 86_400 or seconds > 2_592_000) return error.InvalidPeriod,
        .calendar => {},
    }
}

fn validHost(host: []const u8) bool {
    return host.len != 0 and host.len <= 253 and std.mem.indexOfAny(u8, host, "\x00\r\n /:") == null;
}

fn validPercent(number: f64) bool {
    return std.math.isFinite(number) and number >= 0 and number <= 1;
}
