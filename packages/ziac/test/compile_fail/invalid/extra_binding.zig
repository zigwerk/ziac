const ziac = @import("ziac");

const Env = struct {};
const Bindings = struct {
    unexpected: ziac.Output([]const u8, .public),
};

comptime {
    _ = ziac.binding.validateBindings(Env, Bindings, .global);
}
