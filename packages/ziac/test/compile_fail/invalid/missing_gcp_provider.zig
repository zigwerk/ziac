const std = @import("std");
const ziac = @import("ziac");

pub fn main() !void {
    const Providers = ziac.stack.ProviderSet(.{ziac.resource.ProviderId.local});
    const Context = ziac.stack.Context(Providers);
    var graph = ziac.ResourceGraph.init(std.heap.page_allocator);
    defer graph.deinit();
    var context = Context.init(std.heap.page_allocator, &graph);
    _ = context.gcp();
}
