# CockroachDB Connection Secrets

`cockroach.connection_secret.ConnectionSecret` is the high-level data binding
for an existing GCP-hosted CockroachDB Cloud cluster. It creates a dependency
graph that persists a generated connection URI before applying its password to
the SQL user.

For a complete database, grants, and migration graph, use
`cockroach.application_database.ApplicationDatabase`; it composes this binding
with a separate bootstrap administrator secret so the target database is created
before the generated application URI is used.

## Resource Graph

With an accessor member configured, the component owns five resources:

1. retained `cockroach.Cluster.Existing` topology reference;
2. `gcp.secret.Secret` metadata;
3. append-only `gcp.secret.SecretVersion` connection URI;
4. `cockroach.SqlUser` bound to that exact secret version;
5. `gcp.secret.SecretIamMember` for the Cloud Run service account.

The secret version depends on the existing cluster SQL endpoint and Secret
Manager metadata. The SQL user depends on both the cluster and secret version.
The IAM member depends on the secret metadata. These edges ensure no SQL user
mutation occurs before Secret Manager has durably accepted the credential.

## Password Boundary

`SystemPasswordSource` obtains 32 bytes from `std.Io.randomSecure` and encodes
them with URL-safe unpadded base64. `PasswordSource` is a small injected
interface, so tests use deterministic values without weakening production
generation.

The generated password is held by `Password`, whose `deinit` zeroes its owned
buffer. The complete URI is held by `SecretPayload`, which has the same zeroing
contract. Temporary JSON and base64 request bodies are also zeroed before
release.

Connection URIs use this form:

```text
postgresql://<user>:<password>@<host>:26257/<database>?sslmode=verify-full
```

Username, password, and database path components use RFC 3986 percent encoding.
The parser used by `SqlUser` requires the expected username and an exact
`sslmode=verify-full` suffix before releasing the decoded password.

## Runtime Wiring

The component exposes an owned `payload_spec` and secret-version output. Wire
the live providers around the component while it is alive:

```zig
var system_passwords = ziac.cockroach.connection_secret.SystemPasswordSource{
    .io = io,
};
var generated = ziac.cockroach.connection_secret.ConnectionPayloadSource.init(
    &component.payload_spec,
    system_passwords.source(),
);
gcp_live.secret_source = generated.secretSource();

var stored = ziac.gcp.secret_access.SecretManagerSource.init(&gcp_client);
cockroach_live.secret_source = stored.secretSource();
```

The GCP provider resolves `ziac-cockroach-connection` sources to create the
version. The Cockroach provider later resolves the resulting
`gcp-secret-manager` reference through `versions:access`. State contains only
the Secret Manager resource name and numeric version.

## Retry Semantics

`SqlUser` reads the current user list before writing. An absent user is created;
an existing user has its password reset to the stored secret. Delete treats a
missing user as success.

If Secret Manager creation fails, graph ordering prevents the user operation.
If Secret Manager succeeds and the user call fails, its state checkpoint
survives. A retry accesses the same stored version and creates or resets the
user to that value. No in-memory password cache is required for convergence.

Rotating `generation` creates a new append-only Secret Manager version. Because
the SQL-user input references that version resource, the dependency and desired
hash change together and the provider resets the user from the new stored URI.
