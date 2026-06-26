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

pub fn Output(comptime T: type) type {
    return union(enum) {
        value: T,
        resource_ref: OutputRef,
        unknown_reason: []const u8,

        pub fn known(value: T) @This() {
            return .{ .value = value };
        }

        pub fn fromResource(resource_id: []const u8, field: []const u8) @This() {
            return .{ .resource_ref = .{ .resource_id = resource_id, .field = field } };
        }

        pub fn unknown(reason: []const u8) @This() {
            return .{ .unknown_reason = reason };
        }
    };
}
