# Ziac M65 Cloud SQL Provider Design

Date: 2026-07-13
Status: accepted for implementation

## Objective

Make Cloud SQL for PostgreSQL a production-usable Ziac provider family through
the same three layers as Storage, BigQuery and Firestore: typed primitives,
hardened lifecycle adapters and an opinionated `ManagedPostgres` component.
The provider must cover primary instances, read replicas, databases, built-in
and IAM database users, private IP, TLS policy and client certificates without
persisting passwords or private keys as ordinary state values.

## Contract

M65 pins the Cloud SQL Admin v1 Discovery document:

- API ID: `sqladmin:v1`
- revision: `20260627`
- document SHA-256:
  `e974b1b2e9778df3727ed425582401b2166507e15e842f331f203ed5596e4f4e`
- endpoint: `https://sqladmin.googleapis.com`

Cloud SQL v1 is the provider contract. Ziac does not fall back to v1beta4.
Discovery upgrades must pass the existing semantic source-diff gate.

## Typed Resource Layer

### `gcp.sql.Instance`

Owns one PostgreSQL primary instance. Typed inputs cover version, edition,
region, tier, availability, disk, backup/PITR, maintenance, deletion
protection, database flags, connector enforcement, SSL mode, public/private IP,
authorized networks, allocated range and Google private path. Outputs expose
the canonical connection name, public/private addresses, server CA and state.

Database version and region are replacement fields. Removing private IP after
adoption is rejected because the API contract says private network cannot be
removed. Allocated range is create-only. Public authorized networks require
public IPv4 and are forbidden when connectors are required.

### `gcp.sql.ReadReplica`

Owns a replica instance with an explicit primary output dependency. It shares
the safe compute/network settings but rejects an allocated range and database
objects. The API `masterInstanceName` field makes replica identity explicit.

### `gcp.sql.Database`

Owns one logical database under an instance. Charset and collation are typed,
canonicalized and retained by default. Deletion requires both lifecycle opt-in
and destructive authority.

### `gcp.sql.User`

Owns one built-in or IAM database principal. Built-in users require a secret
reference for their password; the provider resolves it only at mutation time,
zeroes payload buffers and never copies the plaintext into desired inputs,
observed state, diagnostics or artifacts. IAM users reject passwords and pair
with explicit project-level `roles/cloudsql.instanceUser` grants in the
high-level component.

### `gcp.sql.ClientCertificate`

Creates one client certificate and writes its one-time private key directly to
a declared Secret Manager secret. State contains public certificate metadata
and a secret reference to the created version, never PEM private-key bytes.
Certificates are replace-only and deletion uses the SHA-1 fingerprint returned
by Google.

## Lifecycle Layer

All mutating SQL Admin calls return Operations. The adapter stores an operation
handle before polling `operations.get`, resumes it after interruption, handles
DONE errors, and performs a final read of the resource. Create and delete are
idempotent around 404/409 boundaries.

Instance updates use PATCH with the latest settings version as an optimistic
precondition. Remote normalization drops output-only fields and canonicalizes
database flags, authorized networks and IP addresses before drift comparison.
Instance and replica imports accept either an instance ID or
`projects/<project>/instances/<instance>` and store the API's canonical ID.

Databases and users use their documented instance-scoped paths. User GET and
DELETE include type/host query identity where needed. Password drift cannot be
read from Google, so Ziac rotates only when the secret reference changes.

Client certificate creation redacts response bodies from diagnostics, extracts
the private key into a zeroed buffer, adds one Secret Manager version, then
stores only the returned secret reference. Failure after certificate creation
is surfaced as partial state with the operation/certificate identity available
for recovery.

## Private Connectivity Boundary

Cloud SQL private IP requires Private Services Access on the selected VPC.
`Instance` accepts a canonical network and allocated range, but does not imply
that the service-networking connection exists. A graph dependency must point to
an existing managed or referenced connection. M66/M71 provide the broader
Service Networking primitives; M65 qualification may consume a pre-existing
disposable connection. This avoids a hidden cross-project peering mutation.

## High-Level Component

`ziac.gcp.ManagedPostgres` composes:

- one protected, retained regional primary;
- zero or more read replicas;
- declared databases;
- built-in users backed by existing secret references;
- IAM users plus exact project `roles/cloudsql.instanceUser` and optional
  `roles/cloudsql.client` members;
- an optional Secret Manager-backed client certificate.

It returns typed instance connection name, database names, user names, replica
connection names and client-certificate secret reference. It does not generate
passwords, create undeclared networks or grant broad admin roles.

## Intelligence, Estate, Canvas And Cost

Graph synthesis enables `sqladmin.googleapis.com` and derives operation-level
`cloudsql.instances`, `cloudsql.databases`, `cloudsql.users` and
`cloudsql.sslCerts` permissions. Runtime IAM edges distinguish login from proxy
connectivity. Cloud Asset Inventory maps SQL instances to canonical managed
identity; child SQL Admin resources remain managed-only where Asset Inventory
does not provide a compatible type.

The visual artifact exposes engine/version, edition, HA, primary/replica role,
private/public connectivity, database/user counts, backup/PITR and TLS mode.
Cost estimates keep vCPU/RAM instance hours, storage GiB-month, backup
GiB-month and egress assumptions explicit and never label them billed cost.

## Qualification

The deterministic gate proves declaration validation, CRUD request shape,
operation resume, semantic drift, apply/import/refreshed no-op, lifecycle-only
unprotect and retention-aware cleanup. The authenticated runner requires ADC,
a project ending in `-ziac-disposable`, an existing private-services connection
when private IP is selected, and explicit cleanup configuration. It probes a
real PostgreSQL connection without printing credentials and emits exit 77 when
credentials or configuration are absent.

## Non-Goals

- MySQL and SQL Server opinionated components in M65. The low-level instance
  model remains forward-compatible but M65 qualification is PostgreSQL.
- Backup runs, restore actions, clone/failover/promote actions or SQL import.
  These are governed actions, not desired-state resources.
- Automatic Private Services Access creation inside an instance mutation.
- Persisting password or client private-key plaintext.

## Acceptance Gate

An end-user project can declare, plan, apply, import, observe, visualize and
cost a protected PostgreSQL primary with database, users, private networking,
TLS policy and replicas. Secret values never enter ordinary state or artifacts,
and a disposable-project receipt remains the only claim of live qualification.
