const ziac = @import("ziac");

const Providers = ziac.stack.ProviderSet(.{
    ziac.resource.ProviderId.cockroach,
    ziac.resource.ProviderId.gcp,
});

comptime {
    Providers.require(.gcp);
    Providers.require(.cockroach);
}
