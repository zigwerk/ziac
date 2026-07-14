const std = @import("std");
const config_mod = @import("config.zig");
const output = @import("../output.zig");
const resource = @import("../resource.zig");
const value = @import("../value.zig");

pub const BuildError = config_mod.ValidationError || resource.ResourceGraphError || std.mem.Allocator.Error || error{
    DuplicateEnvironmentVariable,
    DuplicateLabel,
    InvalidEnvironmentVariable,
    InvalidKmsKey,
    InvalidLocation,
    InvalidServiceAccount,
    InvalidSource,
    InvalidWorkflowId,
    OutputNotKnown,
    PotentialSecretInSource,
};

pub const CallLogLevel = enum {
    none,
    errors_only,
    all_calls,

    pub fn apiName(self: CallLogLevel) []const u8 {
        return switch (self) {
            .none => "LOG_NONE",
            .errors_only => "LOG_ERRORS_ONLY",
            .all_calls => "LOG_ALL_CALLS",
        };
    }
};

pub const ExecutionHistory = enum {
    disabled,
    detailed,

    pub fn apiName(self: ExecutionHistory) []const u8 {
        return switch (self) {
            .disabled => "EXECUTION_HISTORY_DISABLED",
            .detailed => "EXECUTION_HISTORY_DETAILED",
        };
    }
};

pub const EnvironmentVariable = struct {
    key: []const u8,
    value: []const u8,
};

pub const WorkflowArgs = struct {
    workflow_id: []const u8,
    location: ?[]const u8 = null,
    source_contents: []const u8,
    service_account: output.Output([]const u8, .public),
    kms_key: ?output.Output([]const u8, .public) = null,
    call_log_level: CallLogLevel = .errors_only,
    execution_history: ExecutionHistory = .disabled,
    labels: []const config_mod.Label = &.{},
    user_env: []const EnvironmentVariable = &.{},
    deletion_protection: bool = true,
    protect: bool = true,
    retain_on_delete: bool = true,
};

pub const Workflow = struct {
    pub const Outputs = struct {
        pub const Name = output.Descriptor("name", []const u8, .public);
        pub const RevisionId = output.Descriptor("revision_id", []const u8, .public);
        pub const State = output.Descriptor("state", []const u8, .public);
        pub const UpdateTime = output.Descriptor("update_time", []const u8, .public);
    };

    node: resource.ResourceNode,
    name: Outputs.Name.OutputType,
    revision_id: Outputs.RevisionId.OutputType,
    state: Outputs.State.OutputType,
    update_time: Outputs.UpdateTime.OutputType,

    pub fn build(allocator: std.mem.Allocator, provider: config_mod.ProviderConfig, args: WorkflowArgs) BuildError!Workflow {
        try provider.validate();
        try validateId(args.workflow_id, error.InvalidWorkflowId);
        const location = args.location orelse provider.primary_region;
        try validateId(location, error.InvalidLocation);
        try validateSource(args.source_contents);
        const service_account = try publicOutputValue(args.service_account);
        if (service_account == .string and !validServiceAccount(service_account.string, provider.project_id)) return error.InvalidServiceAccount;
        const kms_key = if (args.kms_key) |candidate| try publicOutputValue(candidate) else value.Value{ .string = "" };
        if (kms_key == .string and kms_key.string.len > 0 and !validKmsKey(kms_key.string, provider.project_id)) return error.InvalidKmsKey;
        var labels = try labelsValueAlloc(allocator, args.labels);
        defer labels.deinit(allocator);
        var env = try envValueAlloc(allocator, args.user_env);
        defer env.deinit(allocator);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(args.source_contents, &digest, .{});
        const digest_hex = std.fmt.bytesToHex(digest, .lower);
        const fields = [_]value.Field{
            .{ .name = "call_log_level", .value = .{ .string = args.call_log_level.apiName() } },
            .{ .name = "deletion_protection", .value = .{ .boolean = args.deletion_protection } },
            .{ .name = "execution_history", .value = .{ .string = args.execution_history.apiName() } },
            .{ .name = "kms_key", .value = kms_key },
            .{ .name = "labels", .value = labels },
            .{ .name = "location", .value = .{ .string = location } },
            .{ .name = "project_id", .value = .{ .string = provider.project_id } },
            .{ .name = "service_account", .value = service_account },
            .{ .name = "source_contents", .value = .{ .string = args.source_contents } },
            .{ .name = "source_sha256", .value = .{ .string = &digest_hex } },
            .{ .name = "user_env", .value = env },
            .{ .name = "workflow_id", .value = .{ .string = args.workflow_id } },
        };
        const id = try std.fmt.allocPrint(allocator, "gcp.workflows.Workflow.{s}.{s}", .{ location, args.workflow_id });
        defer allocator.free(id);
        const node = try nodeOwned(allocator, id, "gcp.workflows.Workflow", args.workflow_id, &fields, .{
            .protect = args.protect,
            .retain_on_delete = args.retain_on_delete,
            .operation_timeout_millis = 30 * 60 * 1000,
        });
        return .{
            .node = node,
            .name = Outputs.Name.fromResource(node.id),
            .revision_id = Outputs.RevisionId.fromResource(node.id),
            .state = Outputs.State.fromResource(node.id),
            .update_time = Outputs.UpdateTime.fromResource(node.id),
        };
    }

    pub fn deinit(self: *Workflow, allocator: std.mem.Allocator) void {
        self.node.deinit(allocator);
        self.* = undefined;
    }
};

fn validateSource(source: []const u8) BuildError!void {
    if (source.len == 0 or source.len > 128 * 1024 or std.mem.indexOfScalar(u8, source, '\x00') != null) return error.InvalidSource;
    const needles = [_][]const u8{ "password=", "password:", "api_key=", "api_key:", "private_key", "authorization: bearer", "client_secret:" };
    for (needles) |needle| if (containsIgnoreCase(source, needle)) return error.PotentialSecretInSource;
}

fn envValueAlloc(allocator: std.mem.Allocator, env: []const EnvironmentVariable) BuildError!value.Value {
    const items = try allocator.alloc(value.Value, env.len);
    defer allocator.free(items);
    var built: usize = 0;
    defer for (items[0..built]) |item| allocator.free(item.object);
    for (env, 0..) |entry, index| {
        if (!validEnvKey(entry.key) or entry.value.len > 4096 or std.mem.indexOfAny(u8, entry.value, "\x00\r") != null) return error.InvalidEnvironmentVariable;
        for (env[0..index]) |previous| if (std.mem.eql(u8, previous.key, entry.key)) return error.DuplicateEnvironmentVariable;
        const fields = try allocator.alloc(value.Field, 2);
        fields[0] = .{ .name = "key", .value = .{ .string = entry.key } };
        fields[1] = .{ .name = "value", .value = .{ .string = entry.value } };
        items[index] = .{ .object = fields };
        built += 1;
    }
    return value.Value.initOwned(allocator, .{ .list = items }) catch |err| return err;
}

fn labelsValueAlloc(allocator: std.mem.Allocator, labels: []const config_mod.Label) BuildError!value.Value {
    const fields = try allocator.alloc(value.Field, labels.len);
    defer allocator.free(fields);
    for (labels, 0..) |label, index| {
        if (!validLabel(label.key) or !validLabelValue(label.value)) return error.InvalidWorkflowId;
        for (labels[0..index]) |previous| if (std.mem.eql(u8, previous.key, label.key)) return error.DuplicateLabel;
        fields[index] = .{ .name = label.key, .value = .{ .string = label.value } };
    }
    return value.Value.initOwned(allocator, .{ .object = fields });
}

fn validateId(text: []const u8, err: BuildError) BuildError!void {
    if (text.len == 0 or text.len > 63 or !std.ascii.isLower(text[0]) or !std.ascii.isAlphanumeric(text[text.len - 1])) return err;
    for (text) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '-') return err;
}

fn validEnvKey(text: []const u8) bool {
    if (text.len == 0 or text.len > 64 or (!std.ascii.isAlphabetic(text[0]) and text[0] != '_')) return false;
    for (text) |character| if (!std.ascii.isAlphanumeric(character) and character != '_') return false;
    return true;
}

fn validLabel(text: []const u8) bool {
    if (text.len == 0 or text.len > 63 or !std.ascii.isLower(text[0])) return false;
    for (text) |character| if (!std.ascii.isLower(character) and !std.ascii.isDigit(character) and character != '_' and character != '-') return false;
    return true;
}

fn validLabelValue(text: []const u8) bool {
    if (text.len > 63) return false;
    for (text) |character| if (!std.ascii.isAlphanumeric(character) and character != '_' and character != '-') return false;
    return true;
}

fn validServiceAccount(text: []const u8, project_id: []const u8) bool {
    const prefix = "projects/";
    return std.mem.startsWith(u8, text, prefix) and std.mem.indexOf(u8, text, project_id) != null and std.mem.indexOf(u8, text, "/serviceAccounts/") != null and std.mem.indexOfScalar(u8, text, '@') != null and std.mem.indexOfAny(u8, text, "\x00\r\n ?") == null;
}

fn validKmsKey(text: []const u8, project_id: []const u8) bool {
    return std.mem.startsWith(u8, text, "projects/") and std.mem.indexOf(u8, text, project_id) != null and std.mem.indexOf(u8, text, "/locations/") != null and std.mem.indexOf(u8, text, "/keyRings/") != null and std.mem.indexOf(u8, text, "/cryptoKeys/") != null and std.mem.indexOfAny(u8, text, "\x00\r\n ?") == null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) if (std.ascii.eqlIgnoreCase(haystack[index .. index + needle.len], needle)) return true;
    return false;
}

fn publicOutputValue(candidate: output.Output([]const u8, .public)) BuildError!value.Value {
    return switch (candidate) {
        .value => |text| .{ .string = text },
        .resource_ref => |reference| .{ .output_ref = .{ .resource_id = reference.resource_id, .field = reference.field } },
        .unknown_reason => error.OutputNotKnown,
    };
}

fn nodeOwned(allocator: std.mem.Allocator, id: []const u8, type_name: []const u8, logical_id: []const u8, fields: []const value.Field, lifecycle: resource.Lifecycle) BuildError!resource.ResourceNode {
    return resource.ResourceNode.initOwned(allocator, .{ .id = id, .provider = .gcp, .type_name = type_name, .logical_id = logical_id, .inputs = .{ .object = fields }, .lifecycle = lifecycle });
}
