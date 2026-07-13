# GCP Cloud SQL For PostgreSQL

M65 provides Cloud SQL through Ziac's three provider layers: typed low-level
resources, a hardened Cloud SQL Admin v1 lifecycle adapter and the opinionated
`ziac.gcp.ManagedPostgres` component.

## Managed PostgreSQL

```zig
var database = try ziac.gcp.ManagedPostgres.build(allocator, provider, .{
    .name = "postgres",
    .primary = .{
        .instance_id = "postgres-primary",
        .database_version = .postgres_17,
        .region = "europe-west1",
        .tier = "db-custom-2-4096",
        .availability = .regional,
        .point_in_time_recovery = true,
        .private_network = "projects/project/global/networks/platform",
    },
    .private_connectivity_dependency = network.resource_name,
    .databases = &.{.{ .name = "app" }},
    .builtin_users = &.{.{
        .name = "app",
        .password = password_version,
    }},
    .iam_users = &.{.{
        .name = "api@project.iam",
        .user_type = .cloud_iam_service_account,
        .member = "serviceAccount:api@project.iam.gserviceaccount.com",
        .client = true,
    }},
});
defer database.deinit();
```

The component creates one protected and retained PostgreSQL primary, declared
databases and users, optional replicas, exact login/client IAM grants, and an
optional client certificate whose one-time private key is written directly to
a declared Secret Manager secret. It returns typed connection, database, user,
replica and certificate-secret outputs.

Private IP is never implicit. A private primary requires
`private_connectivity_dependency`; Ziac records that dependency but does not
create or alter a VPC, allocated range or Private Services Access connection.
That network boundary remains independently owned and reviewable.

## Typed Resources

- `gcp.sql.Instance` covers PostgreSQL version, edition, region, tier, HA,
  disk, backup/PITR, maintenance, deletion protection, flags, connector policy,
  TLS, public/private IP and authorized networks.
- `gcp.sql.ReadReplica` binds to a typed primary instance output and rejects an
  allocated range.
- `gcp.sql.Database` owns charset/collation metadata and retains data by
  default.
- `gcp.sql.User` separates built-in password-backed users from IAM database
  users. Passwords are secret references, not strings.
- `gcp.sql.ClientCertificate` stores public certificate metadata in state and
  the private key only as a Secret Manager version reference.

Database flags and authorized networks are canonicalized before hashing, so
Google ordering changes do not produce drift. Contradictory public/private
settings, connector-enforcement conflicts, invalid maintenance windows, IAM
passwords and missing built-in passwords fail before planning.

## Lifecycle Semantics

SQL Admin mutations checkpoint operation names and resume through
`operations.get`. Instance PATCH requests carry the latest `settingsVersion`;
region, engine, identity and allocated-range changes replace the instance.
Removing a previously configured private network is also replacement-only
because Google does not support detaching private IP from an existing
instance.

Imports accept an instance ID, `projects/<project>/instances/<instance>`, or a
Cloud Asset `//sqladmin.googleapis.com/...` identity. Databases and users use
their instance-scoped identities. Certificate imports require the fingerprint
and an explicit imported Secret Manager version because Google never returns
the private key again.

Built-in user passwords are resolved only inside the mutation call. The
payload and serialized request are zeroed after use. Client-certificate
responses are redacted and zeroed after the key has been copied into a Secret
Manager add-version request; ordinary state and visual artifacts contain no
plaintext credential material.

## Intelligence, Estate And Cost

Permission synthesis enables `sqladmin.googleapis.com` and derives exact
`cloudsql.instances`, `cloudsql.databases`, `cloudsql.users` and
`cloudsql.sslCerts` deployer permissions. Runtime
`roles/cloudsql.instanceUser` and `roles/cloudsql.client` edges remain distinct
as login and connector authority.

Cloud Asset Inventory instances map to canonical
`projects/.../instances/...` managed identity. The canvas records engine,
edition, primary/replica role, HA, private/public connectivity, backup/PITR,
TLS, databases, users and IAM access.

`cloudSqlConfigurationEstimate` requires explicit vCPU-hours, GiB-hours,
storage GiB-month, backup GiB-month and egress GiB assumptions. It is labelled
`configuration_estimate`; billing export remains the only authoritative actual
cost source.

## Qualification

The local qualification proves deterministic declaration, fake-provider
apply, second-state import, refreshed no-op, lifecycle-only unprotect and
retention-aware cleanup. Its receipt is always `authenticated: false`.

`scripts/qualify-cloud-sql.sh` is the authenticated boundary. It requires ADC,
Cloud SQL Auth Proxy, `psql`, a workspace configured for cleanup and a project
ending in `-ziac-disposable`. It deploys, probes SQL Admin resources, opens an
encrypted proxy connection without printing the password, imports into an
empty second state, proves no-op and destroys the disposable instance. Missing
credentials, tools or configuration emit a structured exit-77 skip.

Contract references:

- [Cloud SQL Admin v1 REST](https://cloud.google.com/sql/docs/postgres/admin-api/rest)
- [Private IP](https://cloud.google.com/sql/docs/postgres/configure-private-ip)
- [IAM database authentication](https://cloud.google.com/sql/docs/postgres/iam-authentication)
- [Client certificates](https://cloud.google.com/sql/docs/postgres/admin-api/rest/v1/sslCerts/insert)
