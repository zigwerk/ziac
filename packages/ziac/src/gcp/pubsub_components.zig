const std = @import("std");
const cloud_run = @import("cloud_run.zig");
const config_mod = @import("config.zig");
const iam = @import("iam.zig");
const output = @import("../output.zig");
const pubsub = @import("pubsub.zig");
const resource = @import("../resource.zig");

pub const BuildError = cloud_run.BuildError || iam.BuildError || pubsub.BuildError || resource.ResourceGraphError || error{
    InvalidProjectNumber,
    InvalidPushEndpoint,
};

pub const ZigSubscriberArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    project_number: []const u8,
    service: output.Output([]const u8, .public),
    push_endpoint: []const u8,
    oidc_audience: []const u8 = "",
    push_account_id: []const u8 = "",
    topic_name: []const u8 = "",
    subscription_name: []const u8 = "",
    dead_letter_topic_name: []const u8 = "",
    publishers: []const []const u8 = &.{},
    allowed_persistence_regions: []const []const u8 = &.{},
    topic_retention_seconds: u32 = 24 * 60 * 60,
    subscription_retention_seconds: u32 = 7 * 24 * 60 * 60,
    ack_deadline_seconds: u16 = 30,
    enable_message_ordering: bool = false,
    enable_exactly_once_delivery: bool = false,
    filter: []const u8 = "",
    max_delivery_attempts: u8 = 10,
    retry_policy: pubsub.RetryPolicy = .{},
    retain_on_delete: bool = true,
};

pub const ZigSubscriber = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    topic: pubsub.Topic.Outputs.Name.OutputType,
    subscription: pubsub.Subscription.Outputs.Name.OutputType,
    dead_letter_topic: pubsub.Topic.Outputs.Name.OutputType,
    push_service_account: iam.ServiceAccount.Outputs.Email.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: ZigSubscriberArgs,
    ) BuildError!ZigSubscriber {
        if (!validProjectNumber(args.project_number)) return error.InvalidProjectNumber;
        if (!validHttpsUrl(args.push_endpoint) or
            (args.oidc_audience.len > 0 and !validHttpsUrl(args.oidc_audience))) return error.InvalidPushEndpoint;

        const account_id = if (args.push_account_id.len > 0)
            try allocator.dupe(u8, args.push_account_id)
        else
            try accountIdAlloc(allocator, args.name);
        defer allocator.free(account_id);
        const topic_name = try selectedNameAlloc(allocator, args.topic_name, args.name, "");
        defer allocator.free(topic_name);
        const subscription_name = try selectedNameAlloc(allocator, args.subscription_name, args.name, "-push");
        defer allocator.free(subscription_name);
        const dead_letter_name = try selectedNameAlloc(allocator, args.dead_letter_topic_name, args.name, "-dead-letter");
        defer allocator.free(dead_letter_name);
        const push_email = try std.fmt.allocPrint(allocator, "{s}@{s}.iam.gserviceaccount.com", .{ account_id, provider.project_id });
        defer allocator.free(push_email);
        const push_member = try std.fmt.allocPrint(allocator, "serviceAccount:{s}", .{push_email});
        defer allocator.free(push_member);
        const service_agent = try std.fmt.allocPrint(
            allocator,
            "serviceAccount:service-{s}@gcp-sa-pubsub.iam.gserviceaccount.com",
            .{args.project_number},
        );
        defer allocator.free(service_agent);

        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);

        const account_index = graph.resources.items.len;
        var account = try iam.ServiceAccount.build(allocator, provider, .{
            .account_id = account_id,
            .display_name = "Ziac Pub/Sub push identity",
            .description = "Invokes the Cloud Run event consumer with an OIDC token",
        });
        defer account.deinit(allocator);
        try graph.addResource(account.node);
        const account_resource_id = graph.resources.items[account_index].id;

        const topic_index = graph.resources.items.len;
        var topic = try pubsub.Topic.build(allocator, provider, .{
            .name = topic_name,
            .message_retention_seconds = args.topic_retention_seconds,
            .allowed_persistence_regions = args.allowed_persistence_regions,
            .enforce_in_transit = args.allowed_persistence_regions.len > 0,
            .retain_on_delete = args.retain_on_delete,
        });
        defer topic.deinit(allocator);
        try graph.addResource(topic.node);
        const topic_resource_id = graph.resources.items[topic_index].id;

        const dead_letter_index = graph.resources.items.len;
        var dead_letter = try pubsub.Topic.build(allocator, provider, .{
            .name = dead_letter_name,
            .message_retention_seconds = 7 * 24 * 60 * 60,
            .allowed_persistence_regions = args.allowed_persistence_regions,
            .enforce_in_transit = args.allowed_persistence_regions.len > 0,
            .retain_on_delete = args.retain_on_delete,
        });
        defer dead_letter.deinit(allocator);
        try graph.addResource(dead_letter.node);
        const dead_letter_resource_id = graph.resources.items[dead_letter_index].id;

        const subscription_index = graph.resources.items.len;
        var subscription = try pubsub.Subscription.build(allocator, provider, .{
            .name = subscription_name,
            .topic = pubsub.Topic.Outputs.Name.fromResource(topic_resource_id),
            .delivery = .{ .push = .{
                .endpoint = args.push_endpoint,
                .oidc_service_account_email = push_email,
                .oidc_audience = if (args.oidc_audience.len > 0) args.oidc_audience else args.push_endpoint,
            } },
            .ack_deadline_seconds = args.ack_deadline_seconds,
            .message_retention_seconds = args.subscription_retention_seconds,
            .expiration = .never,
            .enable_message_ordering = args.enable_message_ordering,
            .enable_exactly_once_delivery = args.enable_exactly_once_delivery,
            .filter = args.filter,
            .dead_letter_topic = pubsub.Topic.Outputs.Name.fromResource(dead_letter_resource_id),
            .max_delivery_attempts = args.max_delivery_attempts,
            .retry_policy = args.retry_policy,
            .retain_on_delete = args.retain_on_delete,
        });
        defer subscription.deinit(allocator);
        try graph.addResource(subscription.node);
        const subscription_resource_id = graph.resources.items[subscription_index].id;
        try graph.addDependency(subscription_resource_id, account_resource_id);

        const invoker_name = try std.fmt.allocPrint(allocator, "{s}-invoker", .{account_id});
        defer allocator.free(invoker_name);
        var invoker = try cloud_run.ServiceIamMember.build(allocator, provider, .{
            .name = invoker_name,
            .service = args.service,
            .role = "roles/run.invoker",
            .member = push_member,
        });
        defer invoker.deinit(allocator);
        try graph.addResource(invoker.node);
        try graph.addDependency(invoker.node.id, account_resource_id);

        const dead_letter_publisher_name = try std.fmt.allocPrint(allocator, "{s}-dead-letter-publisher", .{args.name});
        defer allocator.free(dead_letter_publisher_name);
        var dead_letter_publisher = try pubsub.TopicIamMember.build(allocator, provider, .{
            .name = dead_letter_publisher_name,
            .topic = pubsub.Topic.Outputs.Name.fromResource(dead_letter_resource_id),
            .role = "roles/pubsub.publisher",
            .member = service_agent,
        });
        defer dead_letter_publisher.deinit(allocator);
        try graph.addResource(dead_letter_publisher.node);

        const acknowledger_name = try std.fmt.allocPrint(allocator, "{s}-dead-letter-acknowledger", .{args.name});
        defer allocator.free(acknowledger_name);
        var dead_letter_acknowledger = try pubsub.SubscriptionIamMember.build(allocator, provider, .{
            .name = acknowledger_name,
            .subscription = pubsub.Subscription.Outputs.Name.fromResource(subscription_resource_id),
            .role = "roles/pubsub.subscriber",
            .member = service_agent,
        });
        defer dead_letter_acknowledger.deinit(allocator);
        try graph.addResource(dead_letter_acknowledger.node);

        for (args.publishers, 0..) |publisher, index| {
            const binding_name = try std.fmt.allocPrint(allocator, "{s}-publisher-{d}", .{ args.name, index + 1 });
            defer allocator.free(binding_name);
            var access = try pubsub.TopicIamMember.build(allocator, provider, .{
                .name = binding_name,
                .topic = pubsub.Topic.Outputs.Name.fromResource(topic_resource_id),
                .role = "roles/pubsub.publisher",
                .member = publisher,
            });
            defer access.deinit(allocator);
            try graph.addResource(access.node);
        }
        try graph.validateAcyclic();

        return .{
            .allocator = allocator,
            .graph = graph,
            .topic = pubsub.Topic.Outputs.Name.fromResource(topic_resource_id),
            .subscription = pubsub.Subscription.Outputs.Name.fromResource(subscription_resource_id),
            .dead_letter_topic = pubsub.Topic.Outputs.Name.fromResource(dead_letter_resource_id),
            .push_service_account = iam.ServiceAccount.Outputs.Email.fromResource(account_resource_id),
        };
    }

    pub fn deinit(self: *ZigSubscriber) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

fn selectedNameAlloc(
    allocator: std.mem.Allocator,
    selected: []const u8,
    base: []const u8,
    suffix: []const u8,
) std.mem.Allocator.Error![]const u8 {
    if (selected.len > 0) return allocator.dupe(u8, selected);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ base, suffix });
}

fn accountIdAlloc(allocator: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]const u8 {
    var slug = std.ArrayList(u8).empty;
    defer slug.deinit(allocator);
    if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) try slug.append(allocator, 'z');
    for (name) |character| {
        if (slug.items.len == 25) break;
        const normalized = if (std.ascii.isAlphabetic(character))
            std.ascii.toLower(character)
        else if (std.ascii.isDigit(character) or character == '-')
            character
        else
            '-';
        try slug.append(allocator, normalized);
    }
    while (slug.items.len > 0 and slug.items[slug.items.len - 1] == '-') _ = slug.pop();
    while (slug.items.len < 1) try slug.append(allocator, 'z');
    return std.fmt.allocPrint(allocator, "{s}-push", .{slug.items});
}

fn validProjectNumber(project_number: []const u8) bool {
    if (project_number.len < 6 or project_number.len > 30) return false;
    for (project_number) |character| if (!std.ascii.isDigit(character)) return false;
    return true;
}

fn validHttpsUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "https://") and url.len > "https://".len and
        std.mem.indexOfAny(u8, url, "\x00\r\n ") == null;
}
