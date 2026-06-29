comptime {
    _ = @import("smoke_test.zig");
    _ = @import("core_test.zig");
    _ = @import("output_test.zig");
    _ = @import("resource_graph_test.zig");
    _ = @import("state_test.zig");
    _ = @import("plan_test.zig");
    _ = @import("provider_apply_test.zig");
    _ = @import("stack_registry_test.zig");
    _ = @import("local_state_test.zig");
    _ = @import("cli_test.zig");
    _ = @import("gcp_config_test.zig");
    _ = @import("gcp_artifact_registry_test.zig");
}
