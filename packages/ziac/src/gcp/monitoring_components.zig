const std = @import("std");
const config_mod = @import("config.zig");
const monitoring = @import("monitoring.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");

pub const BuildError = monitoring.BuildError || resource.ResourceGraphError || std.mem.Allocator.Error;

pub const LatencyObjective = struct {
    goal: f64,
    threshold_seconds: f64,
};

pub const ServiceObservabilityArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    display_name: []const u8,
    service_kind: monitoring.ServiceKind = .custom,
    endpoint: monitoring.HttpTarget,
    notification_channels: []const output.Output([]const u8, .public) = &.{},
    availability_goal: f64 = 0.999,
    latency: ?LatencyObjective = null,
    period: monitoring.SloPeriod = .{ .rolling = 30 * 24 * 60 * 60 },
    probe_period_seconds: u32 = 60,
    probe_timeout_seconds: u32 = 10,
    alert_duration_seconds: u32 = 120,
    user_labels: []const monitoring.Label = &.{},
    protect: bool = false,
};

pub const ServiceObservability = struct {
    graph: resource.ResourceGraph,
    service: output.Output([]const u8, .public),
    availability_slo: output.Output([]const u8, .public),
    latency_slo: ?output.Output([]const u8, .public),
    uptime_check: output.Output([]const u8, .public),
    alert_policy: output.Output([]const u8, .public),
    dashboard: output.Output([]const u8, .public),

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: ServiceObservabilityArgs,
    ) BuildError!ServiceObservability {
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);

        const service_index = graph.resources.items.len;
        var service = try monitoring.Service.build(allocator, provider, .{
            .name = args.name,
            .display_name = args.display_name,
            .kind = args.service_kind,
            .user_labels = args.user_labels,
            .protect = args.protect,
        });
        defer service.deinit(allocator);
        try graph.addResource(service.node);
        const service_id = graph.resources.items[service_index].id;
        const service_output = monitoring.Service.Outputs.Name.fromResource(service_id);

        const availability_name = try std.fmt.allocPrint(allocator, "{s}-availability", .{args.name});
        defer allocator.free(availability_name);
        const availability_display = try std.fmt.allocPrint(allocator, "{s} availability", .{args.display_name});
        defer allocator.free(availability_display);
        const availability_index = graph.resources.items.len;
        var availability = try monitoring.ServiceLevelObjective.build(allocator, provider, .{
            .name = availability_name,
            .service_name = args.name,
            .service = service_output,
            .display_name = availability_display,
            .goal = args.availability_goal,
            .period = args.period,
            .indicator = .{ .basic = .availability },
            .user_labels = args.user_labels,
            .protect = args.protect,
        });
        defer availability.deinit(allocator);
        try graph.addResource(availability.node);
        const availability_id = graph.resources.items[availability_index].id;
        const availability_output = monitoring.ServiceLevelObjective.Outputs.Name.fromResource(availability_id);

        var latency_output: ?output.Output([]const u8, .public) = null;
        var latency_id: ?[]const u8 = null;
        if (args.latency) |objective| {
            const latency_name = try std.fmt.allocPrint(allocator, "{s}-latency", .{args.name});
            defer allocator.free(latency_name);
            const latency_display = try std.fmt.allocPrint(allocator, "{s} latency", .{args.display_name});
            defer allocator.free(latency_display);
            const latency_index = graph.resources.items.len;
            var latency = try monitoring.ServiceLevelObjective.build(allocator, provider, .{
                .name = latency_name,
                .service_name = args.name,
                .service = service_output,
                .display_name = latency_display,
                .goal = objective.goal,
                .period = args.period,
                .indicator = .{ .basic = .{ .latency = .{ .threshold_seconds = objective.threshold_seconds } } },
                .user_labels = args.user_labels,
                .protect = args.protect,
            });
            defer latency.deinit(allocator);
            try graph.addResource(latency.node);
            latency_id = graph.resources.items[latency_index].id;
            latency_output = monitoring.ServiceLevelObjective.Outputs.Name.fromResource(latency_id.?);
        }

        const uptime_name = try std.fmt.allocPrint(allocator, "{s}-uptime", .{args.name});
        defer allocator.free(uptime_name);
        const uptime_display = try std.fmt.allocPrint(allocator, "{s} endpoint", .{args.display_name});
        defer allocator.free(uptime_display);
        const uptime_index = graph.resources.items.len;
        var uptime = try monitoring.UptimeCheck.build(allocator, provider, .{
            .name = uptime_name,
            .display_name = uptime_display,
            .target = .{ .http = args.endpoint },
            .period_seconds = args.probe_period_seconds,
            .timeout_seconds = args.probe_timeout_seconds,
            .user_labels = args.user_labels,
            .protect = args.protect,
        });
        defer uptime.deinit(allocator);
        try graph.addResource(uptime.node);
        const uptime_id = graph.resources.items[uptime_index].id;
        const uptime_output = monitoring.UptimeCheck.Outputs.Name.fromResource(uptime_id);
        try graph.addDependency(uptime_id, service_id);

        const uptime_filter = try std.fmt.allocPrint(
            allocator,
            "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND resource.type=\"uptime_url\" AND resource.label.host=\"{s}\"",
            .{args.endpoint.host},
        );
        defer allocator.free(uptime_filter);
        const alert_name = try std.fmt.allocPrint(allocator, "{s}-endpoint-unavailable", .{args.name});
        defer allocator.free(alert_name);
        const alert_display = try std.fmt.allocPrint(allocator, "{s} endpoint unavailable", .{args.display_name});
        defer allocator.free(alert_display);
        const alert_conditions = [_]monitoring.AlertCondition{.{
            .id = "endpoint-unavailable",
            .display_name = "Endpoint availability below one",
            .condition = .{ .threshold = .{
                .filter = uptime_filter,
                .comparison = .less_than,
                .threshold = 1,
                .duration_seconds = args.alert_duration_seconds,
                .per_series_aligner = "ALIGN_FRACTION_TRUE",
            } },
        }};
        const alert_index = graph.resources.items.len;
        var alert = try monitoring.AlertPolicy.build(allocator, provider, .{
            .name = alert_name,
            .display_name = alert_display,
            .conditions = &alert_conditions,
            .severity = .critical,
            .documentation = .{
                .subject = alert_display,
                .content = "The public service endpoint is failing its configured uptime check.",
            },
            .notification_channels = args.notification_channels,
            .user_labels = args.user_labels,
            .protect = args.protect,
        });
        defer alert.deinit(allocator);
        try graph.addResource(alert.node);
        const alert_id = graph.resources.items[alert_index].id;
        const alert_output = monitoring.AlertPolicy.Outputs.Name.fromResource(alert_id);
        try graph.addDependency(alert_id, uptime_id);

        const dashboard_name = try std.fmt.allocPrint(allocator, "{s}-operations", .{args.name});
        defer allocator.free(dashboard_name);
        const dashboard_display = try std.fmt.allocPrint(allocator, "{s} operations", .{args.display_name});
        defer allocator.free(dashboard_display);
        const tiles = [_]monitoring.DashboardTile{
            .{ .x = 0, .y = 0, .width = 16, .height = 8, .widget = .{ .scorecard = .{
                .title = "Endpoint availability",
                .series = .{ .filter = uptime_filter, .per_series_aligner = "ALIGN_FRACTION_TRUE" },
            } } },
            .{ .x = 16, .y = 0, .width = 16, .height = 8, .widget = .{ .alert_chart = .{
                .title = "Endpoint alert",
                .alert_policy = alert_output,
            } } },
            .{ .x = 32, .y = 0, .width = 16, .height = 8, .widget = .{ .incident_list = .{
                .title = "Incidents",
                .alert_policies = &.{alert_output},
            } } },
        };
        const dashboard_index = graph.resources.items.len;
        var dashboard = try monitoring.Dashboard.build(allocator, provider, .{
            .name = dashboard_name,
            .display_name = dashboard_display,
            .tiles = &tiles,
            .labels = args.user_labels,
            .protect = args.protect,
        });
        defer dashboard.deinit(allocator);
        try graph.addResource(dashboard.node);
        const dashboard_id = graph.resources.items[dashboard_index].id;
        try graph.addDependency(dashboard_id, service_id);
        try graph.addDependency(dashboard_id, availability_id);
        if (latency_id) |id| try graph.addDependency(dashboard_id, id);
        try graph.addDependency(dashboard_id, uptime_id);
        try graph.addDependency(dashboard_id, alert_id);

        try graph.validateAcyclic();
        return .{
            .graph = graph,
            .service = service_output,
            .availability_slo = availability_output,
            .latency_slo = latency_output,
            .uptime_check = uptime_output,
            .alert_policy = alert_output,
            .dashboard = monitoring.Dashboard.Outputs.Name.fromResource(dashboard_id),
        };
    }

    pub fn deinit(self: *ServiceObservability) void {
        self.graph.deinit();
        self.* = undefined;
    }
};
