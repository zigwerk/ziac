const ziac = @import("ziac");

pub const package_name = "ziac-gcpx";
pub const package_version = "0.1.0";

pub const asset_bucket = @import("asset_bucket.zig");
pub const hermes_desktop = @import("hermes_desktop.zig");

pub const AssetBucket = asset_bucket.AssetBucket;
pub const AssetBucketArgs = asset_bucket.Args;
pub const HermesDesktop = hermes_desktop.HermesDesktop;
pub const HermesDesktopArgs = hermes_desktop.Args;

pub const global_zig_service = struct {
    pub const package = package_name;
    pub const name = "GlobalZigService";
    pub const version = package_version;
    pub const compatibility_import = ziac.gcp.global.ZigService;
};
