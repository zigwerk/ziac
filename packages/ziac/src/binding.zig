const std = @import("std");
const output = @import("output.zig");
const value = @import("value.zig");

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
    comptime Contract: type,
    comptime Bindings: type,
    comptime service_scope: output.Scope,
) type {
    const contract_info = structInfo(Contract, "ZIAC102 deployment binding contract must be a struct");
    const bindings_info = structInfo(Bindings, "ZIAC102 bindings must be a struct");

    inline for (contract_info.fields) |contract_field| {
        comptime var matched = false;
        inline for (bindings_info.fields) |binding_field| {
            if (std.mem.eql(u8, contract_field.name, binding_field.name)) {
                matched = true;
                validatePair(contract_field.name, contract_field.type, binding_field.type, service_scope);
            }
        }
        if (!matched and !isOptional(contract_field.type)) {
            @compileError("ZIAC100 missing deployment binding: " ++ contract_field.name);
        }
    }

    inline for (bindings_info.fields) |binding_field| {
        comptime var matched = false;
        inline for (contract_info.fields) |contract_field| {
            if (std.mem.eql(u8, binding_field.name, contract_field.name)) matched = true;
        }
        if (!matched) @compileError("ZIAC101 unknown deployment binding: " ++ binding_field.name);
    }

    return Bindings;
}

fn validatePair(
    comptime field_name: []const u8,
    comptime raw_contract_type: type,
    comptime binding_type: type,
    comptime service_scope: output.Scope,
) void {
    const contract_type = optionalChild(raw_contract_type);
    if (!hasBindingMetadata(contract_type)) {
        @compileError("ZIAC102 deployment field is not a Value/Secret descriptor: " ++ field_name);
    }
    if (!hasOutputMetadata(binding_type)) {
        @compileError("ZIAC102 binding is not a typed Ziac output: " ++ field_name);
    }
    const secret_reference_string = contract_type.secrecy == .secret and
        binding_type.secrecy == .secret and
        contract_type.ValueType == []const u8 and
        binding_type.ValueType == value.SecretReference;
    if (contract_type.ValueType != binding_type.ValueType and !secret_reference_string) {
        @compileError("ZIAC102 binding value type mismatch: " ++ field_name);
    }
    if (contract_type.secrecy != binding_type.secrecy) {
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
