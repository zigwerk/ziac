const ziac = @import("ziac");

const App = struct {
    pub const Env = struct {};
};
const Providers = ziac.stack.ProviderSet(.{ziac.resource.ProviderId.local});
const Bindings = struct {};
const Service = ziac.gcp.global.ZigService(App, Bindings, Providers);

comptime {
    _ = Service;
}
