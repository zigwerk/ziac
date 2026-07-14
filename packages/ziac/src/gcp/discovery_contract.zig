const std = @import("std");

pub const pinned_at = "2026-07-14";

pub const Source = struct {
    id: []const u8,
    version: []const u8,
    revision: []const u8,
    discovery_url: []const u8,
    document_sha256: []const u8,
};

pub const sources = [_]Source{
    .{
        .id = "apigateway:v1",
        .version = "v1",
        .revision = "20260625",
        .discovery_url = "https://apigateway.googleapis.com/$discovery/rest?version=v1",
        .document_sha256 = "c59cfb39aa30bd6a96ddd94db1194e7a5ace2a0bc2c423cb450d96762f565f6e",
    },
    .{
        .id = "batch:v1",
        .version = "v1",
        .revision = "20260702",
        .discovery_url = "https://batch.googleapis.com/$discovery/rest?version=v1",
        .document_sha256 = "a1d4bccc0c316e9de358a7289fffcd91fb29dbc6b44bf3f9a1e10b9474440296",
    },
    .{
        .id = "cloudfunctions:v2",
        .version = "v2",
        .revision = "20260709",
        .discovery_url = "https://cloudfunctions.googleapis.com/$discovery/rest?version=v2",
        .document_sha256 = "8c0b2977432d0c8ce30afee8f891b5a494585839de086b2e0c6bb7660150a19b",
    },
    .{
        .id = "compute:v1",
        .version = "v1",
        .revision = "20260629",
        .discovery_url = "https://www.googleapis.com/discovery/v1/apis/compute/v1/rest",
        .document_sha256 = "d14b88ee486ca3e49897b737a45717141d2003a9782571d0b96a66f26af0fd12",
    },
    .{
        .id = "container:v1",
        .version = "v1",
        .revision = "20260630",
        .discovery_url = "https://container.googleapis.com/$discovery/rest?version=v1",
        .document_sha256 = "a9af9378a7849d351c538136e06d3006ca6dec81c89f9ef22b2198981a332312",
    },
    .{
        .id = "dns:v1",
        .version = "v1",
        .revision = "20260630",
        .discovery_url = "https://dns.googleapis.com/discovery/v1/apis/dns/v1/rest",
        .document_sha256 = "39b1f648d4fa0824cfc0e8ee19101ddfeda12a53dc3ee3d8c1869a8dae0aeba6",
    },
    .{
        .id = "gkehub:v1",
        .version = "v1",
        .revision = "20260706",
        .discovery_url = "https://gkehub.googleapis.com/$discovery/rest?version=v1",
        .document_sha256 = "b939847af952d89c80f6f4e3dd76e7bdbe1c6078e04c99b7faa0cc97f03ba573",
    },
    .{
        .id = "identitytoolkit:v2",
        .version = "v2",
        .revision = "20260703",
        .discovery_url = "https://identitytoolkit.googleapis.com/$discovery/rest?version=v2",
        .document_sha256 = "a845b96dfef3ecd5eae8022be598b8622a18e9e1be707b2c2bf7a938ef5a3713",
    },
    .{
        .id = "networkconnectivity:v1",
        .version = "v1",
        .revision = "20260701",
        .discovery_url = "https://networkconnectivity.googleapis.com/$discovery/rest?version=v1",
        .document_sha256 = "a785c3a0736931b120a76a2e694f71b5cee6d49471bec8f1c049dac594029b8c",
    },
    .{
        .id = "parametermanager:v1",
        .version = "v1",
        .revision = "20260629",
        .discovery_url = "https://parametermanager.googleapis.com/$discovery/rest?version=v1",
        .document_sha256 = "670701cb42522540ae5af279318d8db584cbc442953d6873ebeed15b8fdd526b",
    },
    .{
        .id = "redis:v1",
        .version = "v1",
        .revision = "20260707",
        .discovery_url = "https://redis.googleapis.com/$discovery/rest?version=v1",
        .document_sha256 = "600495e7c28025e4af8a2d83067a0ded935c55a96acaa67ed9128e584b6646a2",
    },
    .{
        .id = "servicenetworking:v1",
        .version = "v1",
        .revision = "20260622",
        .discovery_url = "https://servicenetworking.googleapis.com/$discovery/rest?version=v1",
        .document_sha256 = "d845894da9ed689b1b76e80a570c105834b3dcd89670f389ba5d0d147ea3575f",
    },
    .{
        .id = "spanner:v1",
        .version = "v1",
        .revision = "20260622",
        .discovery_url = "https://spanner.googleapis.com/$discovery/rest?version=v1",
        .document_sha256 = "6e97664d011e3f3e91b19f654a926e4977270cbea2351e94c2cb45896502d5d1",
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
    .{
        .id = "workflows:v1",
        .version = "v1",
        .revision = "20260701",
        .discovery_url = "https://workflows.googleapis.com/$discovery/rest?version=v1",
        .document_sha256 = "bb944a9423276c3366343834e2bc51a67d11f2ca972317ba2e784ac1a1289202",
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
