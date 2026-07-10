const std = @import("std");
const state_mod = @import("state.zig");
const value_mod = @import("value.zig");

pub const Secrecy = enum {
    public,
    secret,
};

pub const Scope = enum {
    global,
    regional,
};

pub const OutputError = error{
    MissingOutput,
    OutputNotKnown,
    OutputTypeMismatch,
};

pub const OutputRef = struct {
    resource_id: []const u8,
    field: []const u8,
};

pub const SecretRef = struct {
    name: []const u8,

    pub fn named(name: []const u8) SecretRef {
        return .{ .name = name };
    }
};

pub fn Output(
    comptime T: type,
    comptime secrecy_kind: Secrecy,
) type {
    return ScopedOutput(T, secrecy_kind, .global);
}

pub fn ScopedOutput(
    comptime T: type,
    comptime secrecy_kind: Secrecy,
    comptime scope_kind: Scope,
) type {
    return union(enum) {
        const Self = @This();

        pub const ValueType = T;
        pub const secrecy = secrecy_kind;
        pub const scope = scope_kind;

        value: T,
        resource_ref: OutputRef,
        unknown_reason: []const u8,

        pub fn known(value: T) Self {
            return .{ .value = value };
        }

        pub fn fromResource(resource_id: []const u8, field: []const u8) Self {
            return .{ .resource_ref = .{ .resource_id = resource_id, .field = field } };
        }

        pub fn unknown(reason: []const u8) Self {
            return .{ .unknown_reason = reason };
        }

        pub fn referenceOrNull(self: Self) ?OutputRef {
            return switch (self) {
                .resource_ref => |reference| reference,
                .value, .unknown_reason => null,
            };
        }

        pub fn resolve(self: Self, store: *state_mod.InMemoryStateStore) OutputError!T {
            return switch (self) {
                .value => |known_value| known_value,
                .unknown_reason => error.OutputNotKnown,
                .resource_ref => |reference| resolveReference(T, store, reference),
            };
        }

        pub fn exportPublic(self: Self) OutputError!T {
            if (comptime secrecy_kind != .public) {
                @compileError("ZIAC103 secret output cannot use a public export helper");
            }
            return switch (self) {
                .value => |known_value| known_value,
                .resource_ref, .unknown_reason => error.OutputNotKnown,
            };
        }
    };
}

pub fn PublicOutput(comptime T: type) type {
    return Output(T, .public);
}

pub fn SecretOutput(comptime T: type) type {
    return Output(T, .secret);
}

pub fn RegionalOutput(comptime T: type, comptime secrecy_kind: Secrecy) type {
    return ScopedOutput(T, secrecy_kind, .regional);
}

pub fn Descriptor(
    comptime output_field_name: []const u8,
    comptime T: type,
    comptime secrecy_kind: Secrecy,
) type {
    return struct {
        pub const field_name = output_field_name;
        pub const ValueType = T;
        pub const secrecy = secrecy_kind;
        pub const OutputType = Output(T, secrecy_kind);

        pub fn fromResource(resource_id: []const u8) OutputType {
            return OutputType.fromResource(resource_id, output_field_name);
        }
    };
}

fn resolveReference(
    comptime T: type,
    store: *state_mod.InMemoryStateStore,
    reference: OutputRef,
) OutputError!T {
    const record = store.get(reference.resource_id) orelse return error.MissingOutput;
    for (record.outputs) |output| {
        if (!std.mem.eql(u8, output.name, reference.field)) continue;
        if (T == []const u8) {
            return switch (output.value) {
                .string => |string| string,
                else => error.OutputTypeMismatch,
            };
        }
        if (T == value_mod.SecretReference) {
            return switch (output.value) {
                .secret_ref => |secret| secret,
                else => error.OutputTypeMismatch,
            };
        }
        if (T == bool) {
            return switch (output.value) {
                .boolean => |boolean| boolean,
                else => error.OutputTypeMismatch,
            };
        }
        if (T == i64) {
            return switch (output.value) {
                .integer => |integer| integer,
                else => error.OutputTypeMismatch,
            };
        }
        @compileError("unsupported Ziac output value type: " ++ @typeName(T));
    }
    return error.MissingOutput;
}
