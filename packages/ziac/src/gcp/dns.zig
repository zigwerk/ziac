const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    DuplicateRecordData,
    InvalidRecordData,
    InvalidRecordName,
    InvalidTtl,
    InvalidZone,
};

pub const RecordType = enum {
    a,
    aaaa,
    caa,
    cname,
    mx,
    naptr,
    ns,
    ptr,
    soa,
    spf,
    srv,
    txt,

    pub fn apiName(self: RecordType) []const u8 {
        return switch (self) {
            .a => "A",
            .aaaa => "AAAA",
            .caa => "CAA",
            .cname => "CNAME",
            .mx => "MX",
            .naptr => "NAPTR",
            .ns => "NS",
            .ptr => "PTR",
            .soa => "SOA",
            .spf => "SPF",
            .srv => "SRV",
            .txt => "TXT",
        };
    }
};

pub const RecordSetArgs = struct {
    zone: []const u8,
    name: []const u8,
    record_type: RecordType,
    ttl: u32 = 300,
    rrdatas: []const []const u8,
};

pub const RecordSet = struct {
    pub const Outputs = struct {
        pub const Fqdn = output.Descriptor("fqdn", []const u8, .public);
        pub const RecordTypeName = output.Descriptor("record_type", []const u8, .public);
    };

    node: resource.ResourceNode,
    fqdn: Outputs.Fqdn.OutputType,
    record_type: Outputs.RecordTypeName.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: RecordSetArgs,
    ) BuildError!RecordSet {
        try provider.validate();
        if (!isValidZone(args.zone)) return error.InvalidZone;
        if (!isValidFqdn(args.name)) return error.InvalidRecordName;
        if (args.ttl == 0 or args.ttl > std.math.maxInt(i32)) return error.InvalidTtl;
        if (args.rrdatas.len == 0 or (args.record_type == .cname and args.rrdatas.len != 1)) return error.InvalidRecordData;
        for (args.rrdatas, 0..) |data, index| {
            if (data.len == 0) return error.InvalidRecordData;
            for (args.rrdatas[index + 1 ..]) |other| {
                if (std.mem.eql(u8, data, other)) return error.DuplicateRecordData;
            }
        }

        const record_type = args.record_type.apiName();
        const logical_id = try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ args.zone, record_type, args.name });
        defer allocator.free(logical_id);
        const id = try std.fmt.allocPrint(allocator, "gcp.dns.RecordSet.{s}", .{logical_id});
        defer allocator.free(id);
        const rrdatas = try allocator.alloc(value.Value, args.rrdatas.len);
        defer allocator.free(rrdatas);
        for (args.rrdatas, 0..) |data, index| rrdatas[index] = .{ .string = data };
        const fields = [_]value.Field{
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "rrdatas", .value = .{ .list = rrdatas } },
            .{ .name = "ttl", .value = .{ .integer = args.ttl } },
            .{ .name = "type", .value = .{ .string = record_type } },
            .{ .name = "zone", .value = .{ .string = args.zone } },
        };
        const node = resource.ResourceNode.initOwned(allocator, .{
            .id = id,
            .provider = .gcp,
            .type_name = "gcp.dns.RecordSet",
            .schema_version = 1,
            .logical_id = logical_id,
            .inputs = .{ .object = &fields },
        }) catch |err| switch (err) {
            error.DuplicateField => return error.DuplicateField,
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
        };
        return .{
            .node = node,
            .fqdn = Outputs.Fqdn.fromResource(node.id),
            .record_type = Outputs.RecordTypeName.fromResource(node.id),
        };
    }

    pub fn deinit(self: *RecordSet, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn isValidZone(zone: []const u8) bool {
    if (zone.len == 0 or zone.len > 63 or !std.ascii.isLower(zone[0])) return false;
    if (!(std.ascii.isLower(zone[zone.len - 1]) or std.ascii.isDigit(zone[zone.len - 1]))) return false;
    for (zone) |character| {
        if (!(std.ascii.isLower(character) or std.ascii.isDigit(character) or character == '-')) return false;
    }
    return true;
}

fn isValidFqdn(name: []const u8) bool {
    if (name.len < 2 or name.len > 254 or name[name.len - 1] != '.') return false;
    var labels = std.mem.splitScalar(u8, name[0 .. name.len - 1], '.');
    var index: usize = 0;
    while (labels.next()) |label| : (index += 1) {
        if (label.len == 0 or label.len > 63) return false;
        if (std.mem.eql(u8, label, "*")) {
            if (index != 0) return false;
            continue;
        }
        for (label) |character| {
            if (!(std.ascii.isLower(character) or std.ascii.isDigit(character) or character == '-' or character == '_')) return false;
        }
    }
    return index >= 2;
}
