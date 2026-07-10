const ziac = @import("ziac");

const Env = struct {
    region: ziac.binding.Value([]const u8),
};
const Bindings = struct {
    region: ziac.output.RegionalOutput([]const u8, .public),
};

comptime {
    _ = ziac.binding.validateBindings(Env, Bindings, .global);
}
