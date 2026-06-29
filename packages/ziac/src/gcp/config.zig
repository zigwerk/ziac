const std = @import("std");
const validation = @import("validation.zig");

pub const ValidationError = validation.ValidationError;

pub const NetworkTier = enum {
    standard,
    premium,
};

pub const Label = struct {
    key: []const u8,
    value: []const u8,
};

pub const ProviderConfig = struct {
    project_id: []const u8,
    primary_region: []const u8,
    service_regions: []const []const u8 = &.{},
    network_tier: NetworkTier = .standard,
    service_account: ?[]const u8 = null,
    labels: []const Label = &.{},

    pub fn validate(self: ProviderConfig) ValidationError!void {
        if (self.project_id.len == 0) return error.MissingProjectId;
        if (self.primary_region.len == 0) return error.MissingRegion;
        for (self.service_regions) |region| {
            if (region.len == 0) return error.MissingRegion;
        }
        if (self.regionCount() > 1 and self.network_tier != .premium) {
            return error.PremiumTierRequired;
        }
        for (self.labels) |label| {
            if (label.key.len == 0 or label.value.len == 0) return error.MissingLabel;
        }
    }

    pub fn regionCount(self: ProviderConfig) usize {
        if (self.service_regions.len == 0) return 1;
        return self.service_regions.len;
    }
};

test "ProviderConfig region count defaults to primary region" {
    const config = ProviderConfig{ .project_id = "p", .primary_region = "europe-west1" };
    try std.testing.expectEqual(@as(usize, 1), config.regionCount());
}
