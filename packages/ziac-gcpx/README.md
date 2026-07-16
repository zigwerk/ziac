# Ziac GCpx

`ziac-gcpx` is Ziac's official opinionated Google Cloud component package. A
component compiles product-shaped intent into ordinary `ziac` GCP resources and
typed outputs. It does not implement provider CRUD or receive cloud credentials.

Use `AssetBucket` for a versioned, retained bucket and IAM graph. Use
`HermesDesktop` for a low-cost Hermes Agent backend that a desktop client can
reach through an OAuth-gated TLS endpoint.

Every generated resource retains its real GCP type and receives component
provenance for plans and the local canvas.

`ziac-gcpx` deliberately remains a pure typed graph compiler. It does not own
a process runtime, provider client, credential, or causal database. Effectful
Ziac applications call these components while constructing desired
infrastructure, then run state and provider boundaries through their canonical
ZigEffect services and managed runtime. This separation keeps component output
deterministic and makes runtime causality describe actual external work.
