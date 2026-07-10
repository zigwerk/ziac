const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || std.mem.Allocator.Error || error{
    DuplicateField,
    DuplicateRecordData,
    InvalidDnsName,
    InvalidNetwork,
    InvalidRecordData,
    InvalidRecordName,
    InvalidTtl,
    InvalidZone,
    OutputNotKnown,
};

pub const ManagedZoneArgs = struct {
    name: []const u8,
    dns_name: output.Output([]const u8, .public),
    network: output.Output([]const u8, .public),
};

pub const ManagedZone = struct {
    pub const Outputs = struct {
        pub const ZoneName = output.Descriptor("zone_name", []const u8, .public);
        pub const DnsName = output.Descriptor("dns_name", []const u8, .public);
    };

    node: resource.ResourceNode,
    zone_name: Outputs.ZoneName.OutputType,
    dns_name: Outputs.DnsName.OutputType,

    pub fn build(
        allocator: std.mem.Allocator,
        provider: config_mod.ProviderConfig,
        args: ManagedZoneArgs,
    ) BuildError!ManagedZone {
        try provider.validate();
        if (!isValidZone(args.name)) return error.InvalidZone;
        const fields = [_]value.Field{
            .{ .name = "dns_name", .value = try dnsNameValue(args.dns_name) },
            .{ .name = "name", .value = .{ .string = args.name } },
            .{ .name = "network", .value = try networkValue(args.network, provider.project_id) },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "visibility", .value = .{ .string = "PRIVATE" } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.dns.ManagedZone.{s}", .{args.name});
        defer allocator.free(id);
        const node = resource.ResourceNode.initOwned(allocator, .{
            .id = id,
            .provider = .gcp,
            .type_name = "gcp.dns.ManagedZone",
            .logical_id = args.name,
            .inputs = .{ .object = &fields },
        }) catch |err| switch (err) {
            error.DuplicateField => return error.DuplicateField,
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateResource, error.MissingResource, error.DependencyCycle => unreachable,
        };
        return .{
            .node = node,
            .zone_name = Outputs.ZoneName.fromResource(node.id),
            .dns_name = Outputs.DnsName.fromResource(node.id),
        };
    }

    pub fn deinit(self: *ManagedZone, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
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
    name: []const u8 = "",
    name_output: ?output.Output([]const u8, .public) = null,
    logical_name: []const u8 = "",
    record_type: RecordType,
    ttl: u32 = 300,
    rrdatas: []const []const u8 = &.{},
    rrdata_outputs: []const output.Output([]const u8, .public) = &.{},
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
        if ((args.name.len == 0) == (args.name_output == null)) return error.InvalidRecordName;
        const name_value: value.Value = if (args.name_output) |name_output| switch (name_output) {
            .value => |known| if (isValidDnsName(known)) .{ .string = known } else return error.InvalidRecordName,
            .resource_ref => |reference| outputReference(reference),
            .unknown_reason => return error.InvalidRecordName,
        } else blk: {
            if (!isValidFqdn(args.name)) return error.InvalidRecordName;
            break :blk .{ .string = args.name };
        };
        const name_identity = if (args.name_output != null) args.logical_name else args.name;
        if (name_identity.len == 0 or (args.name_output != null and !isValidZone(name_identity))) return error.InvalidRecordName;
        if (args.ttl == 0 or args.ttl > std.math.maxInt(i32)) return error.InvalidTtl;
        const record_data_count = args.rrdatas.len + args.rrdata_outputs.len;
        if (record_data_count == 0 or (args.record_type == .cname and record_data_count != 1)) return error.InvalidRecordData;
        for (args.rrdatas, 0..) |data, index| {
            if (data.len == 0) return error.InvalidRecordData;
            for (args.rrdatas[index + 1 ..]) |other| {
                if (std.mem.eql(u8, data, other)) return error.DuplicateRecordData;
            }
        }
        for (args.rrdata_outputs, 0..) |record_output, index| {
            const reference = record_output.referenceOrNull() orelse switch (record_output) {
                .value => continue,
                .unknown_reason => return error.InvalidRecordData,
                .resource_ref => unreachable,
            };
            for (args.rrdata_outputs[index + 1 ..]) |other| {
                const other_reference = other.referenceOrNull() orelse continue;
                if (std.mem.eql(u8, reference.resource_id, other_reference.resource_id) and
                    std.mem.eql(u8, reference.field, other_reference.field)) return error.DuplicateRecordData;
            }
        }

        const record_type = args.record_type.apiName();
        const logical_id = try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ args.zone, record_type, name_identity });
        defer allocator.free(logical_id);
        const id = try std.fmt.allocPrint(allocator, "gcp.dns.RecordSet.{s}", .{logical_id});
        defer allocator.free(id);
        const rrdatas = try allocator.alloc(value.Value, record_data_count);
        defer allocator.free(rrdatas);
        for (args.rrdatas, 0..) |data, index| rrdatas[index] = .{ .string = data };
        for (args.rrdata_outputs, args.rrdatas.len..) |record_output, index| {
            rrdatas[index] = switch (record_output) {
                .value => |known| .{ .string = known },
                .resource_ref => |reference| .{ .output_ref = .{
                    .resource_id = reference.resource_id,
                    .field = reference.field,
                } },
                .unknown_reason => return error.InvalidRecordData,
            };
        }
        const fields = [_]value.Field{
            .{ .name = "name", .value = name_value },
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

fn dnsNameValue(result: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (result) {
        .value => |known| if (isValidDnsName(known)) .{ .string = known } else error.InvalidDnsName,
        .resource_ref => |reference| outputReference(reference),
        .unknown_reason => error.OutputNotKnown,
    };
}

fn networkValue(result: output.Output([]const u8, .public), project: []const u8) BuildError!value.Value {
    return switch (result) {
        .value => |known| if (isProjectNetwork(known, project)) .{ .string = known } else error.InvalidNetwork,
        .resource_ref => |reference| outputReference(reference),
        .unknown_reason => error.OutputNotKnown,
    };
}

fn outputReference(reference: output.OutputRef) value.Value {
    return .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } };
}

fn isProjectNetwork(input: []const u8, project: []const u8) bool {
    const marker = "projects/";
    const start = std.mem.indexOf(u8, input, marker) orelse return false;
    var segments = std.mem.splitScalar(u8, input[start..], '/');
    return std.mem.eql(u8, segments.next() orelse return false, "projects") and
        std.mem.eql(u8, segments.next() orelse return false, project) and
        std.mem.eql(u8, segments.next() orelse return false, "global") and
        std.mem.eql(u8, segments.next() orelse return false, "networks") and
        (segments.next() orelse return false).len > 0 and segments.next() == null;
}

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

fn isValidDnsName(name: []const u8) bool {
    if (name.len == 0 or name.len > 254) return false;
    if (name[name.len - 1] == '.') return isValidFqdn(name);
    if (name.len + 1 > 254) return false;
    var labels = std.mem.splitScalar(u8, name, '.');
    var count: usize = 0;
    while (labels.next()) |label| : (count += 1) {
        if (label.len == 0 or label.len > 63) return false;
        for (label) |character| {
            if (!(std.ascii.isLower(character) or std.ascii.isDigit(character) or character == '-' or character == '_')) return false;
        }
    }
    return count >= 2;
}
