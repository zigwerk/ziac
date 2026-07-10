# ZigService

`ziac.gcp.global.ZigService` is Ziac's source-to-global-service component. It
accepts a Zig source directory and typed application bindings, then assembles
the build, identity, regional Cloud Run, global HTTPS, and optional DNS graph.
The application supplies no Dockerfile and no raw load-balancer resources.

## Static Contract

The component is specialized with three comptime types:

```zig
const Providers = ziac.stack.ProviderSet(.{ziac.resource.ProviderId.gcp});

const App = struct {
    pub const Env = struct {
        release: ziac.binding.Value([]const u8),
        database_url: ziac.binding.Secret([]const u8),
    };
};

const Bindings = struct {
    release: ziac.PublicOutput([]const u8),
    database_url: ziac.Output(ziac.value.SecretReference, .secret),
};

const Service = ziac.gcp.global.ZigService(App, Bindings, Providers);
```

Instantiation fails at compile time when `App.Env` is absent, GCP is not in the
provider set, a binding is missing or extra, its public/secret class differs, or
its value type cannot be represented as a Cloud Run environment variable.
Environment field names become uppercase variables, for example
`database_url` becomes `DATABASE_URL`.

## Resource Graph

One component creates or composes:

- required GCP API services, retained on destroy;
- separate build and runtime service accounts;
- Artifact Registry writer, Storage object viewer, and Logs writer build IAM;
- a retained regional Docker repository;
- a protected, lifecycle-managed build bucket and content-addressed source
  object;
- a regional Cloud Build whose output is an immutable image digest;
- Secret Manager accessor IAM for each unique runtime secret;
- one Cloud Run service per configured region;
- serverless NEGs, Premium global backend, URL maps, managed certificate,
  HTTPS proxy, and global forwarding rule;
- optional Cloud DNS A record and HTTP-to-HTTPS redirect.

Image, secret, network, address, and certificate values remain typed output
references. The graph derives their dependencies automatically. No secret
plaintext enters desired inputs, state, plans, build archives, or diagnostics.

## Build Contract

Ziac collects source through the deterministic archive implementation. Entries
are sorted and have normalized time, ownership, and modes. Symlinks are rejected
by default. VCS data, Ziac state, Zig caches, environment files, private keys,
and secret directories are always excluded; `.ziacignore` may add exclusions
but cannot negate mandatory ones.

`Dockerfile.ziac` is injected into the archive. The default recipe:

- pins Zig 0.15.2 and verifies the official architecture checksum;
- supports x86_64 and aarch64 Linux musl outputs;
- builds `ReleaseSafe` through the source package's `install` step;
- copies only the selected executable into a pinned distroless static image;
- runs as `nonroot:nonroot` on port 8080.

The build digest covers the source archive digest, generated recipe bytes, and
pinned Cloud Build Docker builder. GCS uses generation-zero creation and local
SHA-256, CRC32C, and size preflight. A repeated source build is adopted by
digest; changed source creates a new immutable image identity.

## Source Lifetime

`Source.root` is a borrowed `std.Io.Dir`. Keep it open until apply completes.
Ziac hashes the directory while building the graph, then regenerates the same
archive at provider execution so source bytes stay out of state. If files
change between planning and apply, the source object integrity preflight fails
instead of uploading bytes under the old digest.

## Secrets

Secret bindings may be typed outputs from `gcp.secret.SecretVersion` or known
GCP Secret Manager references in the current project. Foreign secret providers,
cross-project paths, output fields with the wrong producer type, and inline
secret strings fail before a Cloud Run request. The component grants the
runtime service account `roles/secretmanager.secretAccessor` once per unique
secret and orders each regional service after that IAM binding.

## Health And Runtime

The default startup and liveness paths are `/health/startup` and
`/health/live`. The sample backend at `examples/zig-service-app` implements
both. Override probes, CPU, memory, concurrency, timeout, instance bounds,
Direct VPC, regional subnets, DNS, and redirect behavior through `Service.Args`.

Run the complete local proof with:

```sh
cd packages/ziac
zig build examples
zig build container-e2e-all
```

The second command builds and probes both amd64 and arm64 images using the exact
generated recipe fixture. Authenticated deployment additionally requires the
live GCP project, regions, domain, DNS zone, and credentials described in
`docs/live-gcp.md`.
