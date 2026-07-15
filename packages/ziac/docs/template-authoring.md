# Ziac Template Authoring

A template is an editable Ziac project source tree. It is appropriate when the
starting product includes application code, project intent, environment
structure, CI or several components.

## Package Shape

```text
ziac.package.json
files/
  build.zig
  build.zig.zon
  ziac.project.json
  ziac.stack.zig
  ziac_program.zig
  src/main.zig
```

The manifest kind is `template` and its entry is `files`.

## Render Tokens

The local renderer supports only:

- `{{project_name}}`
- `{{zig_package_name}}`
- `{{package_fingerprint}}`
- `{{ziac_path}}`
- `{{ziac_gcpx_path}}`

Path tokens are already JSON-escaped strings suitable for `build.zig.zon`.
Unknown tokens fail initialization. Do not add shell interpolation, install
hooks, generated credentials or machine-specific absolute paths.

## User Ownership

Initialization renders files and stops. It does not execute the generated
project, contact GCP or retain template mutation authority. The user reviews
ordinary Zig source and then runs check, plan and apply through the normal Ziac
authority boundary.

## Qualification

An official or verified template must pass from a clean Git directory using an
installed prefix:

```sh
ziac init example --template template-id --dir . --yes
zig build test --summary failures
zig build ziac-program -- --stack declared-stack --stage dev
ziac check --stack declared-stack --stage dev --json
```

Assert the expected resources, outputs and component provenance in the emitted
program. Cloud-qualified templates also require a current authenticated create,
health, update, no-op and cleanup receipt for their declared environment.

## Publishing

Pin source and manifest digests. Describe ownership, compatibility, resource
types, permissions, expected cost shape, destructive behavior and cleanup.
Registry acceptance never grants provider credentials or converts a template
into a provider support claim.
