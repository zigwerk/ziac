const ziac = @import("ziac");

const Env = struct {
    region: ziac.binding.Value([]const u8),
};
const Bindings = struct {};

comptime {
    _ = ziac.binding.validateBindings(Env, Bindings, .global);
}
