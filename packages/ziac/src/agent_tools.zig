const std = @import("std");
const zstd = @import("zigeffect_std");
const contract = @import("agent_contract.zig");
const mcp = @import("mcp.zig");
const scenario = @import("scenario.zig");

pub const VerificationRunner = struct {
    ptr: *anyopaque,
    run_alloc: *const fn (*anyopaque, std.mem.Allocator, []const []const u8) anyerror![]u8,

    pub fn runAlloc(self: VerificationRunner, allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
        return self.run_alloc(self.ptr, allocator, argv);
    }
};

pub const Kernel = struct {
    allocator: std.mem.Allocator,
    project: contract.Project,
    verification_runner: VerificationRunner,
    last_artifact: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, project: contract.Project, verification_runner: VerificationRunner) Kernel {
        return .{ .allocator = allocator, .project = project, .verification_runner = verification_runner };
    }

    pub fn deinit(self: *Kernel) void {
        if (self.last_artifact) |artifact| self.allocator.free(artifact);
        self.* = undefined;
    }

    pub fn kernel(self: *Kernel) mcp.Kernel {
        return .{ .ptr = self, .invoke_fn = invokeErased };
    }

    pub fn invoke(self: *Kernel, tool: []const u8, arguments_json: []const u8) ![]const u8 {
        const artifact = if (std.mem.eql(u8, tool, "ziac_simulate"))
            try self.simulateAlloc(arguments_json)
        else if (std.mem.eql(u8, tool, "ziac_propose"))
            try self.proposeAlloc(arguments_json)
        else if (std.mem.eql(u8, tool, "ziac_verify"))
            try self.verifyAlloc(arguments_json)
        else
            return error.UnsupportedAgentTool;
        if (self.last_artifact) |previous| self.allocator.free(previous);
        self.last_artifact = artifact;
        return artifact;
    }

    fn invokeErased(raw: *anyopaque, tool: []const u8, arguments_json: []const u8) ![]const u8 {
        const self: *Kernel = @ptrCast(@alignCast(raw));
        return self.invoke(tool, arguments_json);
    }

    fn simulateAlloc(self: *Kernel, arguments_json: []const u8) ![]u8 {
        const Args = struct {
            scenario_id: []const u8,
            kind: []const u8,
            seed: u64,
            max_steps: usize,
            target_resource: []const u8,
            requirement: []const u8,
            acceptance_check: []const u8,
        };
        var parsed = std.json.parseFromSlice(Args, self.allocator, arguments_json, .{}) catch return error.InvalidAgentToolArguments;
        defer parsed.deinit();
        const kind = std.meta.stringToEnum(scenario.Kind, parsed.value.kind) orelse return error.InvalidAgentToolArguments;
        var receipt = try scenario.runAlloc(self.allocator, .{
            .id = parsed.value.scenario_id,
            .kind = kind,
            .seed = parsed.value.seed,
            .max_steps = parsed.value.max_steps,
            .target_resource = parsed.value.target_resource,
            .requirement = parsed.value.requirement,
            .acceptance_check = parsed.value.acceptance_check,
        });
        defer receipt.deinit();
        return self.allocator.dupe(u8, receipt.json);
    }

    fn proposeAlloc(self: *Kernel, arguments_json: []const u8) ![]u8 {
        const Args = struct {
            scenario_id: []const u8,
            requirement: []const u8,
            resource_id: []const u8,
            finding_id: []const u8,
            operation: []const u8,
            verification: []const []const u8,
        };
        var parsed = std.json.parseFromSlice(Args, self.allocator, arguments_json, .{}) catch return error.InvalidAgentToolArguments;
        defer parsed.deinit();
        var proposal = try scenario.proposalAlloc(self.allocator, .{
            .scenario_id = parsed.value.scenario_id,
            .requirement = parsed.value.requirement,
            .resource_id = parsed.value.resource_id,
            .finding_id = parsed.value.finding_id,
            .operation = parsed.value.operation,
            .verification = parsed.value.verification,
        });
        defer proposal.deinit();
        return self.allocator.dupe(u8, proposal.json);
    }

    fn verifyAlloc(self: *Kernel, arguments_json: []const u8) ![]u8 {
        const Args = struct { acceptance_check: []const u8 };
        var parsed = std.json.parseFromSlice(Args, self.allocator, arguments_json, .{}) catch return error.InvalidAgentToolArguments;
        defer parsed.deinit();
        const check = self.project.acceptanceCheck(parsed.value.acceptance_check) orelse return error.UnknownAcceptanceCheck;
        if (check.legacy_command != null) return error.LegacyAcceptanceCommandDenied;
        try validateVerificationArgv(check.argv);
        const raw_output = try self.verification_runner.runAlloc(self.allocator, check.argv);
        defer self.allocator.free(raw_output);
        const output = try zstd.Secrets.redactAlloc(self.allocator, raw_output);
        defer self.allocator.free(output);
        const command_digest = std.fmt.bytesToHex(check.digest(), .lower);
        const manifest_digest = std.fmt.bytesToHex(self.project.manifest_digest, .lower);
        return std.json.Stringify.valueAlloc(self.allocator, .{
            .schema = "ziac.verification-receipt.v1",
            .acceptance_check = check.id,
            .requirement = check.requirement,
            .argv = check.argv,
            .command_digest = &command_digest,
            .manifest_digest = &manifest_digest,
            .passed = true,
            .output = output,
            .mutation_authorized = false,
        }, .{});
    }
};

pub const ScriptedVerificationRunner = struct {
    output: []const u8,
    call_count: usize = 0,

    pub fn init(output: []const u8) ScriptedVerificationRunner {
        return .{ .output = output };
    }

    pub fn runner(self: *ScriptedVerificationRunner) VerificationRunner {
        return .{ .ptr = self, .run_alloc = runAlloc };
    }

    fn runAlloc(raw: *anyopaque, allocator: std.mem.Allocator, _: []const []const u8) ![]u8 {
        const self: *ScriptedVerificationRunner = @ptrCast(@alignCast(raw));
        self.call_count += 1;
        return allocator.dupe(u8, self.output);
    }
};

pub const UnavailableVerificationRunner = struct {
    pub fn runner(self: *UnavailableVerificationRunner) VerificationRunner {
        return .{ .ptr = self, .run_alloc = runAlloc };
    }

    fn runAlloc(_: *anyopaque, _: std.mem.Allocator, _: []const []const u8) ![]u8 {
        return error.VerificationRunnerUnavailable;
    }
};

pub const NativeVerificationRunner = struct {
    io: std.Io,
    cwd: []const u8 = "",

    pub fn runner(self: *NativeVerificationRunner) VerificationRunner {
        return .{ .ptr = self, .run_alloc = runAlloc };
    }

    fn runAlloc(raw: *anyopaque, allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
        const self: *NativeVerificationRunner = @ptrCast(@alignCast(raw));
        try validateVerificationArgv(argv);
        const result = try std.process.run(allocator, self.io, .{
            .argv = argv,
            .cwd = if (self.cwd.len == 0) .inherit else .{ .path = self.cwd },
            .stdout_limit = .limited(4 * 1024 * 1024),
            .stderr_limit = .limited(4 * 1024 * 1024),
        });
        defer allocator.free(result.stderr);
        const passed = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!passed) {
            allocator.free(result.stdout);
            return error.VerificationFailed;
        }
        return result.stdout;
    }
};

pub fn validateVerificationArgv(argv: []const []const u8) !void {
    if (argv.len == 0 or argv.len > 64) return error.InvalidVerificationCommand;
    const executable = argv[0];
    if (std.fs.path.isAbsolute(executable)) return error.ShellVerificationDenied;
    const basename = std.fs.path.basename(executable);
    const shells = [_][]const u8{ "sh", "bash", "zsh", "fish", "cmd", "cmd.exe", "powershell", "pwsh" };
    for (shells) |shell| if (std.ascii.eqlIgnoreCase(basename, shell)) return error.ShellVerificationDenied;
    for (argv) |arg| {
        if (arg.len == 0 or arg.len > 16 * 1024 or std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidVerificationCommand;
        var segments = std.mem.splitScalar(u8, arg, '/');
        while (segments.next()) |segment| if (std.mem.eql(u8, segment, "..")) return error.VerificationTraversalDenied;
    }
}
