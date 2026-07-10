const ziac = @import("ziac");

const Env = struct {
    database_url: ziac.binding.Secret([]const u8),
};
const Bindings = struct {
    database_url: ziac.Output([]const u8, .public),
};

comptime {
    _ = ziac.binding.validateBindings(Env, Bindings, .global);
}
