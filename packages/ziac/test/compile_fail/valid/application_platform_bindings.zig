const ziac = @import("ziac");

const Env = struct {
    uploads_bucket: ziac.binding.Value([]const u8),
    events_topic: ziac.binding.Value([]const u8),
    tasks_queue: ziac.binding.Value([]const u8),
    service_url: ziac.binding.Value([]const u8),
};

const Bindings = struct {
    uploads_bucket: ziac.Output([]const u8, .public),
    events_topic: ziac.Output([]const u8, .public),
    tasks_queue: ziac.Output([]const u8, .public),
    service_url: ziac.Output([]const u8, .public),
};

comptime {
    _ = ziac.binding.validateBindings(Env, Bindings, .global);
}
