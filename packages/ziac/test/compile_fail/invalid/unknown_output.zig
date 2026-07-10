const ziac = @import("ziac");

comptime {
    _ = ziac.gcp.cloud_run.Service.Outputs.field("missing");
}
