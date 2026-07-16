const ziac = @import("ziac");

const Contract = struct {
    port: ziac.binding.Value(u16),
};
const Bindings = struct {
    port: ziac.Output([]const u8, .public),
};

comptime {
    _ = ziac.binding.validateBindings(Contract, Bindings, .global);
}
