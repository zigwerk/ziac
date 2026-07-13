const std = @import("std");
const zstd = @import("zigeffect_std");

pub const IdentityProvider = enum { google };
pub const Entitlement = enum { none, pro };
pub const ConnectionStatus = enum { disconnected, connected };

pub const Identity = struct {
    provider: IdentityProvider,
    verified: bool,
    subject: []const u8,
};

pub const Connection = struct {
    status: ConnectionStatus,
    project_id: []const u8,
};

pub const ScanInput = struct {
    identity: Identity,
    entitlement: Entitlement,
    connection: Connection,
    observed_at_millis: u64,
    max_pages: usize = 100,
    max_assets: usize = 10_000,
    page_size: u16 = 500,
};

pub const SearchRequest = struct {
    project_id: []const u8,
    page_token: ?[]const u8,
    page_size: u16,
};

pub const Client = struct {
    ptr: *anyopaque,
    search_alloc: *const fn (*anyopaque, std.mem.Allocator, SearchRequest) anyerror![]u8,

    pub fn searchAlloc(self: Client, allocator: std.mem.Allocator, request: SearchRequest) ![]u8 {
        return self.search_alloc(self.ptr, allocator, request);
    }
};

pub const Scan = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    artifact: []u8,
    resource_count: usize,
    edge_count: usize,
    page_count: usize,

    pub fn deinit(self: *Scan) void {
        self.allocator.free(self.artifact);
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.* = undefined;
    }
};

const Asset = struct {
    name: []const u8,
    asset_type: []const u8,
    location: []const u8,
    display_name: []const u8,
    related_resources: []const []const u8,
    id: []const u8,
    ziac_type: []const u8,
    physical_id: []const u8,
};

pub fn scanAlloc(allocator: std.mem.Allocator, client: Client, input: ScanInput) !Scan {
    try validateAccess(input);
    if (input.max_pages == 0 or input.max_assets == 0 or input.page_size == 0 or input.page_size > 500) {
        return error.InvalidScanLimit;
    }

    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var assets: std.ArrayList(Asset) = .empty;
    var next_token: ?[]const u8 = null;
    var page_count: usize = 0;

    while (true) {
        if (page_count >= input.max_pages) return error.ScanPageLimitExceeded;
        const response = try client.searchAlloc(allocator, .{
            .project_id = input.connection.project_id,
            .page_token = next_token,
            .page_size = input.page_size,
        });
        defer allocator.free(response);
        if (response.len > 16 * 1024 * 1024) return error.ScanResponseTooLarge;
        if (zstd.Secrets.containsSecret(response)) return error.SecretMaterialRejected;
        var parsed = std.json.parseFromSlice(std.json.Value, a, response, .{
            .allocate = .alloc_always,
        }) catch return error.InvalidCloudAssetResponse;
        defer parsed.deinit();
        const root = jsonObject(parsed.value) orelse return error.InvalidCloudAssetResponse;
        const results = if (root.get("results")) |value|
            jsonArray(value) orelse return error.InvalidCloudAssetResponse
        else
            null;
        if (results) |items| for (items.items) |item| {
            if (assets.items.len >= input.max_assets) return error.ScanAssetLimitExceeded;
            const object = jsonObject(item) orelse return error.InvalidCloudAssetResponse;
            const name = jsonString(object.get("name")) orelse return error.InvalidCloudAssetResponse;
            const asset_type = jsonString(object.get("assetType")) orelse return error.InvalidCloudAssetResponse;
            if (!validResourceName(name) or asset_type.len == 0) return error.InvalidCloudAssetResponse;
            for (assets.items) |existing| {
                if (std.mem.eql(u8, existing.name, name)) return error.DuplicateCloudAsset;
            }
            const location = jsonString(object.get("location")) orelse "global";
            const display_name = jsonString(object.get("displayName")) orelse resourceBasename(name);
            const related = try relatedResourcesAlloc(a, object.get("relationships"));
            try assets.append(a, .{
                .name = try a.dupe(u8, name),
                .asset_type = try a.dupe(u8, asset_type),
                .location = try a.dupe(u8, location),
                .display_name = try a.dupe(u8, display_name),
                .related_resources = related,
                .id = try observedIdAlloc(a, name),
                .ziac_type = try mappedTypeAlloc(a, asset_type, location, name),
                .physical_id = try managedPhysicalIdAlloc(a, asset_type, name),
            });
        };
        page_count += 1;
        const page_token = jsonString(root.get("nextPageToken"));
        if (page_token == null or page_token.?.len == 0) break;
        next_token = try a.dupe(u8, page_token.?);
    }

    std.mem.sort(Asset, assets.items, {}, lessThanAsset);
    const artifact = try artifactJsonAlloc(allocator, a, assets.items, input);
    errdefer allocator.free(artifact.bytes);
    return .{
        .allocator = allocator,
        .arena = arena,
        .artifact = artifact.bytes,
        .resource_count = assets.items.len,
        .edge_count = artifact.edge_count,
        .page_count = page_count,
    };
}

const ArtifactOutput = struct {
    bytes: []u8,
    edge_count: usize,
};

fn artifactJsonAlloc(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    assets: []const Asset,
    input: ScanInput,
) !ArtifactOutput {
    var resources = std.json.Array.init(arena);
    var regions = std.json.Array.init(arena);
    var region_names: std.ArrayList([]const u8) = .empty;
    var ids: std.StringHashMap([]const u8) = std.StringHashMap([]const u8).init(arena);
    for (assets) |asset| try ids.put(asset.name, asset.id);

    for (assets) |asset| {
        if (!std.mem.eql(u8, asset.location, "global") and !containsString(region_names.items, asset.location)) {
            try region_names.append(arena, asset.location);
        }
    }
    std.mem.sort([]const u8, region_names.items, {}, lessThanString);
    for (region_names.items) |region| try regions.append(.{ .string = region });

    for (assets) |asset| {
        var object: std.json.ObjectMap = .empty;
        try object.put(arena, "id", .{ .string = asset.id });
        try object.put(arena, "provider", .{ .string = "gcp" });
        try object.put(arena, "type", .{ .string = asset.ziac_type });
        try object.put(arena, "logical_id", .{ .string = asset.display_name });
        const scope = if (std.mem.eql(u8, asset.location, "global")) "global" else "regional";
        try object.put(arena, "scope", .{ .string = scope });
        var resource_regions = std.json.Array.init(arena);
        if (!std.mem.eql(u8, asset.location, "global")) {
            try object.put(arena, "region", .{ .string = asset.location });
            try resource_regions.append(.{ .string = asset.location });
        }
        try object.put(arena, "regions", .{ .array = resource_regions });
        try object.put(arena, "operation", .{ .string = "read" });
        try object.put(arena, "health", .{ .string = "unknown" });
        try object.put(arena, "ownership", .{ .string = "observed" });
        var discovery: std.json.ObjectMap = .empty;
        try discovery.put(arena, "provider", .{ .string = "cloud_asset_inventory" });
        try discovery.put(arena, "project_id", .{ .string = input.connection.project_id });
        try discovery.put(arena, "observed_at_millis", .{ .integer = @intCast(input.observed_at_millis) });
        try discovery.put(arena, "source_name", .{ .string = asset.name });
        try object.put(arena, "discovery", .{ .object = discovery });
        var inputs: std.json.ObjectMap = .empty;
        try inputs.put(arena, "asset_type", .{ .string = asset.asset_type });
        try inputs.put(arena, "location", .{ .string = asset.location });
        try inputs.put(arena, "physical_id", .{ .string = asset.physical_id });
        try object.put(arena, "inputs", .{ .object = inputs });
        var lifecycle: std.json.ObjectMap = .empty;
        try lifecycle.put(arena, "protect", .{ .bool = false });
        try lifecycle.put(arena, "retain_on_delete", .{ .bool = false });
        try lifecycle.put(arena, "replace_before_delete", .{ .bool = false });
        try object.put(arena, "lifecycle", .{ .object = lifecycle });
        try object.put(arena, "reasons", .{ .array = std.json.Array.init(arena) });
        try resources.append(.{ .object = object });
    }

    var edges = std.json.Array.init(arena);
    for (assets) |asset| for (asset.related_resources) |related| {
        const target_id = ids.get(related) orelse continue;
        var edge: std.json.ObjectMap = .empty;
        const edge_id = try std.fmt.allocPrint(arena, "{s}->{s}", .{ asset.id, target_id });
        try edge.put(arena, "id", .{ .string = edge_id });
        try edge.put(arena, "from", .{ .string = asset.id });
        try edge.put(arena, "to", .{ .string = target_id });
        try edge.put(arena, "kind", .{ .string = "dependency" });
        try edges.append(.{ .object = edge });
    };

    const graph_digest = try graphDigestAlloc(arena, assets);
    var summary: std.json.ObjectMap = .empty;
    try summary.put(arena, "resources", .{ .integer = @intCast(assets.len) });
    try summary.put(arena, "edges", .{ .integer = @intCast(edges.items.len) });
    try summary.put(arena, "regions", .{ .integer = @intCast(regions.items.len) });
    var root: std.json.ObjectMap = .empty;
    try root.put(arena, "schema", .{ .string = "ziac.visual.v1" });
    try root.put(arena, "format_version", .{ .integer = 1 });
    try root.put(arena, "truth_mode", .{ .string = "live" });
    try root.put(arena, "created_at_millis", .{ .integer = @intCast(input.observed_at_millis) });
    try root.put(arena, "stack", .{ .string = "existing-gcp" });
    try root.put(arena, "stage", .{ .string = input.connection.project_id });
    try root.put(arena, "graph_digest", .{ .string = graph_digest });
    try root.put(arena, "state_serial", .{ .integer = 0 });
    try root.put(arena, "summary", .{ .object = summary });
    try root.put(arena, "regions", .{ .array = regions });
    try root.put(arena, "resources", .{ .array = resources });
    try root.put(arena, "edges", .{ .array = edges });
    try root.put(arena, "routes", .{ .array = std.json.Array.init(arena) });
    try root.put(arena, "observations", .{ .array = std.json.Array.init(arena) });
    try root.put(arena, "diagnostics", .{ .array = std.json.Array.init(arena) });

    const bytes = std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = root }, .{}) catch return error.OutOfMemory;
    if (zstd.Secrets.containsSecret(bytes)) {
        allocator.free(bytes);
        return error.SecretMaterialRejected;
    }
    return .{ .bytes = bytes, .edge_count = edges.items.len };
}

fn validateAccess(input: ScanInput) !void {
    if (input.identity.provider != .google or !input.identity.verified or input.identity.subject.len == 0) {
        return error.GoogleIdentityRequired;
    }
    if (input.entitlement != .pro) return error.ProEntitlementRequired;
    if (input.connection.status != .connected) return error.GcpConnectionRequired;
    if (!validProjectId(input.connection.project_id)) return error.InvalidProjectId;
    if (input.observed_at_millis == 0) return error.InvalidObservationTime;
}

fn relatedResourcesAlloc(allocator: std.mem.Allocator, value: ?std.json.Value) ![]const []const u8 {
    var related: std.ArrayList([]const u8) = .empty;
    const relationships = if (value) |present| jsonObject(present) orelse return error.InvalidCloudAssetResponse else return related.toOwnedSlice(allocator);
    var iterator = relationships.iterator();
    while (iterator.next()) |entry| {
        const relation = jsonObject(entry.value_ptr.*) orelse return error.InvalidCloudAssetResponse;
        const resources = if (relation.get("relatedResources")) |present|
            jsonArray(present) orelse return error.InvalidCloudAssetResponse
        else
            continue;
        for (resources.items) |item| {
            const name = jsonString(item) orelse return error.InvalidCloudAssetResponse;
            if (!validResourceName(name)) return error.InvalidCloudAssetResponse;
            if (!containsString(related.items, name)) try related.append(allocator, try allocator.dupe(u8, name));
        }
    }
    std.mem.sort([]const u8, related.items, {}, lessThanString);
    return related.toOwnedSlice(allocator);
}

fn observedIdAlloc(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(name, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "observed.{s}", .{hex[0..20]});
}

fn mappedTypeAlloc(allocator: std.mem.Allocator, asset_type: []const u8, location: []const u8, name: []const u8) ![]const u8 {
    const mapped = if (std.mem.eql(u8, asset_type, "run.googleapis.com/Service"))
        "gcp.run.Service"
    else if (std.mem.eql(u8, asset_type, "run.googleapis.com/Job"))
        "gcp.run.Job"
    else if (std.mem.eql(u8, asset_type, "run.googleapis.com/WorkerPool"))
        "gcp.run.WorkerPool"
    else if (std.mem.eql(u8, asset_type, "sqladmin.googleapis.com/Instance"))
        "gcp.sql.Instance"
    else if (std.mem.eql(u8, asset_type, "storage.googleapis.com/Bucket"))
        "gcp.storage.Bucket"
    else if (std.mem.eql(u8, asset_type, "pubsub.googleapis.com/Topic"))
        "gcp.pubsub.Topic"
    else if (std.mem.eql(u8, asset_type, "pubsub.googleapis.com/Subscription"))
        "gcp.pubsub.Subscription"
    else if (std.mem.eql(u8, asset_type, "cloudtasks.googleapis.com/Queue"))
        "gcp.tasks.Queue"
    else if (std.mem.eql(u8, asset_type, "eventarc.googleapis.com/Trigger"))
        "gcp.eventarc.Trigger"
    else if (std.mem.eql(u8, asset_type, "iam.googleapis.com/ServiceAccount"))
        "gcp.iam.ServiceAccount"
    else if (std.mem.eql(u8, asset_type, "iam.googleapis.com/Role"))
        if (std.mem.indexOf(u8, name, "/organizations/") != null) "gcp.iam.OrganizationCustomRole" else "gcp.iam.ProjectCustomRole"
    else if (std.mem.eql(u8, asset_type, "iam.googleapis.com/WorkloadIdentityPool"))
        "gcp.iam.WorkloadIdentityPool"
    else if (std.mem.eql(u8, asset_type, "iam.googleapis.com/WorkloadIdentityPoolProvider"))
        "gcp.iam.WorkloadIdentityPoolProvider"
    else if (std.mem.eql(u8, asset_type, "bigquery.googleapis.com/Dataset"))
        "gcp.bigquery.Dataset"
    else if (std.mem.eql(u8, asset_type, "bigquery.googleapis.com/Table"))
        "gcp.bigquery.Table"
    else if (std.mem.eql(u8, asset_type, "bigquery.googleapis.com/Routine"))
        "gcp.bigquery.Routine"
    else if (std.mem.eql(u8, asset_type, "bigqueryreservation.googleapis.com/Reservation"))
        "gcp.bigquery.Reservation"
    else if (std.mem.eql(u8, asset_type, "compute.googleapis.com/Network"))
        "gcp.compute.Network"
    else if (std.mem.eql(u8, asset_type, "compute.googleapis.com/Subnetwork"))
        "gcp.compute.Subnetwork"
    else if (std.mem.eql(u8, asset_type, "compute.googleapis.com/ForwardingRule"))
        if (std.mem.eql(u8, location, "global")) "gcp.compute.GlobalForwardingRule" else "gcp.compute.RegionForwardingRule"
    else if (std.mem.eql(u8, asset_type, "compute.googleapis.com/BackendService"))
        "gcp.compute.BackendService"
    else if (std.mem.eql(u8, asset_type, "compute.googleapis.com/Instance"))
        "gcp.compute.Instance"
    else
        "gcp.asset.Resource";
    return allocator.dupe(u8, mapped);
}

fn managedPhysicalIdAlloc(allocator: std.mem.Allocator, asset_type: []const u8, name: []const u8) ![]const u8 {
    if (std.mem.eql(u8, asset_type, "run.googleapis.com/Service") or
        std.mem.eql(u8, asset_type, "run.googleapis.com/Job") or
        std.mem.eql(u8, asset_type, "run.googleapis.com/WorkerPool"))
    {
        const prefix = "//run.googleapis.com/";
        if (!std.mem.startsWith(u8, name, prefix) or name.len == prefix.len) return error.InvalidCloudAssetResponse;
        return allocator.dupe(u8, name[prefix.len..]);
    }
    if (std.mem.eql(u8, asset_type, "storage.googleapis.com/Bucket")) {
        const bucket_name = std.fs.path.basename(name);
        if (bucket_name.len == 0) return error.InvalidCloudAssetResponse;
        return std.fmt.allocPrint(allocator, "buckets/{s}", .{bucket_name});
    }
    if (std.mem.eql(u8, asset_type, "pubsub.googleapis.com/Topic") or
        std.mem.eql(u8, asset_type, "pubsub.googleapis.com/Subscription"))
    {
        const prefix = "//pubsub.googleapis.com/";
        if (!std.mem.startsWith(u8, name, prefix) or name.len == prefix.len) return error.InvalidCloudAssetResponse;
        return allocator.dupe(u8, name[prefix.len..]);
    }
    if (std.mem.eql(u8, asset_type, "cloudtasks.googleapis.com/Queue")) {
        const prefix = "//cloudtasks.googleapis.com/";
        if (!std.mem.startsWith(u8, name, prefix) or name.len == prefix.len) return error.InvalidCloudAssetResponse;
        return allocator.dupe(u8, name[prefix.len..]);
    }
    if (std.mem.eql(u8, asset_type, "eventarc.googleapis.com/Trigger")) {
        const prefix = "//eventarc.googleapis.com/";
        if (!std.mem.startsWith(u8, name, prefix) or name.len == prefix.len) return error.InvalidCloudAssetResponse;
        return allocator.dupe(u8, name[prefix.len..]);
    }
    if (std.mem.eql(u8, asset_type, "iam.googleapis.com/ServiceAccount") or
        std.mem.eql(u8, asset_type, "iam.googleapis.com/Role") or
        std.mem.eql(u8, asset_type, "iam.googleapis.com/WorkloadIdentityPool") or
        std.mem.eql(u8, asset_type, "iam.googleapis.com/WorkloadIdentityPoolProvider"))
    {
        const prefix = "//iam.googleapis.com/";
        if (!std.mem.startsWith(u8, name, prefix) or name.len == prefix.len) return error.InvalidCloudAssetResponse;
        return allocator.dupe(u8, name[prefix.len..]);
    }
    if (std.mem.eql(u8, asset_type, "bigquery.googleapis.com/Dataset") or
        std.mem.eql(u8, asset_type, "bigquery.googleapis.com/Table") or
        std.mem.eql(u8, asset_type, "bigquery.googleapis.com/Routine"))
    {
        const prefix = "//bigquery.googleapis.com/";
        if (!std.mem.startsWith(u8, name, prefix) or name.len == prefix.len) return error.InvalidCloudAssetResponse;
        return allocator.dupe(u8, name[prefix.len..]);
    }
    if (std.mem.eql(u8, asset_type, "bigqueryreservation.googleapis.com/Reservation")) {
        const prefix = "//bigqueryreservation.googleapis.com/";
        if (!std.mem.startsWith(u8, name, prefix) or name.len == prefix.len) return error.InvalidCloudAssetResponse;
        return allocator.dupe(u8, name[prefix.len..]);
    }
    return allocator.dupe(u8, name);
}

fn graphDigestAlloc(allocator: std.mem.Allocator, assets: []const Asset) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("ziac-estate-v1\x00");
    for (assets) |asset| {
        hasher.update(asset.name);
        hasher.update("\x00");
        hasher.update(asset.asset_type);
        for (asset.related_resources) |related| {
            hasher.update("\x00");
            hasher.update(related);
        }
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, &hex);
}

fn validProjectId(value: []const u8) bool {
    if (value.len < 6 or value.len > 63 or !std.ascii.isLower(value[0])) return false;
    if (value[value.len - 1] == '-') return false;
    for (value) |byte| if (!(std.ascii.isLower(byte) or std.ascii.isDigit(byte) or byte == '-')) return false;
    return true;
}

fn validResourceName(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "//") and value.len <= 2048 and
        std.mem.indexOfScalar(u8, value, 0) == null and
        !zstd.Secrets.containsSecret(value);
}

fn resourceBasename(value: []const u8) []const u8 {
    return std.fs.path.basename(value);
}

fn jsonObject(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => null,
    };
}

fn jsonArray(value: std.json.Value) ?std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => null,
    };
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const present = value orelse return null;
    return switch (present) {
        .string => |text| text,
        else => null,
    };
}

fn containsString(values: []const []const u8, value: []const u8) bool {
    for (values) |candidate| if (std.mem.eql(u8, candidate, value)) return true;
    return false;
}

fn lessThanAsset(_: void, left: Asset, right: Asset) bool {
    return std.mem.lessThan(u8, left.name, right.name);
}

fn lessThanString(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

pub const ScriptedClient = struct {
    allocator: std.mem.Allocator,
    pages: std.ArrayList([]u8) = .empty,
    call_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) ScriptedClient {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ScriptedClient) void {
        for (self.pages.items) |page| self.allocator.free(page);
        self.pages.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn addPage(self: *ScriptedClient, page: []const u8) !void {
        try self.pages.append(self.allocator, try self.allocator.dupe(u8, page));
    }

    pub fn client(self: *ScriptedClient) Client {
        return .{ .ptr = self, .search_alloc = search };
    }

    fn search(raw: *anyopaque, allocator: std.mem.Allocator, _: SearchRequest) ![]u8 {
        const self: *ScriptedClient = @ptrCast(@alignCast(raw));
        if (self.call_count >= self.pages.items.len) return error.ScriptExhausted;
        const page = self.pages.items[self.call_count];
        self.call_count += 1;
        return allocator.dupe(u8, page);
    }
};
