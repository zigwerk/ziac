const ziac = @import("ziac");

const Contract = struct {};
const Bindings = struct {
    unexpected: ziac.Output([]const u8, .public),
};

comptime {
    _ = ziac.binding.validateBindings(Contract, Bindings, .global);
}
