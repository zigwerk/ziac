const std = @import("std");
const output = @import("output.zig");

pub fn Value(comptime T: type) type {
    return Field(T, .public);
}

pub fn Secret(comptime T: type) type {
    return Field(T, .secret);
}

fn Field(comptime T: type, comptime secrecy_kind: output.Secrecy) type {
    return struct {
        pub const ziac_binding_descriptor = true;
        pub const ValueType = T;
        pub const secrecy = secrecy_kind;

        value: T,
    };
}

pub fn validateBindings(
    comptime Env: type,
    comptime Bindings: type,
    comptime service_scope: output.Scope,
) type {
    const env_info = structInfo(Env, "ZIAC102 app Env must be a struct");
    const bindings_info = structInfo(Bindings, "ZIAC102 bindings must be a struct");

    inline for (env_info.fields) |env_field| {
        comptime var matched = false;
        inline for (bindings_info.fields) |binding_field| {
            if (std.mem.eql(u8, env_field.name, binding_field.name)) {
                matched = true;
                validatePair(env_field.name, env_field.type, binding_field.type, service_scope);
            }
        }
        if (!matched and !isOptional(env_field.type)) {
            @compileError("ZIAC100 missing app binding: " ++ env_field.name);
        }
    }

    inline for (bindings_info.fields) |binding_field| {
        comptime var matched = false;
        inline for (env_info.fields) |env_field| {
            if (std.mem.eql(u8, binding_field.name, env_field.name)) matched = true;
        }
        if (!matched) @compileError("ZIAC101 unknown app binding: " ++ binding_field.name);
    }

    return Bindings;
}

fn validatePair(
    comptime field_name: []const u8,
    comptime raw_env_type: type,
    comptime binding_type: type,
    comptime service_scope: output.Scope,
) void {
    const env_type = optionalChild(raw_env_type);
    if (!hasBindingMetadata(env_type)) {
        @compileError("ZIAC102 app Env field is not a Value/Secret descriptor: " ++ field_name);
    }
    if (!hasOutputMetadata(binding_type)) {
        @compileError("ZIAC102 binding is not a typed Ziac output: " ++ field_name);
    }
    if (env_type.ValueType != binding_type.ValueType) {
        @compileError("ZIAC102 binding value type mismatch: " ++ field_name);
    }
    if (env_type.secrecy != binding_type.secrecy) {
        @compileError("ZIAC103 binding secrecy mismatch: " ++ field_name);
    }
    if (binding_type.scope == .regional and service_scope != .regional) {
        @compileError("ZIAC104 regional binding used outside regional service: " ++ field_name);
    }
}

fn structInfo(comptime T: type, comptime message: []const u8) std.builtin.Type.Struct {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| info,
        else => @compileError(message),
    };
}

fn isOptional(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .optional => true,
        else => false,
    };
}

fn optionalChild(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |info| info.child,
        else => T,
    };
}

fn hasBindingMetadata(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "ziac_binding_descriptor") and
            @hasDecl(T, "ValueType") and @hasDecl(T, "secrecy"),
        else => false,
    };
}

fn hasOutputMetadata(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(T, "ValueType") and
            @hasDecl(T, "secrecy") and @hasDecl(T, "scope"),
        else => false,
    };
}
