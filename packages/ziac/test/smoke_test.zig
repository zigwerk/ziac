const std = @import("std");
const ziac = @import("ziac");

test "ziac facade exposes product name and standard library facade" {
    try std.testing.expectEqualStrings("Ziac", ziac.product_name);
    _ = ziac.zstd.fx.Effect;
    _ = ziac.fx.Effect;
}
