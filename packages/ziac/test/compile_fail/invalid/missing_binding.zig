const ziac = @import("ziac");

const Contract = struct {
    region: ziac.binding.Value([]const u8),
};
const Bindings = struct {};

comptime {
    _ = ziac.binding.validateBindings(Contract, Bindings, .global);
}
