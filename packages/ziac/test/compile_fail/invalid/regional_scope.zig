const ziac = @import("ziac");

const Contract = struct {
    region: ziac.binding.Value([]const u8),
};
const Bindings = struct {
    region: ziac.output.RegionalOutput([]const u8, .public),
};

comptime {
    _ = ziac.binding.validateBindings(Contract, Bindings, .global);
}
