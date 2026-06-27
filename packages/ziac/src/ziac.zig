pub const product_name = "Ziac";

pub const zstd = @import("zigeffect_std");
pub const fx = zstd.fx;

pub const core = @import("core.zig");
pub const output = @import("output.zig");
pub const resource = @import("resource.zig");
pub const state = @import("state.zig");
pub const plan = @import("plan.zig");
pub const provider = @import("provider.zig");
pub const apply = @import("apply.zig");

pub const Output = output.Output;
pub const OutputRef = output.OutputRef;
pub const SecretRef = output.SecretRef;
pub const ResourceGraph = resource.ResourceGraph;
pub const ResourceNode = resource.ResourceNode;
pub const DependencyEdge = resource.DependencyEdge;
pub const ResourceStatus = state.ResourceStatus;
pub const StateRecord = state.StateRecord;
pub const InMemoryStateStore = state.InMemoryStateStore;
