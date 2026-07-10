# Ziac Compute Load-Balancer Resources

`gcp.compute` contains the raw resources used by the first global external
Application Load Balancer:

- `GlobalAddress`;
- `RegionServerlessNeg`;
- `BackendService`;
- `UrlMap`;
- `TargetHttpsProxy`;
- `GlobalForwardingRule`.

Global resources require Premium network tier. Backend declarations reject
duplicate regions because a global backend service can attach at most one
serverless NEG per region. A regional NEG retains both region and Cloud Run
service identity so the provider can encode the `SERVERLESS` endpoint type.

## Lifecycle

The Compute handler selects the correct collection and global or regional
operation scope from the resource type. Create and mutable updates return
checkpointable operation handles. Reads with a tracked handle poll the original
operation before fetching normalized remote state. Deletes poll synchronously,
and import reads the supplied physical identifier.

Addresses, NEGs, and forwarding rules classify managed changes as replacement.
Backend services, URL maps, and HTTPS proxies update in place when project and
name are unchanged.

## Optimistic Concurrency

Mutable updates refetch the full remote resource, overlay only fields managed by
Ziac, retain the provider fingerprint and unknown configuration, and send the
appropriate Compute method:

- backend service full update with `PUT`;
- URL map and target HTTPS proxy merge patch with `PATCH`.

A `412 conditionNotMet` maps to Ziac conflict. The handler performs a bounded
refetch and retry, using the new fingerprint while preserving unrelated remote
fields. Scripted tests verify both request bodies.

## Outputs

Every resource emits `self_link`. Global addresses also emit `address`, global
forwarding rules emit `ip_address`, and mutable fingerprinted resources retain a
provider `fingerprint` output for diagnostics and state inspection.
