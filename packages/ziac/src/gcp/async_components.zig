const std = @import("std");
const cloud_run = @import("cloud_run.zig");
const config_mod = @import("config.zig");
const eventarc = @import("eventarc.zig");
const iam = @import("iam.zig");
const output = @import("../output.zig");
const pubsub = @import("pubsub.zig");
const resource = @import("../resource.zig");
const tasks = @import("tasks.zig");

pub const BuildError = cloud_run.BuildError || eventarc.BuildError || iam.BuildError || pubsub.BuildError ||
    tasks.BuildError || resource.ResourceGraphError || error{ InvalidEndpoint, InvalidTransport };

pub const ZigTaskWorkerArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    service: output.Output([]const u8, .public),
    endpoint: []const u8,
    service_account_id: []const u8 = "",
    enqueuers: []const []const u8 = &.{},
    max_dispatches_per_second: f64 = 100,
    max_concurrent_dispatches: u16 = 100,
    retry_config: tasks.RetryConfig = .{},
    logging_sample_ratio: f64 = 0.1,
    retain_on_delete: bool = true,
};

pub const ZigTaskWorker = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    queue: tasks.Queue.Outputs.Name.OutputType,
    service_account: iam.ServiceAccount.Outputs.Email.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: ZigTaskWorkerArgs) BuildError!ZigTaskWorker {
        const endpoint = try parseEndpoint(args.endpoint);
        const account_id = if (args.service_account_id.len > 0)
            try allocator.dupe(u8, args.service_account_id)
        else
            try accountIdAlloc(allocator, args.name, "tasks");
        defer allocator.free(account_id);
        const account_email = try std.fmt.allocPrint(allocator, "{s}@{s}.iam.gserviceaccount.com", .{ account_id, provider.project_id });
        defer allocator.free(account_email);
        const account_member = try std.fmt.allocPrint(allocator, "serviceAccount:{s}", .{account_email});
        defer allocator.free(account_member);

        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);

        const account_index = graph.resources.items.len;
        var account = try iam.ServiceAccount.build(allocator, provider, .{
            .account_id = account_id,
            .display_name = "Ziac Cloud Tasks invocation identity",
            .description = "Mints OIDC tokens for a private Cloud Run task worker",
        });
        defer account.deinit(allocator);
        try graph.addResource(account.node);
        const account_resource_id = graph.resources.items[account_index].id;

        const queue_index = graph.resources.items.len;
        var queue = try tasks.Queue.build(allocator, provider, .{
            .name = args.name,
            .rate_limits = .{
                .max_dispatches_per_second = args.max_dispatches_per_second,
                .max_concurrent_dispatches = args.max_concurrent_dispatches,
            },
            .retry_config = args.retry_config,
            .http_target = .{
                .uri_override = .{
                    .scheme = .https,
                    .host = endpoint.host,
                    .path = endpoint.path,
                    .enforce_mode = .always,
                },
                .method = .post,
                .headers = &.{.{ .key = "content-type", .value = "application/json" }},
                .authorization = .{ .oidc = .{
                    .service_account_email = account_email,
                    .audience = endpoint.origin,
                } },
            },
            .logging_sample_ratio = args.logging_sample_ratio,
            .retain_on_delete = args.retain_on_delete,
        });
        defer queue.deinit(allocator);
        try graph.addResource(queue.node);
        const queue_resource_id = graph.resources.items[queue_index].id;
        try graph.addDependency(queue_resource_id, account_resource_id);

        const invoker_name = try std.fmt.allocPrint(allocator, "{s}-invoker", .{args.name});
        defer allocator.free(invoker_name);
        var invoker = try cloud_run.ServiceIamMember.build(allocator, provider, .{
            .name = invoker_name,
            .service = args.service,
            .role = "roles/run.invoker",
            .member = account_member,
        });
        defer invoker.deinit(allocator);
        try graph.addResource(invoker.node);
        try graph.addDependency(invoker.node.id, account_resource_id);

        for (args.enqueuers, 0..) |member, index| {
            const binding_name = try std.fmt.allocPrint(allocator, "{s}-enqueuer-{d}", .{ args.name, index + 1 });
            defer allocator.free(binding_name);
            var binding = try tasks.QueueIamMember.build(allocator, provider, .{
                .name = binding_name,
                .queue = tasks.Queue.Outputs.Name.fromResource(queue_resource_id),
                .role = "roles/cloudtasks.enqueuer",
                .member = member,
            });
            defer binding.deinit(allocator);
            try graph.addResource(binding.node);
        }
        try graph.validateAcyclic();
        return .{
            .allocator = allocator,
            .graph = graph,
            .queue = tasks.Queue.Outputs.Name.fromResource(queue_resource_id),
            .service_account = iam.ServiceAccount.Outputs.Email.fromResource(account_resource_id),
        };
    }

    pub fn deinit(self: *ZigTaskWorker) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

pub const EventPipelineArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    service: output.Output([]const u8, .public),
    service_name: []const u8,
    destination_region: ?[]const u8 = null,
    destination_path: []const u8 = "/events",
    event_filters: []const eventarc.EventFilter,
    service_account_id: []const u8 = "",
    transport_topic: ?output.Output([]const u8, .public) = null,
    create_transport_topic: bool = false,
    publishers: []const []const u8 = &.{},
    channel: []const u8 = "",
    retain_on_delete: bool = true,
};

pub const EventPipeline = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    trigger: eventarc.Trigger.Outputs.Name.OutputType,
    transport_topic: ?pubsub.Topic.Outputs.Name.OutputType,
    service_account: iam.ServiceAccount.Outputs.Email.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: EventPipelineArgs) BuildError!EventPipeline {
        if (args.create_transport_topic and args.transport_topic != null) return error.InvalidTransport;
        if (!args.create_transport_topic and args.transport_topic == null and args.publishers.len > 0) return error.InvalidTransport;
        const account_id = if (args.service_account_id.len > 0)
            try allocator.dupe(u8, args.service_account_id)
        else
            try accountIdAlloc(allocator, args.name, "events");
        defer allocator.free(account_id);
        const account_email = try std.fmt.allocPrint(allocator, "{s}@{s}.iam.gserviceaccount.com", .{ account_id, provider.project_id });
        defer allocator.free(account_email);
        const account_member = try std.fmt.allocPrint(allocator, "serviceAccount:{s}", .{account_email});
        defer allocator.free(account_member);

        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);

        const account_index = graph.resources.items.len;
        var account = try iam.ServiceAccount.build(allocator, provider, .{
            .account_id = account_id,
            .display_name = "Ziac Eventarc invocation identity",
            .description = "Invokes a private Cloud Run event consumer",
        });
        defer account.deinit(allocator);
        try graph.addResource(account.node);
        const account_resource_id = graph.resources.items[account_index].id;

        var topic_output = args.transport_topic;
        var topic_resource_id: ?[]const u8 = null;
        if (args.create_transport_topic) {
            const topic_index = graph.resources.items.len;
            var topic = try pubsub.Topic.build(allocator, provider, .{
                .name = args.name,
                .message_retention_seconds = 24 * 60 * 60,
                .retain_on_delete = args.retain_on_delete,
            });
            defer topic.deinit(allocator);
            try graph.addResource(topic.node);
            topic_resource_id = graph.resources.items[topic_index].id;
            topic_output = pubsub.Topic.Outputs.Name.fromResource(topic_resource_id.?);
        }

        const trigger_index = graph.resources.items.len;
        var trigger = try eventarc.Trigger.build(allocator, provider, .{
            .name = args.name,
            .event_filters = args.event_filters,
            .service_account = account_email,
            .destination = .{ .cloud_run = .{
                .service = args.service_name,
                .region = args.destination_region orelse provider.primary_region,
                .path = args.destination_path,
            } },
            .transport_topic = topic_output,
            .channel = args.channel,
            .retain_on_delete = args.retain_on_delete,
        });
        defer trigger.deinit(allocator);
        try graph.addResource(trigger.node);
        const trigger_resource_id = graph.resources.items[trigger_index].id;
        try graph.addDependency(trigger_resource_id, account_resource_id);

        const invoker_name = try std.fmt.allocPrint(allocator, "{s}-invoker", .{args.name});
        defer allocator.free(invoker_name);
        var invoker = try cloud_run.ServiceIamMember.build(allocator, provider, .{
            .name = invoker_name,
            .service = args.service,
            .role = "roles/run.invoker",
            .member = account_member,
        });
        defer invoker.deinit(allocator);
        try graph.addResource(invoker.node);
        try graph.addDependency(invoker.node.id, account_resource_id);

        if (topic_output) |topic| {
            for (args.publishers, 0..) |member, index| {
                const binding_name = try std.fmt.allocPrint(allocator, "{s}-publisher-{d}", .{ args.name, index + 1 });
                defer allocator.free(binding_name);
                var binding = try pubsub.TopicIamMember.build(allocator, provider, .{
                    .name = binding_name,
                    .topic = topic,
                    .role = "roles/pubsub.publisher",
                    .member = member,
                });
                defer binding.deinit(allocator);
                try graph.addResource(binding.node);
            }
        }
        try graph.validateAcyclic();
        return .{
            .allocator = allocator,
            .graph = graph,
            .trigger = eventarc.Trigger.Outputs.Name.fromResource(trigger_resource_id),
            .transport_topic = topic_output,
            .service_account = iam.ServiceAccount.Outputs.Email.fromResource(account_resource_id),
        };
    }

    pub fn deinit(self: *EventPipeline) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

const ParsedEndpoint = struct {
    origin: []const u8,
    host: []const u8,
    path: []const u8,
};

fn parseEndpoint(endpoint: []const u8) BuildError!ParsedEndpoint {
    if (!std.mem.startsWith(u8, endpoint, "https://") or std.mem.indexOfAny(u8, endpoint, "\x00\r\n ?#") != null) return error.InvalidEndpoint;
    const host_start = "https://".len;
    const slash = std.mem.indexOfScalarPos(u8, endpoint, host_start, '/') orelse endpoint.len;
    if (slash == host_start) return error.InvalidEndpoint;
    return .{
        .origin = endpoint[0..slash],
        .host = endpoint[host_start..slash],
        .path = if (slash < endpoint.len) endpoint[slash..] else "/",
    };
}

fn accountIdAlloc(allocator: std.mem.Allocator, name: []const u8, suffix: []const u8) std.mem.Allocator.Error![]const u8 {
    var slug = std.ArrayList(u8).empty;
    defer slug.deinit(allocator);
    if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) try slug.append(allocator, 'z');
    const max_base = 29 - suffix.len;
    for (name) |character| {
        if (slug.items.len == max_base) break;
        const normalized = if (std.ascii.isAlphabetic(character)) std.ascii.toLower(character) else if (std.ascii.isDigit(character) or character == '-') character else '-';
        try slug.append(allocator, normalized);
    }
    while (slug.items.len > 0 and slug.items[slug.items.len - 1] == '-') _ = slug.pop();
    while (slug.items.len < 1) try slug.append(allocator, 'z');
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ slug.items, suffix });
}
