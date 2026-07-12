# Estate Pro Control Plane

The Estate Pro control plane is a separate trust boundary from the dashboard.
The browser never receives Google refresh tokens, session assertions, KMS key
identifiers, or Cloud Asset Inventory credentials.

## API boundary

The desktop host uses four authenticated operations:

- `POST /v1/estate/identity:verify`
- `POST /v1/estate/entitlements:lookup`
- `POST /v1/estate/connections:resolve`
- `POST /v1/estate/connections:revoke`

Every operation authenticates the digest of an opaque bearer assertion, binds
the request subject to the session's Google subject, checks expiry and
revocation, and appends an audit event. Connection responses contain only the
project ID and connection status. Encrypted credential material and KMS metadata
stay behind the repository adapter.

## Persistence

`migrations/001_estate_control_plane.sql` defines the CockroachDB production
schema for accounts, hashed sessions, entitlements, encrypted GCP connections,
single-use PKCE challenges, and append-only audit events. Refresh credentials
must be encrypted before insertion with a dedicated Cloud KMS key. The database
contains ciphertext, key version, and a digest for rotation diagnostics; it must
never contain an unencrypted OAuth token.

The in-memory repository is for deterministic tests and local development only.
A production process must refuse startup unless the Cockroach repository and KMS
credential envelope are configured.

## Service process

`zig build` installs `ziac-estate-control-plane`. It requires:

- `DATABASE_URL` with `sslmode=verify-full`;
- `GOOGLE_OAUTH_CLIENT_ID` and `GOOGLE_OAUTH_CLIENT_SECRET`;
- `ZIAC_ESTATE_KMS_KEY` as a complete Cloud KMS CryptoKey resource name;
- Application Default Credentials, supplied by Cloud Run metadata in GCP;
- optional `PORT`, defaulting to `8080`.

Run `migrations/001_estate_control_plane.sql` before starting the service. The
process creates and atomically consumes ten-minute PKCE challenges, exchanges
the callback with Google, stores the encrypted refresh credential, and returns a
random session assertion exactly once. Subsequent desktop calls use the four
Estate operations above.

## Authorization invariants

- A session stores only `SHA-256(assertion)` and expires server-side.
- Entitlement is authoritative at request time; dashboard state is not.
- A connection belongs to exactly one Google subject and one GCP project.
- Revocation changes resolution immediately and is idempotent.
- Observed assets remain read-only after authorization.
- Audit records contain identities and opaque resource IDs, never credentials.
