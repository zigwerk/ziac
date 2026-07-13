const std = @import("std");
const cost = @import("../cost.zig");
const client_mod = @import("client.zig");
const provider = @import("../provider.zig");

pub const Adapter = struct {
    client: *client_mod.Client,
    context: *provider.OperationContext,

    pub fn init(client: *client_mod.Client, context: *provider.OperationContext) Adapter {
        return .{ .client = client, .context = context };
    }

    pub fn listSkusPageAlloc(self: *Adapter, service_id: []const u8, currency: []const u8, page_token: ?[]const u8) !cost.CatalogPage {
        if (!validServiceId(service_id) or !validCurrency(currency) or (page_token != null and !validPageToken(page_token.?))) return error.InvalidBillingRequest;
        const path = if (page_token) |token|
            try std.fmt.allocPrint(self.context.allocator, "/v1/services/{s}/skus?currencyCode={s}&pageSize=5000&pageToken={s}", .{ service_id, currency, token })
        else
            try std.fmt.allocPrint(self.context.allocator, "/v1/services/{s}/skus?currencyCode={s}&pageSize=5000", .{ service_id, currency });
        defer self.context.allocator.free(path);
        var response = try self.request(.{ .api = .cloud_billing, .method = "GET", .path = path, .response_body_limit = 8 * 1024 * 1024 });
        defer response.deinit(self.context.allocator);
        return cost.parseCatalogPageAlloc(self.context.allocator, response.body);
    }

    pub fn queryAlloc(self: *Adapter, project_id: []const u8, sql: []const u8) !BigQueryPage {
        if (!validProjectId(project_id)) return error.InvalidBillingRequest;
        const body = try queryRequestBodyAlloc(self.context.allocator, sql, 10_000);
        defer self.context.allocator.free(body);
        const path = try std.fmt.allocPrint(self.context.allocator, "/bigquery/v2/projects/{s}/queries", .{project_id});
        defer self.context.allocator.free(path);
        var response = try self.request(.{ .api = .bigquery, .method = "POST", .path = path, .body = body, .response_body_limit = 8 * 1024 * 1024 });
        defer response.deinit(self.context.allocator);
        return parseBigQueryPageAlloc(self.context.allocator, response.body);
    }

    pub fn resultsPageAlloc(self: *Adapter, project_id: []const u8, job_id: []const u8, location: ?[]const u8, page_token: ?[]const u8) !BigQueryPage {
        if (!validProjectId(project_id) or !validJobId(job_id) or (location != null and !validLocation(location.?)) or (page_token != null and !validPageToken(page_token.?))) return error.InvalidBillingRequest;
        var query = std.ArrayList(u8).empty;
        defer query.deinit(self.context.allocator);
        if (location) |value| try query.print(self.context.allocator, "location={s}", .{value});
        if (page_token) |value| try query.print(self.context.allocator, "{s}pageToken={s}", .{ if (query.items.len == 0) "" else "&", value });
        const path = try std.fmt.allocPrint(self.context.allocator, "/bigquery/v2/projects/{s}/queries/{s}{s}{s}", .{ project_id, job_id, if (query.items.len == 0) "" else "?", query.items });
        defer self.context.allocator.free(path);
        var response = try self.request(.{ .api = .bigquery, .method = "GET", .path = path, .response_body_limit = 8 * 1024 * 1024 });
        defer response.deinit(self.context.allocator);
        return parseBigQueryPageAlloc(self.context.allocator, response.body);
    }

    fn request(self: *Adapter, request_value: client_mod.Request) !@import("zigeffect_std").Http.Response {
        var diagnostic = client_mod.Diagnostic.init(self.context.allocator);
        defer diagnostic.deinit();
        return self.client.requestJsonAlloc(self.context, request_value, &diagnostic);
    }
};

pub const BigQueryPage = struct {
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    complete: bool,
    project_id: []const u8,
    job_id: []const u8,
    location: ?[]const u8,
    next_page_token: ?[]const u8,
    rows: []cost.BillingRow,

    pub fn deinit(self: *BigQueryPage) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.* = undefined;
    }
};

pub fn parseBigQueryPageAlloc(allocator: std.mem.Allocator, body: []const u8) !BigQueryPage {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var parsed = std.json.parseFromSlice(std.json.Value, a, body, .{}) catch return error.InvalidBigQueryResponse;
    defer parsed.deinit();
    const root = object(parsed.value) orelse return error.InvalidBigQueryResponse;
    const reference = object(root.get("jobReference") orelse return error.InvalidBigQueryResponse) orelse return error.InvalidBigQueryResponse;
    const complete = boolean(root.get("jobComplete")) orelse false;
    const fields = if (root.get("schema")) |schema_value|
        array((object(schema_value) orelse return error.InvalidBigQueryResponse).get("fields")) orelse return error.InvalidBigQueryResponse
    else if (!complete)
        null
    else
        return error.InvalidBigQueryResponse;
    if (fields) |present| {
        if (present.items.len != 3 or !fieldNamed(present.items[0], "resource_id") or !fieldNamed(present.items[1], "cost_micros") or !fieldNamed(present.items[2], "credit_micros")) return error.InvalidBigQueryResponse;
    }
    var rows = std.ArrayList(cost.BillingRow).empty;
    if (array(root.get("rows"))) |values| for (values.items) |row_value| {
        const row = object(row_value) orelse return error.InvalidBigQueryResponse;
        const cells = array(row.get("f")) orelse return error.InvalidBigQueryResponse;
        if (cells.items.len != 3) return error.InvalidBigQueryResponse;
        const resource_id = cellString(cells.items[0]) orelse return error.InvalidBigQueryResponse;
        const cost_micros = std.fmt.parseInt(i64, cellString(cells.items[1]) orelse return error.InvalidBigQueryResponse, 10) catch return error.InvalidBigQueryResponse;
        const credit_micros = std.fmt.parseInt(i64, cellString(cells.items[2]) orelse return error.InvalidBigQueryResponse, 10) catch return error.InvalidBigQueryResponse;
        try rows.append(a, .{ .resource_id = try a.dupe(u8, resource_id), .cost_micros = cost_micros, .credit_micros = credit_micros });
    };
    return .{
        .allocator = allocator,
        .arena = arena,
        .complete = complete,
        .project_id = try a.dupe(u8, string(reference.get("projectId")) orelse return error.InvalidBigQueryResponse),
        .job_id = try a.dupe(u8, string(reference.get("jobId")) orelse return error.InvalidBigQueryResponse),
        .location = if (string(reference.get("location"))) |value| try a.dupe(u8, value) else null,
        .next_page_token = if (string(root.get("pageToken"))) |value| try a.dupe(u8, value) else null,
        .rows = try rows.toOwnedSlice(a),
    };
}

pub fn queryRequestBodyAlloc(allocator: std.mem.Allocator, sql: []const u8, max_results: u32) ![]u8 {
    if (sql.len == 0 or sql.len > 1024 * 1024 or max_results == 0 or max_results > 10_000) return error.InvalidBillingQuery;
    return std.json.Stringify.valueAlloc(allocator, .{
        .query = sql,
        .useLegacySql = false,
        .maxResults = max_results,
        .timeoutMs = 10_000,
    }, .{});
}

fn fieldNamed(value: std.json.Value, expected: []const u8) bool {
    const field = object(value) orelse return false;
    return if (string(field.get("name"))) |name| std.mem.eql(u8, name, expected) else false;
}
fn cellString(value: std.json.Value) ?[]const u8 {
    const cell = object(value) orelse return null;
    return string(cell.get("v"));
}
fn object(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |entry| entry,
        else => null,
    };
}
fn array(value: ?std.json.Value) ?std.json.Array {
    const present = value orelse return null;
    return switch (present) {
        .array => |entry| entry,
        else => null,
    };
}
fn string(value: ?std.json.Value) ?[]const u8 {
    const present = value orelse return null;
    return switch (present) {
        .string => |entry| entry,
        else => null,
    };
}
fn boolean(value: ?std.json.Value) ?bool {
    const present = value orelse return null;
    return switch (present) {
        .bool => |entry| entry,
        else => null,
    };
}

fn validServiceId(value: []const u8) bool {
    return boundedToken(value, 3, 128, "-_");
}
fn validProjectId(value: []const u8) bool {
    return boundedToken(value, 6, 63, "-");
}
fn validJobId(value: []const u8) bool {
    return boundedToken(value, 1, 1024, "-_");
}
fn validLocation(value: []const u8) bool {
    return boundedToken(value, 1, 64, "-");
}
fn validCurrency(value: []const u8) bool {
    if (value.len != 3) return false;
    for (value) |byte| if (!std.ascii.isUpper(byte)) return false;
    return true;
}
fn validPageToken(value: []const u8) bool {
    return value.len > 0 and value.len <= 4096 and std.mem.indexOfAny(u8, value, "\x00\r\n &?#") == null;
}
fn boundedToken(value: []const u8, minimum: usize, maximum: usize, extra: []const u8) bool {
    if (value.len < minimum or value.len > maximum) return false;
    for (value) |byte| if (!(std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, extra, byte) != null)) return false;
    return true;
}
