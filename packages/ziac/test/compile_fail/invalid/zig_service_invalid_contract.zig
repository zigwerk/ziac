const ziac = @import("ziac");

const Providers = ziac.stack.ProviderSet(.{ziac.resource.ProviderId.gcp});
const Bindings = struct {};
const Service = ziac.gcp.global.ZigService(u8, Bindings, Providers);

comptime {
    _ = Service;
}
