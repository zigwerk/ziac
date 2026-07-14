# GCP Spanner, Memorystore And Private Services Access

M66 provides globally distributed relational storage, low-latency caches and
their private network dependency through Ziac's three provider layers: typed
resources, hardened lifecycle adapters and opinionated components.

## Compose A Data Platform

```zig
var private_access = try ziac.gcp.PrivateServiceAccess.build(allocator, provider, .{
    .name = "managed-services",
    .network = "projects/project/global/networks/platform",
    .prefix_length = 16,
});
defer private_access.deinit();

var database = try ziac.gcp.SpannerDatabase.build(allocator, provider, .{
    .base_graph = &private_access.graph,
    .name = "global-app",
    .instance = .{
        .instance_id = "global-app",
        .config = "nam-eur-asia1",
        .display_name = "Global application",
        .edition = .enterprise_plus,
        .capacity = .{ .autoscaling_processing_units = .{ .min = 1000, .max = 5000 } },
        .default_backup_schedule = .none,
    },
    .database_id = "app",
    .backup_schedule = .{
        .schedule_id = "daily",
        .cron = "0 2 * * *",
        .retention_seconds = 14 * 24 * 60 * 60,
    },
    .database_members = &.{.{
        .name = "api-runtime",
        .role = "roles/spanner.databaseUser",
        .member = "serviceAccount:api@project.iam.gserviceaccount.com",
    }},
});
defer database.deinit();

var cache = try ziac.gcp.MemorystoreCache.build(allocator, provider, .{
    .base_graph = &database.graph,
    .name = "sessions",
    .cache = .{ .classic = .{
        .instance_id = "sessions",
        .location = "europe-west1",
        .tier = .standard_ha,
        .memory_size_gb = 8,
        .network = "projects/project/global/networks/platform",
        .connect_mode = .private_service_access,
        .connectivity_dependency = private_access.connection_name,
        .auth_secret = redis_auth_secret.name,
    } },
});
defer cache.deinit();
```

Private connectivity is always visible in the graph. `PrivateServiceAccess`
owns one Compute global address range and one Service Networking connection.
Redis classic refuses private-services mode without that typed dependency.
Redis Cluster uses its native PSC automation and therefore remains a separate
tag of `MemorystoreCache`; classic and cluster settings cannot be mixed.

## Data And Secret Safety

Spanner instances, databases and backups are protected and retained by
default. Instance capacity is a tagged fixed or autoscaling policy. Database
dialect, CMEK and parent identity are replacement boundaries; DDL updates,
backup expiry and schedule retention remain explicit mutations.

Redis AUTH never enters ordinary state. Classic Redis requires a declared
Secret Manager target when AUTH is enabled. The provider writes Google's
one-time generated auth value directly as a new secret version, zeroes its
transient buffers and stores only the secret reference. ACL rules likewise use
secret references instead of plaintext strings.

## Intelligence, Estate And Cost

Permission synthesis enables Spanner, Redis, Compute, Service Networking and,
for generated Redis AUTH, Secret Manager. Spanner database-user access is
shown as runtime read/write authority; Redis Cluster IAM authentication maps to
`redis.clusters.connect` when that role exists in the graph.

Cloud Asset Inventory supports Spanner instances, databases and backups,
Redis instances and clusters, and Service Networking connections. Those map to
canonical managed identities. Google does not expose Spanner backup schedules
or Redis ACL policies as Cloud Asset resource types, so Ziac keeps those
observed records generic instead of claiming safe adoption.

`spannerConfigurationEstimate` requires processing-unit hours, storage
GiB-month and backup GiB-month. `memorystoreConfigurationEstimate` requires
capacity GiB-hours and optional egress. Both are configuration estimates;
actual cost still requires the customer's billing export.

## Qualification

The local receipt proves graph validation, fake-provider apply, import into an
empty state, refreshed no-op and cleanup. It is always marked
`authenticated: false`.

`scripts/qualify-data-services.sh` is the authenticated boundary. It requires
ADC, a project ending in `-ziac-disposable`, a cleanup-enabled stack and a
runner that can reach the private Redis address. It applies the stack, executes
Spanner SQL, performs an authenticated Redis PING without printing the token,
imports all resources into a second state, proves no-op and destroys the
disposable graph. Missing configuration, credentials or tools returns a
structured exit-77 skip.

Contract references:

- [Spanner REST v1](https://cloud.google.com/spanner/docs/reference/rest)
- [Memorystore for Redis REST v1](https://cloud.google.com/memorystore/docs/redis/reference/rest)
- [Memorystore for Redis Cluster IAM](https://cloud.google.com/memorystore/docs/cluster/access-control)
- [Private Services Access](https://cloud.google.com/vpc/docs/private-services-access)
- [Cloud Asset Inventory asset types](https://cloud.google.com/asset-inventory/docs/asset-types)
