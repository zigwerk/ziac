# Ziac Testing V2 Qualification Design

Date: 2026-07-11

Status: validated for implementation

## Objective

Every Ziac Zig test artifact must publish a fail-closed ZigEffect Testing v2
suite receipt. A successful process exit without complete receipt evidence is
not accepted as a passing milestone gate.

## Design

The existing ZigEffect dependency owns the server-mode test runner. ZigEffect
exports it as `zigeffect_test_runner`; `zigeffect-std` re-exports the same
runner module; Ziac resolves that module from its existing dependency and uses
it for the package suite and every example test artifact.

The runner preserves ordinary `std.testing` assertions while recording stable
test identities, discovered and executed counts, pass/skip/fail/pending counts,
log errors, leaks, execution metadata, duration, and an exact replay command.
Receipts are written atomically below `.zigeffect/tests/suites`.

## Acceptance

- `zig build test` writes a complete `ziac-tests` receipt.
- Discovered and executed counts match.
- Pending, failed, leaked, and error-logging counts are zero.
- Every Ziac `b.addTest` artifact selects the server runner.
- Missing or malformed receipts fail the release evidence gate.
