const std = @import("std");
const ziac = @import("ziac");

pub const descriptor = ziac.component.Descriptor{
    .package = "ziac-gcpx",
    .name = "AssetBucket",
    .version = "0.1.0",
    .source_digest = "66a60519ef2ed3a41617362258b381437650ed9e6bbaeffb6d74311e8d735b95",
    .providers = &.{.gcp},
    .resource_types = &.{ "gcp.storage.Bucket", "gcp.storage.BucketIamMember" },
};

pub const Args = ziac.gcp.storage_components.AssetBucketArgs;

pub const AssetBucket = struct {
    allocator: std.mem.Allocator,
    graph: ziac.ResourceGraph,
    name: ziac.gcp.storage.Bucket.Outputs.Name.OutputType,
    url: ziac.gcp.storage.Bucket.Outputs.Url.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: ziac.gcp.ProviderConfig, args: Args) !AssetBucket {
        const component_start = if (args.base_graph) |base| base.resources.items.len else 0;
        var built = try ziac.gcp.storage_components.AssetBucket.build(allocator, provider, args);
        errdefer built.deinit();
        try ziac.component.stampRange(&built.graph, component_start, descriptor, args.name);
        return .{
            .allocator = built.allocator,
            .graph = built.graph,
            .name = built.name,
            .url = built.url,
        };
    }

    pub fn deinit(self: *AssetBucket) void {
        self.graph.deinit();
        self.* = undefined;
    }

    pub fn takeGraph(self: *AssetBucket) ziac.ResourceGraph {
        const graph = self.graph;
        self.graph = ziac.ResourceGraph.init(graph.allocator);
        return graph;
    }
};
