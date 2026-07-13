const std = @import("std");

pub const pinned_at = "2026-07-13";

pub const Source = struct {
    id: []const u8,
    version: []const u8,
    revision: []const u8,
    discovery_url: []const u8,
    document_sha256: []const u8,
};

pub const sources = [_]Source{
    .{
        .id = "compute:v1",
        .version = "v1",
        .revision = "20260629",
        .discovery_url = "https://www.googleapis.com/discovery/v1/apis/compute/v1/rest",
        .document_sha256 = "d14b88ee486ca3e49897b737a45717141d2003a9782571d0b96a66f26af0fd12",
    },
    .{
        .id = "dns:v1",
        .version = "v1",
        .revision = "20260630",
        .discovery_url = "https://dns.googleapis.com/discovery/v1/apis/dns/v1/rest",
        .document_sha256 = "39b1f648d4fa0824cfc0e8ee19101ddfeda12a53dc3ee3d8c1869a8dae0aeba6",
    },
    .{
        .id = "sqladmin:v1",
        .version = "v1",
        .revision = "20260627",
        .discovery_url = "https://sqladmin.googleapis.com/discovery/v1/apis/sqladmin/v1/rest",
        .document_sha256 = "e974b1b2e9778df3727ed425582401b2166507e15e842f331f203ed5596e4f4e",
    },
    .{
        .id = "storage:v1",
        .version = "v1",
        .revision = "20260707",
        .discovery_url = "https://storage.googleapis.com/discovery/v1/apis/storage/v1/rest",
        .document_sha256 = "225e6237f7fff5f24e04f29e1901b1eee999e9e5eee0db7676883cea8948b122",
    },
};

pub const ValidationError = error{
    DuplicateSource,
    InvalidHash,
    InvalidRevision,
    InvalidUrl,
    UnsortedSources,
};

pub fn validate() ValidationError!void {
    return validateSources(&sources);
}

pub fn validateSources(values: []const Source) ValidationError!void {
    for (values, 0..) |source, index| {
        if (source.revision.len == 0 or source.version.len == 0) return error.InvalidRevision;
        if (!std.mem.startsWith(u8, source.discovery_url, "https://")) return error.InvalidUrl;
        if (source.document_sha256.len != 64 or !isLowerHex(source.document_sha256)) return error.InvalidHash;
        if (index > 0) {
            const order = std.mem.order(u8, values[index - 1].id, source.id);
            if (order == .eq) return error.DuplicateSource;
            if (order == .gt) return error.UnsortedSources;
        }
    }
}

pub const Change = struct {
    id: []const u8,
    previous_revision: ?[]const u8,
    next_revision: ?[]const u8,
    previous_document_sha256: ?[]const u8,
    next_document_sha256: ?[]const u8,
    kind: enum { added, removed, changed },
};

pub fn semanticDiffJsonAlloc(
    allocator: std.mem.Allocator,
    current: []const Source,
    next: []const Source,
) std.mem.Allocator.Error![]u8 {
    var changes: std.ArrayList(Change) = .empty;
    defer changes.deinit(allocator);
    var breaking = false;

    for (current) |before| {
        const after = find(next, before.id) orelse {
            try changes.append(allocator, .{
                .id = before.id,
                .previous_revision = before.revision,
                .next_revision = null,
                .previous_document_sha256 = before.document_sha256,
                .next_document_sha256 = null,
                .kind = .removed,
            });
            breaking = true;
            continue;
        };
        if (!std.mem.eql(u8, before.revision, after.revision) or
            !std.mem.eql(u8, before.document_sha256, after.document_sha256))
        {
            try changes.append(allocator, .{
                .id = before.id,
                .previous_revision = before.revision,
                .next_revision = after.revision,
                .previous_document_sha256 = before.document_sha256,
                .next_document_sha256 = after.document_sha256,
                .kind = .changed,
            });
        }
    }
    for (next) |after| {
        if (find(current, after.id) != null) continue;
        try changes.append(allocator, .{
            .id = after.id,
            .previous_revision = null,
            .next_revision = after.revision,
            .previous_document_sha256 = null,
            .next_document_sha256 = after.document_sha256,
            .kind = .added,
        });
    }

    return std.json.Stringify.valueAlloc(allocator, .{
        .schema = "ziac.google.discovery-semantic-diff.v1",
        .changed = changes.items.len != 0,
        .breaking = breaking,
        .changes = changes.items,
    }, .{}) catch return error.OutOfMemory;
}

fn find(values: []const Source, id: []const u8) ?Source {
    for (values) |source| if (std.mem.eql(u8, source.id, id)) return source;
    return null;
}

fn isLowerHex(value: []const u8) bool {
    for (value) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    return true;
}
