pub const product_name = "Ziac";

pub const zstd = @import("zigeffect_std");
pub const fx = zstd.fx;

pub const core = @import("core.zig");
pub const output = @import("output.zig");

pub const Output = output.Output;
pub const OutputRef = output.OutputRef;
pub const SecretRef = output.SecretRef;
