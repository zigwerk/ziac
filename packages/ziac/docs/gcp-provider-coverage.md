# GCP Provider Coverage

Ziac is a broad Google Cloud infrastructure provider with additional
Google-native architecture components. Cloud Run and global routing are a
specialization, not a limit on the resources Ziac intends to manage.

## Coverage Stages

- `planned`: owned by a named roadmap milestone but not yet declarable.
- `contract`: typed Google API contract exists, but lifecycle support is not
  complete.
- `managed`: declaration and deterministic provider lifecycle tests pass.
- `qualified`: an authenticated disposable-project lifecycle receipt also
  passes.

Use `gcp.coverage.resources` as the machine-readable contract for the installed
version. Observed Cloud Asset Inventory kinds do not count as managed resources.

## Managed Surface

The current deterministic provider gate contains 34 managed GCP resource types.
Authenticated qualification remains separate and is tracked in the roadmap.

### Foundation and identity

- `gcp.project.Service`
- `gcp.iam.ServiceAccount`
- `gcp.iam.ProjectMember`
- `gcp.artifact.Repository`
- `gcp.secret.Secret`
- `gcp.secret.SecretVersion`
- `gcp.secret.SecretIamMember`

### Cloud Run and builds

- `gcp.run.Service`
- `gcp.cloudbuild.ZigImage`
- `gcp.storage.BuildBucket`
- `gcp.storage.SourceObject`

### General Cloud Storage

- `gcp.storage.Bucket`
- `gcp.storage.BucketIamMember`

`Bucket` currently covers location, storage class, uniform bucket-level access,
public-access prevention, versioning, soft-delete retention, bucket retention,
a single delete TTL, labels, default CMEK, retained/deletable lifecycle,
metageneration-safe updates and `buckets/` or `gs://` import. `BucketIamMember`
owns one additive role/member relationship and preserves unrelated policy
bindings and members through etag-safe read-modify-write.

Multi-rule lifecycle policy, CORS, IAM conditions, general objects, cost
attribution, visual detail and authenticated qualification remain open M57
items. The specialized `BuildBucket` remains retained and content-addressed.

### Networking and global delivery

- `gcp.compute.Network`
- `gcp.compute.Subnetwork`
- `gcp.compute.Router`
- `gcp.compute.RouterNat`
- `gcp.compute.RegionalAddress`
- `gcp.compute.PscAddress`
- `gcp.compute.PscEndpoint`
- `gcp.compute.GlobalAddress`
- `gcp.compute.RegionServerlessNeg`
- `gcp.compute.BackendService`
- `gcp.compute.UrlMap`
- `gcp.compute.HttpRedirectUrlMap`
- `gcp.compute.ManagedSslCertificate`
- `gcp.compute.TargetHttpProxy`
- `gcp.compute.TargetHttpsProxy`
- `gcp.compute.GlobalForwardingRule`
- `gcp.dns.ManagedZone`
- `gcp.dns.RecordSet`

### Security and orchestration

- `gcp.kms.KeyRing`
- `gcp.kms.CryptoKey`
- `gcp.scheduler.Job`

## Next Application-Platform Tranche

M56-M62 adds the provider catalog and generation spine, then completes:

1. general Cloud Storage;
2. Pub/Sub topics, schemas, subscriptions, snapshots and IAM;
3. Cloud Tasks queues and Eventarc triggers;
4. Cloud Run jobs and worker pools;
5. general additive and authoritative IAM semantics;
6. one integrated authenticated application-platform qualification.

The subsequent waves cover BigQuery, Firestore, Cloud SQL, Spanner,
Memorystore, Compute Engine, GKE, broader networking, Cloud Armor, Certificate
Manager, Monitoring, Logging, Cloud Build/Deploy, organization governance,
security, analytics, integration and stable Vertex AI resources.

See `roadmap.md` for programme status. The source repository also contains the
full design and checklist at:

- `docs/superpowers/specs/2026-07-13-ziac-gcp-provider-coverage-design.md`
- `docs/superpowers/plans/2026-07-13-ziac-gcp-provider-coverage.md`

## Resource Definition Of Done

A complete resource has typed declarations and outputs, canonical identity,
deterministic CRUD/diff/refresh, import and no-op adoption, normalized server
defaults, compare-and-swap behavior, API/IAM preflight, estate identity, canvas
semantics, honest cost provenance, installed agent documentation and an
authenticated disposable-project receipt.

The first ten local capabilities establish `managed`. Authenticated evidence
establishes `qualified`.
