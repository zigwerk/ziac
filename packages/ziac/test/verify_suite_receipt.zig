const std = @import("std");
const ziac = @import("ziac");

pub fn main(init: std.process.Init) !void {
    const path = ".zigeffect/tests/suites/ziac-tests.json";
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        path,
        init.gpa,
        .limited(16 * 1024 * 1024),
    );
    defer init.gpa.free(bytes);
    var receipt = try ziac.testing_receipt.parse(init.gpa, bytes);
    defer receipt.deinit();
    if (!receipt.value.complete or receipt.value.status != .passed) return error.TestSuiteNotQualified;
}
