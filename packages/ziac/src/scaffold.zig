const std = @import("std");

pub const Options = struct {
    project_name: []const u8,
    ziac_path: []const u8,
};

pub const File = struct {
    path: []const u8,
    contents: []const u8,
};

pub const Rendered = struct {
    allocator: std.mem.Allocator,
    files: []File,

    pub fn deinit(self: *Rendered) void {
        for (self.files) |entry| {
            self.allocator.free(entry.path);
            self.allocator.free(entry.contents);
        }
        self.allocator.free(self.files);
        self.* = undefined;
    }

    pub fn file(self: Rendered, path: []const u8) ?[]const u8 {
        for (self.files) |entry| if (std.mem.eql(u8, entry.path, path)) return entry.contents;
        return null;
    }
};

pub const Error = std.mem.Allocator.Error || error{
    InvalidProjectName,
    InvalidZiacPath,
    ProjectFileExists,
};

pub fn renderAlloc(allocator: std.mem.Allocator, options: Options) Error!Rendered {
    try validateProjectName(options.project_name);
    if (options.ziac_path.len == 0 or std.fs.path.isAbsolute(options.ziac_path) or std.mem.indexOfScalar(u8, options.ziac_path, 0) != null) return error.InvalidZiacPath;
    const zon_path = try std.json.Stringify.valueAlloc(allocator, options.ziac_path, .{});
    defer allocator.free(zon_path);
    const zig_name = try zigIdentifierAlloc(allocator, options.project_name);
    defer allocator.free(zig_name);
    var name_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(options.project_name, &name_digest, .{});
    const package_id = std.mem.readInt(u32, name_digest[0..4], .little) | 1;
    const fingerprint = (@as(u64, std.hash.Crc32.hash(zig_name)) << 32) | package_id;

    var files = std.ArrayList(File).empty;
    errdefer freeFiles(allocator, files.items);
    try appendStatic(allocator, &files, "build.zig", build_zig);
    try appendFormatted(allocator, &files, "build.zig.zon", build_zon, .{ zig_name, fingerprint, zon_path });
    try appendFormatted(allocator, &files, "ziac.project.json", project_json, .{options.project_name});
    try appendStatic(allocator, &files, "ziac_program.zig", program_compiler_zig);
    try appendStatic(allocator, &files, "ziac.stack.zig", stack_zig);
    try appendStatic(allocator, &files, "src/main.zig", app_zig);
    try appendStatic(allocator, &files, ".gitignore", gitignore);
    try appendStatic(allocator, &files, ".ziacignore", ziacignore);
    try appendStatic(allocator, &files, ".agents/skills/ziac/SKILL.md", agent_skill);
    try appendStatic(allocator, &files, ".claude/skills/ziac/SKILL.md", agent_skill);
    try appendStatic(allocator, &files, ".gemini/skills/ziac/SKILL.md", agent_skill);
    try appendStatic(allocator, &files, "GEMINI.md", gemini_md);
    try appendStatic(allocator, &files, ".mcp.json", mcp_json);
    try appendStatic(allocator, &files, ".codex/config.toml", codex_config);
    try appendStatic(allocator, &files, ".gemini/settings.json", gemini_settings);
    return .{ .allocator = allocator, .files = try files.toOwnedSlice(allocator) };
}

pub fn projectNameAlloc(allocator: std.mem.Allocator, directory_name: []const u8) Error![]u8 {
    if (directory_name.len == 0 or directory_name.len > 512 or std.mem.indexOfScalar(u8, directory_name, 0) != null) {
        return error.InvalidProjectName;
    }
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    var pending_separator = false;
    for (directory_name) |char| {
        if (std.ascii.isAlphanumeric(char)) {
            if (pending_separator and output.items.len > 0 and output.items.len < 48) try output.append(allocator, '-');
            pending_separator = false;
            if (output.items.len < 48) try output.append(allocator, std.ascii.toLower(char));
        } else {
            pending_separator = output.items.len > 0;
        }
    }
    while (output.items.len > 0 and output.items[output.items.len - 1] == '-') _ = output.pop();
    if (output.items.len == 0) return error.InvalidProjectName;
    return output.toOwnedSlice(allocator);
}

pub fn write(dir: std.Io.Dir, io: std.Io, rendered: Rendered, force: bool) !void {
    if (!force) for (rendered.files) |entry| {
        var handle = dir.openFile(io, entry.path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        handle.close(io);
        return error.ProjectFileExists;
    };
    for (rendered.files) |entry| {
        if (std.fs.path.dirname(entry.path)) |parent| try dir.createDirPath(io, parent);
        try dir.writeFile(io, .{ .sub_path = entry.path, .data = entry.contents });
    }
}

fn validateProjectName(name: []const u8) Error!void {
    if (name.len == 0 or name.len > 48 or name[0] == '-' or name[name.len - 1] == '-') return error.InvalidProjectName;
    for (name) |char| if (!(std.ascii.isLower(char) or std.ascii.isDigit(char) or char == '-')) return error.InvalidProjectName;
}

fn zigIdentifierAlloc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const result = try allocator.dupe(u8, name);
    for (result) |*char| if (char.* == '-') {
        char.* = '_';
    };
    return result;
}

fn appendStatic(allocator: std.mem.Allocator, files: *std.ArrayList(File), path: []const u8, contents: []const u8) !void {
    try files.append(allocator, .{ .path = try allocator.dupe(u8, path), .contents = try allocator.dupe(u8, contents) });
}

fn appendFormatted(allocator: std.mem.Allocator, files: *std.ArrayList(File), path: []const u8, comptime format: []const u8, args: anytype) !void {
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    try files.append(allocator, .{ .path = owned_path, .contents = try std.fmt.allocPrint(allocator, format, args) });
}

fn freeFiles(allocator: std.mem.Allocator, files: []File) void {
    for (files) |entry| {
        allocator.free(entry.path);
        allocator.free(entry.contents);
    }
}

const build_zig =
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\    const ziac_dep = b.dependency("ziac", .{ .target = target, .optimize = optimize });
    \\    const ziac = ziac_dep.module("ziac");
    \\
    \\    const app = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    \\    const executable = b.addExecutable(.{ .name = "app", .root_module = app });
    \\    b.installArtifact(executable);
    \\
    \\    const stack = b.createModule(.{ .root_source_file = b.path("ziac.stack.zig"), .target = target, .optimize = optimize });
    \\    stack.addImport("ziac", ziac);
    \\    stack.addImport("app", app);
    \\    const compiler_module = b.createModule(.{ .root_source_file = b.path("ziac_program.zig"), .target = target, .optimize = optimize });
    \\    compiler_module.addImport("ziac", ziac);
    \\    compiler_module.addImport("stack", stack);
    \\    const compiler = b.addExecutable(.{ .name = "ziac-program-compiler", .root_module = compiler_module });
    \\    const run_compiler = b.addRunArtifact(compiler);
    \\    if (b.args) |args| run_compiler.addArgs(args);
    \\    const program_step = b.step("ziac-program", "Compile the typed Ziac infrastructure program");
    \\    program_step.dependOn(&run_compiler.step);
    \\
    \\    const tests = b.addTest(.{
    \\        .name = "app-tests",
    \\        .root_module = app,
    \\        .test_runner = .{ .path = ziac_dep.module("zigeffect_test_runner").root_source_file.?, .mode = .server },
    \\    });
    \\    const test_step = b.step("test", "Run deterministic application tests");
    \\    test_step.dependOn(&b.addRunArtifact(tests).step);
    \\}
;

const build_zon =
    \\.{{
    \\    .name = .{s},
    \\    .version = "0.1.0",
    \\    .fingerprint = 0x{x},
    \\    .minimum_zig_version = "0.16.0",
    \\    .dependencies = .{{ .ziac = .{{ .path = {s} }} }},
    \\    .paths = .{{ "build.zig", "build.zig.zon", "src", "ziac.stack.zig", "ziac_program.zig", "ziac.project.json" }},
    \\}}
;

const project_json =
    \\{{
    \\  "schema": "ziac.project.v1",
    \\  "project": "{s}",
    \\  "source_roots": ["src", "ziac.stack.zig"],
    \\  "program": {{ "argv": ["zig", "build", "ziac-program", "--"], "max_output_bytes": 8388608 }},
    \\  "components": [{{ "id": "api", "resources": [] }}],
    \\  "requirements": [{{ "id": "global-api-healthy", "summary": "The global API compiles and remains healthy", "component": "api", "required": true }}],
    \\  "acceptance_checks": [{{ "id": "check-global-api", "requirement": "global-api-healthy", "argv": ["zig", "build", "test"] }}],
    \\  "environments": [{{ "id": "development", "stage_patterns": ["dev", "dev_*"], "providers": ["gcp", "cockroach"], "projects": ["*-ziac-disposable"], "regions": ["europe-west1", "us-central1", "asia-northeast1"], "max_monthly_cost_minor": 10000 }}],
    \\  "adaptations": [{{ "resource_type": "gcp.run.Service", "strategy": "local_process" }}, {{ "resource_type": "gcp.compute.BackendService", "strategy": "local_proxy" }}],
    \\  "development": {{ "source_root": ".", "build_argv": ["zig", "build"], "process_argv": ["./zig-out/bin/app"], "health_path": "/health/live", "proxy_port": 4318, "generation_base_port": 45000, "poll_millis": 75 }},
    \\  "scenarios": [{{ "id": "global-api-starts", "requirement": "global-api-healthy", "acceptance_check": "check-global-api", "seed": 42, "required": true }}],
    \\  "authority": {{ "read": true, "plan": true, "apply": false, "delete": false, "secret_read": false, "live_network": false, "process": true }}
    \\}}
;

const program_compiler_zig =
    \\const std = @import("std");
    \\const ziac = @import("ziac");
    \\const stack = @import("stack");
    \\
    \\pub fn main(init: std.process.Init) !void {
    \\    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    \\    defer args.deinit();
    \\    _ = args.skip();
    \\    var stack_name: ?[]const u8 = null;
    \\    var stage: ?[]const u8 = null;
    \\    while (args.next()) |arg| {
    \\        if (std.mem.eql(u8, arg, "--stack")) stack_name = args.next() orelse return error.MissingStack;
    \\        if (std.mem.eql(u8, arg, "--stage")) stage = args.next() orelse return error.MissingStage;
    \\    }
    \\    const target = ziac.program_format.Target{ .stack = stack_name orelse return error.MissingStack, .stage = stage orelse return error.MissingStage };
    \\    var program = try stack.build(init.gpa, init, .{ .stack = target.stack, .stage = target.stage });
    \\    defer program.deinit();
    \\    const artifact = try ziac.program_format.encodeAlloc(init.gpa, target.stack, target.stage, &program);
    \\    defer init.gpa.free(artifact);
    \\    try std.Io.File.stdout().writeStreamingAll(init.io, artifact);
    \\}
;

const stack_zig =
    \\const std = @import("std");
    \\const ziac = @import("ziac");
    \\const App = @import("app");
    \\
    \\const regions = [_][]const u8{ "europe-west1", "us-central1", "asia-northeast1" };
    \\const Providers = ziac.stack.ProviderSet(.{ziac.resource.ProviderId.gcp});
    \\const Bindings = struct {};
    \\const Service = ziac.gcp.global.ZigService(App, Bindings, Providers);
    \\
    \\pub fn build(allocator: std.mem.Allocator, init: std.process.Init, args: ziac.stack_registry.StackArgs) !ziac.stack_registry.StackProgram {
    \\    if (!std.mem.eql(u8, args.stack, "global-api")) return error.UnknownStack;
    \\    var source_root = try std.Io.Dir.cwd().openDir(init.io, ".", .{ .iterate = true });
    \\    defer source_root.close(init.io);
    \\    var component = try Service.build(allocator, .{
    \\        .project_id = init.environ_map.get("ZIAC_GCP_PROJECT") orelse "ziac-dev",
    \\        .primary_region = regions[0],
    \\        .service_regions = &regions,
    \\        .network_tier = .premium,
    \\    }, .{
    \\        .source = .{ .io = init.io, .root = source_root },
    \\        .name = "api",
    \\        .artifact_name = "app",
    \\        .regions = &regions,
    \\        .domain = init.environ_map.get("ZIAC_DOMAIN") orelse "api.example.invalid",
    \\        .dns_zone = init.environ_map.get("ZIAC_DNS_ZONE"),
    \\        .bindings = .{},
    \\    });
    \\    defer component.deinit();
    \\    var outputs = std.ArrayList(ziac.stack_registry.OutputDefinition).empty;
    \\    errdefer outputs.deinit(allocator);
    \\    try outputs.append(allocator, .{ .name = try allocator.dupe(u8, "url"), .source = .{ .literal = try allocator.dupe(u8, component.url.value) } });
    \\    try outputs.append(allocator, .{ .name = try allocator.dupe(u8, "image_digest"), .source = .{ .resource_ref = .{ .resource_id = try allocator.dupe(u8, component.image_digest.resource_ref.resource_id), .field = try allocator.dupe(u8, component.image_digest.resource_ref.field) } } });
    \\    return .{ .allocator = allocator, .graph = component.takeGraph(), .outputs = outputs };
    \\}
;

const app_zig =
    \\const std = @import("std");
    \\
    \\pub const Env = struct {};
    \\const ok = "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 15\r\nconnection: close\r\n\r\n{\"status\":\"ok\"}";
    \\const not_found = "HTTP/1.1 404 Not Found\r\ncontent-type: application/json\r\ncontent-length: 21\r\nconnection: close\r\n\r\n{\"error\":\"not found\"}";
    \\
    \\pub fn main() !void {
    \\    const io = std.Io.Threaded.global_single_threaded.io();
    \\    var address = try std.Io.net.IpAddress.parseIp4("0.0.0.0", 8080);
    \\    var server = try address.listen(io, .{ .reuse_address = true });
    \\    defer server.deinit(io);
    \\    while (true) {
    \\        const stream = server.accept(io) catch continue;
    \\        defer stream.close(io);
    \\        var read_buffer: [4096]u8 = undefined;
    \\        var reader = stream.reader(io, &read_buffer);
    \\        var request: [4096]u8 = undefined;
    \\        const length = reader.interface.readSliceShort(&request) catch continue;
    \\        var write_buffer: [4096]u8 = undefined;
    \\        var writer = stream.writer(io, &write_buffer);
    \\        writer.interface.writeAll(responseFor(request[0..length])) catch continue;
    \\        writer.interface.flush() catch continue;
    \\    }
    \\}
    \\
    \\fn responseFor(request: []const u8) []const u8 {
    \\    return if (std.mem.startsWith(u8, request, "GET /health/startup ") or std.mem.startsWith(u8, request, "GET /health/live ") or std.mem.startsWith(u8, request, "GET / ")) ok else not_found;
    \\}
    \\
    \\test "health response content length is exact" {
    \\    const split = std.mem.indexOf(u8, ok, "\r\n\r\n").?;
    \\    try std.testing.expectEqual(@as(usize, 15), ok[split + 4 ..].len);
    \\}
;

const gitignore =
    \\.zig-cache/
    \\zig-out/
    \\.ziac/
    \\.env
;

const ziacignore =
    \\.agents/
    \\.claude/
    \\.gemini/
    \\.git/
    \\.ziac/
    \\docs/
;

const agent_skill =
    \\---
    \\name: ziac
    \\description: Build, validate, visualize, test, and deploy this Ziac and ZigEffect infrastructure project. Use for Zig application Env bindings, GCP or Cockroach resources, plans, local development, dashboard investigation, provider diagnostics, and capability-gated infrastructure changes.
    \\---
    \\
    \\# Ziac Development
    \\
    \\Treat `ziac.project.json` as executable project intent. Before changing infrastructure, read its requirements, acceptance checks, environments, adaptations, scenarios, and authority policy together with `ziac.stack.zig` and the application's `Env` declaration.
    \\
    \\## Development loop
    \\
    \\1. Run `ziac check --stack global-api --stage dev --json`.
    \\2. Run `zig build test --summary failures` and inspect the Testing v2 receipt under `.zigeffect/tests/suites/`.
    \\3. Make the smallest typed change through public Ziac APIs. Keep application requirements, resource bindings, provider availability, scope, and outputs comptime-valid.
    \\4. Run `ziac plan --stack global-api --stage dev --json`. Diagnose structured plan and causal evidence instead of parsing terminal scrollback.
    \\5. Open `ziac dashboard --stack global-api --stage dev` when topology, ownership, locality, permissions, costs, or provider progress matter.
    \\6. Apply only an integrity-checked saved plan under an explicit capability envelope. Never expand apply, delete, secret, live-network, project, stage, region, or cost authority implicitly.
    \\
    \\## Infrastructure rules
    \\
    \\- Keep `observed`, `referenced`, and Ziac-managed resources distinct. Observed estate resources are read-only until a zero-change adoption plan is proved.
    \\- Bind secrets by provider reference. Never request, print, persist, or place secret values in source, plans, state, logs, receipts, MCP arguments, or dashboard artifacts.
    \\- Prefer the GCP and Cockroach high-level components already exported by Ziac. Preserve provider resource names, output wiring, lifecycle protection, and regional locality.
    \\- Use immutable images, readiness before traffic, and causal rollback evidence for Cloud Run changes.
    \\- Keep agent proposals non-mutating. Verification may run only manifest-declared fixed argv checks with process authority.
    \\
    \\## Agent interface
    \\
    \\Use the project-local Ziac MCP server for simulation, proposals, and declared verification. Query the graph and receipts before inferring state. If required evidence is missing, incomplete, stale, truncated, or credential-gated, report that limitation rather than claiming success.
;

const gemini_md =
    \\# Ziac Agent Context
    \\
    \\This project uses the same Ziac project contract and safety boundaries across Gemini, Codex, and Claude Code.
    \\Activate the workspace skill at `.gemini/skills/ziac/SKILL.md` before infrastructure work.
;

const mcp_json =
    \\{"mcpServers":{"ziac":{"command":"ziac","args":["mcp","serve","--project","ziac.project.json","--stack","global-api","--stage","dev"]}}}
;

const codex_config =
    \\[mcp_servers.ziac]
    \\command = "ziac"
    \\args = ["mcp", "serve", "--project", "ziac.project.json", "--stack", "global-api", "--stage", "dev"]
;

const gemini_settings =
    \\{"mcpServers":{"ziac":{"command":"ziac","args":["mcp","serve","--project","ziac.project.json","--stack","global-api","--stage","dev"]}}}
;
