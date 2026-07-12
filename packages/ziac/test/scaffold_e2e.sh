#!/usr/bin/env bash
set -euo pipefail

ziac_bin="$1"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package_dir="$(cd "${script_dir}/.." && pwd)"
workspace="$(mktemp -d "${TMPDIR:-/tmp}/ziac-scaffold-e2e.XXXXXX")"
trap 'rm -rf "${workspace}"' EXIT

"${ziac_bin}" init global-api --dir "${workspace}/global-api" --ziac-path "${package_dir}"
cd "${workspace}/global-api"
zig build test --summary failures
zig build ziac-program -- --stack global-api --stage dev > program.json
grep -Fq '"schema":"ziac.program.v1"' program.json
"${ziac_bin}" check --stack global-api --stage dev --json > check.json
grep -Fq '"status":"valid"' check.json
"${ziac_bin}" plan --stack global-api --stage dev --json > plan.json
grep -Fq '"stack":"global-api"' plan.json
grep -Eq '"create":[1-9][0-9]*' plan.json
"${ziac_bin}" deploy --stack global-api --stage dev --json > deploy.json
grep -Fq '"status":"success"' deploy.json
"${ziac_bin}" plan --stack global-api --stage dev --json > noop.json
grep -Fq '"create":0' noop.json
grep -Fq '"update":0' noop.json
grep -Fq '"delete":0' noop.json
grep -Eq '"noop":[1-9][0-9]*' noop.json
"${ziac_bin}" dashboard --stack global-api --stage dev --artifact-only --out dashboard.json > dashboard-receipt.json
grep -Fq '"status":"ready"' dashboard-receipt.json
grep -Fq '"schema":"ziac.visual.v1"' dashboard.json
