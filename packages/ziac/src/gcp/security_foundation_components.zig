const std = @import("std");
const binary = @import("binary_authorization.zig");
const config_mod = @import("config.zig");
const private_ca = @import("private_ca.zig");
const securitycenter = @import("securitycenter.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");

pub const BuildError = binary.BuildError || private_ca.BuildError || securitycenter.BuildError || resource.ResourceGraphError || std.mem.Allocator.Error || error{ InvalidName, MissingOrganization };

pub const FindingMuteRule = struct {
    name: []const u8,
    description: []const u8 = "",
    config_type: securitycenter.MuteConfigType,
    filter: []const u8,
    expiry_time: []const u8 = "",
    removal_policy: securitycenter.RemovalPolicy = .retain,
};

pub const FindingResourceValueRule = struct {
    name: []const u8,
    description: []const u8 = "",
    resource_value: securitycenter.ResourceValue,
    cloud_provider: securitycenter.CloudProvider = .google_cloud,
    resource_type: []const u8 = "",
    scope: []const u8 = "",
    labels: []const config_mod.Label = &.{},
    tag_values: []const []const u8 = &.{},
    removal_policy: securitycenter.RemovalPolicy = .retain,
};

pub const SecurityFindingPipelineArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    parent: output.Output([]const u8, .public),
    organization: ?output.Output([]const u8, .public) = null,
    location: []const u8 = "global",
    topic: output.Output([]const u8, .public),
    dataset: output.Output([]const u8, .public),
    filter: []const u8,
    mute_rules: []const FindingMuteRule = &.{},
    resource_value_rules: []const FindingResourceValueRule = &.{},
    removal_policy: securitycenter.RemovalPolicy = .retain,
};

pub const SecurityFindingPipeline = struct {
    graph: resource.ResourceGraph,
    notification: output.Output([]const u8, .public),
    bigquery_export: output.Output([]const u8, .public),

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: SecurityFindingPipelineArgs) BuildError!SecurityFindingPipeline {
        try validateName(args.name);
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);
        const notification_name = try std.fmt.allocPrint(allocator, "{s}-notifications", .{args.name});
        defer allocator.free(notification_name);
        var notification = try securitycenter.NotificationConfig.build(allocator, provider, .{
            .name = notification_name,
            .parent = args.parent,
            .location = args.location,
            .pubsub_topic = args.topic,
            .filter = args.filter,
            .removal_policy = args.removal_policy,
        });
        defer notification.deinit(allocator);
        try graph.addResource(notification.node);
        const notification_id = graph.resources.items[graph.resources.items.len - 1].id;
        const export_name = try std.fmt.allocPrint(allocator, "{s}-warehouse", .{args.name});
        defer allocator.free(export_name);
        var warehouse_export = try securitycenter.BigQueryExport.build(allocator, provider, .{
            .name = export_name,
            .parent = args.parent,
            .location = args.location,
            .dataset = args.dataset,
            .filter = args.filter,
            .removal_policy = args.removal_policy,
        });
        defer warehouse_export.deinit(allocator);
        try graph.addResource(warehouse_export.node);
        const export_id = graph.resources.items[graph.resources.items.len - 1].id;
        for (args.mute_rules) |rule| {
            var mute = try securitycenter.MuteConfig.build(allocator, provider, .{
                .name = rule.name,
                .parent = args.parent,
                .location = args.location,
                .description = rule.description,
                .config_type = rule.config_type,
                .filter = rule.filter,
                .expiry_time = rule.expiry_time,
                .removal_policy = rule.removal_policy,
            });
            defer mute.deinit(allocator);
            try graph.addResource(mute.node);
        }
        if (args.resource_value_rules.len != 0 and args.organization == null) return error.MissingOrganization;
        for (args.resource_value_rules) |rule| {
            var resource_value = try securitycenter.ResourceValueConfig.build(allocator, provider, .{
                .name = rule.name,
                .organization = args.organization.?,
                .location = args.location,
                .description = rule.description,
                .resource_value = rule.resource_value,
                .cloud_provider = rule.cloud_provider,
                .resource_type = rule.resource_type,
                .scope = rule.scope,
                .labels = rule.labels,
                .tag_values = rule.tag_values,
                .removal_policy = rule.removal_policy,
            });
            defer resource_value.deinit(allocator);
            try graph.addResource(resource_value.node);
        }
        try graph.validateAcyclic();
        return .{
            .graph = graph,
            .notification = securitycenter.NotificationConfig.Outputs.Name.fromResource(notification_id),
            .bigquery_export = securitycenter.BigQueryExport.Outputs.Name.fromResource(export_id),
        };
    }

    pub fn deinit(self: *SecurityFindingPipeline) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

pub const TrustedArtifactPolicyArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    project: output.Output([]const u8, .public),
    note: output.Output([]const u8, .public),
    public_keys: []const binary.AttestorPublicKey,
    verifier_members: []const []const u8 = &.{},
    allowlist_patterns: []const []const u8 = &.{},
    enforcement: binary.Enforcement = .block_and_audit,
    removal_policy: binary.RemovalPolicy = .retain,
};

pub const TrustedArtifactPolicy = struct {
    graph: resource.ResourceGraph,
    attestor: output.Output([]const u8, .public),
    policy: output.Output([]const u8, .public),

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: TrustedArtifactPolicyArgs) BuildError!TrustedArtifactPolicy {
        try validateName(args.name);
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);
        const attestor_name = try std.fmt.allocPrint(allocator, "{s}-attestor", .{args.name});
        defer allocator.free(attestor_name);
        var attestor = try binary.Attestor.build(allocator, provider, .{
            .name = attestor_name,
            .project = args.project,
            .note_reference = args.note,
            .public_keys = args.public_keys,
            .removal_policy = args.removal_policy,
        });
        defer attestor.deinit(allocator);
        try graph.addResource(attestor.node);
        const attestor_id = graph.resources.items[graph.resources.items.len - 1].id;
        const attestor_output = binary.Attestor.Outputs.Name.fromResource(attestor_id);
        for (args.verifier_members, 0..) |member, index| {
            const binding_name = try std.fmt.allocPrint(allocator, "{s}-verifier-{d}", .{ args.name, index + 1 });
            defer allocator.free(binding_name);
            var binding = try binary.AttestorIamMember.build(allocator, provider, .{
                .name = binding_name,
                .attestor = attestor_output,
                .role = "roles/binaryauthorization.attestorsVerifier",
                .member = member,
            });
            defer binding.deinit(allocator);
            try graph.addResource(binding.node);
            try graph.addDependency(graph.resources.items[graph.resources.items.len - 1].id, attestor_id);
        }
        const policy_name = try std.fmt.allocPrint(allocator, "{s}-policy", .{args.name});
        defer allocator.free(policy_name);
        var policy = try binary.Policy.build(allocator, provider, .{
            .name = policy_name,
            .project = args.project,
            .allowlist_patterns = args.allowlist_patterns,
            .default_rule = .{ .evaluation = .require_attestation, .enforcement = args.enforcement, .attestors = &.{attestor_output} },
        });
        defer policy.deinit(allocator);
        try graph.addResource(policy.node);
        const policy_id = graph.resources.items[graph.resources.items.len - 1].id;
        try graph.addDependency(policy_id, attestor_id);
        try graph.validateAcyclic();
        return .{
            .graph = graph,
            .attestor = binary.Attestor.Outputs.Name.fromResource(attestor_id),
            .policy = binary.Policy.Outputs.Name.fromResource(policy_id),
        };
    }

    pub fn deinit(self: *TrustedArtifactPolicy) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

pub const PrivateCertificateAuthorityArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    project: output.Output([]const u8, .public),
    location: []const u8,
    subject: private_ca.Subject,
    tier: private_ca.Tier = .enterprise,
    maximum_certificate_lifetime_seconds: u64 = 86_400,
    authority_lifetime_seconds: u64 = 315_360_000,
    key_algorithm: private_ca.KeyAlgorithm = .ec_p384_sha384,
    requester_members: []const []const u8 = &.{},
    removal_policy: private_ca.RemovalPolicy = .retain,
};

pub const PrivateCertificateAuthority = struct {
    graph: resource.ResourceGraph,
    pool: output.Output([]const u8, .public),
    authority: output.Output([]const u8, .public),
    template: output.Output([]const u8, .public),

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: PrivateCertificateAuthorityArgs) BuildError!PrivateCertificateAuthority {
        try validateName(args.name);
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);
        const pool_name = try std.fmt.allocPrint(allocator, "{s}-trust", .{args.name});
        defer allocator.free(pool_name);
        var pool = try private_ca.CaPool.build(allocator, provider, .{
            .name = pool_name,
            .project = args.project,
            .location = args.location,
            .tier = args.tier,
            .maximum_lifetime_seconds = args.maximum_certificate_lifetime_seconds,
            .removal_policy = args.removal_policy,
        });
        defer pool.deinit(allocator);
        try graph.addResource(pool.node);
        const pool_id = graph.resources.items[graph.resources.items.len - 1].id;
        const pool_output = private_ca.CaPool.Outputs.Name.fromResource(pool_id);
        const authority_name = try std.fmt.allocPrint(allocator, "{s}-root", .{args.name});
        defer allocator.free(authority_name);
        var authority = try private_ca.CertificateAuthority.build(allocator, provider, .{
            .name = authority_name,
            .pool = pool_output,
            .authority_type = .self_signed,
            .lifetime_seconds = args.authority_lifetime_seconds,
            .key_algorithm = args.key_algorithm,
            .subject = args.subject,
            .removal_policy = args.removal_policy,
        });
        defer authority.deinit(allocator);
        try graph.addResource(authority.node);
        const authority_id = graph.resources.items[graph.resources.items.len - 1].id;
        try graph.addDependency(authority_id, pool_id);
        const template_name = try std.fmt.allocPrint(allocator, "{s}-workload", .{args.name});
        defer allocator.free(template_name);
        var template = try private_ca.CertificateTemplate.build(allocator, provider, .{
            .name = template_name,
            .project = args.project,
            .location = args.location,
            .maximum_lifetime_seconds = args.maximum_certificate_lifetime_seconds,
            .allow_subject_passthrough = true,
            .key_usage = .{ .digital_signature = true, .client_auth = true, .server_auth = true },
            .removal_policy = args.removal_policy,
        });
        defer template.deinit(allocator);
        try graph.addResource(template.node);
        const template_id = graph.resources.items[graph.resources.items.len - 1].id;
        for (args.requester_members, 0..) |member, index| {
            const binding_name = try std.fmt.allocPrint(allocator, "{s}-requester-{d}", .{ args.name, index + 1 });
            defer allocator.free(binding_name);
            var binding = try private_ca.CaPoolIamMember.build(allocator, provider, .{
                .name = binding_name,
                .resource = pool_output,
                .role = "roles/privateca.certificateRequester",
                .member = member,
            });
            defer binding.deinit(allocator);
            try graph.addResource(binding.node);
            try graph.addDependency(graph.resources.items[graph.resources.items.len - 1].id, pool_id);
        }
        try graph.validateAcyclic();
        return .{
            .graph = graph,
            .pool = private_ca.CaPool.Outputs.Name.fromResource(pool_id),
            .authority = private_ca.CertificateAuthority.Outputs.Name.fromResource(authority_id),
            .template = private_ca.CertificateTemplate.Outputs.Name.fromResource(template_id),
        };
    }

    pub fn deinit(self: *PrivateCertificateAuthority) void {
        self.graph.deinit();
        self.* = undefined;
    }
};

fn validateName(name: []const u8) BuildError!void {
    if (name.len == 0 or name.len > 40) return error.InvalidName;
    for (name) |char| if (!(std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '-')) return error.InvalidName;
}
