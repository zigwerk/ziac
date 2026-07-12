const std = @import("std");
const agent_contract = @import("agent_contract.zig");
const program_format = @import("program_format.zig");
const stack_registry = @import("stack_registry.zig");

pub const RunError = error{
    ProgramCompilerFailed,
    ProgramCompilerOutputTooLarge,
};

pub const Runner = struct {
    ptr: *anyopaque,
    runAllocFn: *const fn (*anyopaque, std.mem.Allocator, []const []const u8, usize) anyerror![]u8,

    pub fn runAlloc(self: Runner, allocator: std.mem.Allocator, argv: []const []const u8, max_output_bytes: usize) ![]u8 {
        return self.runAllocFn(self.ptr, allocator, argv, max_output_bytes);
    }
};

pub fn targetFromArgs(args: []const []const u8) ?program_format.Target {
    var stack: ?[]const u8 = null;
    var stage: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--stack") and index + 1 < args.len) stack = args[index + 1];
        if (std.mem.eql(u8, args[index], "--stage") and index + 1 < args.len) stage = args[index + 1];
    }
    if (stack == null or stage == null) return null;
    return .{ .stack = stack.?, .stage = stage.? };
}

pub fn loadAlloc(
    allocator: std.mem.Allocator,
    compiler: agent_contract.ProgramCompiler,
    runner: Runner,
    target: program_format.Target,
) !stack_registry.StackProgram {
    var argv = try std.ArrayList([]const u8).initCapacity(allocator, compiler.argv.len + 4);
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, compiler.argv);
    try argv.appendSlice(allocator, &.{ "--stack", target.stack, "--stage", target.stage });
    const artifact = try runner.runAlloc(allocator, argv.items, compiler.max_output_bytes);
    defer allocator.free(artifact);
    return program_format.decodeAlloc(allocator, artifact, target);
}

pub const NativeRunner = struct {
    io: std.Io,
    cwd_path: ?[]const u8 = null,

    pub fn runner(self: *NativeRunner) Runner {
        return .{ .ptr = self, .runAllocFn = runAlloc };
    }

    fn runAlloc(raw: *anyopaque, allocator: std.mem.Allocator, argv: []const []const u8, max_output_bytes: usize) ![]u8 {
        const self: *NativeRunner = @ptrCast(@alignCast(raw));
        const result = try std.process.run(allocator, self.io, .{
            .argv = argv,
            .cwd = if (self.cwd_path) |path| .{ .path = path } else .inherit,
            .stdout_limit = .limited(max_output_bytes),
            .stderr_limit = .limited(1024 * 1024),
        });
        defer allocator.free(result.stderr);
        const passed = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!passed) {
            allocator.free(result.stdout);
            return error.ProgramCompilerFailed;
        }
        return result.stdout;
    }
};

pub const ScriptedRunner = struct {
    artifact: []const u8,
    call_count: usize = 0,
    last_stack: ?[]const u8 = null,
    last_stage: ?[]const u8 = null,

    pub fn init(artifact: []const u8) ScriptedRunner {
        return .{ .artifact = artifact };
    }

    pub fn runner(self: *ScriptedRunner) Runner {
        return .{ .ptr = self, .runAllocFn = runAlloc };
    }

    fn runAlloc(raw: *anyopaque, allocator: std.mem.Allocator, argv: []const []const u8, max_output_bytes: usize) ![]u8 {
        const self: *ScriptedRunner = @ptrCast(@alignCast(raw));
        if (self.artifact.len > max_output_bytes) return error.ProgramCompilerOutputTooLarge;
        self.call_count += 1;
        if (argv.len < 4 or !std.mem.eql(u8, argv[argv.len - 4], "--stack") or !std.mem.eql(u8, argv[argv.len - 2], "--stage")) {
            return error.ProgramCompilerFailed;
        }
        self.last_stack = argv[argv.len - 3];
        self.last_stage = argv[argv.len - 1];
        return allocator.dupe(u8, self.artifact);
    }
};
