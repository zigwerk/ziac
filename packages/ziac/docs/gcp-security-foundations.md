# GCP Security Foundations

Ziac manages Security Command Center configuration, Binary Authorization trust
and Certificate Authority Service as one typed security-platform surface. The
provider separates repeatable desired state from high-consequence security
actions: an ordinary plan cannot revoke a certificate or change a CA's enabled,
disabled or deleted state.

## Managed Resources

| Ziac type | Google API | Lifecycle |
| --- | --- | --- |
| `gcp.securitycenter.Source` | Security Command Center v2 | Permanent source; list discovery; never deleted |
| `gcp.securitycenter.NotificationConfig` | Security Command Center v2 | Regional CRUD with exact update mask |
| `gcp.securitycenter.MuteConfig` | Security Command Center v2 | Static or expiring dynamic mute policy |
| `gcp.securitycenter.BigQueryExport` | Security Command Center v2 | Retained export with generated principal |
| `gcp.securitycenter.ResourceValueConfig` | Security Command Center v2 | Typed batch-created resource-value policy |
| `gcp.binaryauthorization.Policy` | Binary Authorization v1 | Project singleton; etag-safe full replacement |
| `gcp.binaryauthorization.Attestor` | Binary Authorization v1 | Immutable note identity; etag-safe key update |
| `gcp.binaryauthorization.AttestorIamMember` | Binary Authorization v1 | Additive conditional IAM |
| `gcp.privateca.CaPool` | Private CA v1 | Resumable; immutable tier; retained by default |
| `gcp.privateca.CertificateAuthority` | Private CA v1 | Resumable; retained; state changes are actions |
| `gcp.privateca.CertificateTemplate` | Private CA v1 | Resumable; immutable issuance constraints |
| `gcp.privateca.Certificate` | Private CA v1 | Issued identity is retained; revocation is an action |
| `gcp.privateca.CaPoolIamMember` | Private CA v1 | Additive conditional IAM |
| `gcp.privateca.CertificateTemplateIamMember` | Private CA v1 | Additive conditional IAM |

The provider catalog pins the dated Discovery documents and SHA-256 digests for
all three APIs. Contract upgrades must produce a semantic diff before the pins
move.

## Opinionated Layer

`SecurityFindingPipeline` composes SCC notification and BigQuery routes and can
optionally install typed mute and resource-value rules. `TrustedArtifactPolicy`
composes an attestor, exact verifier IAM and project admission policy.
`PrivateCertificateAuthority` composes a retained CA pool, root authority,
workload certificate template and least-privilege requester IAM.

```zig
var admission = try ziac.gcp.TrustedArtifactPolicy.build(allocator, provider, .{
    .name = "runtime",
    .project = ziac.PublicOutput([]const u8).known("projects/security-prod"),
    .note = ziac.PublicOutput([]const u8).known(
        "projects/security-prod/notes/release-attestations",
    ),
    .public_keys = &.{.{
        .id = "https://security.example/keys/release",
        .key = .{ .pkix = .{
            .public_key_pem = public_key_pem,
            .signature_algorithm = .ecdsa_p256_sha256,
        } },
    }},
    .verifier_members = &.{runtime_service_account},
});
defer admission.deinit();
```

Pass `base_graph` to merge the three components into one statically validated
security graph. The complete compilable example is
`examples/security_foundation.zig`.

## Lifecycle And Authority

- Binary Authorization policy updates include the observed etag; an ordinary
  delete restores only a declared safe baseline.
- Attestor and CA IAM perform bounded policy-version-3 read/modify/write and
  preserve unrelated bindings.
- Private CA long-running operations are checkpointed and resumable.
- Certificates never contain private key material in Ziac state or artifacts.
- CA enable, disable, soft-delete and undelete, plus certificate revocation,
  require a payload-bound capability digest and emit a governed receipt.
- Retained declarations and explicit destructive authority are separate gates.

Permission synthesis reports exact SCC, Binary Authorization and Private CA
deployer permissions plus runtime attestor-verification and certificate-request
permissions. The 3D canvas names finding routes, admission trust, CA pools,
issuers, templates and runtime IAM relationships.

## Import And Cost

Cloud Asset Inventory maps supported official asset names to the same canonical
physical identities used by managed state. IAM member resources remain Ziac
policy projections rather than pretending to be independent Google assets.

Binary Authorization configuration is reported as zero direct management cost.
Security Command Center cost requires an explicit tier/subscription SKU, and
Private CA estimates require active-CA months and certificate issuance counts.
Without those assumptions or connected billing export, the dashboard reports
cost as unavailable rather than inventing usage.

## Qualification

The deterministic receipt is
`ziac.gcp.security-foundation-qualification.v1`. It proves the merged graph and
visual digests, exact deployer/runtime authority, create/import/no-op counts,
retention, resumable operations, finding routes, admission policy, private trust
topology and governed action boundaries. It always records
`authenticated=false` and keeps estimated cost null without observed usage.

`scripts/qualify-security-foundation.sh` is the separate live boundary. It
requires ADC, a project ending in `-ziac-disposable`, explicit SCC, attestor and
CA probe identities, and the exact confirmation
`QUALIFY_DISPOSABLE_SECURITY_FOUNDATION`. Missing prerequisites produce a
structured exit-77 skip. The runner applies a user-owned stack, probes each
service, imports all state into a second stage and requires a no-op plan. It
does not enable, disable, delete or undelete a CA and never revokes a
certificate.
