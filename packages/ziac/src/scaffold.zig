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
    MissingScaffoldFile,
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
    try appendStatic(allocator, &files, ".agents/skills/gcp-developer-research/SKILL.md", gcp_research_skill);
    try appendStatic(allocator, &files, ".claude/skills/gcp-developer-research/SKILL.md", gcp_research_skill);
    try appendStatic(allocator, &files, ".gemini/skills/gcp-developer-research/SKILL.md", gcp_research_skill);
    try appendStatic(allocator, &files, ".codex/agents/gcp-developer-researcher.toml", codex_gcp_researcher);
    try appendStatic(allocator, &files, ".claude/agents/gcp-developer-researcher.md", claude_gcp_researcher);
    try appendStatic(allocator, &files, ".gemini/agents/gcp-developer-researcher.md", gemini_gcp_researcher);
    try appendStatic(allocator, &files, ".env.example", env_example);
    try appendStatic(allocator, &files, "GEMINI.md", gemini_md);
    try appendStatic(allocator, &files, ".mcp.json", mcp_json);
    try appendStatic(allocator, &files, ".codex/config.toml", codex_config);
    try appendStatic(allocator, &files, ".gemini/settings.json", gemini_settings);
    return .{ .allocator = allocator, .files = try files.toOwnedSlice(allocator) };
}

pub const SelfHostProject = enum { bootstrap, data, control_plane, billing };

pub fn renderSelfHostAlloc(allocator: std.mem.Allocator, options: Options, project: SelfHostProject) Error!Rendered {
    var rendered = try renderAlloc(allocator, options);
    errdefer rendered.deinit();
    const stack_name: []const u8 = switch (project) {
        .bootstrap => "bootstrap",
        .data => "data",
        .control_plane => "control-plane",
        .billing => "billing",
    };
    const stack_source: []const u8 = switch (project) {
        .bootstrap => self_host_bootstrap_stack,
        .data => self_host_data_stack,
        .control_plane => self_host_control_plane_stack,
        .billing => self_host_billing_stack,
    };
    const project_contents = try std.fmt.allocPrint(allocator, self_host_project_json, .{ options.project_name, stack_name, stack_name });
    errdefer allocator.free(project_contents);
    try replaceFile(rendered.files, allocator, "ziac.project.json", project_contents);
    try replaceFile(rendered.files, allocator, "ziac.stack.zig", try allocator.dupe(u8, stack_source));
    return rendered;
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

pub fn writeWorkspaceAgentFiles(dir: std.Io.Dir, io: std.Io, rendered: Rendered) !void {
    const paths = [_][]const u8{
        ".agents/skills/ziac/SKILL.md",
        ".claude/skills/ziac/SKILL.md",
        ".gemini/skills/ziac/SKILL.md",
        ".agents/skills/gcp-developer-research/SKILL.md",
        ".claude/skills/gcp-developer-research/SKILL.md",
        ".gemini/skills/gcp-developer-research/SKILL.md",
        ".codex/agents/gcp-developer-researcher.toml",
        ".claude/agents/gcp-developer-researcher.md",
        ".gemini/agents/gcp-developer-researcher.md",
        "GEMINI.md",
    };
    for (paths) |path| {
        const contents = rendered.file(path) orelse return error.MissingAgentScaffold;
        if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(io, parent);
        try dir.writeFile(io, .{ .sub_path = path, .data = contents });
    }
    const root_files = [_]File{
        .{ .path = ".env.example", .contents = env_example },
        .{ .path = ".mcp.json", .contents = workspace_mcp_json },
        .{ .path = ".codex/config.toml", .contents = workspace_codex_config },
        .{ .path = ".gemini/settings.json", .contents = workspace_gemini_settings },
    };
    for (root_files) |entry| try writeIfMissing(dir, io, entry);
}

fn writeIfMissing(dir: std.Io.Dir, io: std.Io, entry: File) !void {
    var existing = dir.openFile(io, entry.path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            if (std.fs.path.dirname(entry.path)) |parent| try dir.createDirPath(io, parent);
            try dir.writeFile(io, .{ .sub_path = entry.path, .data = entry.contents });
            return;
        },
        else => return err,
    };
    existing.close(io);
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

fn replaceFile(files: []File, allocator: std.mem.Allocator, path: []const u8, contents: []const u8) !void {
    for (files) |*entry| {
        if (!std.mem.eql(u8, entry.path, path)) continue;
        allocator.free(entry.contents);
        entry.contents = contents;
        return;
    }
    allocator.free(contents);
    return error.MissingScaffoldFile;
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
    \\  "dashboard": {{ "stack": "global-api", "stage": "dev" }},
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

const self_host_project_json =
    \\{{
    \\  "schema": "ziac.project.v1",
    \\  "project": "{s}",
    \\  "source_roots": ["ziac.stack.zig"],
    \\  "program": {{ "argv": ["zig", "build", "ziac-program", "--"], "max_output_bytes": 8388608 }},
    \\  "dashboard": {{ "stack": "{s}", "stage": "prod" }},
    \\  "components": [{{ "id": "platform", "resources": [] }}],
    \\  "requirements": [{{ "id": "self-host-valid", "summary": "The Ziac Cloud self-host graph compiles", "component": "platform", "required": true }}],
    \\  "acceptance_checks": [{{ "id": "check-self-host", "requirement": "self-host-valid", "argv": ["zig", "build", "ziac-program", "--", "--stack", "{s}", "--stage", "prod"] }}],
    \\  "environments": [{{ "id": "production", "stage_patterns": ["prod"], "providers": ["gcp"], "projects": ["ziac-cloud-*"], "regions": ["europe-west1", "us-central1"], "max_monthly_cost_minor": 100000 }}],
    \\  "adaptations": [],
    \\  "scenarios": [{{ "id": "self-host-compiles", "requirement": "self-host-valid", "acceptance_check": "check-self-host", "seed": 42, "required": true }}],
    \\  "authority": {{ "read": true, "plan": true, "apply": false, "delete": false, "secret_read": false, "live_network": false, "process": true }}
    \\}}
;

const self_host_bootstrap_stack =
    \\const std = @import("std");
    \\const ziac = @import("ziac");
    \\const regions = [_][]const u8{ "europe-west1", "us-central1" };
    \\pub fn build(allocator: std.mem.Allocator, init: std.process.Init, args: ziac.stack_registry.StackArgs) !ziac.stack_registry.StackProgram {
    \\    if (!std.mem.eql(u8, args.stack, "bootstrap")) return error.UnknownStack;
    \\    const project = init.environ_map.get("ZIAC_GCP_PROJECT") orelse "ziac-cloud-dev";
    \\    const bucket = init.environ_map.get("ZIAC_BOOTSTRAP_STATE_BUCKET") orelse init.environ_map.get("ZIAC_STATE_BUCKET") orelse "ziac-cloud-dev-state";
    \\    return ziac.self_host.buildBootstrap(allocator, .{ .project_id = project, .primary_region = regions[0], .regions = &regions, .state_bucket = bucket });
    \\}
;

const self_host_control_plane_stack =
    \\const std = @import("std");
    \\const ziac = @import("ziac");
    \\const regions = [_][]const u8{ "europe-west1", "us-central1" };
    \\pub fn build(allocator: std.mem.Allocator, init: std.process.Init, args: ziac.stack_registry.StackArgs) !ziac.stack_registry.StackProgram {
    \\    if (!std.mem.eql(u8, args.stack, "control-plane")) return error.UnknownStack;
    \\    const project = init.environ_map.get("ZIAC_GCP_PROJECT") orelse "ziac-cloud-dev";
    \\    return ziac.self_host.buildControlPlane(allocator, .{
    \\        .project_id = project, .primary_region = regions[0], .regions = &regions,
    \\        .domain = init.environ_map.get("ZIAC_CONTROL_PLANE_DOMAIN") orelse "api.example.invalid",
    \\        .dns_zone = init.environ_map.get("ZIAC_DNS_ZONE") orelse "example-invalid",
    \\        .image = init.environ_map.get("ZIAC_CONTROL_PLANE_IMAGE") orelse "europe-west1-docker.pkg.dev/ziac-cloud-dev/ziac/control-plane@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    \\        .database_secret = init.environ_map.get("ZIAC_DATABASE_SECRET") orelse "projects/ziac-cloud-dev/secrets/database-url/versions/latest",
    \\        .oauth_client_id_secret = init.environ_map.get("ZIAC_OAUTH_CLIENT_ID_SECRET") orelse "projects/ziac-cloud-dev/secrets/google-oauth-client-id/versions/latest",
    \\        .oauth_client_secret = init.environ_map.get("ZIAC_OAUTH_CLIENT_SECRET") orelse "projects/ziac-cloud-dev/secrets/google-oauth-client-secret/versions/latest",
    \\        .kms_key = init.environ_map.get("ZIAC_ESTATE_KMS_KEY") orelse "projects/ziac-cloud-dev/locations/europe-west1/keyRings/ziac-cloud/cryptoKeys/connection-vault",
    \\    });
    \\}
;

const self_host_data_stack =
    \\const std = @import("std");
    \\const ziac = @import("ziac");
    \\const regions = [_][]const u8{ "europe-west1", "us-central1" };
    \\pub fn build(allocator: std.mem.Allocator, init: std.process.Init, args: ziac.stack_registry.StackArgs) !ziac.stack_registry.StackProgram {
    \\    if (!std.mem.eql(u8, args.stack, "data")) return error.UnknownStack;
    \\    return ziac.self_host.buildData(allocator, .{
    \\        .project_id = init.environ_map.get("ZIAC_GCP_PROJECT") orelse "ziac-cloud-dev",
    \\        .primary_region = regions[0], .regions = &regions,
    \\        .cluster_id = init.environ_map.get("ZIAC_COCKROACH_CLUSTER_ID") orelse "8e9f4f46-example-cluster-id",
    \\        .admin_secret_version = init.environ_map.get("ZIAC_COCKROACH_ADMIN_SECRET_VERSION") orelse "1",
    \\    });
    \\}
;

const self_host_billing_stack =
    \\const std = @import("std");
    \\const ziac = @import("ziac");
    \\pub fn build(allocator: std.mem.Allocator, init: std.process.Init, args: ziac.stack_registry.StackArgs) !ziac.stack_registry.StackProgram {
    \\    if (!std.mem.eql(u8, args.stack, "billing")) return error.UnknownStack;
    \\    const project = init.environ_map.get("ZIAC_GCP_PROJECT") orelse "ziac-cloud-dev";
    \\    return ziac.self_host.buildBilling(allocator, .{
    \\        .project_id = project, .region = "europe-west1",
    \\        .image = init.environ_map.get("ZIAC_BILLING_IMAGE") orelse "europe-west1-docker.pkg.dev/ziac-cloud-dev/ziac/billing@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    \\        .billing_project = init.environ_map.get("ZIAC_BILLING_PROJECT") orelse project,
    \\        .export_table = init.environ_map.get("ZIAC_BILLING_EXPORT_TABLE") orelse "billing_export.gcp_billing_export_resource_v1_example",
    \\        .control_plane_url = init.environ_map.get("ZIAC_CONTROL_PLANE_URL") orelse "https://api.example.invalid",
    \\        .database_secret = init.environ_map.get("ZIAC_DATABASE_SECRET") orelse "projects/ziac-cloud-dev/secrets/database-url/versions/latest",
    \\    });
    \\}
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
    \\const ok = "{\"status\":\"ok\"}";
    \\const not_found = "{\"error\":\"not found\"}";
    \\
    \\pub fn main() !void {
    \\    const io = std.Io.Threaded.global_single_threaded.io();
    \\    var address = try std.Io.net.IpAddress.parseIp4("0.0.0.0", 8080);
    \\    var server = try address.listen(io, .{ .reuse_address = true });
    \\    defer server.deinit(io);
    \\    while (true) {
    \\        const stream = server.accept(io) catch continue;
    \\        handle(io, stream) catch {};
    \\    }
    \\}
    \\
    \\fn handle(io: std.Io, stream: std.Io.net.Stream) !void {
    \\    defer stream.close(io);
    \\    var read_buffer: [4096]u8 = undefined;
    \\    var reader = stream.reader(io, &read_buffer);
    \\    var write_buffer: [4096]u8 = undefined;
    \\    var writer = stream.writer(io, &write_buffer);
    \\    var server = std.http.Server.init(&reader.interface, &writer.interface);
    \\    var request = try server.receiveHead();
    \\    const found = routeFound(request.head.target);
    \\    try request.respond(if (found) ok else not_found, .{ .status = if (found) .ok else .not_found, .keep_alive = false, .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }} });
    \\}
    \\
    \\fn routeFound(target: []const u8) bool {
    \\    return std.mem.eql(u8, target, "/health/startup") or std.mem.eql(u8, target, "/health/live") or std.mem.eql(u8, target, "/");
    \\}
    \\
    \\test "health routing is exact" {
    \\    try std.testing.expect(routeFound("/health/live"));
    \\    try std.testing.expect(!routeFound("/missing"));
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
    \\description: Build, validate, visualize, test, and deploy Ziac and ZigEffect infrastructure across a standalone project or monorepo workspace. Use for Zig application Env bindings, GCP or Cockroach resources, plans, local development, dashboard investigation, provider diagnostics, project decomposition, and capability-gated infrastructure changes.
    \\---
    \\
    \\# Ziac Development
    \\
    \\Treat every `ziac.project.json` as an independently deployable unit of executable intent. A repository may contain one project or many nested projects. Before changing infrastructure, discover all project manifests from the Git root, select the smallest project that owns the capability, and read its requirements, acceptance checks, environments, adaptations, scenarios, authority policy, `ziac.stack.zig`, and application `Env` declaration.
    \\
    \\## Bundled knowledge
    \\
    \\Resolve `.dependencies.ziac.path` from the owning project's `build.zig.zon`. That relocatable directory is the installed Ziac knowledge root; it must not be replaced with a source-checkout or machine-specific path. Read its `README.md`, `docs/agent-development-kit.md`, and `docs/gcp-provider-coverage.md` first, then load only the provider or workflow document relevant to the task. Run `ziac provider resources --json` for the exact managed and planned surface shipped by the installed CLI. Use local docs for the behavior and pinned contracts shipped with this CLI. Delegate current Google Cloud facts to `gcp-developer-researcher` before relying on them.
    \\
    \\## Development loop
    \\
    \\1. From the workspace root, identify the owning project. Run project commands from that project root or select it explicitly with `--project` where supported.
    \\2. Run `ziac check --stack global-api --stage dev --json` in the owning project.
    \\3. Run `zig build test --summary failures` and inspect the Testing v2 receipt under `.zigeffect/tests/suites/`.
    \\4. Make the smallest typed change through public Ziac APIs. Keep application requirements, resource bindings, provider availability, scope, and outputs comptime-valid.
    \\5. Run `ziac plan --stack global-api --stage dev --json`. Diagnose structured plan and causal evidence instead of parsing terminal scrollback.
    \\6. Open `ziac dashboard` from the repository root to inspect the merged canvas. Filter to the changed project, its dependencies, or its consumers while retaining workspace context.
    \\7. Apply only an integrity-checked saved plan under an explicit capability envelope. Never expand apply, delete, secret, live-network, project, stage, region, or cost authority implicitly.
    \\
    \\## Infrastructure rules
    \\
    \\- Keep `observed`, `referenced`, and Ziac-managed resources distinct. Observed estate resources are read-only until a zero-change adoption plan is proved.
    \\- Bind secrets by provider reference. Never request, print, persist, or place secret values in source, plans, state, logs, receipts, MCP arguments, or dashboard artifacts.
    \\- Prefer the GCP and Cockroach high-level components already exported by Ziac. Preserve provider resource names, output wiring, lifecycle protection, and regional locality.
    \\- Use immutable images, readiness before traffic, and causal rollback evidence for Cloud Run changes.
    \\- Keep agent proposals non-mutating. Verification may run only manifest-declared fixed argv checks with process authority.
    \\- Preserve project independence. Do not make an implicit cross-project dependency, edit a neighbouring project, or combine state merely because projects share a repository.
    \\- Use explicit typed outputs and inputs for cross-project wiring. Validate the changed project and then the merged workspace graph. Treat duplicate ownership of one managed cloud resource as a conflict.
    \\- Assume a project may later split. Keep feature boundaries, state ownership, provider authority, and CI targets clear enough to move without rewriting unrelated infrastructure.
    \\- Delegate current or uncertain GCP API, IAM, quota, pricing, region, availability, and product-lifecycle claims to the `gcp-developer-researcher` before changing provider behavior. Require official sources and distinguish documented facts from inference.
    \\
    \\## Agent interface
    \\
    \\Use the project-local Ziac MCP server for simulation, proposals, and declared verification. Query the graph and receipts before inferring state. If required evidence is missing, incomplete, stale, truncated, or credential-gated, report that limitation rather than claiming success.
;

const gcp_research_skill =
    \\---
    \\name: gcp-developer-research
    \\description: Research current Google Cloud platform behavior from official Google Developer Knowledge sources. Use for GCP APIs, protobuf and REST contracts, IAM permissions, quotas, regions, pricing inputs, release status, Cloud Run, networking, billing, and architecture constraints before implementing or reviewing Ziac provider behavior.
    \\---
    \\
    \\# GCP Developer Research
    \\
    \\Act as a read-only research specialist. Never mutate a Google Cloud project, call a deployment tool, request or reveal credentials, or treat an inference as an API guarantee.
    \\
    \\For a Ziac provider question, resolve `.dependencies.ziac.path` from the owning project's `build.zig.zon` and read the relevant shipped baseline under that package's `docs/`, especially `docs/gcp-specialization.md`, `docs/google-rpc.md`, and the product-specific document. These files describe what the installed Ziac version implements; they are not authority for current GCP behavior.
    \\
    \\## Research protocol
    \\
    \\1. Restate the product, API and version, region, date sensitivity, and implementation constraint in the question.
    \\2. Call `search_documents` with one focused query. Prefer results from `developers.google.com` and `docs.cloud.google.com`.
    \\3. Rank an exact API or reference page first, then a product guide, release note, and finally a concept page. Discard unrelated or duplicate results.
    \\4. Call `get_documents` only for the best few parent documents needed to answer accurately.
    \\5. Reconcile contradictory guidance using update dates, API version, release notes, and product lifecycle status. The Developer Knowledge service is Public Preview, so fall back to official Google documentation when it is unavailable.
    \\6. Do not invent fields, permissions, quotas, regions, availability, pricing, or guarantees. Say when the official material is incomplete.
    \\
    \\## Response contract
    \\
    \\Return these compact sections:
    \\
    \\- `Finding`: the official behavior that answers the question.
    \\- `Recommended Ziac implication`: the provider, compiler, runtime, or documentation consequence.
    \\- `Constraints`: preview status, regions, permissions, quotas, transport, or other limits.
    \\- `Sources`: direct official URLs, ordered by authority.
    \\- `Confidence`: high, medium, or low, with any inference labelled explicitly.
;

const gemini_md =
    \\# Ziac Agent Context
    \\
    \\This project uses the same Ziac project contract and safety boundaries across Gemini, Codex, and Claude Code.
    \\Activate the workspace skill at `.gemini/skills/ziac/SKILL.md` before infrastructure work. Delegate current or uncertain Google Cloud questions to the `gcp-developer-researcher` agent, which follows `.gemini/skills/gcp-developer-research/SKILL.md`.
;

const codex_gcp_researcher =
    \\sandbox_mode = "read-only"
    \\developer_instructions = """
    \\You are Ziac's GCP Developer Researcher. Follow the gcp-developer-research skill exactly. Use only official Google Developer Knowledge results, rank sources by authority and recency, return direct source URLs, and clearly label inference. Do not edit files, mutate infrastructure, request secrets, or claim unsupported GCP behavior.
    \\"""
;

const claude_gcp_researcher =
    \\---
    \\name: gcp-developer-researcher
    \\description: Research current Google Cloud APIs, IAM, quotas, regions, pricing inputs, and product constraints from official sources before Ziac implementation. Delegate uncertain or time-sensitive GCP claims here.
    \\permissionMode: plan
    \\disallowedTools: Write, Edit
    \\skills:
    \\  - gcp-developer-research
    \\mcpServers:
    \\  - google-developer-knowledge
    \\---
    \\
    \\Follow the gcp-developer-research skill. Return official findings and implementation implications; do not change code or cloud resources.
;

const gemini_gcp_researcher =
    \\---
    \\name: gcp-developer-researcher
    \\description: Read-only specialist for current official Google Cloud developer documentation and Ziac implementation implications.
    \\kind: local
    \\max_turns: 8
    \\tools:
    \\  - search_documents
    \\  - get_documents
    \\mcpServers:
    \\  - google-developer-knowledge
    \\---
    \\
    \\Follow `.gemini/skills/gcp-developer-research/SKILL.md`. Research only; never edit files or mutate infrastructure.
;

const env_example =
    \\DEVELOPERKNOWLEDGE_API_KEY=
;

const mcp_json =
    \\{"mcpServers":{"ziac":{"command":"ziac","args":["mcp","serve","--project","ziac.project.json","--stack","global-api","--stage","dev"]},"google-developer-knowledge":{"type":"http","url":"https://developerknowledge.googleapis.com/mcp","headers":{"X-Goog-Api-Key":"${DEVELOPERKNOWLEDGE_API_KEY:-}"}}}}
;

const codex_config =
    \\[mcp_servers.ziac]
    \\command = "ziac"
    \\args = ["mcp", "serve", "--project", "ziac.project.json", "--stack", "global-api", "--stage", "dev"]
    \\
    \\[mcp_servers.google_developer_knowledge]
    \\url = "https://developerknowledge.googleapis.com/mcp"
    \\env_http_headers = { "X-Goog-Api-Key" = "DEVELOPERKNOWLEDGE_API_KEY" }
    \\enabled_tools = ["search_documents", "get_documents"]
    \\
    \\[agents.gcp_developer_researcher]
    \\description = "Research current official GCP documentation and return ranked Ziac implementation implications."
    \\config_file = "agents/gcp-developer-researcher.toml"
;

const gemini_settings =
    \\{"mcpServers":{"ziac":{"command":"ziac","args":["mcp","serve","--project","ziac.project.json","--stack","global-api","--stage","dev"]},"google-developer-knowledge":{"httpUrl":"https://developerknowledge.googleapis.com/mcp","headers":{"X-Goog-Api-Key":"${DEVELOPERKNOWLEDGE_API_KEY}"},"includeTools":["search_documents","get_documents"],"timeout":30000}}}
;

const workspace_mcp_json =
    \\{"mcpServers":{"google-developer-knowledge":{"type":"http","url":"https://developerknowledge.googleapis.com/mcp","headers":{"X-Goog-Api-Key":"${DEVELOPERKNOWLEDGE_API_KEY:-}"}}}}
;

const workspace_codex_config =
    \\[mcp_servers.google_developer_knowledge]
    \\url = "https://developerknowledge.googleapis.com/mcp"
    \\env_http_headers = { "X-Goog-Api-Key" = "DEVELOPERKNOWLEDGE_API_KEY" }
    \\enabled_tools = ["search_documents", "get_documents"]
    \\
    \\[agents.gcp_developer_researcher]
    \\description = "Research current official GCP documentation and return ranked Ziac implementation implications."
    \\config_file = "agents/gcp-developer-researcher.toml"
;

const workspace_gemini_settings =
    \\{"mcpServers":{"google-developer-knowledge":{"httpUrl":"https://developerknowledge.googleapis.com/mcp","headers":{"X-Goog-Api-Key":"${DEVELOPERKNOWLEDGE_API_KEY}"},"includeTools":["search_documents","get_documents"],"timeout":30000}}}
;
