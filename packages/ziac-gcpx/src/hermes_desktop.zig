const std = @import("std");
const ziac = @import("ziac");

pub const descriptor = ziac.component.Descriptor{
    .package = "ziac-gcpx",
    .name = "HermesDesktop",
    .version = "0.1.0",
    .source_digest = "fbdbd78c1f14bb43135a2f8adfb1a9b6ea2eac2583febdf4ae80c690e421a236",
    .providers = &.{.gcp},
    .resource_types = &.{
        "gcp.compute.Disk",
        "gcp.compute.Firewall",
        "gcp.compute.Instance",
        "gcp.compute.Network",
        "gcp.compute.RegionalAddress",
        "gcp.compute.Subnetwork",
        "gcp.dns.RecordSet",
        "gcp.iam.ServiceAccount",
        "gcp.secret.Secret",
        "gcp.secret.SecretIamMember",
        "gcp.secret.SecretVersion",
    },
};

pub const Args = ziac.gcp.HermesComputeArgs;

pub const HermesDesktop = struct {
    allocator: std.mem.Allocator,
    graph: ziac.ResourceGraph,
    desktop_url: ziac.PublicOutput([]const u8),
    instance: ziac.PublicOutput([]const u8),
    internal_ip: ziac.PublicOutput([]const u8),
    public_ip: ziac.PublicOutput([]const u8),
    disk: ziac.PublicOutput([]const u8),
    network: ziac.PublicOutput([]const u8),
    subnetwork: ziac.PublicOutput([]const u8),
    service_account: ziac.PublicOutput([]const u8),
    environment_secret: ziac.PublicOutput([]const u8),
    environment_version: ziac.Output(ziac.value.SecretReference, .secret),
    owned_desktop_url: []u8,

    pub fn build(allocator: std.mem.Allocator, provider: ziac.gcp.ProviderConfig, args: Args) !HermesDesktop {
        const component_start = if (args.base_graph) |base| base.resources.items.len else 0;
        var built = try ziac.gcp.HermesCompute.build(allocator, provider, args);
        errdefer built.deinit();
        try ziac.component.stampRange(&built.graph, component_start, descriptor, args.name);
        return .{
            .allocator = built.allocator,
            .graph = built.graph,
            .desktop_url = built.desktop_url,
            .instance = built.instance,
            .internal_ip = built.internal_ip,
            .public_ip = built.public_ip,
            .disk = built.disk,
            .network = built.network,
            .subnetwork = built.subnetwork,
            .service_account = built.service_account,
            .environment_secret = built.environment_secret,
            .environment_version = built.environment_version,
            .owned_desktop_url = built.owned_desktop_url,
        };
    }

    pub fn deinit(self: *HermesDesktop) void {
        self.graph.deinit();
        self.allocator.free(self.owned_desktop_url);
        self.* = undefined;
    }

    pub fn takeGraph(self: *HermesDesktop) ziac.ResourceGraph {
        const graph = self.graph;
        self.graph = ziac.ResourceGraph.init(graph.allocator);
        return graph;
    }
};
