# Ziac CockroachDB Cloud Client

Ziac's CockroachDB Cloud client is a native Zig client for the Cloud API surface
needed by the provider. It shares the owned zigeffect-std transport and Ziac
provider operation context used by Google resources.

## Version And Authentication

The client pins the current v1 date contract:

```text
Cc-Version: 2024-09-16
```

The default API root is `https://cockroachlabs.cloud/api`; tests and private
proxies can inject another root. Every request sends the configured service
account secret key as a bearer token and includes JSON content negotiation.

`ApiKey.fromEnvAlloc` copies a named environment value into owned memory. The
owned key, temporary authorization headers, SQL passwords, and API-key request
bodies are zeroed or redacted before release and never appear in diagnostics.

## Errors And Rate Limits

Cockroach authentication and authorization failures map separately to Ziac's
`AuthenticationFailed` and `AuthorizationFailed` errors. Invalid requests,
missing resources, conflicts, rate limits, provider timeouts, and transient
service failures retain their own provider categories.

Per-request diagnostics own the response status, request ID, redacted message,
and parsed `Retry-After` delay. Idempotent typed reads use a bounded retry path;
rate-limit delays override the configured fallback delay through the provider
context's clock, so cancellation and deadlines remain deterministic in tests.

## Typed Resources

The initial typed response surface includes:

- cluster identity, name, cloud provider, plan, state, and cluster SQL DNS;
- regional public SQL, internal, Private Service Connect, and Console DNS
  endpoints, node count, and primary-region metadata;
- SQL-user names and `pagination.next_page`.

The mutable cluster surface emits exact GCP Basic, Standard, and Advanced create
and update schemas, including string-encoded usage limits and remote deletion
protection. Serverless creates always request an empty IP allowlist. Cluster
delete treats `404` as converged and remains gated by the managed resource's
local, remote, and explicit-confirmation checks.

Unknown response fields are ignored to preserve forward compatibility within
the pinned API version. Returned clusters, users, page tokens, headers, and
bodies are all owned.

`listAllSqlUsersAlloc` preserves server order, percent-encodes opaque page
tokens, rejects a repeated token, and stops at a configurable page ceiling. This
prevents malformed responses from creating an unbounded provider loop.
