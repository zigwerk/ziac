const ziac = @import("ziac");

const Contract = struct {
    database_url: ziac.binding.Secret([]const u8),
};
const Bindings = struct {
    database_url: ziac.Output([]const u8, .public),
};

comptime {
    _ = ziac.binding.validateBindings(Contract, Bindings, .global);
}
