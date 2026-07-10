# Ziac Google REST Client

Ziac provider resources use one authenticated JSON client rather than issuing
raw HTTP requests. The client composes native ADC, the shared zigeffect-std HTTP
transport, Ziac operation contexts, and the provider error taxonomy.

## API Endpoints

`gcp.client.Endpoints` owns the base URL selection for Service Usage, IAM,
Artifact Registry, Cloud Run, Compute, Cloud DNS, and Secret Manager. Production
defaults point at Google APIs; tests can replace one or all roots with scripted
servers. Resource implementations pass an API family and relative path, while
operation polling can pass a previously constructed absolute URL.

Every request includes:

- the cached ADC token as `Authorization`;
- JSON `Accept` and `Content-Type` headers;
- stable `User-Agent` and `X-Goog-Api-Client` values.

Token and authorization buffers are owned for the request and zeroed before
release. `TokenCache` uses short locked sections for concurrent reads and token
replacement; network refreshes never run while holding its spin lock.

## Errors And Diagnostics

HTTP and Google error envelopes map to Ziac `ProviderError` categories:

- unauthenticated and permission denied;
- invalid configuration, not found, and conflict;
- quota exhaustion and rate limiting;
- transient service failure;
- timeout, cancellation, and provider defects.

Each call receives its own `Diagnostic`, so concurrent resources do not share a
mutable last-error slot. Diagnostics retain owned request IDs, Google status,
redacted message, HTTP status, and parsed `Retry-After` delay. Credential values
and sentinel-shaped secrets never survive redaction.

## Long-Running Operations

`gcp.operation.Target` supports:

- generic Google long-running operations used by Cloud Run and Service Usage;
- Compute global operations;
- Compute regional operations.

The poller checks the provider deadline and cancellation token before every
request, sleeps through the operation context's clock, retries bounded transient
or rate-limit failures, and honors `Retry-After`. `waitWithDiagnosticAlloc`
retains the final per-operation diagnostic for provider receipts; `waitAlloc`
is the convenience form when the caller only needs the terminal payload.
