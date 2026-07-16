const std = @import("std");
const provenance = @import("provenance.zig");

pub const package_schema = "ziac.package.v1";
pub const registry_schema = "ziac.registry.v1";
pub const max_manifest_bytes: usize = 256 * 1024;
pub const max_registry_entries: usize = 1024;
pub const max_template_files: usize = 256;
pub const max_template_file_bytes: usize = 4 * 1024 * 1024;

pub const Kind = enum { provider, component, template };
pub const Maturity = enum { experimental, preview, stable };
pub const Qualification = enum { community, verified, official, cloud_qualified };

pub const Compatibility = struct {
    ziac: []const u8,
    zig: []const u8,
};

pub const ProviderRpc = struct {
    protocol: []const u8,
    provider: []const u8,
    executable: []const u8,
    max_inflight: u16,
};

pub const ManifestError = std.mem.Allocator.Error || error{
    InvalidPackageJson,
    UnsupportedPackageSchema,
    InvalidPackageName,
    InvalidPackageVersion,
    InvalidPackageKind,
    InvalidPackageSummary,
    InvalidPackageLicense,
    InvalidPackageSource,
    InvalidPackageEntry,
    InvalidPackageCompatibility,
    InvalidPackageProvider,
    InvalidPackageResourceType,
    InvalidPackageMaturity,
    MissingProviderRpc,
    UnexpectedProviderRpc,
    InvalidProviderRpc,
    DuplicatePackageValue,
    ExecutablePackageHook,
    SecretMaterialDetected,
    UnknownPackageField,
};

pub const Manifest = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    name: []const u8,
    version: []const u8,
    kind: Kind,
    summary: []const u8,
    license: []const u8,
    source: []const u8,
    entry: []const u8,
    compatibility: Compatibility,
    providers: []const []const u8,
    resource_types: []const []const u8,
    maturity: Maturity,
    provider_rpc: ?ProviderRpc,
    manifest_digest: [32]u8,

    pub fn parseAlloc(allocator: std.mem.Allocator, bytes: []const u8) ManifestError!Manifest {
        if (bytes.len == 0 or bytes.len > max_manifest_bytes) return error.InvalidPackageJson;
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch return error.InvalidPackageJson;
        defer parsed.deinit();
        const root = jsonObject(parsed.value) orelse return error.InvalidPackageJson;
        try validateManifestFields(root);
        if (!std.mem.eql(u8, try requiredString(root, "schema"), package_schema)) return error.UnsupportedPackageSchema;

        const compatibility_value = root.get("compatibility") orelse return error.InvalidPackageJson;
        const compatibility_object = jsonObject(compatibility_value) orelse return error.InvalidPackageJson;
        if (compatibility_object.count() != 2 or compatibility_object.get("ziac") == null or compatibility_object.get("zig") == null) return error.InvalidPackageCompatibility;

        const providers = try parseStringArray(a, root.get("providers") orelse return error.InvalidPackageJson, 8);
        const resource_types = try parseStringArray(a, root.get("resource_types") orelse return error.InvalidPackageJson, 512);
        sortStrings(providers);
        sortStrings(resource_types);
        try rejectDuplicates(providers);
        try rejectDuplicates(resource_types);
        const kind = parseEnum(Kind, try requiredString(root, "kind")) orelse return error.InvalidPackageKind;
        const provider_rpc = if (root.get("provider_rpc")) |rpc_value| try parseProviderRpc(a, rpc_value) else null;

        var result = Manifest{
            .allocator = allocator,
            .arena = arena,
            .name = try a.dupe(u8, try requiredString(root, "name")),
            .version = try a.dupe(u8, try requiredString(root, "version")),
            .kind = kind,
            .summary = try a.dupe(u8, try requiredString(root, "summary")),
            .license = try a.dupe(u8, try requiredString(root, "license")),
            .source = try a.dupe(u8, try requiredString(root, "source")),
            .entry = try a.dupe(u8, try requiredString(root, "entry")),
            .compatibility = .{
                .ziac = try a.dupe(u8, try requiredString(compatibility_object, "ziac")),
                .zig = try a.dupe(u8, try requiredString(compatibility_object, "zig")),
            },
            .providers = providers,
            .resource_types = resource_types,
            .maturity = parseEnum(Maturity, try requiredString(root, "maturity")) orelse return error.InvalidPackageMaturity,
            .provider_rpc = provider_rpc,
            .manifest_digest = [_]u8{0} ** 32,
        };
        try result.validate();
        const canonical = try result.canonicalJsonAlloc(a);
        std.crypto.hash.sha2.Sha256.hash(canonical, &result.manifest_digest, .{});
        return result;
    }

    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.* = undefined;
    }

    pub fn digest(self: Manifest) [32]u8 {
        return self.manifest_digest;
    }

    pub fn canonicalJsonAlloc(self: Manifest, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        var output = std.ArrayList(u8).empty;
        errdefer output.deinit(allocator);
        try output.appendSlice(allocator, "{\"schema\":");
        try appendJsonString(&output, allocator, package_schema);
        try appendNamedString(&output, allocator, "name", self.name);
        try appendNamedString(&output, allocator, "version", self.version);
        try appendNamedString(&output, allocator, "kind", @tagName(self.kind));
        try appendNamedString(&output, allocator, "summary", self.summary);
        try appendNamedString(&output, allocator, "license", self.license);
        try appendNamedString(&output, allocator, "source", self.source);
        try appendNamedString(&output, allocator, "entry", self.entry);
        try output.appendSlice(allocator, ",\"compatibility\":{\"ziac\":");
        try appendJsonString(&output, allocator, self.compatibility.ziac);
        try output.appendSlice(allocator, ",\"zig\":");
        try appendJsonString(&output, allocator, self.compatibility.zig);
        try output.append(allocator, '}');
        try appendNamedStringArray(&output, allocator, "providers", self.providers);
        try appendNamedStringArray(&output, allocator, "resource_types", self.resource_types);
        try appendNamedString(&output, allocator, "maturity", @tagName(self.maturity));
        if (self.provider_rpc) |rpc| {
            try output.appendSlice(allocator, ",\"provider_rpc\":{\"protocol\":");
            try appendJsonString(&output, allocator, rpc.protocol);
            try appendNamedString(&output, allocator, "provider", rpc.provider);
            try appendNamedString(&output, allocator, "executable", rpc.executable);
            try output.print(allocator, ",\"max_inflight\":{d}", .{rpc.max_inflight});
            try output.append(allocator, '}');
        }
        try output.append(allocator, '}');
        return output.toOwnedSlice(allocator);
    }

    fn validate(self: Manifest) ManifestError!void {
        if (!provenance.validPackageName(self.name) or std.mem.indexOfScalar(u8, self.name, '/') == null) return error.InvalidPackageName;
        if (!provenance.validVersion(self.version)) return error.InvalidPackageVersion;
        if (!validText(self.summary, 240)) return error.InvalidPackageSummary;
        if (!provenance.validToken(self.license, 64)) return error.InvalidPackageLicense;
        if (!std.mem.startsWith(u8, self.source, "https://") or !validText(self.source, 2048)) return error.InvalidPackageSource;
        if (!validRelativePath(self.entry)) return error.InvalidPackageEntry;
        switch (self.kind) {
            .provider => {
                if (!provenance.validToken(self.entry, 128)) return error.InvalidPackageEntry;
                const rpc = self.provider_rpc orelse return error.MissingProviderRpc;
                if (!std.mem.eql(u8, rpc.protocol, "ziac.provider.rpc.v1") or
                    !provenance.validToken(rpc.provider, 64) or
                    !provenance.validToken(rpc.executable, 128) or
                    !std.mem.eql(u8, self.entry, rpc.executable) or rpc.max_inflight != 1)
                    return error.InvalidProviderRpc;
                if (self.providers.len != 1 or !std.mem.eql(u8, self.providers[0], rpc.provider)) return error.InvalidProviderRpc;
                for (self.resource_types) |resource_type| {
                    if (!std.mem.startsWith(u8, resource_type, rpc.provider) or resource_type.len <= rpc.provider.len or resource_type[rpc.provider.len] != '.') return error.InvalidProviderRpc;
                }
            },
            .component => if (!std.mem.endsWith(u8, self.entry, ".zig")) return error.InvalidPackageEntry,
            .template => if (!std.mem.eql(u8, self.entry, "files")) return error.InvalidPackageEntry,
        }
        if (self.kind != .provider and self.provider_rpc != null) return error.UnexpectedProviderRpc;
        if (!validCompatibility(self.compatibility.ziac) or !validCompatibility(self.compatibility.zig)) return error.InvalidPackageCompatibility;
        if (self.providers.len == 0 or self.resource_types.len == 0) return error.InvalidPackageJson;
        for (self.providers) |provider| if (!provenance.validToken(provider, 64)) return error.InvalidPackageProvider;
        for (self.resource_types) |resource_type| {
            if (self.kind == .provider) {
                if (!validProviderResourcePattern(resource_type)) return error.InvalidPackageResourceType;
            } else if (!validResourceType(resource_type)) return error.InvalidPackageResourceType;
        }
    }
};

pub const RegistryEntry = struct {
    name: []const u8,
    version: []const u8,
    kind: Kind,
    summary: []const u8,
    path: []const u8,
    manifest_sha256: []const u8,
    qualification: Qualification,
};

pub const SearchOptions = struct {
    query: []const u8 = "",
    kind: ?Kind = null,
    limit: usize = 50,
};

pub const RegistryError = ManifestError || error{
    InvalidRegistryJson,
    UnsupportedRegistrySchema,
    InvalidRegistryEntry,
    DuplicateRegistryEntry,
    InvalidSearch,
    PackageIdentityMismatch,
    PackageDigestMismatch,
};

pub const Registry = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    entries: []RegistryEntry,

    pub fn parseAlloc(allocator: std.mem.Allocator, bytes: []const u8) RegistryError!Registry {
        if (bytes.len == 0 or bytes.len > 4 * 1024 * 1024) return error.InvalidRegistryJson;
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{}) catch return error.InvalidRegistryJson;
        defer parsed.deinit();
        const root = jsonObject(parsed.value) orelse return error.InvalidRegistryJson;
        if (root.count() != 2) return error.InvalidRegistryJson;
        if (!std.mem.eql(u8, try requiredString(root, "schema"), registry_schema)) return error.UnsupportedRegistrySchema;
        const packages = jsonArray(root.get("packages") orelse return error.InvalidRegistryJson) orelse return error.InvalidRegistryJson;
        if (packages.len > max_registry_entries) return error.InvalidRegistryJson;
        const entries = try a.alloc(RegistryEntry, packages.len);
        for (packages, 0..) |value, index| entries[index] = try parseRegistryEntry(a, value);
        std.mem.sort(RegistryEntry, entries, {}, registryEntryLessThan);
        if (entries.len > 1) for (entries[1..], entries[0 .. entries.len - 1]) |current, previous| if (std.mem.eql(u8, current.name, previous.name) and std.mem.eql(u8, current.version, previous.version)) return error.DuplicateRegistryEntry;
        return .{ .allocator = allocator, .arena = arena, .entries = entries };
    }

    pub fn deinit(self: *Registry) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.* = undefined;
    }

    pub fn verifyManifest(self: Registry, entry: RegistryEntry, bytes: []const u8) RegistryError!void {
        _ = self;
        var manifest = try Manifest.parseAlloc(std.heap.page_allocator, bytes);
        defer manifest.deinit();
        if (!std.mem.eql(u8, manifest.name, entry.name) or !std.mem.eql(u8, manifest.version, entry.version) or manifest.kind != entry.kind) return error.PackageIdentityMismatch;
        const actual = std.fmt.bytesToHex(manifest.digest(), .lower);
        if (!std.mem.eql(u8, &actual, entry.manifest_sha256)) return error.PackageDigestMismatch;
    }

    pub fn searchAlloc(self: Registry, allocator: std.mem.Allocator, options: SearchOptions) RegistryError![]usize {
        if (options.query.len > 256 or options.limit == 0 or options.limit > 100) return error.InvalidSearch;
        var matches = std.ArrayList(usize).empty;
        errdefer matches.deinit(allocator);
        for (self.entries, 0..) |entry, index| {
            if (options.kind) |kind| if (entry.kind != kind) continue;
            if (options.query.len != 0 and !containsInsensitive(entry.name, options.query) and !containsInsensitive(entry.summary, options.query)) continue;
            try matches.append(allocator, index);
            if (matches.items.len == options.limit) break;
        }
        return matches.toOwnedSlice(allocator);
    }
};

pub const TemplateContext = struct {
    project_name: []const u8,
    zig_package_name: []const u8,
    package_fingerprint: []const u8,
    ziac_path_json: []const u8,
    ziac_gcpx_path_json: []const u8,
    zigeffect_path_json: []const u8,
    zigeffect_std_path_json: []const u8,
};

pub const TemplateError = std.mem.Allocator.Error || error{
    MissingTemplateFiles,
    TooManyTemplateFiles,
    TemplateFileTooLarge,
    InvalidTemplatePath,
    UnsupportedTemplateFile,
    TemplateFileExists,
    UnknownTemplateToken,
};

pub fn renderTemplate(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: std.Io.Dir,
    target: std.Io.Dir,
    context: TemplateContext,
    force: bool,
) !void {
    if (!provenance.validPackageName(context.project_name) or !provenance.validToken(context.zig_package_name, 128) or
        !validHexToken(context.package_fingerprint) or !validJsonString(context.ziac_path_json) or
        !validJsonString(context.ziac_gcpx_path_json) or !validJsonString(context.zigeffect_path_json) or
        !validJsonString(context.zigeffect_std_path_json)) return error.InvalidTemplatePath;
    var files_dir = source.openDir(io, "files", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.MissingTemplateFiles,
        else => return err,
    };
    defer files_dir.close(io);
    var paths = std.ArrayList([]u8).empty;
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    var walker = try files_dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| switch (entry.kind) {
        .directory => {},
        .file => {
            if (paths.items.len >= max_template_files) return error.TooManyTemplateFiles;
            if (!validRelativePath(entry.path)) return error.InvalidTemplatePath;
            try paths.append(allocator, try allocator.dupe(u8, entry.path));
        },
        else => return error.UnsupportedTemplateFile,
    };
    std.mem.sort([]u8, paths.items, {}, stringLessThan);
    if (!force) for (paths.items) |path| {
        var existing = target.openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        existing.close(io);
        return error.TemplateFileExists;
    };
    for (paths.items) |path| {
        const bytes = files_dir.readFileAlloc(io, path, allocator, .limited(max_template_file_bytes + 1)) catch |err| switch (err) {
            error.StreamTooLong => return error.TemplateFileTooLarge,
            else => return err,
        };
        defer allocator.free(bytes);
        if (bytes.len > max_template_file_bytes or std.mem.indexOfScalar(u8, bytes, 0) != null) return error.TemplateFileTooLarge;
        const rendered = try renderTemplateTextAlloc(allocator, bytes, context);
        defer allocator.free(rendered);
        if (std.fs.path.dirname(path)) |parent| try target.createDirPath(io, parent);
        try target.writeFile(io, .{ .sub_path = path, .data = rendered });
    }
}

pub fn renderTemplateTextAlloc(allocator: std.mem.Allocator, input: []const u8, context: TemplateContext) TemplateError![]u8 {
    var current = try allocator.dupe(u8, input);
    errdefer allocator.free(current);
    inline for (.{
        .{ "{{project_name}}", context.project_name },
        .{ "{{zig_package_name}}", context.zig_package_name },
        .{ "{{package_fingerprint}}", context.package_fingerprint },
        .{ "{{ziac_path}}", context.ziac_path_json },
        .{ "{{ziac_gcpx_path}}", context.ziac_gcpx_path_json },
        .{ "{{zigeffect_path}}", context.zigeffect_path_json },
        .{ "{{zigeffect_std_path}}", context.zigeffect_std_path_json },
    }) |replacement| {
        const next = try std.mem.replaceOwned(u8, allocator, current, replacement[0], replacement[1]);
        allocator.free(current);
        current = next;
    }
    if (std.mem.indexOf(u8, current, "{{") != null) return error.UnknownTemplateToken;
    return current;
}

fn validateManifestFields(root: std.json.ObjectMap) ManifestError!void {
    const known = [_][]const u8{ "schema", "name", "version", "kind", "summary", "license", "source", "entry", "compatibility", "providers", "resource_types", "maturity", "provider_rpc" };
    var iterator = root.iterator();
    while (iterator.next()) |entry| {
        if (containsString(&known, entry.key_ptr.*)) continue;
        if (containsInsensitive(entry.key_ptr.*, "secret") or containsInsensitive(entry.key_ptr.*, "token") or containsInsensitive(entry.key_ptr.*, "password") or containsInsensitive(entry.key_ptr.*, "credential")) return error.SecretMaterialDetected;
        if (containsInsensitive(entry.key_ptr.*, "install") or containsInsensitive(entry.key_ptr.*, "hook") or containsInsensitive(entry.key_ptr.*, "command") or containsInsensitive(entry.key_ptr.*, "script")) return error.ExecutablePackageHook;
        return error.UnknownPackageField;
    }
}

fn parseProviderRpc(allocator: std.mem.Allocator, value: std.json.Value) ManifestError!ProviderRpc {
    const object = jsonObject(value) orelse return error.InvalidProviderRpc;
    const known = [_][]const u8{ "protocol", "provider", "executable", "max_inflight" };
    if (object.count() != known.len) return error.InvalidProviderRpc;
    for (known) |field| if (object.get(field) == null) return error.InvalidProviderRpc;
    const max_inflight = switch (object.get("max_inflight").?) {
        .integer => |number| if (number > 0 and number <= std.math.maxInt(u16)) @as(u16, @intCast(number)) else return error.InvalidProviderRpc,
        else => return error.InvalidProviderRpc,
    };
    return .{
        .protocol = try allocator.dupe(u8, try requiredString(object, "protocol")),
        .provider = try allocator.dupe(u8, try requiredString(object, "provider")),
        .executable = try allocator.dupe(u8, try requiredString(object, "executable")),
        .max_inflight = max_inflight,
    };
}

fn parseRegistryEntry(allocator: std.mem.Allocator, value: std.json.Value) RegistryError!RegistryEntry {
    const object = jsonObject(value) orelse return error.InvalidRegistryEntry;
    const known = [_][]const u8{ "name", "version", "kind", "summary", "path", "manifest_sha256", "qualification" };
    if (object.count() != known.len) return error.InvalidRegistryEntry;
    for (known) |field| if (object.get(field) == null) return error.InvalidRegistryEntry;
    const name = try requiredString(object, "name");
    const version = try requiredString(object, "version");
    const summary = try requiredString(object, "summary");
    const path = try requiredString(object, "path");
    const digest = try requiredString(object, "manifest_sha256");
    if (!provenance.validPackageName(name) or std.mem.indexOfScalar(u8, name, '/') == null or !provenance.validVersion(version) or !validText(summary, 240) or !validRelativePath(path) or !provenance.validDigest(digest)) return error.InvalidRegistryEntry;
    return .{
        .name = try allocator.dupe(u8, name),
        .version = try allocator.dupe(u8, version),
        .kind = parseEnum(Kind, try requiredString(object, "kind")) orelse return error.InvalidRegistryEntry,
        .summary = try allocator.dupe(u8, summary),
        .path = try allocator.dupe(u8, path),
        .manifest_sha256 = try allocator.dupe(u8, digest),
        .qualification = parseEnum(Qualification, try requiredString(object, "qualification")) orelse return error.InvalidRegistryEntry,
    };
}

fn parseStringArray(allocator: std.mem.Allocator, value: std.json.Value, max: usize) ManifestError![][]const u8 {
    const items = jsonArray(value) orelse return error.InvalidPackageJson;
    if (items.len == 0 or items.len > max) return error.InvalidPackageJson;
    const result = try allocator.alloc([]const u8, items.len);
    for (items, 0..) |item, index| result[index] = try allocator.dupe(u8, switch (item) {
        .string => |string| string,
        else => return error.InvalidPackageJson,
    });
    return result;
}

fn rejectDuplicates(values: []const []const u8) error{DuplicatePackageValue}!void {
    if (values.len > 1) for (values[1..], values[0 .. values.len - 1]) |current, previous| if (std.mem.eql(u8, current, previous)) return error.DuplicatePackageValue;
}

fn sortStrings(values: [][]const u8) void {
    std.mem.sort([]const u8, values, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);
}

fn registryEntryLessThan(_: void, left: RegistryEntry, right: RegistryEntry) bool {
    const name_order = std.mem.order(u8, left.name, right.name);
    if (name_order == .lt) return true;
    if (name_order == .gt) return false;
    return std.mem.order(u8, left.version, right.version) == .lt;
}

fn stringLessThan(_: void, left: []u8, right: []u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn parseEnum(comptime T: type, value: []const u8) ?T {
    inline for (@typeInfo(T).@"enum".fields) |field| if (std.mem.eql(u8, value, field.name)) return @enumFromInt(field.value);
    return null;
}

fn jsonObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn jsonArray(value: std.json.Value) ?[]std.json.Value {
    return switch (value) {
        .array => |array| array.items,
        else => null,
    };
}

fn requiredString(object: std.json.ObjectMap, field: []const u8) ManifestError![]const u8 {
    return switch (object.get(field) orelse return error.InvalidPackageJson) {
        .string => |string| string,
        else => error.InvalidPackageJson,
    };
}

fn validRelativePath(path: []const u8) bool {
    if (path.len == 0 or path.len > 1024 or std.fs.path.isAbsolute(path) or path[path.len - 1] == '/' or std.mem.indexOfScalar(u8, path, 0) != null or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    return true;
}

fn validCompatibility(value: []const u8) bool {
    if (!validText(value, 128)) return false;
    for (value) |char| if (!(std.ascii.isAlphanumeric(char) or char == '.' or char == '-' or char == '+' or char == '<' or char == '>' or char == '=' or char == ' ')) return false;
    return true;
}

fn validResourceType(value: []const u8) bool {
    if (value.len == 0 or value.len > 256 or std.mem.indexOfScalar(u8, value, '.') == null) return false;
    for (value) |char| if (!(std.ascii.isAlphanumeric(char) or char == '.' or char == '_')) return false;
    return true;
}

fn validProviderResourcePattern(value: []const u8) bool {
    if (validResourceType(value)) return true;
    if (!std.mem.endsWith(u8, value, ".*") or value.len < 3) return false;
    return validResourceType(value[0 .. value.len - 1]);
}

fn validText(value: []const u8, max: usize) bool {
    if (value.len == 0 or value.len > max) return false;
    for (value) |char| if (char < 0x20 or char == 0x7f) return false;
    return true;
}

fn validHexToken(value: []const u8) bool {
    if (value.len == 0 or value.len > 32) return false;
    for (value) |char| if (!(std.ascii.isDigit(char) or char >= 'a' and char <= 'f')) return false;
    return true;
}

fn validJsonString(value: []const u8) bool {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return false;
    return std.mem.indexOfAny(u8, value, "\r\n\x00") == null;
}

fn containsString(values: []const []const u8, target: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, target)) return true;
    return false;
}

fn containsInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |start| {
        var matches = true;
        for (needle, 0..) |char, index| if (std.ascii.toLower(haystack[start + index]) != std.ascii.toLower(char)) {
            matches = false;
            break;
        };
        if (matches) return true;
    }
    return false;
}

fn appendNamedString(output: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
    try output.appendSlice(allocator, ",\"");
    try output.appendSlice(allocator, name);
    try output.appendSlice(allocator, "\":");
    try appendJsonString(output, allocator, value);
}

fn appendNamedStringArray(output: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, values: []const []const u8) !void {
    try output.appendSlice(allocator, ",\"");
    try output.appendSlice(allocator, name);
    try output.appendSlice(allocator, "\":[");
    for (values, 0..) |value, index| {
        if (index != 0) try output.append(allocator, ',');
        try appendJsonString(output, allocator, value);
    }
    try output.append(allocator, ']');
}

fn appendJsonString(output: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(encoded);
    try output.appendSlice(allocator, encoded);
}
