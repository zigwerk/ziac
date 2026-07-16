const std = @import("std");
const ziac = @import("ziac");

test "exact deployment contract and binding type match validates at comptime" {
    const Contract = struct {
        database_url: ziac.binding.Secret([]const u8),
        region: ziac.binding.Value([]const u8),
    };
    const Bindings = struct {
        database_url: ziac.Output([]const u8, .secret),
        region: ziac.Output([]const u8, .public),
    };

    const Normalized = ziac.binding.validateBindings(Contract, Bindings, .global);
    try std.testing.expect(Normalized == Bindings);
}

test "optional environment fields may be omitted" {
    const Contract = struct {
        region: ziac.binding.Value([]const u8),
        release: ?ziac.binding.Value([]const u8),
    };
    const Bindings = struct {
        region: ziac.Output([]const u8, .public),
    };

    const Normalized = ziac.binding.validateBindings(Contract, Bindings, .global);
    try std.testing.expect(Normalized == Bindings);
}

test "binding value type secrecy and scope are comptime inspectable" {
    const Public = ziac.binding.Value(u16);
    const Secret = ziac.binding.Secret([]const u8);
    const Regional = ziac.output.RegionalOutput([]const u8, .public);

    try std.testing.expect(Public.ValueType == u16);
    try std.testing.expectEqual(ziac.output.Secrecy.public, Public.secrecy);
    try std.testing.expectEqual(ziac.output.Secrecy.secret, Secret.secrecy);
    try std.testing.expectEqual(ziac.output.Scope.regional, Regional.scope);
}

test "regional output validates inside a regional service context" {
    const Contract = struct {
        region: ziac.binding.Value([]const u8),
    };
    const Bindings = struct {
        region: ziac.output.RegionalOutput([]const u8, .public),
    };

    const Normalized = ziac.binding.validateBindings(Contract, Bindings, .regional);
    try std.testing.expect(Normalized == Bindings);
}

test "a Secret Manager reference safely satisfies a secret deployment field" {
    const Contract = struct {
        database_url: ziac.binding.Secret([]const u8),
    };
    const Bindings = struct {
        database_url: ziac.Output(ziac.value.SecretReference, .secret),
    };

    const Normalized = ziac.binding.validateBindings(Contract, Bindings, .global);
    try std.testing.expect(Normalized == Bindings);
}
