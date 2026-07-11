const std = @import("std");
const ziac = @import("ziac");

test "Testing v2 receipt validation fails closed on incomplete evidence" {
    const passing =
        \\{"schema":"zigeffect.test-suite-receipt.v2","schema_version":2,"suite":"ziac-tests","status":"passed","complete":true,"started_ms":10,"ended_ms":12,"duration_ms":2,"execution":{"zig_version":"0.16.0","target":"aarch64-macos","optimize":"Debug","seed":42,"runner_version":"2.0.0","replay_command":"zig build test"},"counts":{"discovered":1,"executed":1,"passed":1,"skipped":0,"failed":0,"pending":0,"log_errors":0,"leaks":0},"tests":[{"index":0,"id":"unit","status":"passed","error_name":null,"log_error_count":0,"leak_count":0,"duration_ms":1}],"limitations":[]}
    ;
    var receipt = try ziac.testing_receipt.parse(std.testing.allocator, passing);
    defer receipt.deinit();
    try std.testing.expect(receipt.value.complete);
    try std.testing.expectEqual(ziac.testing_receipt.Status.passed, receipt.value.status);

    const incomplete =
        \\{"schema":"zigeffect.test-suite-receipt.v2","schema_version":2,"suite":"ziac-tests","status":"passed","complete":false,"started_ms":10,"ended_ms":12,"duration_ms":2,"execution":{"zig_version":"0.16.0","target":"aarch64-macos","optimize":"Debug","seed":42,"runner_version":"2.0.0","replay_command":"zig build test"},"counts":{"discovered":1,"executed":0,"passed":0,"skipped":0,"failed":0,"pending":1,"log_errors":0,"leaks":0},"tests":[{"index":0,"id":"unit","status":"pending","error_name":null,"log_error_count":0,"leak_count":0,"duration_ms":0}],"limitations":[]}
    ;
    try std.testing.expectError(error.InvalidVerdict, ziac.testing_receipt.parse(std.testing.allocator, incomplete));
}
