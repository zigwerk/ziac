const std = @import("std");
const resource = @import("resource.zig");

pub const schema = "ziac.project.v1";

pub const AdaptationStrategy = enum {
    local_process,
    local_service,
    local_proxy,
    cloud_read,
    cloud_resource,
    mock,
    skip,
    remote_only,
};

pub const Component = struct {
    id: []const u8,
    resources: []const []const u8,
};

pub const Requirement = struct {
    id: []const u8,
    summary: []const u8,
    component: []const u8,
    required: bool,
};

pub const AcceptanceCheck = struct {
    id: []const u8,
    requirement: []const u8,
    argv: []const []const u8,
    legacy_command: ?[]const u8 = null,

    pub fn digest(self: AcceptanceCheck) [32]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        for (self.argv) |arg| {
            var length: [8]u8 = undefined;
            std.mem.writeInt(u64, &length, arg.len, .little);
            hasher.update(&length);
            hasher.update(arg);
        }
        if (self.legacy_command) |command| {
            hasher.update("legacy-shell-command-disabled:");
            hasher.update(command);
        }
        var result: [32]u8 = undefined;
        hasher.final(&result);
        return result;
    }
};

pub const Environment = struct {
    id: []const u8,
    stage_patterns: []const []const u8,
    providers: []const []const u8,
    projects: []const []const u8,
    regions: []const []const u8,
    max_monthly_cost_minor: u64,
};

pub const Adaptation = struct {
    resource_type: []const u8,
    strategy: AdaptationStrategy,
};

pub const Scenario = struct {
    id: []const u8,
    requirement: []const u8,
    acceptance_check: []const u8,
    seed: u64,
    required: bool,
};

pub const Permissions = struct {
    read: bool = false,
    plan: bool = false,
    apply: bool = false,
    delete: bool = false,
    secret_read: bool = false,
    live_network: bool = false,
    process: bool = false,
};

pub const Development = struct {
    source_root: []const u8,
    build_argv: []const []const u8,
    process_argv: []const []const u8,
    health_path: []const u8,
    proxy_port: u16,
    generation_base_port: u16,
    poll_millis: u64,
};

pub const ProgramCompiler = struct {
    argv: []const []const u8,
    max_output_bytes: usize = 8 * 1024 * 1024,
};

pub const ParseError = std.mem.Allocator.Error || error{
    InvalidProjectJson,
    UnsupportedProjectSchema,
    InvalidProjectId,
    InvalidSourceRoot,
    DuplicateId,
    DuplicateAdaptation,
    DanglingComponent,
    DanglingRequirement,
    DanglingAcceptanceCheck,
    InvalidEnvironment,
    InvalidScenario,
    InvalidAdaptation,
    InvalidDevelopment,
    InvalidProgramCompiler,
    UnsafeDefaultAuthority,
};

pub const Project = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    id: []const u8,
    source_roots: []const []const u8,
    components: []const Component,
    requirements: []const Requirement,
    acceptance_checks: []const AcceptanceCheck,
    environments: []const Environment,
    adaptations: []const Adaptation,
    scenarios: []const Scenario,
    authority: Permissions,
    development: ?Development,
    program: ?ProgramCompiler,
    manifest_digest: [32]u8,

    pub fn parseAlloc(allocator: std.mem.Allocator, bytes: []const u8) ParseError!Project {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        var parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch return error.InvalidProjectJson;
        defer parsed.deinit();
        const root = object(parsed.value) orelse return error.InvalidProjectJson;
        if (!std.mem.eql(u8, try requiredString(root, "schema"), schema)) return error.UnsupportedProjectSchema;
        const id = try dupeNonEmpty(a, try requiredString(root, "project"));
        const source_roots = try parseStringArray(a, root.get("source_roots") orelse return error.InvalidProjectJson);
        const components = try parseComponents(a, root.get("components") orelse return error.InvalidProjectJson);
        const requirements = try parseRequirements(a, root.get("requirements") orelse return error.InvalidProjectJson);
        const acceptance_checks = try parseAcceptanceChecks(a, root.get("acceptance_checks") orelse return error.InvalidProjectJson);
        const environments = try parseEnvironments(a, root.get("environments") orelse return error.InvalidProjectJson);
        const adaptations = try parseAdaptations(a, root.get("adaptations") orelse return error.InvalidProjectJson);
        const scenarios = try parseScenarios(a, root.get("scenarios") orelse return error.InvalidProjectJson);
        const authority = try parsePermissions(root.get("authority") orelse return error.InvalidProjectJson);
        const development = if (root.get("development")) |value| try parseDevelopment(a, value) else null;
        const program = if (root.get("program")) |value| try parseProgramCompiler(a, value) else null;
        var manifest_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &manifest_digest, .{});

        var project = Project{
            .allocator = allocator,
            .arena = arena,
            .id = id,
            .source_roots = source_roots,
            .components = components,
            .requirements = requirements,
            .acceptance_checks = acceptance_checks,
            .environments = environments,
            .adaptations = adaptations,
            .scenarios = scenarios,
            .authority = authority,
            .development = development,
            .program = program,
            .manifest_digest = manifest_digest,
        };
        try project.validate();
        return project;
    }

    pub fn deinit(self: *Project) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.* = undefined;
    }

    pub fn component(self: Project, id: []const u8) ?Component {
        for (self.components) |item| if (std.mem.eql(u8, item.id, id)) return item;
        return null;
    }

    pub fn requirement(self: Project, id: []const u8) ?Requirement {
        for (self.requirements) |item| if (std.mem.eql(u8, item.id, id)) return item;
        return null;
    }

    pub fn acceptanceCheck(self: Project, id: []const u8) ?AcceptanceCheck {
        for (self.acceptance_checks) |item| if (std.mem.eql(u8, item.id, id)) return item;
        return null;
    }

    pub fn adaptationFor(self: Project, type_name: []const u8) ?AdaptationStrategy {
        for (self.adaptations) |item| if (std.mem.eql(u8, item.resource_type, type_name)) return item.strategy;
        return null;
    }

    fn validate(self: *Project) ParseError!void {
        if (self.id.len == 0) return error.InvalidProjectId;
        for (self.source_roots) |root| {
            if (root.len == 0 or std.fs.path.isAbsolute(root) or hasParentSegment(root)) return error.InvalidSourceRoot;
        }
        try requireUnique(Component, self.components, componentId);
        try requireUnique(Requirement, self.requirements, requirementId);
        try requireUnique(AcceptanceCheck, self.acceptance_checks, acceptanceId);
        try requireUnique(Environment, self.environments, environmentId);
        try requireUnique(Scenario, self.scenarios, scenarioId);
        for (self.adaptations, 0..) |item, index| {
            if (item.resource_type.len == 0) return error.InvalidAdaptation;
            for (self.adaptations[index + 1 ..]) |other| {
                if (std.mem.eql(u8, item.resource_type, other.resource_type)) return error.DuplicateAdaptation;
            }
        }
        for (self.requirements) |item| if (self.component(item.component) == null) return error.DanglingComponent;
        for (self.acceptance_checks) |item| if (self.requirement(item.requirement) == null) return error.DanglingRequirement;
        for (self.acceptance_checks) |item| {
            if (item.argv.len == 0 and item.legacy_command == null) return error.InvalidProjectJson;
            if (item.argv.len != 0 and item.legacy_command != null) return error.InvalidProjectJson;
            for (item.argv) |arg| if (arg.len == 0 or std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidProjectJson;
        }
        for (self.scenarios) |item| {
            if (item.seed == 0) return error.InvalidScenario;
            if (self.requirement(item.requirement) == null) return error.DanglingRequirement;
            const check = self.acceptanceCheck(item.acceptance_check) orelse return error.DanglingAcceptanceCheck;
            if (!std.mem.eql(u8, check.requirement, item.requirement)) return error.InvalidScenario;
        }
        for (self.requirements) |item| if (item.required) {
            var covered = false;
            for (self.scenarios) |scenario| if (scenario.required and std.mem.eql(u8, scenario.requirement, item.id)) {
                covered = true;
                break;
            };
            if (!covered) return error.InvalidScenario;
        };
        for (self.environments) |environment| {
            if (environment.id.len == 0 or environment.stage_patterns.len == 0 or environment.providers.len == 0 or
                environment.regions.len == 0 or environment.max_monthly_cost_minor == 0) return error.InvalidEnvironment;
        }
        if (self.authority.delete) return error.UnsafeDefaultAuthority;
        if (self.development) |development| {
            if (development.source_root.len == 0 or std.fs.path.isAbsolute(development.source_root) or
                hasParentSegment(development.source_root) or development.build_argv.len == 0 or
                development.process_argv.len == 0 or development.health_path.len == 0 or
                development.health_path[0] != '/' or std.mem.indexOfScalar(u8, development.health_path, 0) != null or
                development.generation_base_port < 1024 or development.generation_base_port > 64_000 or
                development.poll_millis < 10 or development.poll_millis > 10_000)
            {
                return error.InvalidDevelopment;
            }
        }
        if (self.program) |program| {
            if (program.argv.len == 0 or program.max_output_bytes < 1024 or program.max_output_bytes > 64 * 1024 * 1024) {
                return error.InvalidProgramCompiler;
            }
            const executable = program.argv[0];
            if (!std.mem.eql(u8, executable, "zig")) return error.InvalidProgramCompiler;
            for (program.argv) |arg| {
                if (arg.len == 0 or std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidProgramCompiler;
            }
        }
    }
};

pub const Action = enum { read, plan, apply, delete, secret_read, live_network, process };

pub const AutonomyBudget = struct {
    max_creates: usize = 0,
    max_updates: usize = 0,
    max_deletes: usize = 0,
    max_regions: usize = 0,
    max_monthly_cost_minor: u64 = 0,
    deadline_millis: u64 = 0,
};

pub const AuthorizationRequest = struct {
    now_millis: u64,
    started_at_millis: u64 = 0,
    stage: []const u8,
    project: []const u8,
    provider: resource.ProviderId,
    action: Action,
    creates: usize = 0,
    updates: usize = 0,
    deletes: usize = 0,
    regions: usize = 0,
    monthly_cost_minor: u64 = 0,
    plan_digest: ?[]const u8 = null,
};

pub const AuthorizationError = error{
    CapabilityExpired,
    TargetDenied,
    ActionDenied,
    BudgetExceeded,
    DeadlineExceeded,
    PlanDigestRequired,
    PlanDigestMismatch,
};

pub const CapabilityEnvelope = struct {
    id: []const u8,
    stages: []const []const u8,
    projects: []const []const u8,
    providers: []const resource.ProviderId,
    permissions: Permissions,
    budget: AutonomyBudget,
    expires_at_millis: u64,
    approved_plan_digest: ?[]const u8 = null,

    pub fn require(self: CapabilityEnvelope, request: AuthorizationRequest) AuthorizationError!void {
        if (self.id.len == 0 or request.now_millis > self.expires_at_millis) return error.CapabilityExpired;
        if (!containsString(self.stages, request.stage) or !containsString(self.projects, request.project) or
            !containsProvider(self.providers, request.provider)) return error.TargetDenied;
        if (!permission(self.permissions, request.action)) return error.ActionDenied;
        if (request.creates > self.budget.max_creates or request.updates > self.budget.max_updates or
            request.deletes > self.budget.max_deletes or request.regions > self.budget.max_regions or
            request.monthly_cost_minor > self.budget.max_monthly_cost_minor) return error.BudgetExceeded;
        if (self.budget.deadline_millis > 0 and request.started_at_millis > 0 and
            request.now_millis -| request.started_at_millis > self.budget.deadline_millis) return error.DeadlineExceeded;
        if (request.action == .apply or request.action == .delete) {
            const approved = self.approved_plan_digest orelse return error.PlanDigestRequired;
            const supplied = request.plan_digest orelse return error.PlanDigestRequired;
            if (!std.mem.eql(u8, approved, supplied)) return error.PlanDigestMismatch;
        }
    }
};

fn parseComponents(allocator: std.mem.Allocator, value: std.json.Value) ParseError![]const Component {
    const items = array(value) orelse return error.InvalidProjectJson;
    const result = try allocator.alloc(Component, items.len);
    for (items, 0..) |item, index| {
        const source = object(item) orelse return error.InvalidProjectJson;
        result[index] = .{
            .id = try dupeNonEmpty(allocator, try requiredString(source, "id")),
            .resources = try parseStringArray(allocator, source.get("resources") orelse return error.InvalidProjectJson),
        };
    }
    return result;
}

fn parseRequirements(allocator: std.mem.Allocator, value: std.json.Value) ParseError![]const Requirement {
    const items = array(value) orelse return error.InvalidProjectJson;
    const result = try allocator.alloc(Requirement, items.len);
    for (items, 0..) |item, index| {
        const source = object(item) orelse return error.InvalidProjectJson;
        result[index] = .{
            .id = try dupeNonEmpty(allocator, try requiredString(source, "id")),
            .summary = try dupeNonEmpty(allocator, try requiredString(source, "summary")),
            .component = try dupeNonEmpty(allocator, try requiredString(source, "component")),
            .required = try requiredBool(source, "required"),
        };
    }
    return result;
}

fn parseAcceptanceChecks(allocator: std.mem.Allocator, value: std.json.Value) ParseError![]const AcceptanceCheck {
    const items = array(value) orelse return error.InvalidProjectJson;
    const result = try allocator.alloc(AcceptanceCheck, items.len);
    for (items, 0..) |item, index| {
        const source = object(item) orelse return error.InvalidProjectJson;
        const argv = if (source.get("argv")) |argv_value| try parseStringArray(allocator, argv_value) else &.{};
        const legacy_command = if (source.get("command")) |command_value|
            try dupeNonEmpty(allocator, string(command_value) orelse return error.InvalidProjectJson)
        else
            null;
        result[index] = .{
            .id = try dupeNonEmpty(allocator, try requiredString(source, "id")),
            .requirement = try dupeNonEmpty(allocator, try requiredString(source, "requirement")),
            .argv = argv,
            .legacy_command = legacy_command,
        };
    }
    return result;
}

fn parseEnvironments(allocator: std.mem.Allocator, value: std.json.Value) ParseError![]const Environment {
    const items = array(value) orelse return error.InvalidProjectJson;
    const result = try allocator.alloc(Environment, items.len);
    for (items, 0..) |item, index| {
        const source = object(item) orelse return error.InvalidProjectJson;
        result[index] = .{
            .id = try dupeNonEmpty(allocator, try requiredString(source, "id")),
            .stage_patterns = try parseStringArray(allocator, source.get("stage_patterns") orelse return error.InvalidProjectJson),
            .providers = try parseStringArray(allocator, source.get("providers") orelse return error.InvalidProjectJson),
            .projects = try parseStringArray(allocator, source.get("projects") orelse return error.InvalidProjectJson),
            .regions = try parseStringArray(allocator, source.get("regions") orelse return error.InvalidProjectJson),
            .max_monthly_cost_minor = try requiredU64(source, "max_monthly_cost_minor"),
        };
    }
    return result;
}

fn parseAdaptations(allocator: std.mem.Allocator, value: std.json.Value) ParseError![]const Adaptation {
    const items = array(value) orelse return error.InvalidProjectJson;
    const result = try allocator.alloc(Adaptation, items.len);
    for (items, 0..) |item, index| {
        const source = object(item) orelse return error.InvalidProjectJson;
        result[index] = .{
            .resource_type = try dupeNonEmpty(allocator, try requiredString(source, "resource_type")),
            .strategy = std.meta.stringToEnum(AdaptationStrategy, try requiredString(source, "strategy")) orelse return error.InvalidAdaptation,
        };
    }
    return result;
}

fn parseScenarios(allocator: std.mem.Allocator, value: std.json.Value) ParseError![]const Scenario {
    const items = array(value) orelse return error.InvalidProjectJson;
    const result = try allocator.alloc(Scenario, items.len);
    for (items, 0..) |item, index| {
        const source = object(item) orelse return error.InvalidProjectJson;
        result[index] = .{
            .id = try dupeNonEmpty(allocator, try requiredString(source, "id")),
            .requirement = try dupeNonEmpty(allocator, try requiredString(source, "requirement")),
            .acceptance_check = try dupeNonEmpty(allocator, try requiredString(source, "acceptance_check")),
            .seed = try requiredU64(source, "seed"),
            .required = try requiredBool(source, "required"),
        };
    }
    return result;
}

fn parsePermissions(value: std.json.Value) ParseError!Permissions {
    const source = object(value) orelse return error.InvalidProjectJson;
    return .{
        .read = try requiredBool(source, "read"),
        .plan = try requiredBool(source, "plan"),
        .apply = try requiredBool(source, "apply"),
        .delete = try requiredBool(source, "delete"),
        .secret_read = try requiredBool(source, "secret_read"),
        .live_network = try requiredBool(source, "live_network"),
        .process = try optionalBool(source, "process", false),
    };
}

fn parseDevelopment(allocator: std.mem.Allocator, value: std.json.Value) ParseError!Development {
    const source = object(value) orelse return error.InvalidProjectJson;
    const proxy_port = std.math.cast(u16, try requiredU64(source, "proxy_port")) orelse return error.InvalidDevelopment;
    const generation_base_port = std.math.cast(u16, try requiredU64(source, "generation_base_port")) orelse return error.InvalidDevelopment;
    return .{
        .source_root = try dupeNonEmpty(allocator, try requiredString(source, "source_root")),
        .build_argv = try parseStringArray(allocator, source.get("build_argv") orelse return error.InvalidProjectJson),
        .process_argv = try parseStringArray(allocator, source.get("process_argv") orelse return error.InvalidProjectJson),
        .health_path = try dupeNonEmpty(allocator, try requiredString(source, "health_path")),
        .proxy_port = proxy_port,
        .generation_base_port = generation_base_port,
        .poll_millis = try requiredU64(source, "poll_millis"),
    };
}

fn parseProgramCompiler(allocator: std.mem.Allocator, value: std.json.Value) ParseError!ProgramCompiler {
    const source = object(value) orelse return error.InvalidProjectJson;
    const max_output = if (source.get("max_output_bytes")) |entry|
        switch (entry) {
            .integer => |inner| std.math.cast(usize, inner) orelse return error.InvalidProjectJson,
            else => return error.InvalidProjectJson,
        }
    else
        8 * 1024 * 1024;
    return .{
        .argv = try parseStringArray(allocator, source.get("argv") orelse return error.InvalidProjectJson),
        .max_output_bytes = max_output,
    };
}

fn parseStringArray(allocator: std.mem.Allocator, value: std.json.Value) ParseError![]const []const u8 {
    const items = array(value) orelse return error.InvalidProjectJson;
    const result = try allocator.alloc([]const u8, items.len);
    for (items, 0..) |item, index| result[index] = try dupeNonEmpty(allocator, string(item) orelse return error.InvalidProjectJson);
    return result;
}

fn object(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |result| result,
        else => null,
    };
}

fn array(value: std.json.Value) ?[]const std.json.Value {
    return switch (value) {
        .array => |result| result.items,
        else => null,
    };
}

fn string(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |result| result,
        else => null,
    };
}

fn requiredString(source: std.json.ObjectMap, name: []const u8) ParseError![]const u8 {
    return string(source.get(name) orelse return error.InvalidProjectJson) orelse error.InvalidProjectJson;
}

fn requiredBool(source: std.json.ObjectMap, name: []const u8) ParseError!bool {
    const value = source.get(name) orelse return error.InvalidProjectJson;
    return switch (value) {
        .bool => |result| result,
        else => error.InvalidProjectJson,
    };
}

fn optionalBool(source: std.json.ObjectMap, name: []const u8, default: bool) ParseError!bool {
    const value = source.get(name) orelse return default;
    return switch (value) {
        .bool => |result| result,
        else => error.InvalidProjectJson,
    };
}

fn requiredU64(source: std.json.ObjectMap, name: []const u8) ParseError!u64 {
    const value = source.get(name) orelse return error.InvalidProjectJson;
    return switch (value) {
        .integer => |result| std.math.cast(u64, result) orelse error.InvalidProjectJson,
        else => error.InvalidProjectJson,
    };
}

fn dupeNonEmpty(allocator: std.mem.Allocator, value: []const u8) ParseError![]const u8 {
    if (value.len == 0) return error.InvalidProjectJson;
    return allocator.dupe(u8, value);
}

fn hasParentSegment(path: []const u8) bool {
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return true;
    return false;
}

fn requireUnique(comptime T: type, items: []const T, comptime idFn: fn (T) []const u8) ParseError!void {
    for (items, 0..) |item, index| {
        if (idFn(item).len == 0) return error.InvalidProjectJson;
        for (items[index + 1 ..]) |other| if (std.mem.eql(u8, idFn(item), idFn(other))) return error.DuplicateId;
    }
}

fn componentId(value: Component) []const u8 {
    return value.id;
}
fn requirementId(value: Requirement) []const u8 {
    return value.id;
}
fn acceptanceId(value: AcceptanceCheck) []const u8 {
    return value.id;
}
fn environmentId(value: Environment) []const u8 {
    return value.id;
}
fn scenarioId(value: Scenario) []const u8 {
    return value.id;
}

fn containsString(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, expected)) return true;
    return false;
}

fn containsProvider(values: []const resource.ProviderId, expected: resource.ProviderId) bool {
    for (values) |value| if (value == expected) return true;
    return false;
}

fn permission(permissions: Permissions, action: Action) bool {
    return switch (action) {
        .read => permissions.read,
        .plan => permissions.plan,
        .apply => permissions.apply,
        .delete => permissions.delete,
        .secret_read => permissions.secret_read,
        .live_network => permissions.live_network,
        .process => permissions.process,
    };
}
