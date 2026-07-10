# Ziac ZigService Design

**Date:** 2026-07-10
**Roadmap:** Ziac E2E Milestone M7

## Objective

Make one typed Ziac component take a Zig application directory to an immutable
Artifact Registry image and a globally routed multi-region Cloud Run service.
The caller supplies Zig source, an application type with `Env`, typed bindings,
and deployment policy. The caller does not write a Dockerfile, Cloud Build
configuration, regional Cloud Run resources, or load-balancer resources.

## Constraints

- Source and build inputs must be deterministic and content addressed.
- Source archives must never include local Ziac state, VCS metadata, build
  caches, environment files, private keys, or conventional secret directories.
- Symlinks are never followed. The default policy rejects them so an archive
  cannot escape its declared root.
- Every container image used to build or run the application is pinned by
  digest. Zig release downloads are pinned by version and SHA-256.
- Cloud Build consumes a generation-pinned GCS object and returns the pushed
  Artifact Registry digest. Cloud Run consumes that immutable digest, not a tag.
- Archive bytes, credentials, and secret values are not persisted in Ziac
  desired state. State contains paths, hashes, object generations, build IDs,
  log links, and immutable image references only.
- All mutations remain behind the existing explicit live-provider safety gate.

## Source Archive

`build/source_archive.zig` accepts an open root directory, `std.Io`, limits,
optional `.ziacignore` rules, and optional generated files. It returns owned
gzip-compressed tar bytes, a lowercase SHA-256 digest, and an ordered manifest.

The implementation gathers entries before writing, normalizes separators to
`/`, rejects absolute or parent-traversing paths, filters ignored paths, and
sorts by bytewise path. Only regular files enter the archive. Empty directories
therefore do not change the build digest. Tar ownership is zeroed, modification
time is zero, and mode is normalized to `0644` or `0755` according to the source
executable bit. Zig's gzip writer emits a zero timestamp.

Built-in exclusions are mandatory:

- `.git`, `.zig-cache`, `zig-out`, and `.ziac` trees;
- `.env`, `.env.*`, `*.pem`, and `*.key` files; and
- `secrets` and `.secrets` directories at any depth.

`.ziacignore` adds root-relative glob rules. `*` and `?` do not cross `/`; `**`
does. A trailing `/` matches a directory tree. Blank lines and comments are
ignored. Negation is rejected instead of pretending to implement full
`.gitignore` precedence. Generated paths participate in the same ordering,
collision, size, and traversal checks but cannot override mandatory exclusions.

## Cloud Storage Context

The GCP build layer owns a regional, uniform-access source bucket and one
content-addressed object per archive:

```text
ziac-builds-<project-hash>/<stack>/<source-sha256>.tar.gz
```

The bucket uses public-access prevention and lifecycle cleanup for old source
objects. Object creation uses `ifGenerationMatch=0`. A conflict triggers a GET;
an existing object is adopted only when its metadata digest and size match.
The provider recomputes the archive at apply time and requires the declared
digest before upload, closing the plan/apply source-change race. The archive
payload is supplied through an injected local source reader, never through
serialized resource inputs.

## Cloud Build

`gcp.cloud_build.ZigImage` references the bucket, object, object generation,
repository URL, source digest, and build recipe digest. Its regional Cloud Build
request uses a generation-pinned `storageSource`, a digest-pinned Docker builder,
an immutable source-derived image tag, explicit timeout/logging settings, and
the `images` field so Cloud Build records the pushed digest.

Ziac generates `Dockerfile.ziac` in memory. Its build stage downloads the pinned
Zig toolchain, verifies the toolchain SHA-256, compiles a static Linux binary in
release-safe mode, and copies it into a digest-pinned non-root distroless image.
The application binary name and build step are validated identifiers, not shell
fragments.

Create stores the returned build ID as an operation handle. Read/resume polls
`projects/{project}/locations/{region}/builds/{id}`. Pending states remain
incomplete; `SUCCESS` requires exactly one matching `results.images` entry and
returns `<repository>/<image>@sha256:...`. Failure status, bounded redacted
detail, and the console log URL are surfaced without fetching unbounded logs.
The source/build digest identity makes unchanged builds a normal refresh/noop.

## ZigService

`gcp.global.ZigService` composes:

1. required project APIs;
2. a regional Artifact Registry Docker repository;
3. the protected build-context bucket;
4. deterministic source archive and generated build recipe;
5. the GCS source object;
6. the regional Cloud Build image; and
7. `ContainerService` using the immutable image output.

The component accepts an application type and a binding struct. It invokes the
existing comptime application/binding/provider contracts before constructing
resources. Bindings are lowered into Cloud Run environment and Secret Manager
volume declarations without exposing secret values. The application defaults
to port `8080`, startup path `/health/startup`, and liveness path `/health/live`;
production deployments require warm instances and both probes through the
existing `ContainerService` policy.

Source digest changes replace the object/build identity and update every
regional Cloud Run service through the image output edge. Reverting to a prior
digest reuses the content-addressed object and can adopt the prior immutable
image when the build result is already in state or refreshable from Cloud Build.

## Failure And Recovery

- Source changes between planning and upload fail before network mutation.
- Existing object conflicts are read and validated rather than overwritten.
- Interrupted Cloud Build creation resumes from the persisted build ID.
- Build terminal failures never produce an image output.
- Cloud Run cannot execute until the image digest is available.
- Destroy removes application resources and build records first. Immutable
  source objects and repositories use explicit retention policy so recovery and
  rollback are not accidentally destroyed.

## Verification Boundary

Automated tests cover archive determinism and exclusion, exact Storage and Cloud
Build requests, operation resume and failure, digest extraction, graph ordering,
comptime bindings, source-change propagation, and the no-Dockerfile public API.
Docker integration builds and runs the sample locally on both supported target
architectures where available.

The authenticated gate separately requires a disposable GCP project, bucket,
domain, two regions, and Cockroach Cloud credentials. It builds from a clean
checkout, deploys, probes HTTPS and SQL regionally, changes and reverts source,
rotates the SQL password, verifies noop/reuse behavior, and destroys application
resources while retaining the protected Cockroach cluster.
