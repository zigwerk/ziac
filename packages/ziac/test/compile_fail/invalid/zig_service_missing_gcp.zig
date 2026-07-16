const ziac = @import("ziac");

const DeploymentContract = struct {};
const Providers = ziac.stack.ProviderSet(.{ziac.resource.ProviderId.local});
const Bindings = struct {};
const Service = ziac.gcp.global.ZigService(DeploymentContract, Bindings, Providers);

comptime {
    _ = Service;
}
