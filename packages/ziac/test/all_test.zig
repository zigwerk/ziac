comptime {
    _ = @import("smoke_test.zig");
    _ = @import("core_test.zig");
    _ = @import("value_test.zig");
    _ = @import("output_test.zig");
    _ = @import("binding_test.zig");
    _ = @import("resource_graph_test.zig");
    _ = @import("state_test.zig");
    _ = @import("plan_test.zig");
    _ = @import("provider_apply_test.zig");
    _ = @import("executor_test.zig");
    _ = @import("checkpoint_test.zig");
    _ = @import("lock_test.zig");
    _ = @import("state_workflow_test.zig");
    _ = @import("plan_precondition_test.zig");
    _ = @import("stack_registry_test.zig");
    _ = @import("provider_set_test.zig");
    _ = @import("local_state_test.zig");
    _ = @import("cli_test.zig");
    _ = @import("gcp_config_test.zig");
    _ = @import("gcp_artifact_registry_test.zig");
    _ = @import("gcp_cloud_run_test.zig");
    _ = @import("gcp_auth_test.zig");
}
