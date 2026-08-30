# Contributing to Zigwerk Projects

Thank you for helping improve Zigwerk software.

## Before You Start

1. Read the target repository's `README.md`, `AGENTS.md` and package-specific
   contribution notes.
2. Search existing issues and discussions.
3. Open an issue before substantial API, architecture or compatibility work.
4. Keep changes scoped to one coherent outcome.

## Engineering Standard

- Add a failing deterministic test before changing behaviour.
- Preserve typed errors, bounded resources and explicit effect boundaries.
- Do not record credentials, personal data or raw payloads in logs, traces or
  causal evidence.
- Run the repository's complete required checks and include the exact result in
  the pull request.
- Update public documentation and migration guidance when changing contracts.

Generated code must name its source contract and generator. Vendored source
must retain its upstream licence and notice.

## Pull Requests

Explain the problem, the chosen design, tests run and any remaining limitation.
Small reviewable pull requests are preferred. Maintainers may ask for a design
note before accepting changes with broad API or operational impact.

By contributing, you agree that your contribution is licensed under the
repository's Apache License 2.0.

