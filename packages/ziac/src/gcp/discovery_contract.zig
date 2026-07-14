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
        .id = "artifactregistry:v1",
        .version = "v1",
        .revision = "20260702",
        .discovery_url = "https://artifactregistry.googleapis.com/$discovery/rest?version=v1",
        .document_sha256 = "8db01db5354a58d312b1e627f067741b40fb41bf1940c211e58676a91d1fd719",
    },
    .{
        .id = "batch:v1",
        .version = "v1",
        .revision = "20260702",
        .discovery_url = "https://batch.googleapis.com/$discovery/rest?version=v1",
        .document_sha256 = "a1d4bccc0c316e9de358a7289fffcd91fb29dbc6b44bf3f9a1e10b9474440296",
    },
    .{
        .id = "cloudbilling:v1",
        .version = "v1",
        .revision = "20260710",
        .discovery_url = "https://cloudbilling.googleapis.com/$discovery/rest?version=v1",
        .document_sha256 = "1daf9db8ef1984bbc46adfdeec581e1f1774a87fbec2ae0fda5b4c0cf302f10a",
    },
    .{
        .id = "cloudbuild:v1",
        .version = "v1",
        .revision = "20260627",
        .discovery_url = "https://cloudbuild.googleapis.com/$discovery/rest?version=v1",
        .document_sha256 = "2ccaf9685578eb58438cab4a3c0765dc108f3c26148c2399988749e4db80ccf7",
    },
    .{
        .id = "cloudbuild:v2",
        .version = "v2",
        .revision = "20260627",
        .discovery_url = "https://cloudbuild.googleapis.com/$discovery/rest?version=v2",
        .document_sha256 = "0f278d1563896222cf12a40c013dbacc0ab45ca3e0526f6b83855a5ea62e9f84",
    },
    .{
        .id = "clouddeploy:v1",
        .version = "v1",
        .revision = "20260706",
        .discovery_url = "https://clouddeploy.googleapis.com/$discovery/rest?version=v1",
        .document_sha256 = "1ad7831e467cc5aeae81c49bac3726de166d864afa9d68cf3ce558fae1d52e56",
    },
    .{
        .id = "cloudfunctions:v2",
        .version = "v2",
        .revision = "20260709",
        .discovery_url = "https://cloudfunctions.googleapis.com/$discovery/rest?version=v2",
        .document_sha256 = "8c0b2977432d0c8ce30afee8f891b5a494585839de086b2e0c6bb7660150a19b",
    },
    .{
        .id = "cloudkms:v1",
        .version = "v1",
        .revision = "20260702",
        .discovery_url = "https://cloudkms.googleapis.com/$discovery/rest?version=v1",
        .document_sha256 = "0d84c07e14c61f76c620f1910ab59a36421721596957c300870a2df003c848d9",
    },
    .{
        .id = "cloudresourcemanager:v3",
        .version = "v3",
        .revision = "20260709",
        .discovery_url = "https://cloudresourcemanager.googleapis.com/$discovery/rest?version=v3",
        .document_sha256 = "19b05a73c08cb7650e9da7072503cd602ddb68b7341f29ce3ea15999f9f69253",
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
        .id = "logging:v2",
        .version = "v2",
        .revision = "20260706",
        .discovery_url = "https://logging.googleapis.com/$discovery/rest?version=v2",
        .document_sha256 = "7b9427e591ffd255ad8579a471200f9045cf5b72446f5dfa7fc648e761dc5e7d",
    },
    .{
        .id = "monitoring:v1",
        .version = "v1",
        .revision = "20260705",
        .discovery_url = "https://monitoring.googleapis.com/$discovery/rest?version=v1",
        .document_sha256 = "e75eaa5aaaea322cdf03d2970edcb37cf4b1a832c50fcc4a450da5778c73d5c5",
    },
    .{
        .id = "monitoring:v3",
        .version = "v3",
        .revision = "20260705",
        .discovery_url = "https://monitoring.googleapis.com/$discovery/rest?version=v3",
        .document_sha256 = "9419509a1ced59a7bda62d54135551cbf0f9c68dce0de8185a6d1a10beb85394",
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
        .id = "secretmanager:v1",
        .version = "v1",
        .revision = "20260705",
        .discovery_url = "https://secretmanager.googleapis.com/$discovery/rest?version=v1",
        .document_sha256 = "f04b20cabd72df1a41c311153a2d674fff9f7b6299d84c426da3a925c68c7131",
    },
    .{
        .id = "servicenetworking:v1",
        .version = "v1",
        .revision = "20260622",
        .discovery_url = "https://servicenetworking.googleapis.com/$discovery/rest?version=v1",
        .document_sha256 = "d845894da9ed689b1b76e80a570c105834b3dcd89670f389ba5d0d147ea3575f",
    },
    .{
        .id = "serviceusage:v1beta1",
        .version = "v1beta1",
        .revision = "20260629",
        .discovery_url = "https://serviceusage.googleapis.com/$discovery/rest?version=v1beta1",
        .document_sha256 = "7fa0f49af58ad3b8d7591c176f0004cb84125abcbc973e4b95cd17426346e61d",
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
