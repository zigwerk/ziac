const std = @import("std");
const ziac = @import("ziac");

pub fn build(
    allocator: std.mem.Allocator,
    init: std.process.Init,
    args: ziac.stack_registry.StackArgs,
) !ziac.stack_registry.StackProgram {
    _ = init;
    var normalized = args;
    if (std.mem.eql(u8, args.stack, "global-api")) normalized.stack = "hello-global";
    var program = try ziac.stack_registry.fixtureRegistry().build(allocator, normalized);
    errdefer program.deinit();
    var index = program.outputs.items.len;
    while (index > 0) {
        index -= 1;
        if (!program.outputs.items[index].secret) continue;
        var removed = program.outputs.orderedRemove(index);
        removed.deinit(allocator);
    }
    return program;
}
