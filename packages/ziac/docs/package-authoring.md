# Ziac Component Package Authoring

Component packages compile typed inputs into ordinary Ziac resources and typed
outputs. They are reusable libraries, not provider plugins.

## Package Shape

An independent component package contains:

```text
build.zig
build.zig.zon
ziac.package.json
src/root.zig
test/root_test.zig
```

Import only the public `ziac` module. Do not import provider transport, token,
state or internal source paths.

## Manifest

Declare the exact component entry, providers and concrete resource types:

```json
{
  "schema": "ziac.package.v1",
  "name": "acme/asset-site",
  "version": "1.0.0",
  "kind": "component",
  "summary": "A governed static asset site",
  "license": "Apache-2.0",
  "source": "https://github.com/acme/ziac-asset-site",
  "entry": "src/root.zig",
  "compatibility": {
    "ziac": ">=0.1.0 <0.2.0",
    "zig": ">=0.16.0 <0.17.0"
  },
  "providers": ["gcp"],
  "resource_types": ["gcp.storage.Bucket"],
  "maturity": "preview"
}
```

Run `ziac package verify .` before publishing.

## Expansion Contract

Define a `ziac.component.Descriptor` with the same package identity and declared
surface. Record the graph length before expansion, build resources through
public Ziac APIs, then stamp only the new range. Return typed outputs rather
than requiring callers to know internal resource IDs.

Components must be deterministic for the same typed input. They must not read
ambient credentials, mutate the filesystem, call cloud APIs, create hidden
state or inspect secret values.

## Tests

Use the Testing v2 runner and prove:

- exact concrete resource types and dependency edges;
- typed output wiring and secrecy;
- deterministic component provenance;
- no provider or state authority is imported;
- invalid input fails before graph mutation;
- descriptor declarations cover every emitted type; and
- the package compiles from outside the Ziac source checkout.

Authenticated cloud qualification is an additional tier, never a replacement
for deterministic expansion tests.

## Contribution Paths

Community components can publish independently and later submit immutable
registry metadata. New cloud CRUD behavior belongs in a reviewed `ziac-gcp`
change with provider lifecycle and conformance evidence, not in a component.
