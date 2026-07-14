const std = @import("std");
const config_mod = @import("config.zig");
const iam = @import("iam.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const spanner = @import("spanner.zig");

pub const BuildError = spanner.BuildError || resource.ResourceGraphError || error{
    ConflictingBackupSchedules,
    DuplicateBackup,
    DuplicateIamMember,
};

pub const BackupSpec = struct {
    backup_id: []const u8,
    expire_time: []const u8,
    version_time: []const u8 = "",
    kms_key_name: []const u8 = "",
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const BackupScheduleSpec = struct {
    schedule_id: []const u8,
    cron: []const u8,
    retention_seconds: u32,
    mode: spanner.BackupMode = .full,
    kms_key_name: []const u8 = "",
    retain_on_delete: bool = true,
};

pub const IamMemberSpec = struct {
    name: []const u8,
    role: []const u8,
    member: []const u8,
    condition: ?iam.Condition = null,
};

pub const SpannerDatabaseArgs = struct {
    base_graph: ?*const resource.ResourceGraph = null,
    name: []const u8,
    instance: spanner.InstanceArgs,
    database_id: []const u8,
    dialect: spanner.Dialect = .google_standard_sql,
    ddl: []const []const u8 = &.{},
    kms_key_name: []const u8 = "",
    version_retention_period: []const u8 = "1h",
    default_leader: []const u8 = "",
    drop_protection: bool = true,
    protect: bool = true,
    retain_on_delete: bool = true,
    backup_schedule: ?BackupScheduleSpec = null,
    backups: []const BackupSpec = &.{},
    instance_members: []const IamMemberSpec = &.{},
    database_members: []const IamMemberSpec = &.{},
};

pub const SpannerDatabase = struct {
    allocator: std.mem.Allocator,
    graph: resource.ResourceGraph,
    instance_name: output.Output([]const u8, .public),
    database_name: output.Output([]const u8, .public),
    backup_schedule_name: ?output.Output([]const u8, .public),
    backup_names: []output.Output([]const u8, .public),

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: SpannerDatabaseArgs) BuildError!SpannerDatabase {
        try validateArgs(args);
        var graph = resource.ResourceGraph.init(allocator);
        errdefer graph.deinit();
        if (args.base_graph) |base| try graph.appendGraph(base);

        const instance_index = graph.resources.items.len;
        var instance = try spanner.Instance.build(allocator, provider, args.instance);
        defer instance.deinit(allocator);
        try graph.addResource(instance.node);
        const instance_id = graph.resources.items[instance_index].id;
        const instance_name = spanner.Instance.Outputs.Name.fromResource(instance_id);

        const database_index = graph.resources.items.len;
        var database = try spanner.Database.build(allocator, provider, .{
            .database_id = args.database_id,
            .instance = instance_name,
            .instance_id = args.instance.instance_id,
            .dialect = args.dialect,
            .ddl = args.ddl,
            .kms_key_name = args.kms_key_name,
            .version_retention_period = args.version_retention_period,
            .default_leader = args.default_leader,
            .drop_protection = args.drop_protection,
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
        });
        defer database.deinit(allocator);
        try graph.addResource(database.node);
        const database_id = graph.resources.items[database_index].id;
        const database_name = spanner.Database.Outputs.Name.fromResource(database_id);

        var backup_schedule_name: ?output.Output([]const u8, .public) = null;
        if (args.backup_schedule) |spec| {
            const schedule_index = graph.resources.items.len;
            var schedule = try spanner.BackupSchedule.build(allocator, provider, .{
                .schedule_id = spec.schedule_id,
                .database = database_name,
                .instance_id = args.instance.instance_id,
                .database_id = args.database_id,
                .cron = spec.cron,
                .retention_seconds = spec.retention_seconds,
                .mode = spec.mode,
                .kms_key_name = spec.kms_key_name,
                .retain_on_delete = spec.retain_on_delete,
            });
            defer schedule.deinit(allocator);
            try graph.addResource(schedule.node);
            backup_schedule_name = spanner.BackupSchedule.Outputs.Name.fromResource(graph.resources.items[schedule_index].id);
        }

        const backup_names = try allocator.alloc(output.Output([]const u8, .public), args.backups.len);
        errdefer allocator.free(backup_names);
        for (args.backups, 0..) |spec, index| {
            const backup_index = graph.resources.items.len;
            var backup = try spanner.Backup.build(allocator, provider, .{
                .backup_id = spec.backup_id,
                .database = database_name,
                .instance_id = args.instance.instance_id,
                .database_id = args.database_id,
                .expire_time = spec.expire_time,
                .version_time = spec.version_time,
                .kms_key_name = spec.kms_key_name,
                .protect = spec.protect,
                .retain_on_delete = spec.retain_on_delete,
            });
            defer backup.deinit(allocator);
            try graph.addResource(backup.node);
            backup_names[index] = spanner.Backup.Outputs.Name.fromResource(graph.resources.items[backup_index].id);
        }

        for (args.instance_members) |spec| {
            var member = try spanner.InstanceIamMember.build(allocator, provider, .{
                .name = spec.name,
                .instance = instance_name,
                .instance_id = args.instance.instance_id,
                .role = spec.role,
                .member = spec.member,
                .condition = spec.condition,
            });
            defer member.deinit(allocator);
            try graph.addResource(member.node);
        }
        for (args.database_members) |spec| {
            var member = try spanner.DatabaseIamMember.build(allocator, provider, .{
                .name = spec.name,
                .database = database_name,
                .instance_id = args.instance.instance_id,
                .database_id = args.database_id,
                .role = spec.role,
                .member = spec.member,
                .condition = spec.condition,
            });
            defer member.deinit(allocator);
            try graph.addResource(member.node);
        }

        try graph.validateAcyclic();
        return .{
            .allocator = allocator,
            .graph = graph,
            .instance_name = instance_name,
            .database_name = database_name,
            .backup_schedule_name = backup_schedule_name,
            .backup_names = backup_names,
        };
    }

    pub fn deinit(self: *SpannerDatabase) void {
        self.graph.deinit();
        self.allocator.free(self.backup_names);
        self.* = undefined;
    }
};

fn validateArgs(args: SpannerDatabaseArgs) BuildError!void {
    if (args.backup_schedule != null and args.instance.default_backup_schedule == .automatic) return error.ConflictingBackupSchedules;
    for (args.backups, 0..) |backup, index| for (args.backups[index + 1 ..]) |other| {
        if (std.mem.eql(u8, backup.backup_id, other.backup_id)) return error.DuplicateBackup;
    };
    for (args.instance_members, 0..) |member, index| {
        for (args.instance_members[index + 1 ..]) |other| if (std.mem.eql(u8, member.name, other.name)) return error.DuplicateIamMember;
        for (args.database_members) |other| if (std.mem.eql(u8, member.name, other.name)) return error.DuplicateIamMember;
    }
    for (args.database_members, 0..) |member, index| for (args.database_members[index + 1 ..]) |other| {
        if (std.mem.eql(u8, member.name, other.name)) return error.DuplicateIamMember;
    };
}
